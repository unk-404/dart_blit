/// Standardized async random-access file for v0.2.0.
library;

import 'dart:async';
import 'dart:typed_data';

import 'address_io.dart';
import 'async_io.dart';
import 'bytes_file.dart';
import 'cancel.dart';
import 'errors.dart';
import 'backend/open_backend.dart';
import 'options.dart';
import '../unsafe/bytes.dart';

/// One read request for [AsyncFile.readMany].
final class ReadRequest {
  ReadRequest(this.offset, this.dst);
  final int offset;
  final ReadBuf dst;
}

/// One write request for [AsyncFile.writeMany].
final class WriteRequest {
  WriteRequest(this.offset, this.src);
  final int offset;
  final IoSlice src;
}

/// Random-access async file with a stable, engine-independent API.
final class AsyncFile implements AsyncRead, AsyncWrite {
  AsyncFile._(this.path, this._backend, this.options);

  factory AsyncFile.fromBackend(
    String path,
    BytesFile backend, {
    FileOptions options = const FileOptions(),
  }) => AsyncFile._(path, backend, options);

  final String path;
  final BytesFile _backend;
  final FileOptions options;

  bool _closed = false;
  bool _closing = false;
  int _position = 0;
  final Set<Future<void>> _pending = {};

  static Future<AsyncFile> open(
    String path, {
    FileOptions options = const FileOptions(),
  }) async {
    if (options.exclusive && options.create) {
      var exists = false;
      try {
        final probe = await openBackend(
          path,
          options.copyWith(create: false, mode: FileMode.read),
        );
        await probe.close();
        exists = true;
      } catch (_) {
        // Missing file: proceed with the exclusive create.
      }
      if (exists) {
        throw BlitIOException('file already exists', path: path);
      }
    }
    final BytesFile backend;
    try {
      backend = await openBackend(path, options);
    } catch (error, stack) {
      Error.throwWithStackTrace(
        BlitIOException('failed to open $path', path: path, cause: error),
        stack,
      );
    }
    final file = AsyncFile._(path, backend, options);
    if (options.truncate && options.writable) {
      await backend.truncate(0);
    }
    return file;
  }

  Future<T> _guard<T>(String op, Future<T> Function() body) async {
    try {
      return await body();
    } on BlitException {
      rethrow;
    } catch (error, stack) {
      Error.throwWithStackTrace(
        BlitIOException('$op failed', path: path, cause: error),
        stack,
      );
    }
  }

  void _checkOpen() {
    if (_closed || _closing) {
      throw ClosedException('file is closed', path: path);
    }
  }

  Future<T> _track<T>(Future<T> future) {
    final done = Completer<void>();
    _pending.add(done.future);
    future.then(
      (_) {
        _pending.remove(done.future);
        done.complete();
      },
      onError: (Object error, StackTrace stack) {
        _pending.remove(done.future);
        done.complete();
      },
    );
    return future;
  }

  void _checkReadable() {
    _checkOpen();
    if (options.mode == FileMode.write) {
      throw BlitIOException('file is write-only', path: path);
    }
  }

  void _checkWritable() {
    _checkOpen();
    if (!options.writable) {
      throw BlitIOException('file is read-only', path: path);
    }
  }

  Future<int> get length => _track(_lengthImpl());

  Future<int> _lengthImpl() async {
    _checkOpen();
    return _guard('length', () => _backend.length);
  }

  int get position => _position;

  Future<int> readAt(int offset, ReadBuf dst, {CancelToken? cancel}) async {
    _checkReadable();
    cancel?.throwIfCancelled(path: path);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (!dst.hasRemaining) return 0;
    return _track(_readAtImpl(offset, dst));
  }

  Future<int> _readAtImpl(int offset, ReadBuf dst) async {
    final n = await _guard(
      'readAt',
      () => _backend.readAt(offset, dst.unfilled),
    );
    dst.advance(n);
    return n;
  }

  Future<int> writeAt(int offset, IoSlice src, {CancelToken? cancel}) async {
    _checkWritable();
    cancel?.throwIfCancelled(path: path);
    return _track(
      _guard(
        'writeAt',
        () =>
            _backend.writeAt(offset, src.bytes, start: src.start, end: src.end),
      ),
    );
  }

  Future<List<int>> readMany(
    List<ReadRequest> requests, {
    CancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled(path: path);
    if (requests.length > 1) {
      final merged = _tryMergeReadContiguous(requests);
      if (merged != null) {
        final bytes = Uint8List(merged.total);
        final n = await readAt(merged.offset, ReadBuf(bytes), cancel: cancel);
        final out = <int>[];
        var base = 0;
        for (final request in requests) {
          final want = request.dst.remaining;
          final available = (n - base).clamp(0, want);
          if (available > 0) {
            request.dst.unfilled.setRange(0, available, bytes, base);
            request.dst.advance(available);
          }
          out.add(available);
          base += want;
        }
        return out;
      }
      if (_backend.supportsConcurrentReads) {
        return Future.wait([
          for (final request in requests)
            readAt(request.offset, request.dst, cancel: cancel),
        ]);
      }
    }
    final out = <int>[];
    for (final request in requests) {
      out.add(await readAt(request.offset, request.dst, cancel: cancel));
    }
    return out;
  }

  ({int offset, int total})? _tryMergeReadContiguous(
    List<ReadRequest> requests,
  ) {
    var total = 0;
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      if (i > 0) {
        final previous = requests[i - 1];
        if (request.offset != previous.offset + previous.dst.remaining) {
          return null;
        }
      }
      total += request.dst.remaining;
    }
    if (total == 0 || total > 8 * 1024 * 1024) return null;
    return (offset: requests.first.offset, total: total);
  }

