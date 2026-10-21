/// WebAssembly.Memory arena for UnsafeBytes.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../io/web/js.dart' show jsObject;

import 'dart:typed_data';

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
  int _bump = 0;
  int _freeHead = 0;

  JSArrayBuffer get buffer => _memory.buffer;

  int get capacity =>
      ((buffer as JSObject)['byteLength'] as JSNumber).toDartInt;

  void _ensure(int end) {
    if (end <= capacity) return;
    final pages = ((end - capacity) + _pageBytes - 1) ~/ _pageBytes;
    _memory.grow(pages);
  }

  int _readU32(int offset) {
    final view = JSUint8Array(buffer, offset, 4).toDart;
    return view[0] | (view[1] << 8) | (view[2] << 16) | (view[3] << 24);
  }

  void _writeU32(int offset, int value) {
    final view = JSUint8Array(buffer, offset, 4).toDart;
    view[0] = value & 0xFF;
    view[1] = (value >> 8) & 0xFF;
    view[2] = (value >> 16) & 0xFF;
    view[3] = (value >> 24) & 0xFF;
  }

  int alloc(int length) {
    if (length < 0) throw RangeError.value(length, 'length');
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
