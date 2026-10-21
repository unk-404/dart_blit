/// Self-contained asynchronous I/O utilities.
///
/// This layer is transport-agnostic: it composes over existing async backends
/// and Futures, and does not create an executor or event loop. It is web-safe
/// and works with `Uint8List`, [Bytes], [BytesMut], and native-backed typed
/// data views.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/bytes.dart';
import '../core/bytes_mut.dart';
import '../core/u64/uint64.dart';

/// Result of one async read.
final class ReadResult {
  const ReadResult(this.bytes, {this.eof = false});

  final int bytes;
  final bool eof;

  @override
  String toString() => 'ReadResult(bytes: $bytes, eof: $eof)';
}

/// A mutable read target with a filled/capacity split.
///
/// Readers write into
/// [unfilled] and call [advance], so wrappers do not need to allocate a second
/// buffer or copy twice.
final class ReadBuf {
  ReadBuf(Uint8List buffer, {int filled = 0, int? capacity})
    : _buffer = buffer,
      _filled = filled,
      _capacity = capacity ?? buffer.length {
    if (filled < 0 || filled > _capacity || _capacity > buffer.length) {
      throw RangeError('Invalid ReadBuf filled/capacity');
    }
  }

  final Uint8List _buffer;
  int _filled;
  final int _capacity;

  Uint8List get buffer => _buffer;
  int get filled => _filled;
  int get capacity => _capacity;
  int get remaining => _capacity - _filled;
  bool get hasRemaining => remaining > 0;

  /// View of bytes `[filled, capacity)`.
  Uint8List get unfilled => Uint8List.sublistView(_buffer, _filled, _capacity);

  void advance(int n) {
    if (n < 0 || n > remaining) {
      throw RangeError.range(n, 0, remaining, 'n');
    }
    _filled += n;
  }
}

/// A byte range for async writes.
final class IoSlice {
  IoSlice(Uint8List bytes, {int start = 0, int? end})
    : bytes = bytes,
      start = start,
      length = _checkedLength(bytes, start, end);

  IoSlice.fromBytes(Bytes value)
    : bytes = value.asUint8List(),
      start = 0,
      length = value.length;

  final Uint8List bytes;
  final int start;
  final int length;

  int get end => start + length;

  /// A zero-copy view of `[start, end)`.
  Uint8List get view => Uint8List.sublistView(bytes, start, end);

  static int _checkedLength(Uint8List bytes, int start, int? end) {
    final e = end ?? bytes.length;
    RangeError.checkValidRange(start, e, bytes.length);
    return e - start;
  }
}

/// Asynchronous byte source.
abstract interface class AsyncRead {
  Future<ReadResult> readInto(ReadBuf dst);
}

/// Asynchronous byte sink.
abstract interface class AsyncWrite {
  Future<int> writeFrom(IoSlice src);

  Future<void> flush();
}

/// A buffered asynchronous byte source.
abstract interface class AsyncBufRead implements AsyncRead {
  Future<bool> fillBuf();
  Uint8List get buffer;
  int get buffered;
  void consume(int n);
}

/// End of stream before an exact read completed.
final class UnexpectedEof implements Exception {
  const UnexpectedEof([this.required = 0, this.received = 0]);
  final int required;
  final int received;

  @override
  String toString() =>
      'UnexpectedEof: required $required bytes, received $received';
}

/// A read-to-end limit was exceeded.
final class LimitExceeded implements Exception {
  const LimitExceeded(this.limit);
  final int limit;

  @override
  String toString() => 'LimitExceeded: $limit bytes';
}

/// Read-side utility methods.
extension AsyncReadExt on AsyncRead {
  /// Fills [dst] completely or throws [UnexpectedEof].
  Future<void> readExact(ReadBuf dst) async {
    while (dst.hasRemaining) {
      final result = await readInto(dst);
      if (result.bytes == 0) {
        throw UnexpectedEof(dst.capacity, dst.filled);
      }
    }
  }

