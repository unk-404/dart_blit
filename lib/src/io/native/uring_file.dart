/// Linux `io_uring` file backend, built on the pure-Dart `io_uring` package.
///
/// Linux-only.  `io_uring` uses raw syscalls + mmap; there is no C shim,
/// `liburing` dependency or native asset.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:io_uring/io_uring.dart';

import '../bytes_file.dart';

/// A [BytesFile] backed by Linux `io_uring` SQ/CQ rings.
///
/// One reaper isolate is created per open file by [UringLoop].  For high queue
/// depth use [readMany] / [writeMany]; they submit one batch and reap with a
/// single `io_uring_enter`.
final class UringBytesFile implements BytesFile {
  UringBytesFile._(
    this.path,
    this.readOnly,
    this._fd,
    this._loop,
    this._length,
    this._lease,
  );

  final String path;
  final bool readOnly;
  final int _fd;
  final UringLoop _loop;
  final UringLoopLease? _lease;
  int _length;
  bool _closed = false;
  bool _fixedRegistered = false;
  final List<UringBuffer> _bufferPool = <UringBuffer>[];
  final Set<UringBuffer> _busyBuffers = <UringBuffer>{};
  final List<UringBuffer> _fixedBuffers = <UringBuffer>[];
  final Map<UringBuffer, int> _fixedIndices = <UringBuffer, int>{};
  final Set<UringBuffer> _fixedBusy = <UringBuffer>{};

  static const int _fixedBufferSize = 8 << 20;
  static const int _fixedBufferCount = 4;

  UringBuffer _acquireBuffer(int length) {
    for (final buffer in _fixedBuffers) {
      if (!_fixedBusy.contains(buffer) && buffer.length >= length) {
        _fixedBusy.add(buffer);
        return buffer;
      }
    }
    for (final buffer in _bufferPool) {
      if (!_busyBuffers.contains(buffer) && buffer.length >= length) {
        _busyBuffers.add(buffer);
        return buffer;
      }
    }
    final buffer = UringBuffer.allocate(length);
    _bufferPool.add(buffer);
    _busyBuffers.add(buffer);
    return buffer;
  }

  void _releaseBuffer(UringBuffer buffer) {
    _fixedBusy.remove(buffer);
    _busyBuffers.remove(buffer);
  }

  UringOp _readOp(UringBuffer buffer, int length, int offset) {
    final index = _fixedIndices[buffer];
    if (index != null) {
      return ReadFixedOp(
        fd: _fd,
        buffer: buffer.pointer,
        length: length,
        offset: offset,
        bufIndex: index,
      );
    }
    return ReadOp(
      fd: _fd,
      buffer: buffer.pointer,
      length: length,
      offset: offset,
    );
  }

  UringOp _writeOp(UringBuffer buffer, int length, int offset) {
    final index = _fixedIndices[buffer];
    if (index != null) {
      return WriteFixedOp(
        fd: _fd,
        buffer: buffer.pointer,
        length: length,
        offset: offset,
        bufIndex: index,
      );
    }
    return WriteOp(
      fd: _fd,
      buffer: buffer.pointer,
      length: length,
      offset: offset,
    );
  }

  void _registerFixedBuffers(int entries) {
    final count = math.min(entries, _fixedBufferCount);
    try {
      for (var i = 0; i < count; i++) {
        final buffer = UringBuffer.allocate(_fixedBufferSize);
        _fixedBuffers.add(buffer);
        _fixedIndices[buffer] = i;
      }
      _loop.ring.registerBuffers(_fixedBuffers);
      _fixedRegistered = true;
    } on Object {
      _fixedRegistered = false;
      for (final buffer in _fixedBuffers) {
        buffer.dispose();
      }
      _fixedBuffers.clear();
      _fixedIndices.clear();
    }
  }

