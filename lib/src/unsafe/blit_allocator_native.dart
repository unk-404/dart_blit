/// Mimalloc-inspired size-class allocator for blit experiments.
///
/// This is intentionally not wired into UnsafeBytes yet. It reserves one
/// external arena, uses fixed 64 KiB slabs and per-class free lists, and avoids
/// per-allocation FFI calls.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int _defaultArenaSize = 64 * 1024 * 1024;
const int _defaultSlabSize = 64 * 1024;
const int _slabHeader = 16;

const List<int> _classes = [
  8,
  16,
  32,
  64,
  128,
  256,
  512,
  1024,
  2048,
  4096,
  8192,
  16384,
  32768,
  65536,
];

final class BlitAllocator {
  BlitAllocator({
    this.arenaSize = _defaultArenaSize,
    this.slabSize = _defaultSlabSize,
  }) : _arena = malloc.allocate<Uint8>(arenaSize) {
    _base = _arena.address;
    _bytes = _arena.asTypedList(arenaSize);
    _data = ByteData.sublistView(_bytes);
  }

  final int arenaSize;
  final int slabSize;
  final Pointer<Uint8> _arena;
  late final int _base;
  late final Uint8List _bytes;
  late final ByteData _data;
  late final List<int> _heads = List<int>.filled(_classes.length, 0);
  final Map<int, int> _slabClass = {};
  int _bump = 0;
  bool _closed = false;

  int alloc(int size) {
    if (_closed) throw StateError('allocator is closed');
    if (size <= 0) size = 1;
    var classIndex = _classFor(size);
    if (classIndex < 0) {
      return malloc.allocate<Uint8>(size).address;
    }
    var head = _heads[classIndex];
    if (head == 0) {
      head = _newSlab(classIndex);
    }
    final next = _readU32(head);
    _heads[classIndex] = next;
    return _base + head;
  }

  void free(int address) {
    if (_closed) throw StateError('allocator is closed');
    final offset = address - _base;
    if (offset < 0 || offset >= _bump) {
      malloc.free(Pointer<Uint8>.fromAddress(address));
      return;
    }
    final slabOffset = offset & ~(slabSize - 1);
    final classSize = _slabClass[slabOffset];
    if (classSize == null) throw StateError('invalid allocator address');
    final classIndex = _indexOf(classSize);
    _writeU32(offset, _heads[classIndex]);
    _heads[classIndex] = offset;
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    malloc.free(_arena);
  }

  int _newSlab(int classIndex) {
    final overhead = _slabHeader;
    final slabOffset = _bump;
    final end = slabOffset + slabSize;
    if (end > arenaSize) throw StateError('allocator arena exhausted');
    _bump = end;
    final classSize = _classes[classIndex];
    final count = (slabSize - overhead) ~/ classSize;
    if (count <= 0) throw StateError('invalid slab size');
    final first = slabOffset + overhead;
    _slabClass[slabOffset] = classSize;
    for (var i = 0; i < count; i++) {
      final at = first + i * classSize;
      final next = i + 1 < count ? at + classSize : 0;
      _writeU32(at, next);
    }
    return first;
  }

  static int _classFor(int size) {
    for (var i = 0; i < _classes.length; i++) {
      if (size <= _classes[i]) return i;
    }
    return -1;
  }

  static int _indexOf(int classSize) {
    for (var i = 0; i < _classes.length; i++) {
      if (_classes[i] == classSize) return i;
    }
    throw StateError('invalid size class');
  }

  int _readU32(int offset) => _data.getUint32(offset, Endian.little);
  void _writeU32(int offset, int value) =>
      _data.setUint32(offset, value, Endian.little);
}
