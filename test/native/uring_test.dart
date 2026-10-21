@TestOn('linux')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart';

Uint8List _pattern(int n, {int seed = 0}) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (seed + i * 17) & 0xFF;
  }
  return out;
}

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}'
      '.dart_tool${Platform.pathSeparator}uring_'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    path = '${dir.path}${Platform.pathSeparator}data.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  tearDownAll(() async {
    // Shared-loop leases reuse idle reaper isolates. Close the process-wide
    // pool so `dart test` does not wait for an idle reaper forever.
    await UringBytesFile.closeSharedLoopPool(entries: 16);
  });

  test('write/read/append/truncate/flush', () async {
    final file = await openUringBytesFile(path, entries: 16);
    try {
      final data = _pattern(64 * 1024);
      expect(await file.writeAt(0, data), data.length);
      expect(await file.length, data.length);
      final back = Uint8List(data.length);
      expect(await file.readAt(0, back), data.length);
      expect(back, data);

      final tail = _pattern(4096, seed: 7);
      expect(await file.append(tail), tail.length);
      expect(await file.length, data.length + tail.length);

      await file.truncate(1024);
      expect(await file.length, 1024);
      await file.flush();
    } finally {
      await file.close();
    }
  });

  test('readMany/writeMany batch', () async {
    final file = await openUringBytesFile(path, entries: 16);
    try {
      final blocks = [for (var i = 0; i < 4; i++) _pattern(4096, seed: i * 31)];
      final offsets = [for (var i = 0; i < 4; i++) i * 4096];
      expect(await file.writeMany(offsets, blocks), everyElement(4096));
      final reads = await file.readMany(offsets, 4096);
      expect(reads, everyElement(4096));
      final all = Uint8List(4 * 4096);
      expect(await file.readAt(0, all), all.length);
      for (var i = 0; i < 4; i++) {
        expect(all.sublist(i * 4096, (i + 1) * 4096), blocks[i]);
      }
    } finally {
      await file.close();
    }
  });

  test('shared loop lease survives close/reopen', () async {
    final first = await openUringBytesFile(path, sharedLoop: true, entries: 16);
    final data = _pattern(4096);
    try {
      expect(await first.writeAt(0, data), data.length);
    } finally {
      await first.close();
    }

    final second = await openUringBytesFile(
      path,
      create: false,
      sharedLoop: true,
      entries: 16,
    );
    try {
      final back = Uint8List(data.length);
      expect(await second.readAt(0, back), data.length);
      expect(back, data);
    } finally {
      await second.close();
    }
  });

  test('read-only mode rejects writes', () async {
    final writer = await openUringBytesFile(path);
    await writer.writeAt(0, _pattern(8));
    await writer.close();

    final reader = await openUringBytesFile(
      path,
      create: false,
      readOnly: true,
    );
    try {
      expect(await reader.readAt(0, Uint8List(8)), 8);
      await expectLater(
        reader.writeAt(0, _pattern(8)),
        throwsA(isA<StateError>()),
      );
    } finally {
      await reader.close();
    }
  });
}

