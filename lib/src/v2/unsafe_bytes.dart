/// Fixed-length, bounds-free external memory allocated by blit.
library;

import 'dart:typed_data';

import 'unsafe_allocator.dart';

/// An owned raw allocation handle.
///
/// The handle is an `int` extension type, so it does not add a Dart object per
/// allocation. The length is not stored here; the caller must pass it to
/// [view] and all length-bearing operations. [free] uses the allocator's own
/// header.
extension type UnsafeBytes._(int _address) {
  /// Allocates [length] bytes outside the Dart GC.
  static UnsafeBytes alloc(int length) => UnsafeBytes._(unsafeAlloc(length));

  /// Wraps a caller-owned address. [free] is undefined for such a handle.
  static UnsafeBytes fromAddress(int address) => UnsafeBytes._(address);

  int get address => _address;

  bool get isNull => _address == 0;

  /// Frees this allocation. Double-free/use-after-free is undefined.
  void free() => unsafeFree(_address);

  /// Creates a zero-copy view. [length] is caller-supplied and unchecked.
  Uint8List view(int length) => unsafeView(_address, length);

  Uint8List _at(int offset, int length) =>
      unsafeView(_address + offset, length);

  /// Unsafe slice; no bounds check and no ownership transfer.
  UnsafeBytes slice(int offset) => UnsafeBytes._(_address + offset);

  int getInt8(int offset) => ByteData.sublistView(_at(offset, 1)).getInt8(0);
  int getUint8(int offset) => ByteData.sublistView(_at(offset, 1)).getUint8(0);
  int getInt16(int offset, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 2)).getInt16(0, endian);
  int getUint16(int offset, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 2)).getUint16(0, endian);
  int getInt32(int offset, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 4)).getInt32(0, endian);
  int getUint32(int offset, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 4)).getUint32(0, endian);
  double getFloat32(int offset, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 4)).getFloat32(0, endian);
  double getFloat64(int offset, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 8)).getFloat64(0, endian);

  void setInt8(int offset, int value) =>
      ByteData.sublistView(_at(offset, 1)).setInt8(0, value);
  void setUint8(int offset, int value) =>
      ByteData.sublistView(_at(offset, 1)).setUint8(0, value);
  void setInt16(int offset, int value, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 2)).setInt16(0, value, endian);
  void setUint16(int offset, int value, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 2)).setUint16(0, value, endian);
  void setInt32(int offset, int value, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 4)).setInt32(0, value, endian);
  void setUint32(int offset, int value, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 4)).setUint32(0, value, endian);
  void setFloat32(int offset, double value, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 4)).setFloat32(0, value, endian);
  void setFloat64(int offset, double value, {Endian endian = Endian.little}) =>
      ByteData.sublistView(_at(offset, 8)).setFloat64(0, value, endian);
}
