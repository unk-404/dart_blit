/// WebAssembly.Memory arena and raw accessors.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../io/web/js.dart' show jsObject;

const int _headerBytes = 8;
const int _pageBytes = 64 * 1024;

@JS('WebAssembly.Memory')
extension type _WasmMemory._(JSObject _) implements JSObject {
  external factory _WasmMemory(JSObject descriptor);
  external JSArrayBuffer get buffer;
  external int grow(int deltaPages);
}

final class _WebArena {
  _WebArena()
    : _memory = _WasmMemory(jsObject({'initial': 16, 'maximum': 65536}));

  final _WasmMemory _memory;
  ByteData? _data;
  int _bump = 0;
  int _freeHead = 0;

  JSArrayBuffer get buffer => _memory.buffer;

  int get capacity =>
      ((buffer as JSObject)['byteLength'] as JSNumber).toDartInt;

  ByteData get data {
    final byteBuffer = buffer.toDart;
    final cached = _data;
    if (cached != null && cached.buffer == byteBuffer) return cached;
    return _data = ByteData.sublistView(Uint8List.view(byteBuffer));
  }

  void _ensure(int end) {
    if (end <= capacity) return;
    final pages = ((end - capacity) + _pageBytes - 1) ~/ _pageBytes;
    _memory.grow(pages);
    _data = null;
  }

  int _readU32(int offset) => data.getUint32(offset, Endian.little);
  void _writeU32(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);

  int alloc(int length) {
    final total = (length + _headerBytes + 7) & ~7;
    var previous = 0;
    var current = _freeHead;
    while (current != 0) {
      final size = _readU32(current);
      final next = _readU32(current + 4);
      if (size >= total) {
        if (previous == 0) {
          _freeHead = next;
        } else {
          _writeU32(previous + 4, next);
        }
        _writeU32(current, size);
        _writeU32(current + 4, 0);
        return current + _headerBytes;
      }
      previous = current;
      current = next;
    }
    final at = _bump;
    final end = at + total;
    _ensure(end);
    _bump = end;
    _writeU32(at, total);
    _writeU32(at + 4, 0);
    return at + _headerBytes;
  }

  void free(int address) {
    if (address < _headerBytes) return;
    final header = address - _headerBytes;
    _writeU32(header + 4, _freeHead);
    _freeHead = header;
  }

  Uint8List view(int address, int length) =>
      JSUint8Array(buffer, address, length).toDart;
}

_WebArena? _arena;

_WebArena get _sharedArena => _arena ??= _WebArena();

int unsafeAlloc(int length) => _sharedArena.alloc(length);

void unsafeFree(int address) => _sharedArena.free(address);

Uint8List unsafeView(int address, int length) =>
    _sharedArena.view(address, length);

int unsafeReadUint8(int address, int offset) =>
    _sharedArena.data.getUint8(address + offset);

void unsafeWriteUint8(int address, int offset, int value) =>
    _sharedArena.data.setUint8(address + offset, value);

int unsafeReadInt8(int address, int offset) =>
    _sharedArena.data.getInt8(address + offset);

void unsafeWriteInt8(int address, int offset, int value) =>
    _sharedArena.data.setInt8(address + offset, value);

int unsafeReadInt16(int address, int offset) =>
    _sharedArena.data.getInt16(address + offset, Endian.little);

void unsafeWriteInt16(int address, int offset, int value) =>
    _sharedArena.data.setInt16(address + offset, value, Endian.little);

int unsafeReadUint16(int address, int offset) =>
    _sharedArena.data.getUint16(address + offset, Endian.little);

void unsafeWriteUint16(int address, int offset, int value) =>
    _sharedArena.data.setUint16(address + offset, value, Endian.little);

int unsafeReadInt32(int address, int offset) =>
    _sharedArena.data.getInt32(address + offset, Endian.little);

void unsafeWriteInt32(int address, int offset, int value) =>
    _sharedArena.data.setInt32(address + offset, value, Endian.little);

int unsafeReadUint32(int address, int offset) =>
    _sharedArena.data.getUint32(address + offset, Endian.little);

void unsafeWriteUint32(int address, int offset, int value) =>
    _sharedArena.data.setUint32(address + offset, value, Endian.little);

double unsafeReadFloat32(int address, int offset) =>
    _sharedArena.data.getFloat32(address + offset, Endian.little);

void unsafeWriteFloat32(int address, int offset, double value) =>
    _sharedArena.data.setFloat32(address + offset, value, Endian.little);

double unsafeReadFloat64(int address, int offset) =>
    _sharedArena.data.getFloat64(address + offset, Endian.little);

void unsafeWriteFloat64(int address, int offset, double value) =>
    _sharedArena.data.setFloat64(address + offset, value, Endian.little);
