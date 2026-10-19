/// Growable byte buffer with O(1) `freeze`/`split` views.
///
/// `BytesMut` owns a `Uint8List` plus a logical window `[start, start+length)`.
/// `freeze()` returns an immutable [Bytes] view and marks this buffer frozen;
/// the next mutation copies the visible range, so the frozen view stays valid.
/// This is a deliberately safe subset of Rust's `BytesMut` (no aliasing
/// `split_to` returning a mutable sibling).
library;

import 'dart:typed_data';

import 'bytes.dart';
import 'bytes_like.dart';
import 'u64/uint64.dart';

final class BytesMut implements BytesLike {
  Uint8List _data;
  int _start;
  int _length;
  bool _frozen;

  BytesMut([int capacity = 0])
    : _data = Uint8List(capacity < 0 ? 0 : capacity),
      _start = 0,
      _length = 0,
      _frozen = false;

  /// Copies [bytes] into a new buffer.
  factory BytesMut.fromBytes(Bytes bytes, {int? capacity}) {
    final cap = capacity == null || capacity < bytes.length
        ? bytes.length
        : capacity;
    final data = Uint8List(cap);
    data.setRange(0, bytes.length, bytes.asUint8List());
    return BytesMut._(data, 0, bytes.length, false);
  }

  /// Copies [data] into a new buffer.
  factory BytesMut.fromUint8List(Uint8List data) =>
      BytesMut._(Uint8List.fromList(data), 0, data.length, false);

  BytesMut._(this._data, this._start, this._length, this._frozen);

  @override
  int get length => _length;
  int get capacity => _data.length - _start;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length != 0;
  bool get isUnique => !_frozen;

  /// Zero-copy view of the visible range.
  @override
  Uint8List asUint8List() =>
      Uint8List.sublistView(_data, _start, _start + _length);

  ByteData asByteData() =>
      ByteData.sublistView(_data, _start, _start + _length);

  /// Explicit copy.
  Uint8List toUint8List() => Uint8List.fromList(asUint8List());

  /// Ensures capacity for [additional] bytes and unfreezes if needed.
  void _ensureWritable(int additional) {
    final needed = _length + additional;
    if (!_frozen && _start + needed <= _data.length) return;

    if (!_frozen && _start > 0 && needed <= _data.length) {
      _data.setRange(0, _length, _data, _start);
      _start = 0;
      return;
    }

    var newCapacity = _data.isEmpty ? 8 : _data.length * 2;
    if (newCapacity < needed) newCapacity = needed;
    final next = Uint8List(newCapacity);
    next.setRange(0, _length, _data, _start);
    _data = next;
    _start = 0;
    _frozen = false;
  }

  void reserve(int additional) {
    if (additional < 0) throw RangeError.value(additional, 'additional');
    _ensureWritable(additional);
  }

  /// Truncates to [newLength] (shrinking only).
  void truncate(int newLength) {
    if (newLength < 0 || newLength > _length) {
      throw RangeError.range(newLength, 0, _length, 'newLength');
    }
    _length = newLength;
  }

  void clear() {
    _start = 0;
    _length = 0;
  }

  /// Returns an immutable view of this buffer and marks it frozen.
  ///
  /// The view shares memory; the next mutation of this `BytesMut` copies.
  Bytes freeze() {
    _frozen = true;
    return Bytes.view(_data, _start, _length);
  }

  /// Returns the first [at] bytes as an immutable view and advances self.
  ///
  /// The returned view is copy-on-write protected: the next [BytesMut]
  /// mutation copies the remaining range instead of overwriting shared storage.
  Bytes splitTo(int at) {
    if (at < 0 || at > _length) {
      throw RangeError.range(at, 0, _length, 'at');
    }
    final out = Bytes.view(_data, _start, at);
    _frozen = true;
    _start += at;
    _length -= at;
    return out;
  }

  /// Returns `[at, length)` as an immutable view; self keeps `[0, at)`.
  ///
  /// The returned view is copy-on-write protected: the next [BytesMut]
  /// mutation copies the remaining range instead of overwriting shared storage.
  Bytes splitOff(int at) {
    if (at < 0 || at > _length) {
      throw RangeError.range(at, 0, _length, 'at');
    }
    final out = Bytes.view(_data, _start + at, _length - at);
    _frozen = true;
    _length = at;
    return out;
  }

  /// Appends one byte without a capacity check.
  ///
  /// The caller must have reserved enough capacity (for example with
  /// [reserve]); this is the hot-path variant for bit writers.
  void putUint8Unchecked(int value) {
    _data[_start + _length] = value & 0xFF;
    _length++;
  }

  /// Ensures room for [count] more bytes and returns a writable tail view.
  ///
  /// The returned view aliases this buffer's storage and is not reflected in
  /// [length] until [advance] is called. This lets bit writers append directly
  /// with a `Uint8List` and an offset instead of one `putUint8` call per byte.
  Uint8List spareView(int count) {
    if (count < 0) throw RangeError.value(count, 'count');
    _ensureWritable(count);
    final base = _start + _length;
    return Uint8List.sublistView(_data, base, base + count);
  }

