@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String srcPath;
  late String dstPath;

  setUp(() {
    dir = Directory('${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}punch_test_'
        '${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    srcPath = '${dir.path}${Platform.pathSeparator}src.bin';
    dstPath = '${dir.path}${Platform.pathSeparator}dst.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('punchHole deallocates without changing length', () {
    final file = openMmapFileSync(srcPath);
    try {
      file.truncate(1 << 20);
      final pattern = Uint8List(4096)..fillRange(0, 4096, 0x7F);
      file.writeAt(0, pattern);
      file.writeAt(1 << 19, pattern);
      file.flush();

      file.punchHole(4096, 4096);
      file.flush();
      final out = Uint8List(4096);
      expect(file.readAt(4096, out), 4096);
      expect(out.every((b) => b == 0), isTrue);
      expect(file.length, 1 << 20);
    } finally {
      file.close();
    }
  });

  test('cloneRangeFrom clones when the volume supports block clone', () {
    final src = openMmapFileSync(srcPath);
    final dst = openMmapFileSync(dstPath);
    try {
      src.truncate(1 << 20);
      final pattern = Uint8List(4096);
      for (var i = 0; i < pattern.length; i++) {
        pattern[i] = (i * 11 + 3) & 0xFF;
      }
      src.writeAt(0, pattern);
      src.flush();

      dst.truncate(1 << 20);
      try {
        dst.cloneRangeFrom(src, length: 4096);
      } on WindowsException catch (e) {
        // NTFS/FAT may not implement block cloning; the API is best-effort.
        if (e.code == 1 || e.code == 50 || e.code == 87) return;
        rethrow;
      }
      final out = Uint8List(4096);
      expect(dst.readAt(0, out), 4096);
      expect(out, pattern);
    } finally {
      src.close();
      dst.close();
    }
  });
}
