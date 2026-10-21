@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String srcPath;
  late String dstPath;

  setUp(() {
    dir = Directory('${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}placeholder_'
        '${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    srcPath = '${dir.path}${Platform.pathSeparator}src.bin';
    dstPath = '${dir.path}${Platform.pathSeparator}dst.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('placeholder can atomically map different files', () {
    final src = openMmapFileSync(srcPath);
    final dst = openMmapFileSync(dstPath);
    MmapPlaceholder? placeholder;
    try {
      const size = 1 << 20;
      src.truncate(size);
      dst.truncate(size);
      final first = Uint8List(size)..fillRange(0, size, 0x11);
      final second = Uint8List(size)..fillRange(0, size, 0x22);
      src.writeAt(0, first);
      dst.writeAt(0, second);
      src.flush();
      dst.flush();

      placeholder = src.createPlaceholder(size);
      final view1 = placeholder.map(src);
      expect(view1.bytes.sublist(0, 16).every((b) => b == 0x11), isTrue);
      view1.close();

      final view2 = placeholder.map(dst);
      expect(view2.bytes.sublist(0, 16).every((b) => b == 0x22), isTrue);
      view2.close();
    } on UnsupportedError {
      // Older Windows without MapViewOfFile3.
      return;
    } finally {
      placeholder?.close();
      src.close();
      dst.close();
    }
  });
}

