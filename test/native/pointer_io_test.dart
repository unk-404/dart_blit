@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:blit/src/io/native/native.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}'
      '.dart_tool${Platform.pathSeparator}native_ptr_'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    path = '${dir.path}${Platform.pathSeparator}data.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('readAtPointer/writeAtPointer bypass typed-data copies', () {
    final file = openMmapFileSync(path);
    final src = calloc<Uint8>(4096);
    final dst = calloc<Uint8>(4096);
    try {
      for (var i = 0; i < 4096; i++) {
        src[i] = (i * 13 + 7) & 0xFF;
      }
      expect(file.writeAtPointer(0, src, 4096), 4096);
      expect(file.readAtPointer(0, dst, 4096), 4096);
      for (var i = 0; i < 4096; i++) {
        expect(dst[i], src[i]);
      }
      expect(file.length, 4096);
    } finally {
      calloc.free(src);
      calloc.free(dst);
      file.close();
    }
  });

  test('readAtPointer returns short read at EOF', () {
    final file = openMmapFileSync(path);
    final dst = calloc<Uint8>(4096);
    try {
      file.truncate(8);
      expect(file.readAtPointer(0, dst, 4096), 8);
      expect(file.readAtPointer(8, dst, 4096), 0);
    } finally {
      calloc.free(dst);
      file.close();
    }
  });
}