  /// Opens [path] on Linux using io_uring.
  ///
  /// Throws [UnsupportedError] on non-Linux platforms.  [entries] is the SQ/CQ
  /// ring size; batch callers should raise it above the batch size.
  /// [sharedLoop] leases a loop from `io_uring`'s process-wide
  /// [UringLoopPool] instead of opening a private ring.
  static Future<UringBytesFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    int entries = 256,
    bool sharedLoop = false,
  }) async {
    if (!Platform.isLinux || Platform.isAndroid) {
      throw UnsupportedError('io_uring is only available on Linux');
    }
    if (entries < 2) throw RangeError.value(entries, 'entries');
    final flags =
        (readOnly ? PosixConstants.oRdonly : PosixConstants.oRdwr) |
        (create && !readOnly ? PosixConstants.oCreat : 0) |
        PosixConstants.oCloexec;
    final fd = Posix.open(path, flags: flags, mode: 0x1A4);
    UringLoop? loop;
    UringLoopLease? lease;
    try {
      if (sharedLoop) {
        lease = await UringLoop.acquire(entries: entries);
        loop = lease.loop;
      } else {
        loop = await UringLoop.open(entries: entries);
      }
      final length = File(path).lengthSync();
      final file = UringBytesFile._(path, readOnly, fd, loop, length, lease);
      file._registerFixedBuffers(entries);
      return file;
    } on Object {
      if (lease != null) {
        await lease.release();
      } else if (loop != null) {
        await loop.close();
      }
      Posix.close(fd);
      rethrow;
    }
  }

  @override
  Future<int> get length async => _length;

  @override
  Future<int> readAt(
    int offset,
    Uint8List dst, {
    int start = 0,
    int? end,
  }) async {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    final count = e - start;
    if (count == 0) return 0;
    final buffer = _acquireBuffer(count);
    try {
      final cqe = await _loop.run(_readOp(buffer, count, offset));
      if (cqe.isError) {
        throw IoUringException.fromCompletion(cqe.result, operation: 'read');
      }
      final n = cqe.result;
      dst.setRange(start, start + n, buffer.bytes);
      return n;
    } finally {
      _releaseBuffer(buffer);
    }
  }

  @override
  Future<int> writeAt(
    int offset,
    Uint8List src, {
    int start = 0,
    int? end,
  }) async {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    final count = e - start;
    if (count == 0) return 0;
    final buffer = _acquireBuffer(count);
    try {
      buffer.bytes.setRange(0, count, src, start);
      final cqe = await _loop.run(_writeOp(buffer, count, offset));
      if (cqe.isError) {
        throw IoUringException.fromCompletion(cqe.result, operation: 'write');
      }
      final n = cqe.result;
      if (offset + n > _length) _length = offset + n;
      return n;
    } finally {
      _releaseBuffer(buffer);
    }
  }

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) {
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    return writeAt(_length, src, start: start, end: e);
  }

  /// Batched positional reads; one native buffer per range and one submit.
  Future<List<int>> readMany(List<int> offsets, int blockSize) async {
    _checkOpen();
    if (offsets.isEmpty) return const <int>[];
    if (blockSize <= 0) throw RangeError.value(blockSize, 'blockSize');
    final buffers = <UringBuffer>[];
    try {
      final ops = <UringOp>[];
      for (final offset in offsets) {
        if (offset < 0) throw RangeError.value(offset, 'offset');
        final buffer = _acquireBuffer(blockSize);
        buffers.add(buffer);
        ops.add(_readOp(buffer, blockSize, offset));
      }
      final completions = await Future.wait(_loop.runAll(ops));
      final result = <int>[];
      for (var i = 0; i < completions.length; i++) {
        final cqe = completions[i];
        if (cqe.isError) {
          throw IoUringException.fromCompletion(
            cqe.result,
            operation: 'readMany',
          );
        }
        result.add(cqe.result);
      }
      return result;
    } finally {
      for (final buffer in buffers) {
        _releaseBuffer(buffer);
      }
    }
  }

  /// Batched positional writes; one native buffer per range and one submit.
  Future<List<int>> writeMany(List<int> offsets, List<Uint8List> blocks) async {
    _checkWritable();
    if (offsets.length != blocks.length) {
      throw ArgumentError('offsets and blocks must have the same length');
    }
    if (offsets.isEmpty) return const <int>[];
    final buffers = <UringBuffer>[];
    try {
      final ops = <UringOp>[];
      for (var i = 0; i < offsets.length; i++) {
        final offset = offsets[i];
        if (offset < 0) throw RangeError.value(offset, 'offset');
        final data = blocks[i];
        final buffer = _acquireBuffer(data.isEmpty ? 1 : data.length);
        buffers.add(buffer);
        if (data.isNotEmpty) {
          buffer.bytes.setRange(0, data.length, data);
        }
        ops.add(_writeOp(buffer, data.length, offset));
      }
      final completions = await Future.wait(_loop.runAll(ops));
      final result = <int>[];
      for (var i = 0; i < completions.length; i++) {
        final cqe = completions[i];
        if (cqe.isError) {
          throw IoUringException.fromCompletion(
            cqe.result,
            operation: 'writeMany',
          );
        }
        final n = cqe.result;
        if (offsets[i] + n > _length) _length = offsets[i] + n;
        result.add(n);
      }
      return result;
    } finally {
      for (final buffer in buffers) {
        _releaseBuffer(buffer);
      }
    }
  }

  @override
  Future<void> truncate(int newLength) async {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    final cqe = await _loop.run(FtruncateOp(fd: _fd, length: newLength));
    if (cqe.isError) {
      throw IoUringException.fromCompletion(cqe.result, operation: 'ftruncate');
    }
    _length = newLength;
  }

  @override
  Future<void> flush() async {
    _checkOpen();
    final cqe = await _loop.run(FsyncOp(fd: _fd));
    if (cqe.isError) {
      throw IoUringException.fromCompletion(cqe.result, operation: 'fsync');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (_fixedRegistered) {
        _fixedRegistered = false;
        try {
          _loop.ring.unregisterBuffers();
        } on Object {
          // The ring may already be faulted/closed; release still runs.
        }
      }
    } finally {
      Posix.close(_fd);
      for (final buffer in _bufferPool) {
        buffer.dispose();
      }
      _bufferPool.clear();
      _busyBuffers.clear();
      for (final buffer in _fixedBuffers) {
        buffer.dispose();
      }
      _fixedBuffers.clear();
      _fixedIndices.clear();
      _fixedBusy.clear();
      final lease = _lease;
      if (lease != null) {
        await lease.release();
      } else {
        await _loop.close();
      }
    }
  }

  @override
  Future<void> delete() async {
    await close();
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  bool get isClosed => _closed;

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

  @override
  String toString() =>
      'UringBytesFile($path, length: $_length, readOnly: $readOnly)';
}

/// Opens a Linux io_uring-backed [BytesFile].
///
/// [sharedLoop] leases a loop from the process-wide [UringLoopPool] instead of
/// creating a private reaper isolate. Leases are exclusive; use it for
/// sequential open/close workloads, not to multiplex concurrent files.
Future<UringBytesFile> openUringBytesFile(
  String path, {
  bool create = true,
  bool readOnly = false,
  int entries = 256,
  bool sharedLoop = false,
}) => UringBytesFile.open(
  path,
  create: create,
  readOnly: readOnly,
  entries: entries,
  sharedLoop: sharedLoop,
);
