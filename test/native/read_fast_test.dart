@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}'
      '.dart_tool${Platform.pathSeparator}read_fast_'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    path = '${dir.path}${Platform.pathSeparator}data.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('auto-selects a pool for a small read-only file', () async {
    final data = Uint8List.fromList(List<int>.generate(64 * 1024, (i) => i));
    File(path).writeAsBytesSync(data);

    final fast = await ReadFast.open(path, workers: 2);
    try {
      expect(fast.engine, isNot(ReadFastEngine.isolatePool));
      expect(fast.workers, 2);
      final back = Uint8List(4096);
      expect(await fast.readAt(4096, back), 4096);
      expect(back, data.sublist(4096, 8192));
      expect(await fast.length, data.length);

      final many = await fast.readMany([0, 8192], 1024);
      expect(many, hasLength(2));
      expect(many[0], data.sublist(0, 1024));
      expect(many[1], data.sublist(8192, 9216));
    } finally {
      await fast.close();
    }
  });

  test('write mode keeps the portable pool', () async {
    File(path).writeAsBytesSync(<int>[]);
    final fast = await ReadFast.open(path, readOnly: false, workers: 2);
    try {
      final data = Uint8List.fromList([1, 2, 3, 4]);
      expect(await fast.writeAt(0, data), 4);
      final back = Uint8List(4);
      expect(await fast.readAt(0, back), 4);
      expect(back, data);
    } finally {
      await fast.close();
    }
  });
}