  Future<List<int>> writeMany(
    List<WriteRequest> requests, {
    CancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled(path: path);
    if (requests.length > 1) {
      final merged = _tryMergeContiguous(requests);
      if (merged != null) {
        final n = await writeAt(
          merged.offset,
          IoSlice(merged.bytes),
          cancel: cancel,
        );
        if (n != merged.bytes.length) {
          throw BlitIOException(
            'short batch write: $n of ${merged.bytes.length}',
            path: path,
          );
        }
        return [for (final request in requests) request.src.length];
      }
      final span = await _tryMergeSpan(requests, cancel: cancel);
      if (span != null) {
        final n = await writeAt(
          span.offset,
          IoSlice(span.bytes),
          cancel: cancel,
        );
        if (n != span.bytes.length) {
          throw BlitIOException(
            'short batch write: $n of ${span.bytes.length}',
            path: path,
          );
        }
        return [for (final request in requests) request.src.length];
      }
    }
    final out = <int>[];
    for (final request in requests) {
      out.add(await writeAt(request.offset, request.src, cancel: cancel));
    }
    return out;
  }

  ({int offset, Uint8List bytes})? _tryMergeContiguous(
    List<WriteRequest> requests,
  ) {
    var total = 0;
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      if (i > 0) {
        final previous = requests[i - 1];
        if (request.offset != previous.offset + previous.src.length) {
          return null;
        }
      }
      total += request.src.length;
    }
    if (total == 0 || total > 8 * 1024 * 1024) return null;
    final out = Uint8List(total);
    var at = 0;
    for (final request in requests) {
      out.setRange(
        at,
        at + request.src.length,
        request.src.bytes,
        request.src.start,
      );
      at += request.src.length;
    }
    return (offset: requests.first.offset, bytes: out);
  }

  /// Coalesces clustered, non-contiguous writes into one read-modify-write.
  Future<({int offset, Uint8List bytes})?> _tryMergeSpan(
    List<WriteRequest> requests, {
    CancelToken? cancel,
  }) async {
    if (options.mode == FileMode.write) return null;
    var total = 0;
    var min = requests.first.offset;
    var max = requests.first.offset + requests.first.src.length;
    for (final request in requests) {
      if (request.offset < min) min = request.offset;
      final end = request.offset + request.src.length;
      if (end > max) max = end;
      total += request.src.length;
    }
    final span = max - min;
    if (span <= 0 || span > 1024 * 1024) return null;
    if (span > total * 8) return null;
    final out = Uint8List(span);
    try {
      await readAt(min, ReadBuf(out), cancel: cancel);
    } on CancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
    for (final request in requests) {
      final at = request.offset - min;
      out.setRange(
        at,
        at + request.src.length,
        request.src.bytes,
        request.src.start,
      );
    }
    return (offset: min, bytes: out);
  }

  /// Reads into [dst] without a Dart-side intermediate buffer.
  Future<int> readAtUnsafe(
    int offset,
    UnsafeBytes dst,
    int length, {
    CancelToken? cancel,
  }) {
    final backend = _backend;
    if (backend is AddressIo) {
      return _guard(
        'readAtUnsafe',
        () async =>
            (backend as AddressIo).readAtAddress(offset, dst.address, length),
      );
    }
    return readAt(offset, ReadBuf(dst.view(length)), cancel: cancel);
  }

  /// Writes from [src] without a Dart-side intermediate buffer.
  Future<int> writeAtUnsafe(
    int offset,
    UnsafeBytes src,
    int length, {
    CancelToken? cancel,
  }) {
    final backend = _backend;
    if (backend is AddressIo) {
      return _guard(
        'writeAtUnsafe',
        () async =>
            (backend as AddressIo).writeAtAddress(offset, src.address, length),
      );
    }
    return writeAt(offset, IoSlice(src.view(length)), cancel: cancel);
  }

  Future<int> append(IoSlice src, {CancelToken? cancel}) async {
    cancel?.throwIfCancelled(path: path);
    final len = await length;
    final n = await writeAt(len, src, cancel: cancel);
    _position = len + n;
    return n;
  }

  @override
  Future<ReadResult> readInto(ReadBuf dst) async {
    final n = await readAt(_position, dst);
    _position += n;
    return ReadResult(n, eof: n == 0);
  }

  @override
  Future<int> writeFrom(IoSlice src) async {
    final n = await writeAt(_position, src);
    _position += n;
    return n;
  }

  @override
  Future<void> flush({CancelToken? cancel}) async {
    _checkOpen();
    cancel?.throwIfCancelled(path: path);
    return _track(_guard('flush', () => _backend.flush()));
  }

  Future<void> flushWith(Durability durability, {CancelToken? cancel}) async {
    _checkOpen();
    cancel?.throwIfCancelled(path: path);
    return _track(_guard('flush', () => _backend.flush()));
  }

  Future<void> truncate(int newLength, {CancelToken? cancel}) async {
    _checkWritable();
    cancel?.throwIfCancelled(path: path);
    return _track(_guard('truncate', () => _backend.truncate(newLength)));
  }

  Future<void> _drainPending() async {
    while (_pending.isNotEmpty) {
      await Future.wait([
        for (final future in _pending)
          future.then((_) {}, onError: (Object error, StackTrace stack) {}),
      ]);
    }
  }

  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    try {
      await _drainPending();
      await _guard('close', () => _backend.close());
    } finally {
      _closed = true;
    }
  }

  Future<void> delete() async {
    _checkOpen();
    _closing = true;
    try {
      await _drainPending();
      await _guard('delete', () => _backend.delete());
    } finally {
      _closed = true;
    }
  }

  bool get isClosed => _closed;
}
