import 'dart:io';

import 'package:blit/blit_io.dart';
import 'package:blit/blit_native.dart';
import 'package:blit/unsafe.dart';
import 'package:test/test.dart';

void main() {
  test('UnsafeBytes alloc/view/access/free', () {
    final bytes = UnsafeBytes.alloc(16);
    try {
      expect(bytes.isNull, isFalse);
      final view = bytes.view(16);
      bytes.setInt8(0, -1);
      bytes.setUint16(2, 0x1234);
      bytes.setInt32(4, 0x1020304);
      bytes.setFloat64(8, 1.5);

      expect(bytes.getInt8(0), -1);
      expect(bytes.getUint16(2), 0x1234);
      expect(bytes.getInt32(4), 0x1020304);
      expect(bytes.getFloat64(8), 1.5);

      final sub = bytes.slice(2);
      expect(sub.address, bytes.address + 2);
      expect(sub.view(4).sublist(0, 2), [0x34, 0x12]);
      expect(view.length, 16);
    } finally {
      bytes.free();
    }
  });

  test('raw int API', () {
    final address = unsafeAlloc(8);
    try {
      unsafeWriteInt32(address, 0, 0x11223344);
      expect(unsafeReadInt32(address, 0), 0x11223344);
      unsafeWriteUint16(address, 4, 0xABCD);
      expect(unsafeReadUint16(address, 4), 0xABCD);
    } finally {
      unsafeFree(address);
    }
  });

  test('batch copy/move/fill/compare', () {
    final a = UnsafeBytes.alloc(32);
    final b = UnsafeBytes.alloc(32);
    try {
      a.view(32).setAll(0, List.generate(32, (i) => i));
      unsafeCopy(b.address, a.address, 32);
      expect(unsafeCompare(a.address, b.address, 32), 0);

      unsafeFill(b.address, 0xAA, 8);
      expect(b.view(8), everyElement(0xAA));
      expect(unsafeCompare(a.address, b.address, 8), isNot(0));

      unsafeMove(a.address + 4, a.address, 8);
      expect(a.view(4), [0, 1, 2, 3]);
      expect(a.view(8).sublist(4), [0, 1, 2, 3]);
    } finally {
      a.free();
      b.free();
    }
  });
  test('AddressIo direct UnsafeBytes path', () async {
    final path =
        '${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}unsafe_addr_'
        '${DateTime.now().microsecondsSinceEpoch}.bin';
    final backend = await NativeMmapFile.open(path, create: true);
    final file = AsyncFile.fromBackend(
      path,
      backend,
      options: const FileOptions(mode: FileMode.readWrite),
    );
    final bytes = UnsafeBytes.alloc(8);
    try {
      await file.truncate(8);
      bytes.view(8).setAll(0, [5, 4, 3, 2, 1, 0, 9, 8]);
      expect(await file.writeAtUnsafe(0, bytes, 8), 8);
      bytes.view(8).fillRange(0, 8, 0);
      expect(await file.readAtUnsafe(0, bytes, 8), 8);
      expect(bytes.view(8), [5, 4, 3, 2, 1, 0, 9, 8]);
    } finally {
      bytes.free();
      await file.close();
      File(path).deleteSync();
    }
  });
  test('UnsafeBytes as AsyncFile target/source', () async {
    final path =
        '${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}unsafe_'
        '${DateTime.now().microsecondsSinceEpoch}.bin';
    final bytes = UnsafeBytes.alloc(8);
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    try {
      bytes.view(8).setAll(0, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(await file.writeAtUnsafe(0, bytes, 8), 8);
      bytes.view(8).fillRange(0, 8, 0);
      expect(await file.readAtUnsafe(0, bytes, 8), 8);
      expect(bytes.view(8), [1, 2, 3, 4, 5, 6, 7, 8]);
    } finally {
      await file.close();
      bytes.free();
      File(path).deleteSync();
    }
  });
}
