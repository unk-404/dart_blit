import 'dart:ffi';

import 'package:blit/blit_native.dart';
import 'package:blit/unsafe.dart';
import 'package:test/test.dart';

void main() {
  test('BlitAllocator size classes and free list', () {
    final allocator = BlitAllocator(arenaSize: 1 << 20);
    try {
      final a = allocator.alloc(5);
      final b = allocator.alloc(5);
      expect(a, isNot(b));
      final view = Pointer<Uint8>.fromAddress(a).asTypedList(5);
      view.setAll(0, [1, 2, 3, 4, 5]);
      allocator.free(a);
      final c = allocator.alloc(5);
      expect(c, a);
      Pointer<Uint8>.fromAddress(c).asTypedList(5).setAll(0, [9, 8, 7, 6, 5]);
      expect(Pointer<Uint8>.fromAddress(c).asTypedList(5), [9, 8, 7, 6, 5]);
      allocator.free(b);
      allocator.free(c);
    } finally {
      allocator.dispose();
    }
  });

  test('BlitAllocator large fallback', () {
    final allocator = BlitAllocator(arenaSize: 1 << 20);
    try {
      final address = allocator.alloc(1 << 17);
      expect(address, isNot(0));
      allocator.free(address);
    } finally {
      allocator.dispose();
    }
  });

  test('DartAllocator baseline', () {
    final allocator = DartAllocator();
    final value = allocator.alloc(8);
    value[0] = 1;
    expect(value.length, 8);
    allocator.free(value);
  });
}

