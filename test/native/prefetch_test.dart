@TestOn('vm')
library;

import 'dart:io';

import 'package:blit/bytes_ffi.dart';
import 'package:test/test.dart';

void main() {
  late String path;

  setUp(() {
    final dir = Directory('${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}prefetch_test')
      ..createSync(recursive: true);
    path = '${dir.path}${Platform.pathSeparator}'
        'prefetch_${DateTime.now().microsecondsSinceEpoch}.bin';
  });

  tearDown(() {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  test('prefetch/discard accept a subrange', () {
    final file = openMmapFileSync(path);
    try {
      file.truncate(1 << 20);
      final region = file.map(offset: 0, length: 1 << 20);
      region.prefetch(offset: 0, length: 4096);
      region.discard(offset: 0, length: 4096);
      region.prefetch();
      region.discard();
      region.close();
    } finally {
      file.close();
    }
  });

  test('prefetch/discard validate bounds', () {
    final file = openMmapFileSync(path);
    try {
      file.truncate(1 << 20);
      final region = file.map(offset: 0, length: 4096);
      expect(() => region.prefetch(offset: -1), throwsRangeError);
      expect(() => region.discard(offset: 0, length: 8192),
          throwsRangeError);
      region.close();
    } finally {
      file.close();
    }
  });
}