  /// Reads until EOF, returning an immutable view over the accumulated data.
  Future<Bytes> readToEnd({int? limit}) async {
    final out = BytesMut();
    while (true) {
      if (limit != null && out.length >= limit) {
        throw LimitExceeded(limit);
      }
      final take = limit == null
          ? 64 * 1024
          : (limit - out.length).clamp(1, 64 * 1024);
      final spare = out.spareView(take);
      final dst = ReadBuf(spare);
      final result = await readInto(dst);
      out.advance(dst.filled);
      if (result.eof && dst.filled == 0) break;
      if (result.bytes == 0) break;
    }
    return out.freeze();
  }

  Future<Uint8List> _readN(int n) async {
    final out = Uint8List(n);
    await readExact(ReadBuf(out));
    return out;
  }

  Future<int> readU8() async => (await _readN(1))[0];

  Future<int> readU16({Endian endian = Endian.big}) async =>
      ByteData.sublistView(await _readN(2)).getUint16(0, endian);

  Future<int> readU32({Endian endian = Endian.big}) async =>
      ByteData.sublistView(await _readN(4)).getUint32(0, endian);

  Future<Uint64> readU64({Endian endian = Endian.big}) async {
    final data = await _readN(8);
    return Uint64.readFrom(ByteData.sublistView(data), 0, endian: endian);
  }

  Future<double> readF32({Endian endian = Endian.big}) async =>
      ByteData.sublistView(await _readN(4)).getFloat32(0, endian);

  Future<double> readF64({Endian endian = Endian.big}) async =>
      ByteData.sublistView(await _readN(8)).getFloat64(0, endian);

  /// Reads at most [limit] bytes from this source.
  AsyncRead take(int limit) => _TakeReader(this, limit);

  /// Reads this source, then [next].
  AsyncRead chain(AsyncRead next) => _ChainReader(this, next);

  /// Copies this source into [dst], optionally up to [limit] bytes.
  Future<int> copyTo(
    AsyncWrite dst, {
    int bufferSize = 64 * 1024,
    int? limit,
  }) => _copy(this, dst, bufferSize: bufferSize, limit: limit);
}

/// Write-side utility methods.
extension AsyncWriteExt on AsyncWrite {
  /// Writes all bytes in [src], looping over short writes.
  Future<void> writeAll(IoSlice src) async {
    var offset = 0;
    while (offset < src.length) {
      final n = await writeFrom(
        IoSlice(src.bytes, start: src.start + offset, end: src.end),
      );
      if (n <= 0) throw StateError('writeFrom made no progress');
      offset += n;
    }
  }

  Future<void> writeUint8(int value) =>
      writeAll(IoSlice(Uint8List.fromList([value & 0xFF])));

  Future<void> writeUint16(int value, {Endian endian = Endian.big}) {
    final data = ByteData(2)..setUint16(0, value, endian);
    return writeAll(IoSlice(data.buffer.asUint8List()));
  }

  Future<void> writeUint32(int value, {Endian endian = Endian.big}) {
    final data = ByteData(4)..setUint32(0, value, endian);
    return writeAll(IoSlice(data.buffer.asUint8List()));
  }

  Future<void> writeUint64(Uint64 value, {Endian endian = Endian.big}) {
    final data = ByteData(8);
    value.writeTo(data, 0, endian: endian);
    return writeAll(IoSlice(data.buffer.asUint8List()));
  }

  Future<void> writeFloat64(double value, {Endian endian = Endian.big}) {
    final data = ByteData(8)..setFloat64(0, value, endian);
    return writeAll(IoSlice(data.buffer.asUint8List()));
  }
}

/// Copies [src] into [dst] without per-chunk allocations.
Future<int> _copy(
  AsyncRead src,
  AsyncWrite dst, {
  int bufferSize = 64 * 1024,
  int? limit,
}) async {
  if (bufferSize <= 0) throw RangeError.value(bufferSize, 'bufferSize');
  final buffer = Uint8List(bufferSize);
  var total = 0;
  while (true) {
    if (limit != null && total >= limit) break;
    final want = limit == null
        ? buffer.length
        : (limit - total).clamp(1, buffer.length);
    final rb = ReadBuf(buffer, capacity: want);
    final result = await src.readInto(rb);
    if (rb.filled > 0) {
      await dst.writeAll(IoSlice(buffer, start: 0, end: rb.filled));
      total += rb.filled;
    }
    if (result.eof && rb.filled == 0) break;
    if (rb.filled == 0) break;
  }
  return total;
}

