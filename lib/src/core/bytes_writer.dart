/// Writer over a caller-provided `Uint8List` (Rust `BufMut` semantics).
///
/// `BytesWriter` never allocates and never grows the destination; it is the
/// recommended way to fill an I/O buffer before a single `writeAt`.
library;

import 'dart:typed_data';

import 'u64/uint64.dart';

final class BytesWriter {
  final Uint8List _dst;
  final int _limit;
  int _position;

  BytesWriter(Uint8List dst, [int offset = 0])
      : _dst = dst,
        _limit = dst.length,
        _position = offset {
    RangeError.checkValueInInterval(offset, 0, dst.length, 'offset');
  }

  int get position => _position;
  int get remaining => _limit - _position;
  bool get hasRemaining => _position < _limit;

  void _need(int n) {
    if (n < 0 || _position + n > _limit) {
      throw RangeError.range(_position + n, 0, _limit, 'position');
    }
  }

  void putUint8(int value) {
    _need(1);
    _dst[_position++] = value & 0xFF;
  }

  void putUint16(int value, {Endian endian = Endian.big}) {
    _need(2);
    if (endian == Endian.big) {
      _dst[_position] = (value ~/ 256) & 0xFF;
      _dst[_position + 1] = value & 0xFF;
    } else {
      _dst[_position] = value & 0xFF;
      _dst[_position + 1] = (value ~/ 256) & 0xFF;
    }
    _position += 2;
  }

  void putUint32(int value, {Endian endian = Endian.big}) {
    _need(4);
    if (endian == Endian.big) {
      _dst[_position] = (value ~/ 0x1000000) & 0xFF;
      _dst[_position + 1] = (value ~/ 0x10000) & 0xFF;
      _dst[_position + 2] = (value ~/ 0x100) & 0xFF;
      _dst[_position + 3] = value & 0xFF;
    } else {
      _dst[_position] = value & 0xFF;
      _dst[_position + 1] = (value ~/ 0x100) & 0xFF;
      _dst[_position + 2] = (value ~/ 0x10000) & 0xFF;
      _dst[_position + 3] = (value ~/ 0x1000000) & 0xFF;
    }
    _position += 4;
  }

  void putUint64(Uint64 value, {Endian endian = Endian.big}) {
    _need(8);
    if (endian == Endian.big) {
      putUint32(value.hi);
      putUint32(value.lo);
    } else {
      putUint32(value.lo, endian: Endian.little);
      putUint32(value.hi, endian: Endian.little);
    }
  }

  void putFloat64(double value, {Endian endian = Endian.big}) {
    _need(8);
    ByteData.sublistView(_dst, _position, _position + 8)
        .setFloat64(0, value, endian);
    _position += 8;
  }

  void putSlice(List<int> value) {
    _need(value.length);
    _dst.setRange(_position, _position + value.length, value);
    _position += value.length;
  }

  void putRepeated(int byte, int count) {
    _need(count);
    final b = byte & 0xFF;
    for (var i = 0; i < count; i++) {
      _dst[_position + i] = b;
    }
    _position += count;
  }

  /// Writes [value] as [nbytes] big-endian bytes (0..8).
  void putUint(int value, int nbytes) {
    if (nbytes < 0 || nbytes > 8) {
      throw RangeError.range(nbytes, 0, 8, 'nbytes');
    }
    _need(nbytes);
    for (var i = nbytes - 1; i >= 0; i--) {
      _dst[_position + i] = value & 0xFF;
      value = value ~/ 256;
    }
    _position += nbytes;
  }

  /// Returns a zero-copy view of the written range.
  Uint8List finish() => Uint8List.sublistView(_dst, 0, _position);
}
