/// Fixed-length external memory handle.
library;

import 'dart:typed_data';

import 'allocator.dart';
import 'allocator_api.dart';

/// An owned raw allocation handle.
///
/// The handle is an `int` extension type, so it does not add a Dart object per
/// allocation. Length is not stored; callers pass it when a view is requested.
extension type UnsafeBytes._(int _address) {
  static UnsafeBytes alloc(int length) => UnsafeBytes._(unsafeAlloc(length));

  /// Opt-in external allocation. [freeWith] must use the same allocator in the
  /// same isolate; [free] remains the system-allocator path.
  static UnsafeBytes allocWith(UnsafeAllocator allocator, int length) =>
      UnsafeBytes._(allocator.alloc(length));

  /// Wraps caller-owned memory. [free] is undefined for such a handle.
  static UnsafeBytes fromAddress(int address) => UnsafeBytes._(address);

  int get address => _address;

  bool get isNull => _address == 0;

  /// Frees this allocation. Double-free/use-after-free is undefined.
  void free() => unsafeFree(_address);

  /// Frees an [allocWith] allocation. The allocator must match and live in the
  /// same isolate. Mixing this with [free] is undefined.
  void freeWith(UnsafeAllocator allocator) => allocator.free(_address);

  /// Zero-copy view; length is caller-supplied.
  Uint8List view(int length) => unsafeView(_address, length);

  /// Unsafe slice; no bounds check and no ownership transfer.
  UnsafeBytes slice(int offset) => UnsafeBytes._(_address + offset);

  int getInt8(int offset) => unsafeReadInt8(_address, offset);
  int getUint8(int offset) => unsafeReadUint8(_address, offset);
  int getInt16(int offset) => unsafeReadInt16(_address, offset);
  int getUint16(int offset) => unsafeReadUint16(_address, offset);
  int getInt32(int offset) => unsafeReadInt32(_address, offset);
  int getUint32(int offset) => unsafeReadUint32(_address, offset);
  double getFloat32(int offset) => unsafeReadFloat32(_address, offset);
  double getFloat64(int offset) => unsafeReadFloat64(_address, offset);

  void setInt8(int offset, int value) =>
      unsafeWriteInt8(_address, offset, value);
  void setUint8(int offset, int value) =>
      unsafeWriteUint8(_address, offset, value);
  void setInt16(int offset, int value) =>
      unsafeWriteInt16(_address, offset, value);
  void setUint16(int offset, int value) =>
      unsafeWriteUint16(_address, offset, value);
  void setInt32(int offset, int value) =>
      unsafeWriteInt32(_address, offset, value);
  void setUint32(int offset, int value) =>
      unsafeWriteUint32(_address, offset, value);
  void setFloat32(int offset, double value) =>
      unsafeWriteFloat32(_address, offset, value);
  void setFloat64(int offset, double value) =>
      unsafeWriteFloat64(_address, offset, value);
}
