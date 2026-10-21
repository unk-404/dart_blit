import 'dart:io';

import 'package:blit/blit_io.dart';
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
