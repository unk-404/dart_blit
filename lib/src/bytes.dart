/// Immutable, zero-copy view over a byte buffer.
///
/// A `Bytes` is `(buffer, offset, length)`: [slice] is O(1) and does not copy.
/// It mirrors the core semantics of Rust's `bytes::Bytes` without a vtable or
/// reference counting; the backing buffer is shared and must not be mutated by
/// the caller while a `Bytes` view exists.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'u64/uint64.dart';

/// Immutable view over `[offset, offset + length)` of a `Uint8List`.
final class Bytes implements Comparable<Bytes> {
  final Uint8List _buffer;
  final int _offset;
  final int _length;

  Bytes._(this._buffer, this._offset, this._length);

  /// An empty view (no allocation).
  static final Bytes empty = Bytes._(Uint8List(0), 0, 0);

  /// Wraps [data] without copying.  The caller must not mutate [data] while
  /// this view is alive.
  factory Bytes.fromUint8List(Uint8List data) => Bytes._(data, 0, data.length);

  /// Wraps a `Uint8List` view starting at [offsetInBytes].
  factory Bytes.view(Uint8List data, [int offsetInBytes = 0, int? length]) {
    final len = length ?? (data.length - offsetInBytes);
    RangeError.checkValidRange(offsetInBytes, offsetInBytes + len, data.length);
    return Bytes._(data, offsetInBytes, len);
  }

  /// Copies [data] into a new buffer.
  factory Bytes.fromList(List<int> data) {
    final buffer = Uint8List.fromList(data);
    return Bytes._(buffer, 0, buffer.length);
  }

  factory Bytes.fromString(String value) => Bytes.fromList(utf8.encode(value));

  /// Shares the underlying buffer of [data] (zero copy).
  factory Bytes.fromByteData(ByteData data) {
    final view = Uint8List.view(
        data.buffer, data.offsetInBytes, data.lengthInBytes);
    return Bytes._(view, 0, view.length);
  }

  factory Bytes.fromByteBuffer(ByteBuffer buffer) {
    final view = Uint8List.view(buffer);
    return Bytes._(view, 0, view.length);
  }

  /// Copies a range of [data].
  factory Bytes.copyOf(Uint8List data, [int start = 0, int? end]) {
    final e = end ?? data.length;
    RangeError.checkValidRange(start, e, data.length);
    return Bytes._(Uint8List.fromList(data.sublist(start, e)), 0, e - start);
  }

  int get length => _length;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length != 0;

  /// Zero-copy mutable view.  Mutating it mutates the underlying buffer.
  Uint8List asUint8List() =>
      Uint8List.sublistView(_buffer, _offset, _offset + _length);

  /// Zero-copy `ByteData` view.
  ByteData asByteData() =>
      ByteData.sublistView(_buffer, _offset, _offset + _length);

  /// Explicit copy (Rust's `to_vec`).
  Uint8List toUint8List() => Uint8List.fromList(asUint8List());

  /// O(1) slice.  [start] and [end] are relative to this view.
  Bytes slice(int start, [int? end]) {
    final e = end ?? _length;
    RangeError.checkValidRange(start, e, _length);
    return Bytes._(_buffer, _offset + start, e - start);
  }

  /// Alias for [slice].
  Bytes sublist(int start, [int? end]) => slice(start, end);

  /// Reads one byte.
  int operator [](int index) {
    if (index < 0 || index >= _length) {
      throw RangeError.range(index, 0, _length - 1, 'index');
    }
    return _buffer[_offset + index];
  }

  void _check(int index, int width) {
    if (index < 0 || index + width > _length) {
      throw RangeError.range(index, 0, _length - width, 'index');
    }
  }

  int getUint8(int index) => this[index];

  int getUint16(int index, {Endian endian = Endian.big}) {
    _check(index, 2);
    final i = _offset + index;
    final a = _buffer[i];
    final b = _buffer[i + 1];
    return endian == Endian.big ? (a << 8) | b : (b << 8) | a;
  }

  int getUint32(int index, {Endian endian = Endian.big}) {
    _check(index, 4);
    final i = _offset + index;
    final a = _buffer[i];
    final b = _buffer[i + 1];
    final c = _buffer[i + 2];
    final d = _buffer[i + 3];
    if (endian == Endian.big) {
      return (a << 24) | (b << 16) | (c << 8) | d;
    }
    return (d << 24) | (c << 16) | (b << 8) | a;
  }

  Uint64 getUint64(int index, {Endian endian = Endian.big}) {
    _check(index, 8);
    return Uint64.readFrom(asByteData(), index, endian: endian);
  }

  double getFloat64(int index, {Endian endian = Endian.big}) {
    _check(index, 8);
    return ByteData.sublistView(
            _buffer, _offset + index, _offset + index + 8)
        .getFloat64(0, endian);
  }

  double getFloat32(int index, {Endian endian = Endian.big}) {
    _check(index, 4);
    return ByteData.sublistView(
            _buffer, _offset + index, _offset + index + 4)
        .getFloat32(0, endian);
  }

  /// Copies this view into [dst] starting at [start].
  void copyTo(Uint8List dst, [int start = 0]) {
    RangeError.checkValidRange(start, start + _length, dst.length);
    dst.setRange(start, start + _length, asUint8List());
  }

  /// Returns the first index of [value] in `[start, end)`, or -1.
  int indexOf(int value, [int start = 0, int? end]) {
    final e = end ?? _length;
    RangeError.checkValidRange(start, e, _length);
    final i = asUint8List().indexOf(value, start);
    return i >= 0 && i < e ? i : -1;
  }

  /// Lexicographic comparison.
  @override
  int compareTo(Bytes other) {
    final n = _length < other._length ? _length : other._length;
    for (var i = 0; i < n; i++) {
      final a = _buffer[_offset + i];
      final b = other._buffer[other._offset + i];
      if (a != b) return a < b ? -1 : 1;
    }
    return _length.compareTo(other._length);
  }

  /// Content equality (O(n)).
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Bytes || other._length != _length) return false;
    for (var i = 0; i < _length; i++) {
      if (_buffer[_offset + i] != other._buffer[other._offset + i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    // FNV-1a; cold path.
    var h = 0x811C9DC5;
    for (var i = 0; i < _length; i++) {
      h = (h * 31 + _buffer[_offset + i]) & 0xFFFFFFFF;
    }
    return h;
  }

  @override
  String toString() => 'Bytes($_length)';
}
