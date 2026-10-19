@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bytes_pool_test_');
    path = '${dir.path}${Platform.pathSeparator}pool.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('parallel write/read with auto workers', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
    expect(pool.activeWorkers, 4);

    const size = 16 * 4096;
    for (var i = 0; i < 16; i++) {
      final chunk = Uint8List(4096)..fillRange(0, 4096, i);
      await pool.writeAt(i * 4096, chunk);
    }
    expect(await pool.length, size);

    final results = await Future.wait([
      for (var i = 0; i < 16; i++) pool.read(i * 4096, 4096),
    ]);
    for (var i = 0; i < 16; i++) {
      expect(results[i].length, 4096);
      expect(results[i][0], i);
      expect(results[i][4095], i);
    }

    await pool.close();
    expect(pool.isClosed, isTrue);
  });

  test('readAt fills caller buffer', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 2);
    final src = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
    await pool.writeAt(0, src);
    final dst = Uint8List(1000);
    expect(await pool.readAt(0, dst), 1000);
    expect(dst, src);
    await pool.close();
  });

  test('append and truncate are barriers', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
    await pool.writeAt(0, Uint8List.fromList([1, 2, 3]));
    await pool.append(Uint8List.fromList([4, 5]));
    expect(await pool.length, 5);
    await pool.truncate(2);
    expect(await pool.length, 2);
    final out = Uint8List(2);
    await pool.readAt(0, out);
    expect(out, [1, 2]);
    await pool.flush();
    await pool.close();
  });

  test('readMany/writeMany use the auto queue', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 8);
    final offsets = [for (var i = 0; i < 100; i++) i * 8];
    final blocks = [
      for (var i = 0; i < 100; i++) Uint8List(8)..fillRange(0, 8, i),
    ];
    expect(await pool.writeMany(offsets, blocks), 800);
    final reads = await pool.readMany(offsets, 8);
    expect(reads.length, 100);
    for (var i = 0; i < 100; i++) {
      expect(reads[i], blocks[i]);
    }
    expect(await pool.readMany([], 8), isEmpty);
    expect((await pool.readMany([0], 0)).single, isEmpty);
    await pool.close();
  });

  test('maxQueue applies backpressure without deadlock', () async {
    final pool = await ParallelBytesFile.open(
      path,
      maxWorkers: 2,
      maxQueue: 2,
    );
    try {
      await pool.truncate(0);
      final writes = [
        for (var i = 0; i < 64; i++)
          pool.writeAt(i * 8, Uint8List(8)..fillRange(0, 8, i)),
      ];
      await Future.wait(writes).timeout(const Duration(seconds: 20));
      expect(await pool.length, 64 * 8);
    } finally {
      await pool.close();
    }
  });

  test('readMany coalesces adjacent ranges and preserves order', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
    await pool.truncate(0);
    final blocks = [
      for (var i = 0; i < 64; i++)
        Uint8List(4096)..fillRange(0, 4096, i),
    ];
    final offsets = [for (var i = 0; i < 64; i++) i * 4096];
    expect(await pool.writeMany(offsets, blocks), 64 * 4096);

    // Deliberately unsorted: merging sorts internally, but results must map
    // back to the caller's requested order.
    final requested = [for (var i = 0; i < 64; i++) ((i * 17) % 64) * 4096];
    final reads = await pool.readMany(requested, 4096);
    for (var i = 0; i < requested.length; i++) {
      expect(reads[i], blocks[requested[i] ~/ 4096]);
    }
    await pool.close();
  });

  test('barrier drains jobs queued before it', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
    await pool.truncate(0);
    final writes = [
      for (var i = 0; i < 32; i++)
        pool.writeAt(
            i * 4096, Uint8List(4096)..fillRange(0, 4096, i)),
    ];
    // The old implementation paused dispatch and deadlocked here.
    final appended = await pool.append(Uint8List.fromList([1, 2, 3]));
    expect(appended, 3);
    await Future.wait(writes);
    expect(await pool.length, 32 * 4096 + 3);
    await pool.close();
  });

  test('close drains queued jobs instead of hanging', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
    final writes = [
      for (var i = 0; i < 32; i++)
        pool.writeAt(i * 4096, Uint8List(4096)),
    ];
    await pool.close().timeout(const Duration(seconds: 10));
    // Every submitted write either completed or failed deterministically.
    await Future.wait(writes.map((f) => f.catchError((_) => 0)));
    expect(pool.isClosed, isTrue);
  });

  test('IOCP worker engine (Windows only) is byte-identical', () async {
    if (!Platform.isWindows) {
      return;
    }
    final pool = await ParallelBytesFile.open(
      path,
      maxWorkers: 2,
      useIocp: true,
    );
    final offsets = [for (var i = 0; i < 64; i++) i * 4];
    final blocks = [
      for (var i = 0; i < 64; i++) Uint8List(4)..fillRange(0, 4, i),
    ];
    expect(await pool.writeMany(offsets, blocks), 256);
    final reads = await pool.readMany(offsets, 4);
    for (var i = 0; i < 64; i++) {
      expect(reads[i], blocks[i]);
    }
    await pool.close();
  });

  test('create:false on missing file fails', () async {
    await expectLater(
      ParallelBytesFile.open(path, create: false),
      throwsA(isA<Exception>()),
    );
  });

  test('delete removes the file', () async {
    final pool = await ParallelBytesFile.open(path, maxWorkers: 2);
    await pool.writeAt(0, Uint8List.fromList([1]));
    await pool.delete();
    expect(File(path).existsSync(), isFalse);
  });
}