/// Top-level copy helper.
Future<int> copy(
  AsyncRead src,
  AsyncWrite dst, {
  int bufferSize = 64 * 1024,
  int? limit,
}) => _copy(src, dst, bufferSize: bufferSize, limit: limit);

/// Sequential reader over a fixed `Uint8List`.
final class Uint8ListReader implements AsyncRead {
  Uint8ListReader(this.bytes, {this.start = 0, int? end})
    : end = end ?? bytes.length,
      _position = start {
    RangeError.checkValidRange(start, this.end, bytes.length);
  }

  final Uint8List bytes;
  int start;
  int end;
  int _position;

  int get position => _position;

  @override
  Future<ReadResult> readInto(ReadBuf dst) async {
    if (_position >= end) return const ReadResult(0, eof: true);
    final n = (end - _position).clamp(0, dst.remaining);
    dst.unfilled.setRange(0, n, bytes, _position);
    dst.advance(n);
    _position += n;
    return ReadResult(n, eof: _position >= end);
  }
}

/// Sequential reader over an immutable [Bytes] view.
final class BytesAsyncReader implements AsyncRead {
  BytesAsyncReader(this.bytes, {int start = 0, int? end})
    : _reader = Uint8ListReader(bytes.asUint8List(), start: start, end: end);

  final Bytes bytes;
  final Uint8ListReader _reader;

  int get position => _reader.position;

  @override
  Future<ReadResult> readInto(ReadBuf dst) => _reader.readInto(dst);
}

/// Fixed-capacity writer over a caller-owned `Uint8List`.
final class Uint8ListWriter implements AsyncWrite {
  Uint8ListWriter(this.bytes, {int start = 0, int? end})
    : _position = start,
      _limit = end ?? bytes.length {
    RangeError.checkValidRange(start, _limit, bytes.length);
  }

  final Uint8List bytes;
  int _position;
  final int _limit;

  int get position => _position;
  int get remaining => _limit - _position;

  @override
  Future<int> writeFrom(IoSlice src) async {
    final n = src.length.clamp(0, remaining);
    if (n < src.length) throw RangeError('Uint8ListWriter is full');
    bytes.setRange(_position, _position + n, src.bytes, src.start);
    _position += n;
    return n;
  }

  @override
  Future<void> flush() async {}
}

/// Growable writer backed by [BytesMut].
final class BytesMutAsyncWriter implements AsyncWrite {
  BytesMutAsyncWriter([BytesMut? mut]) : mut = mut ?? BytesMut();

  final BytesMut mut;

  @override
  Future<int> writeFrom(IoSlice src) async {
    if (src.length == 0) return 0;
    final spare = mut.spareView(src.length);
    spare.setRange(0, src.length, src.bytes, src.start);
    mut.advance(src.length);
    return src.length;
  }

  @override
  Future<void> flush() async {}

  Bytes freeze() => mut.freeze();
}

/// Buffered reader with an internal byte buffer.
final class BufReader<R extends AsyncRead> implements AsyncBufRead {
  BufReader(this.inner, {int capacity = 64 * 1024})
    : _buffer = Uint8List(capacity);

  final R inner;
  final Uint8List _buffer;
  int _start = 0;
  int _end = 0;

  @override
  Uint8List get buffer => Uint8List.sublistView(_buffer, _start, _end);

  @override
  int get buffered => _end - _start;

  @override
  Future<bool> fillBuf() async {
    if (_start < _end) return true;
    _start = 0;
    _end = 0;
    final dst = ReadBuf(_buffer);
    final result = await inner.readInto(dst);
    _end = dst.filled;
    return _end > 0 || !result.eof;
  }

  @override
  void consume(int n) {
    if (n < 0 || n > buffered) throw RangeError.value(n, 'n');
    _start += n;
  }

  @override
  Future<ReadResult> readInto(ReadBuf dst) async {
    if (dst.remaining == 0) return const ReadResult(0);
    if (_start == _end) {
      if (dst.remaining >= _buffer.length) {
        return inner.readInto(dst);
      }
      final ok = await fillBuf();
      if (!ok && _end == 0) return const ReadResult(0, eof: true);
    }
    final n = buffered.clamp(0, dst.remaining);
    dst.unfilled.setRange(0, n, _buffer, _start);
    dst.advance(n);
    _start += n;
    return ReadResult(n);
  }
}

