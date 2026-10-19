/// A small, isolate-local native block allocator for buffered scratch buffers.
///
/// `calloc` zeroes every scratch block on allocation; read/write scratch does
/// not need initialized memory, and file objects otherwise ask the OS for a new
/// block on every open. This pool keeps uninitialized blocks and reuses them
/// across files in the same isolate. Direct I/O buffers are deliberately *not*
/// allocated here: they need page alignment and keep their platform-specific
/// `VirtualAlloc`/`posix_memalign` path.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class _Block {
  _Block(this.pointer, this.capacity);

  final Pointer<Uint8> pointer;
  final int capacity;
}

/// Reuses uninitialized native blocks; one instance per isolate.
final class PooledNativeAllocator implements Allocator {
  PooledNativeAllocator([Allocator backing = malloc]) : _backing = backing;

  final Allocator _backing;
  final List<_Block> _free = <_Block>[];
  final Map<int, int> _capacityByAddress = <int, int>{};

  static const int _maxCachedBlocks = 32;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    for (var i = 0; i < _free.length; i++) {
      final block = _free[i];
      if (block.capacity >= byteCount) {
        _free.removeAt(i);
        _capacityByAddress[block.pointer.address] = block.capacity;
        return block.pointer.cast<T>();
      }
    }
    final pointer = _backing.allocate<Uint8>(byteCount);
    _capacityByAddress[pointer.address] = byteCount;
    return pointer.cast<T>();
  }

  @override
  void free(Pointer pointer) {
    final address = pointer.address;
    final capacity = _capacityByAddress.remove(address);
    if (capacity == null) return;
    if (_free.length >= _maxCachedBlocks) {
      _backing.free(pointer);
      return;
    }
    _free.add(_Block(pointer.cast<Uint8>(), capacity));
  }
}

/// Shared buffered-scratch allocator for the native mmap backends.
final PooledNativeAllocator nativeScratchAllocator = PooledNativeAllocator();
