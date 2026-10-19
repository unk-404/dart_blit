@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/src/io/native/iocp_windows.dart';
import 'package:test/test.dart';

/// Tests for the Windows IOCP/overlapped batch engine.
///
/// The engine only makes sense on Windows (it links `kernel32.dll`); on other
/// platforms the file still compiles and the single test is skipped.
void main() {
  if (!Platform.isWindows) {
    test('Windows IOCP engine (skipped on this platform)', () {}, skip: true);
    return;
  }

  const block = 4096;
  const eightMiB = 8 << 20;

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bytes_iocp_test_');
    path = '${dir.path}${Platform.pathSeparator}iocp.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Uint8List pattern(int length, int seed) {
    final data = Uint8List(length);
    for (var i = 0; i < length; i++) {
      data[i] = (i * 31 + seed * 7 + (i >> 8)) & 0xFF;
    }
    return data;
  }

  test('8 MiB writeMany/readMany round trip (QD 32)', () {
    const count = eightMiB ~/ block;
    final offsets = <int>[for (var i = 0; i < count; i++) i * block];
    final blocks = <Uint8List>[
      for (var i = 0; i < count; i++) pattern(block, i),
    ];

    final file = IocpFile.openSync(path, queueDepth: 32);
    try {
      file.truncate(eightMiB, sparse: true);
      expect(file.length, eightMiB);
      expect(file.writeManySync(offsets, blocks), eightMiB);
      file.flush();

      final loaded = file.readManySync(offsets, block);
      expect(loaded.length, eightMiB);
      for (var i = 0; i < count; i += 97) {
        expect(
          loaded.sublist(i * block, (i + 1) * block),
          blocks[i],
          reason: 'block $i',
        );
      }
      // Last block is always checked.
      expect(loaded.sublist(eightMiB - block), blocks.last);
    } finally {
      file.close();
    }

    // Independent cross-check through dart:io: the file on disk must match.
    final onDisk = File(path).readAsBytesSync();
    expect(onDisk.length, eightMiB);
    for (var i = 0; i < count; i += 131) {
      expect(
        onDisk.sublist(i * block, (i + 1) * block),
        blocks[i],
        reason: 'on-disk block $i',
      );
    }
  });

  test('queue depth 1/8/32 give identical data', () {
    final reference = pattern(eightMiB, 3);
    File(path).writeAsBytesSync(reference);
    final random = Random(2024);
    final offsets = <int>[
      for (var i = 0; i < 64; i++) random.nextInt(eightMiB ~/ block) * block,
    ];

    Uint8List? expected;
    for (final depth in <int>[1, 8, 32]) {
      final file = IocpFile.openSync(
        path,
        create: false,
        readOnly: true,
        queueDepth: depth,
      );
      try {
        final watch = Stopwatch()..start();
        final loaded = file.readManySync(offsets, block);
        watch.stop();
        final iops = offsets.length * 1e6 / watch.elapsedMicroseconds;
        // Informational only; the assertion is on the bytes, not the clock.
        print(
          '  QD=$depth  ${iops.toStringAsFixed(0)} IOPS '
          '(cold-ish single batch)',
        );
        expect(loaded.length, offsets.length * block);
        expected ??= loaded;
        expect(loaded, expected, reason: 'QD $depth differs from QD 1');
      } finally {
        file.close();
      }
    }
  });

  test('random 4K batch matches dart:io contents', () {
    final reference = pattern(eightMiB, 11);
    File(path).writeAsBytesSync(reference);
    final random = Random(99);
    final offsets = <int>[
      for (var i = 0; i < 256; i++) random.nextInt(eightMiB ~/ block) * block,
    ];

    final file = IocpFile.openSync(
      path,
      create: false,
      readOnly: true,
      queueDepth: 64,
    );
    try {
      final loaded = file.readManySync(offsets, block);
      expect(loaded.length, offsets.length * block);
      for (var i = 0; i < offsets.length; i++) {
        final at = offsets[i];
        expect(
          loaded.sublist(i * block, (i + 1) * block),
          reference.sublist(at, at + block),
          reason: 'request $i at offset $at',
        );
      }
    } finally {
      file.close();
    }
  });

  test('read-only handle rejects every write path', () {
    File(path).writeAsBytesSync(pattern(block * 4, 5));
    final file = IocpFile.openSync(path, create: false, readOnly: true);
    try {
      expect(file.readOnly, isTrue);
      final dst = Uint8List(block);
      expect(file.readAtSync(0, dst), block);
      expect(() => file.writeAtSync(0, Uint8List(1)), throwsStateError);
      expect(
        () => file.writeManySync(<int>[0], <Uint8List>[Uint8List(1)]),
        throwsStateError,
      );
      expect(() => file.truncate(1), throwsStateError);
      file.flush();
    } finally {
      file.close();
    }
  });

  test('EOF and range behaviour', () {
    const size = 8192;
    final content = pattern(size, 17);
    final file = IocpFile.openSync(path);
    try {
      file.truncate(size, sparse: false);
      file.writeAtSync(0, content);
      file.flush();

      expect(file.readAtSync(size, Uint8List(64)), 0);
      expect(file.readAtSync(size + 100, Uint8List(64)), 0);

      final tail = Uint8List(block);
      expect(file.readAtSync(size - 100, tail), 100);
      expect(tail.sublist(0, 100), content.sublist(size - 100));

      expect(file.readAtSync(0, Uint8List(0)), 0);

      // readManySync requires offset + blockLength <= length.
      expect(file.readManySync(<int>[0], size).length, size);
      expect(() => file.readManySync(<int>[0], size + 1), throwsRangeError);
      expect(() => file.readManySync(<int>[size], block), throwsRangeError);
      expect(() => file.readManySync(<int>[-1], block), throwsRangeError);
      expect(() => file.readManySync(<int>[], block), returnsNormally);
      expect(file.readManySync(<int>[], block), isEmpty);
      expect(file.readManySync(<int>[0], 0), isEmpty);

      // writeManySync: mismatched lists and extension beyond EOF.
      expect(
        () => file.writeManySync(<int>[0], <Uint8List>[]),
        throwsArgumentError,
      );
      expect(file.writeManySync(<int>[], <Uint8List>[]), 0);
      final extra = pattern(block, 21);
      expect(file.writeManySync(<int>[size], <Uint8List>[extra]), block);
      expect(file.length, size + block);
      final back = Uint8List(block);
      expect(file.readAtSync(size, back), block);
      expect(back, extra);
    } finally {
      file.close();
    }
  });

  test('truncate grows sparse and shrinks', () {
    final file = IocpFile.openSync(path);
    try {
      file.truncate(1 << 20, sparse: true);
      expect(file.length, 1 << 20);

      final zeros = Uint8List(block);
      expect(file.readAtSync(512 * 1024, zeros), block);
      expect(zeros.every((b) => b == 0), isTrue);

      final data = pattern(block, 31);
      expect(file.writeAtSync(0, data), block);
      file.flush();
      expect(file.readAtSync(0, Uint8List(block)), block);

      file.truncate(4096);
      expect(file.length, 4096);
      expect(file.readAtSync(4096, Uint8List(8)), 0);

      // sparse: false must still work (explicitly zero-filling gap).
      file.truncate(8192, sparse: false);
      expect(file.length, 8192);
      expect(file.readAtSync(4096, Uint8List(8)), 8);
    } finally {
      file.close();
    }
  });

  test('single-block readAt/writeAt, including partial views', () {
    final file = IocpFile.openSync(path);
    try {
      file.truncate(1 << 16, sparse: true);
      final src = pattern(1 << 16, 41);
      expect(file.writeAtSync(0, src), src.length);

      final dst = Uint8List(1024);
      expect(file.readAtSync(777, dst), 1024);
      expect(dst, src.sublist(777, 777 + 1024));

      final dst2 = Uint8List(64);
      expect(file.readAtSync(1000, dst2, start: 16, end: 48), 32);
      expect(dst2.sublist(16, 48), src.sublist(1000, 1032));
      expect(dst2.sublist(0, 16).every((b) => b == 0), isTrue);

      expect(() => file.readAtSync(-1, dst), throwsRangeError);
      expect(
        () => file.readAtSync(0, dst, start: 100, end: 50),
        throwsRangeError,
      );
    } finally {
      file.close();
    }
  });

  test('close is idempotent and operations after close throw', () {
    final file = IocpFile.openSync(path);
    file.truncate(1 << 20, sparse: true);
    file.writeAtSync(0, pattern(block, 55));
    final other = IocpFile.openSync(path, create: false, readOnly: true);
    other.close();
    file.close();
    expect(file.isClosed, isTrue);
    expect(() => file.close(), returnsNormally);
    expect(() => file.readAtSync(0, Uint8List(8)), throwsStateError);
    expect(() => file.writeAtSync(0, Uint8List(8)), throwsStateError);
    expect(() => file.readManySync(<int>[0], 8), throwsStateError);
    expect(() => file.truncate(1), throwsStateError);
    expect(() => file.flush(), throwsStateError);
    expect(() => file.length, throwsStateError);
    expect(File(path).lengthSync(), 1 << 20);
  });

  test('queueDepth is clamped to 1..128', () {
    final low = IocpFile.openSync(path, queueDepth: 0);
    expect(low.queueDepth, 1);
    low.close();
    final high = IocpFile.openSync(path, queueDepth: 999);
    expect(high.queueDepth, 128);
    high.close();
    final exact = IocpFile.openSync(path, queueDepth: 64);
    expect(exact.queueDepth, 64);
    exact.close();
  });

  test('open (async) works and create=false reports IocpException', () async {
    final missing =
        '${dir.path}${Platform.pathSeparator}missing_${DateTime.now().microsecondsSinceEpoch}.bin';
    expect(
      () => IocpFile.openSync(missing, create: false),
      throwsA(
        isA<IocpException>()
            .having((e) => e.op, 'op', 'CreateFileW')
            .having((e) => e.code, 'code', isNot(0))
            .having((e) => e.path, 'path', missing),
      ),
    );

    final file = await IocpFile.open(path, queueDepth: 16);
    expect(file.queueDepth, 16);
    expect(file.isClosed, isFalse);
    file.truncate(block, sparse: true);
    final payload = pattern(block, 77);
    expect(file.writeAtSync(0, payload), block);
    expect(file.readManySync(<int>[0], block), payload);
    file.close();
  });
}