  /// Commits [count] bytes previously written through [spareView].
  void advance(int count) {
    if (count < 0 || _length + count > _data.length - _start) {
      throw RangeError.value(count, 'count');
    }
    _length += count;
  }

  void putUint8(int value) {
    _ensureWritable(1);
    putUint8Unchecked(value);
  }

  /// Appends two bytes without a capacity check.
  void putUint16Unchecked(int value, {Endian endian = Endian.big}) {
    final i = _start + _length;
    if (endian == Endian.big) {
      _data[i] = (value ~/ 256) & 0xFF;
      _data[i + 1] = value & 0xFF;
    } else {
      _data[i] = value & 0xFF;
      _data[i + 1] = (value ~/ 256) & 0xFF;
    }
    _length += 2;
  }

  void putUint16(int value, {Endian endian = Endian.big}) {
    _ensureWritable(2);
    putUint16Unchecked(value, endian: endian);
  }

  /// Appends four bytes without a capacity check.
  void putUint32Unchecked(int value, {Endian endian = Endian.big}) {
    final i = _start + _length;
    if (endian == Endian.big) {
      _data[i] = (value ~/ 0x1000000) & 0xFF;
      _data[i + 1] = (value ~/ 0x10000) & 0xFF;
      _data[i + 2] = (value ~/ 0x100) & 0xFF;
      _data[i + 3] = value & 0xFF;
    } else {
      _data[i] = value & 0xFF;
      _data[i + 1] = (value ~/ 0x100) & 0xFF;
      _data[i + 2] = (value ~/ 0x10000) & 0xFF;
      _data[i + 3] = (value ~/ 0x1000000) & 0xFF;
    }
    _length += 4;
  }

  void putUint32(int value, {Endian endian = Endian.big}) {
    _ensureWritable(4);
    putUint32Unchecked(value, endian: endian);
  }

  /// Appends eight bytes without a capacity check.
  void putUint64Unchecked(Uint64 value, {Endian endian = Endian.big}) {
    if (endian == Endian.big) {
      putUint32Unchecked(value.hi);
      putUint32Unchecked(value.lo);
    } else {
      putUint32Unchecked(value.lo, endian: Endian.little);
      putUint32Unchecked(value.hi, endian: Endian.little);
    }
  }

  void putUint64(Uint64 value, {Endian endian = Endian.big}) {
    _ensureWritable(8);
    putUint64Unchecked(value, endian: endian);
  }

  /// Appends a float64 without a capacity check.
  void putFloat64Unchecked(double value, {Endian endian = Endian.big}) {
    ByteData.sublistView(
      _data,
      _start + _length,
      _start + _length + 8,
    ).setFloat64(0, value, endian);
    _length += 8;
  }

  void putFloat64(double value, {Endian endian = Endian.big}) {
    _ensureWritable(8);
    putFloat64Unchecked(value, endian: endian);
  }

  /// Appends [value]'s visible bytes without a capacity check.
  void putBytesUnchecked(Bytes value) {
    _data.setRange(
      _start + _length,
      _start + _length + value.length,
      value.asUint8List(),
    );
    _length += value.length;
  }

  void putBytes(Bytes value) {
    _ensureWritable(value.length);
    putBytesUnchecked(value);
  }

  /// Appends a `List<int>` without a capacity check.
  void putSliceUnchecked(List<int> value) {
    _data.setRange(_start + _length, _start + _length + value.length, value);
    _length += value.length;
  }

  void putSlice(List<int> value) {
    _ensureWritable(value.length);
    putSliceUnchecked(value);
  }

  /// Appends [count] copies of [byte] without a capacity check.
  void putRepeatedUnchecked(int byte, int count) {
    final b = byte & 0xFF;
    final base = _start + _length;
    for (var i = 0; i < count; i++) {
      _data[base + i] = b;
    }
    _length += count;
  }

  void putRepeated(int byte, int count) {
    if (count < 0) throw RangeError.value(count, 'count');
    _ensureWritable(count);
    putRepeatedUnchecked(byte, count);
  }

  /// Writes [value] as [nbytes] big-endian bytes without a capacity check.
  void putUintUnchecked(int value, int nbytes) {
    for (var i = nbytes - 1; i >= 0; i--) {
      _data[_start + _length + i] = value & 0xFF;
      value = value ~/ 256;
    }
    _length += nbytes;
  }

  /// Writes [value] as [nbytes] big-endian bytes (0..8).
  void putUint(int value, int nbytes) {
    if (nbytes < 0 || nbytes > 8) {
      throw RangeError.range(nbytes, 0, 8, 'nbytes');
    }
    _ensureWritable(nbytes);
    putUintUnchecked(value, nbytes);
  }

  Bytes toBytes() => Bytes.fromUint8List(Uint8List.fromList(asUint8List()));

  @override
  String toString() => 'BytesMut(length: $_length, capacity: $capacity)';
}