/// Buffered writer; flushes when its buffer fills.
final class BufWriter<W extends AsyncWrite> implements AsyncWrite {
  BufWriter(this.inner, {int capacity = 64 * 1024})
    : _buffer = Uint8List(capacity);

  final W inner;
  final Uint8List _buffer;
  int _filled = 0;

  @override
  Future<int> writeFrom(IoSlice src) async {
    final original = src.length;
    var offset = 0;
    while (offset < src.length) {
      final n = (src.length - offset).clamp(0, _buffer.length - _filled);
      _buffer.setRange(_filled, _filled + n, src.bytes, src.start + offset);
      _filled += n;
      offset += n;
      if (_filled == _buffer.length) await _drain();
    }
    return original;
  }

  Future<void> _drain() async {
    if (_filled == 0) return;
    await inner.writeAll(IoSlice(_buffer, start: 0, end: _filled));
    _filled = 0;
  }

  @override
  Future<void> flush() async {
    await _drain();
    await inner.flush();
  }
}

/// Turns an [AsyncRead] into a chunked stream.
Stream<Uint8List> readerStream(
  AsyncRead reader, {
  int bufferSize = 64 * 1024,
}) async* {
  if (bufferSize <= 0) throw RangeError.value(bufferSize, 'bufferSize');
  while (true) {
    final buffer = Uint8List(bufferSize);
    final dst = ReadBuf(buffer);
    final result = await reader.readInto(dst);
    if (dst.filled > 0) {
      yield Uint8List.sublistView(buffer, 0, dst.filled);
    }
    if (result.eof && dst.filled == 0) break;
    if (dst.filled == 0) break;
  }
}

/// Reads a UTF-8 line from a buffered source, sans trailing `\n`/`\r\n`.
Future<String?> readLine(AsyncBufRead reader) async {
  final bytes = BytesMut();
  while (true) {
    if (reader.buffered == 0) {
      final ok = await reader.fillBuf();
      if (!ok) {
        if (bytes.isEmpty) return null;
        break;
      }
    }
    final buf = reader.buffer;
    final nl = buf.indexOf(0x0A);
    if (nl < 0) {
      final spare = bytes.spareView(buf.length);
      spare.setRange(0, buf.length, buf);
      bytes.advance(buf.length);
      reader.consume(buf.length);
      continue;
    }
    final spare = bytes.spareView(nl);
    spare.setRange(0, nl, buf);
    bytes.advance(nl);
    reader.consume(nl + 1);
    break;
  }
  final list = bytes.asUint8List();
  final end = list.isNotEmpty && list.last == 0x0D
      ? list.length - 1
      : list.length;
  return utf8.decode(list.sublist(0, end));
}

final class _TakeReader implements AsyncRead {
  _TakeReader(this._inner, this._remaining);
  final AsyncRead _inner;
  int _remaining;

  @override
  Future<ReadResult> readInto(ReadBuf dst) async {
    if (_remaining <= 0 || dst.remaining == 0) {
      return const ReadResult(0, eof: true);
    }
    final original = dst.remaining;
    final limited = ReadBuf(
      dst.buffer,
      filled: dst.filled,
      capacity: dst.filled + (original < _remaining ? original : _remaining),
    );
    final result = await _inner.readInto(limited);
    final n = limited.filled - dst.filled;
    dst.advance(n);
    _remaining -= n;
    return ReadResult(n, eof: result.eof || _remaining <= 0);
  }
}

final class _ChainReader implements AsyncRead {
  _ChainReader(this._first, this._second);
  final AsyncRead _first;
  final AsyncRead _second;
  bool _firstDone = false;

  @override
  Future<ReadResult> readInto(ReadBuf dst) async {
    if (!_firstDone) {
      final result = await _first.readInto(dst);
      if (dst.filled > 0 || !result.eof) return result;
      _firstDone = true;
    }
    return _second.readInto(dst);
  }
}
