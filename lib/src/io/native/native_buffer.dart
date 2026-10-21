/// Native-backed byte buffers for zero-copy I/O paths.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../async_io.dart';

final class NativeBuffer {
  NativeBuffer._(this.pointer, this.length)
    : bytes = pointer.asTypedList(length);

  factory NativeBuffer.allocate(int length, {bool zero = false}) {
    if (length < 0) throw RangeError.value(length, 'length');
    final pointer = zero
        ? calloc<Uint8>(length)
        : malloc.allocate<Uint8>(length);
    return NativeBuffer._(pointer, length);
  }

  final Pointer<Uint8> pointer;
  final int length;
  final Uint8List bytes;

  bool _disposed = false;

  bool get isDisposed => _disposed;

  Uint8List view([int start = 0, int? end]) =>
      Uint8List.sublistView(bytes, start, end ?? length);

  ReadBuf readBuf({int filled = 0, int? capacity}) =>
      ReadBuf(bytes, filled: filled, capacity: capacity);

  IoSlice writeSlice([int start = 0, int? end]) =>
      IoSlice(bytes, start: start, end: end);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    malloc.free(pointer);
  }
}

/// Reuses native buffers by exact byte size.
final class NativeBufferPool {
  NativeBufferPool({this.maxPerSize = 8});

  final int maxPerSize;
  final Map<int, List<NativeBuffer>> _free = {};
  int _cached = 0;

  int get cached => _cached;

  NativeBuffer acquire(int length, {bool zero = false}) {
    final list = _free[length];
    if (list != null && list.isNotEmpty) {
      _cached--;
      return list.removeLast();
    }
    return NativeBuffer.allocate(length, zero: zero);
  }

  void release(NativeBuffer buffer) {
    if (buffer.isDisposed) return;
    final list = _free.putIfAbsent(buffer.length, () => []);
    if (list.length >= maxPerSize) {
      buffer.dispose();
      return;
    }
    list.add(buffer);
    _cached++;
  }

  void clear() {
    for (final list in _free.values) {
      for (final buffer in list) {
        buffer.dispose();
      }
    }
    _free.clear();
    _cached = 0;
  }
}

