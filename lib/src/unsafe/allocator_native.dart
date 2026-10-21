/// Native malloc/free raw operations.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

int unsafeAlloc(int length) => malloc.allocate<Uint8>(length).address;

void unsafeFree(int address) =>
    malloc.free(Pointer<Uint8>.fromAddress(address));

Uint8List unsafeView(int address, int length) =>
    Pointer<Uint8>.fromAddress(address).asTypedList(length);

int unsafeReadUint8(int address, int offset) =>
    Pointer<Uint8>.fromAddress(address + offset).value;

void unsafeWriteUint8(int address, int offset, int value) =>
    Pointer<Uint8>.fromAddress(address + offset).value = value;

int unsafeReadInt8(int address, int offset) =>
    Pointer<Int8>.fromAddress(address + offset).value;

void unsafeWriteInt8(int address, int offset, int value) =>
    Pointer<Int8>.fromAddress(address + offset).value = value;

int unsafeReadInt16(int address, int offset) =>
    Pointer<Int16>.fromAddress(address + offset).value;

void unsafeWriteInt16(int address, int offset, int value) =>
    Pointer<Int16>.fromAddress(address + offset).value = value;

int unsafeReadUint16(int address, int offset) =>
    Pointer<Uint16>.fromAddress(address + offset).value;

void unsafeWriteUint16(int address, int offset, int value) =>
    Pointer<Uint16>.fromAddress(address + offset).value = value;

int unsafeReadInt32(int address, int offset) =>
    Pointer<Int32>.fromAddress(address + offset).value;

void unsafeWriteInt32(int address, int offset, int value) =>
    Pointer<Int32>.fromAddress(address + offset).value = value;

int unsafeReadUint32(int address, int offset) =>
    Pointer<Uint32>.fromAddress(address + offset).value;

void unsafeWriteUint32(int address, int offset, int value) =>
    Pointer<Uint32>.fromAddress(address + offset).value = value;

double unsafeReadFloat32(int address, int offset) =>
    Pointer<Float>.fromAddress(address + offset).value;

void unsafeWriteFloat32(int address, int offset, double value) =>
    Pointer<Float>.fromAddress(address + offset).value = value;

double unsafeReadFloat64(int address, int offset) =>
    Pointer<Double>.fromAddress(address + offset).value;

void unsafeWriteFloat64(int address, int offset, double value) =>
    Pointer<Double>.fromAddress(address + offset).value = value;
