/// Consuming cursor over a [Bytes] (Rust `Buf` semantics).
library;

import 'dart:typed_data';

import 'bytes.dart';
import 'u64/uint64.dart';

final class BytesReader {
  final Bytes _bytes;
  int _position;

  BytesReader(Bytes bytes, [int position = 0])
      : _bytes = bytes,
        _position = position {
    RangeError.checkValueInInterval(position, 0, bytes.length, 'position');
  }

  Bytes get buffer => _bytes;
  int get position => _position;
  int get remaining => _bytes.length - _position;
  bool get hasRemaining => _position < _bytes.length;

  /// Current remaining view (O(1)).
  Bytes chunk() => _bytes.slice(_position);

  void advance(int count) {
    if (count < 0 || count > remaining) {
      throw RangeError.range(count, 0, remaining, 'count');
    }
    _position += count;
  }

  void skip(int count) => advance(count);

  int readUint8() {
    final v = _bytes[_position];
    _position++;
    return v;
  }

  /// Reads one byte without a bounds check.
  ///
  /// The caller must guarantee [remaining] >= 1; this is for hot loops that
  /// already validate the frame length.
  int readUint8Unchecked() => _bytes.getUint8Unchecked(_position++);

  int readUint16({Endian endian = Endian.big}) {
    final v = _bytes.getUint16(_position, endian: endian);
    _position += 2;
    return v;
  }

  /// Reads two bytes without a bounds check (caller guarantees remaining).
  int readUint16Unchecked({Endian endian = Endian.big}) {
    final v = _bytes.getUint16Unchecked(_position, endian: endian);
    _position += 2;
    return v;
  }

  int readUint32({Endian endian = Endian.big}) {
    final v = _bytes.getUint32(_position, endian: endian);
    _position += 4;
    return v;
  }

  /// Reads four bytes without a bounds check (caller guarantees remaining).
  int readUint32Unchecked({Endian endian = Endian.big}) {
    final v = _bytes.getUint32Unchecked(_position, endian: endian);
    _position += 4;
    return v;
  }

  Uint64 readUint64({Endian endian = Endian.big}) {
    final v = _bytes.getUint64(_position, endian: endian);
    _position += 8;
    return v;
  }

  /// Reads eight bytes without a bounds check (caller guarantees remaining).
  Uint64 readUint64Unchecked({Endian endian = Endian.big}) {
    final first = _bytes.getUint32Unchecked(_position, endian: endian);
    final second = _bytes.getUint32Unchecked(_position + 4, endian: endian);
    _position += 8;
    return endian == Endian.big
        ? Uint64(first, second)
        : Uint64(second, first);
  }

  /// Returns a zero-copy view of the next [length] bytes and advances.
  Bytes readBytes(int length) {
    if (length < 0 || length > remaining) {
      throw RangeError.range(length, 0, remaining, 'length');
    }
    final out = _bytes.slice(_position, _position + length);
    _position += length;
    return out;
  }

  /// Copies the next [length] bytes into [dst] starting at [start].
  int readInto(Uint8List dst, [int start = 0, int? end]) {
    final e = end ?? dst.length;
    final n = e - start;
    if (n < 0 || n > remaining) {
      throw RangeError.range(n, 0, remaining, 'length');
    }
    dst.setRange(start, e, _bytes.asUint8List(), _position);
    _position += n;
    return n;
  }

  /// Peeks without consuming.
  int peekUint8([int offset = 0]) {
    final i = _position + offset;
    if (i < 0 || i >= _bytes.length) {
      throw RangeError.range(i, 0, _bytes.length - 1, 'offset');
    }
    return _bytes[i];
  }
}
