@TestOn('mac-os')
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
        '.dart_tool${Platform.pathSeparator}macos_ops_'
        '${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    srcPath = '${dir.path}${Platform.pathSeparator}src.bin';
    dstPath = '${dir.path}${Platform.pathSeparator}dst.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('preallocate + adviseRead', () {
    final file = openMmapFileSync(srcPath);
    try {
      file.preallocate(1 << 20);
      expect(file.length, 1 << 20);
      final data = Uint8List(4096)..fillRange(0, 4096, 0x5A);
      file.writeAt(0, data);
      file.adviseRead(offset: 0, length: 4096);
      final out = Uint8List(4096);
      expect(file.readAt(0, out), 4096);
      expect(out, data);
    } finally {
      file.close();
    }
  });

  test('cloneFileSync uses APFS clone', () {
    final src = openMmapFileSync(srcPath);
    try {
      src.truncate(1 << 20);
      src.writeAt(0, Uint8List.fromList([1, 2, 3, 4]));
      src.flush();
    } finally {
      src.close();
    }
    cloneFileSync(srcPath, dstPath);
    expect(File(dstPath).lengthSync(), 1 << 20);
    final out = Uint8List(4);
    final dst = openMmapFileSync(dstPath);
    try {
      expect(dst.readAt(0, out), 4);
      expect(out, [1, 2, 3, 4]);
    } finally {
      dst.close();
    }
  });
}
