@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart';

void main() {
  late String path;

  setUp(() {
    path = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'blit_direct_${DateTime.now().microsecondsSinceEpoch}.bin';
  });

  tearDown(() {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  test('direct I/O aligned read/write', () {
    const size = 1 << 20;
    final file = openMmapFileSync(path, direct: true);
    try {
      file.truncate(size);
      final src = Uint8List(size);
      for (var i = 0; i < src.length; i++) {
        src[i] = (i * 17 + 3) & 0xFF;
      }
      expect(file.writeAt(0, src), size);
      file.flush();

      final dst = Uint8List(size);
      expect(file.readAt(0, dst), size);
      expect(dst, src);
    } finally {
      file.close();
    }
  });

  test('direct I/O largePages opt-in falls back safely', () {
    final file = openMmapFileSync(path, direct: true, largePages: true);
    try {
      file.truncate(1 << 20);
      final src = Uint8List(1 << 20)..fillRange(0, 1 << 20, 0x42);
      expect(file.writeAt(0, src), 1 << 20);
      final dst = Uint8List(1 << 20);
      expect(file.readAt(0, dst), 1 << 20);
      expect(dst, src);
      // Privilege-dependent; fallback must still be correct.
      expect(file.usesLargePages, anyOf(isTrue, isFalse));
    } finally {
      file.close();
    }
  });

  test('direct I/O rejects unaligned access and mmap', () {
    final file = openMmapFileSync(path, direct: true);    try {
      file.truncate(1 << 20);
      expect(
        () => file.writeAt(1, Uint8List(4096)),
        throwsArgumentError,
      );
      expect(
        () => file.readAt(0, Uint8List(100)),
        throwsArgumentError,
      );
      expect(() => file.map(length: 4096), throwsUnsupportedError);
    } finally {
      file.close();
    }
  });

  test('direct I/O pool aligned read/write', () async {
    const blocks = 64;
    const blockSize = 4096;
    final pool = await ParallelBytesFile.open(
      path,
      direct: true,
      maxWorkers: 4,
    );
    try {
      await pool.truncate(blocks * blockSize);
      final data = [
        for (var i = 0; i < blocks; i++)
          Uint8List(blockSize)..fillRange(0, blockSize, i),
      ];
      final offsets = [for (var i = 0; i < blocks; i++) i * blockSize];
      expect(await pool.writeMany(offsets, data), blocks * blockSize);
      final reads = await pool.readMany(offsets, blockSize);
      for (var i = 0; i < blocks; i++) {
        expect(reads[i], data[i]);
      }
    } finally {
      await pool.close();
    }
  });
}

