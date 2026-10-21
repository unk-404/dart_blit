/// Concurrency, barrier and durability stress tests for [ParallelBytesFile].
///
/// The default workload is 100k 4 KiB random reads/writes per round over a
/// small working set, for two rounds, using real temp files (no mocks).  Set
/// `BYTES_STRESS_OPS` to shrink it for a quick local run:
///
///     $env:BYTES_STRESS_OPS = '20000'; dart test test/native/stress_test.dart
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart';

const int _blockSize = 4096;
const int _slots = 2048; // 8 MiB working set
const int _batchSize = 256;
const int _rounds = 2;

int _opsPerRound() {
  final raw = Platform.environment['BYTES_STRESS_OPS'];
  if (raw == null) return 100000;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 100) return 100000;
  return parsed;
}

/// A deterministic 4 KiB block that encodes its own identity in the header and
/// fills the rest with a byte derived from `(slot, seq)`.
///
/// Verification regenerates the expected block instead of keeping 8 MiB of
/// shadow buffers alive; that also catches stale/cross-slot writes.
Uint8List _pattern(int round, int slot, int seq) {
  final block = Uint8List(_blockSize);
  block[0] = round & 0xFF;
  block[1] = (round >> 8) & 0xFF;
  block[2] = slot & 0xFF;
  block[3] = (slot >> 8) & 0xFF;
  block[4] = seq & 0xFF;
  block[5] = (seq >> 8) & 0xFF;
  block[6] = (seq >> 16) & 0xFF;
  block[7] = (seq >> 24) & 0xFF;
  block.fillRange(8, _blockSize, (slot * 7 + seq * 13) & 0xFF);
  return block;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _workers() => math.min(8, math.max(2, Platform.numberOfProcessors));

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bytes_stress_');
    path = '${dir.path}${Platform.pathSeparator}stress.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('ParallelBytesFile stress', () {
    test('100k concurrent random 4K reads/writes stay consistent', () async {
      final ops = _opsPerRound();
      final writeOps = ops * 3 ~/ 5;
      final readOps = ops - writeOps;
      final pool = await ParallelBytesFile.open(path, maxWorkers: _workers());
      final rnd = math.Random(0x5753);
      try {
        expect(pool.activeWorkers, _workers());

        for (var round = 0; round < _rounds; round++) {
          await pool.truncate(0);
          final seqOf = List<int>.filled(_slots, -1);

          // ---- concurrent write phase -------------------------------------
          var perm = List<int>.generate(_slots, (i) => i)..shuffle(rnd);
          var permIndex = 0;
          var seq = 0;
          var done = 0;
          var maxSlot = -1;
          while (done < writeOps) {
            if (permIndex >= perm.length) {
              perm = List<int>.generate(_slots, (i) => i)..shuffle(rnd);
              permIndex = 0;
            }
            // One batch never contains the same slot twice: overlapping writes
            // are explicitly unordered, so the shadow model must be unambiguous.
            final n = math.min(
              math.min(_batchSize, perm.length - permIndex),
              writeOps - done,
            );
            final offsets = <int>[];
            final blocks = <Uint8List>[];
            for (var i = 0; i < n; i++) {
              final slot = perm[permIndex++];
              offsets.add(slot * _blockSize);
              blocks.add(_pattern(round, slot, seq));
              seqOf[slot] = seq;
              if (slot > maxSlot) maxSlot = slot;
              seq++;
            }
            final total = await pool.writeMany(offsets, blocks);
            expect(
              total,
              n * _blockSize,
              reason: 'round $round write batch at op $done',
            );
            done += n;
          }
          expect(pool.pending, 0);
          expect(pool.lengthSync, (maxSlot + 1) * _blockSize);

          // ---- verify every written slot (last-write-wins) ----------------
          final allOffsets = <int>[
            for (var slot = 0; slot <= maxSlot; slot++) slot * _blockSize,
          ];
          final blocks = await pool.readMany(allOffsets, _blockSize);
          final mismatched = <int>[];
          for (var slot = 0; slot <= maxSlot; slot++) {
            final expected = _pattern(round, slot, seqOf[slot]);
            if (!_bytesEqual(blocks[slot], expected)) mismatched.add(slot);
          }
          expect(
            mismatched,
            isEmpty,
            reason: 'round $round full-file verification',
          );

          // ---- concurrent random read phase -------------------------------
          final badReads = <int>[];
          var readDone = 0;
          while (readDone < readOps) {
            final n = math.min(_batchSize, readOps - readDone);
            final offsets = <int>[
              for (var i = 0; i < n; i++) rnd.nextInt(_slots) * _blockSize,
            ];
            final reads = await pool.readMany(offsets, _blockSize);
            for (var i = 0; i < n; i++) {
              final slot = offsets[i] ~/ _blockSize;
              if (seqOf[slot] < 0) continue;
              if (!_bytesEqual(reads[i], _pattern(round, slot, seqOf[slot]))) {
                badReads.add(slot);
              }
            }
            readDone += n;
          }
          expect(badReads, isEmpty, reason: 'round $round random reads');
          expect(pool.pending, 0);
          expect(pool.isClosed, isFalse);
        }
      } finally {
        await pool.close();
      }
      expect(pool.isClosed, isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('single-worker pool is consistent', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 1);
      try {
        await pool.truncate(0);
        final offsets = [for (var i = 0; i < 32; i++) i * _blockSize];
        final blocks = [for (var i = 0; i < 32; i++) _pattern(0, i, i)];
        expect(await pool.writeMany(offsets, blocks), 32 * _blockSize);
        final reads = await pool.readMany(offsets, _blockSize);
        for (var i = 0; i < 32; i++) {
          expect(reads[i], blocks[i]);
        }
      } finally {
        await pool.close();
      }
    });
  });

  group('ParallelBytesFile barriers', () {
    test(
      'append observes earlier queued writes without awaiting them',
      () async {
        final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
        try {
          await pool.truncate(0);
          const blocks = 32;
          final writes = <Future<int>>[
            for (var i = 0; i < blocks; i++)
              pool.writeAt(i * _blockSize, _pattern(0, i, i)),
          ];
          // Submitted while the writes are still queued: append is a barrier.
          expect(await pool.append(Uint8List.fromList([0xAB, 0xCD, 0xEF])), 3);
          await Future.wait(writes);
          expect(pool.lengthSync, blocks * _blockSize + 3);
          expect(await pool.read(blocks * _blockSize, 3), [0xAB, 0xCD, 0xEF]);

          // The appended bytes did not disturb the blocks.
          final read = await pool.read(31 * _blockSize, _blockSize);
          expect(read, _pattern(0, 31, 31));
        } finally {
          await pool.close();
        }
      },
    );

    test('truncate is a barrier for queued writes', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
      try {
        await pool.truncate(0);
        await pool.writeAt(0, Uint8List.fromList(List<int>.filled(4096, 1)));
        final lateWrites = <Future<int>>[
          for (var i = 0; i < 16; i++)
            pool.writeAt(i * 256, Uint8List.fromList([i, i, i])),
        ];
        await pool.truncate(16);
        await Future.wait(lateWrites);
        expect(pool.lengthSync, 16);
        expect((await pool.read(0, 16)).length, 16);
        expect(await pool.read(16, 16), isEmpty, reason: 'past the new EOF');
      } finally {
        await pool.close();
      }
    });

    test('flush is a barrier and data survives close/reopen', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
      final offsets = [for (var i = 0; i < 64; i++) i * _blockSize];
      final blocks = [for (var i = 0; i < 64; i++) _pattern(3, i, i)];
      try {
        await pool.truncate(0);
        await pool.writeMany(offsets, blocks);
        await pool.flush();
        expect(pool.lengthSync, 64 * _blockSize);
      } finally {
        await pool.close();
      }

      final reopened = await ParallelBytesFile.open(
        path,
        create: false,
        maxWorkers: 2,
      );
      try {
        final reads = await reopened.readMany(offsets, _blockSize);
        for (var i = 0; i < 64; i++) {
          expect(reads[i], blocks[i]);
        }
      } finally {
        await reopened.close();
      }
    });
  });

  group('ParallelBytesFile close semantics', () {
    test('close drains in-flight work, then rejects everything', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 4);
      await pool.truncate(0);
      final writes = <Future<int>>[
        for (var i = 0; i < 64; i++)
          pool.writeAt(i * _blockSize, _pattern(7, i, i)),
      ];
      await pool.close();
      final results = await Future.wait(writes);
      expect(results.every((n) => n == _blockSize), isTrue);
      expect(pool.isClosed, isTrue);
      expect(pool.activeWorkers, 0);
      expect(pool.pending, 0);

      await expectLater(pool.readMany([0], _blockSize), throwsStateError);
      await expectLater(pool.read(0, 4), throwsStateError);
      await expectLater(pool.readAt(0, Uint8List(4)), throwsStateError);
      await expectLater(pool.writeAt(0, Uint8List(4)), throwsStateError);
      await expectLater(pool.append(Uint8List(4)), throwsStateError);
      expect(() => pool.truncate(0), throwsStateError);
      expect(() => pool.flush(), throwsStateError);
      await expectLater(pool.length, throwsStateError);
      expect(() => pool.lengthSync, throwsStateError);

      // Everything acknowledged before close is durable.
      final reopened = await ParallelBytesFile.open(path, maxWorkers: 2);
      try {
        expect(await reopened.length, 64 * _blockSize);
        expect(
          await reopened.read(63 * _blockSize, _blockSize),
          _pattern(7, 63, 63),
        );
      } finally {
        await reopened.close();
      }

      await pool.close(); // idempotent
      await pool.close();
      expect(pool.isClosed, isTrue);
    });

    test('delete closes the pool and removes the file', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 2);
      await pool.writeAt(0, Uint8List.fromList([1, 2, 3]));
      await pool.delete();
      expect(pool.isClosed, isTrue);
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('ParallelBytesFile API edges', () {
    test('readMany/writeMany preserve request order and report EOF', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 8);
      try {
        await pool.truncate(0);
        final offsets = [for (var i = 0; i < 100; i++) i * 16];
        final blocks = [
          for (var i = 0; i < 100; i++)
            Uint8List(16)..fillRange(0, 16, i & 0xFF),
        ];
        expect(await pool.writeMany(offsets, blocks), 1600);

        final reversed = offsets.reversed.toList(growable: false);
        final reads = await pool.readMany(reversed, 16);
        for (var i = 0; i < 100; i++) {
          expect(reads[i], blocks[99 - i]);
        }

        expect(await pool.read(1600, 16), isEmpty, reason: 'read at EOF');
        expect((await pool.read(1590, 16)).length, 10);
        final dst = Uint8List(16);
        expect(await pool.readAt(1590, dst), 10);
        expect(dst.sublist(0, 10), blocks[99].sublist(6));

        // Sub-range read/write into caller buffers.
        final sub = Uint8List(8);
        expect(await pool.readAt(0, sub, start: 4, end: 8), 4);
        expect(sub.sublist(0, 4), Uint8List(4));
        await pool.writeAt(
          32,
          Uint8List.fromList([1, 2, 3, 4]),
          start: 1,
          end: 3,
        );
        expect(await pool.read(32, 2), [2, 3]);
      } finally {
        await pool.close();
      }
    });

    test('truncate extends with zeros and shrinks', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 2);
      try {
        await pool.truncate(0);
        await pool.writeAt(0, Uint8List.fromList([1, 2, 3]));
        await pool.truncate(1 << 20);
        expect(await pool.length, 1 << 20);
        final gap = await pool.read(4096, 4096);
        expect(gap.length, 4096);
        expect(gap.every((b) => b == 0), isTrue);
        expect(await pool.read(0, 3), [1, 2, 3]);

        await pool.truncate(1);
        expect(await pool.length, 1);
        expect((await pool.read(0, 16)).length, 1);
      } finally {
        await pool.close();
      }
    });

    test('invalid arguments are rejected', () async {
      final pool = await ParallelBytesFile.open(path, maxWorkers: 2);
      try {
        await pool.truncate(64);
        await expectLater(pool.readAt(-1, Uint8List(4)), throwsRangeError);
        await expectLater(pool.read(-1, 4), throwsRangeError);
        await expectLater(pool.read(0, -1), throwsRangeError);
        await expectLater(pool.writeAt(-1, Uint8List(4)), throwsRangeError);
        await expectLater(
          pool.readAt(0, Uint8List(4), start: 2, end: 1),
          throwsRangeError,
        );
        await expectLater(
          pool.readAt(0, Uint8List(4), start: 0, end: 5),
          throwsRangeError,
        );
        await expectLater(pool.readMany([0], -1), throwsRangeError);
        await expectLater(
          pool.writeMany([0], <Uint8List>[]),
          throwsArgumentError,
        );
        expect(() => pool.truncate(-1), throwsRangeError);
      } finally {
        await pool.close();
      }
    });

    test('read-only pool rejects writes', () async {
      var pool = await ParallelBytesFile.open(path, maxWorkers: 2);
      await pool.writeAt(0, Uint8List.fromList([1, 2, 3]));
      await pool.close();

      pool = await ParallelBytesFile.open(
        path,
        create: false,
        readOnly: true,
        maxWorkers: 2,
      );
      try {
        expect(pool.readOnly, isTrue);
        final out = Uint8List(3);
        expect(await pool.readAt(0, out), 3);
        expect(out, [1, 2, 3]);
        await expectLater(pool.writeAt(0, Uint8List(1)), throwsStateError);
        await expectLater(pool.append(Uint8List(1)), throwsStateError);
        expect(() => pool.truncate(0), throwsStateError);
      } finally {
        await pool.close();
      }
    });

    test('create:false fails on a missing file', () async {
      await expectLater(
        ParallelBytesFile.open(path, create: false),
        throwsA(isA<Exception>()),
      );
    });
  });
}

