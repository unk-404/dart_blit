/// Native malloc/free allocator for UnsafeBytes.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

int unsafeAlloc(int length) {
  if (length < 0) throw RangeError.value(length, 'length');
  return malloc.allocate<Uint8>(length).address;
}

void unsafeFree(int address) {
  malloc.free(Pointer<Uint8>.fromAddress(address));
}

Uint8List unsafeView(int address, int length) =>
    Pointer<Uint8>.fromAddress(address).asTypedList(length);
