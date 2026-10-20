// IndexedDB backend benchmark. Browser-only; emits benchmark_test-compatible
// JSONL so CI can merge these rows into the main chart (Dart-only rows).
//
// Run:
//   dart test -p chrome benchmark/idb_benchmarks_test.dart
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/src/io/web/web.dart';
import 'package:test/test.dart';

const int _fileSize = 32 * 1024 * 1024;
const int _block = 4096;
const int _seq = 8 * 1024 * 1024;
const int _warmup = 4;
const int _iterations = 24;

final _dbName =
    'blit-idb-bench-'
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
final _path = 'bench/idb.bin';
var _sink = 0;

Uint8List _pattern(int n, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (seed + i * 17) & 0xFF]);

Future<void> _measure(
  String name,
  String unit,
  int operationsPerBody,
  int bytesPerBody,
  Future<void> Function() body,
) async {
  for (var i = 0; i < _warmup; i++) {
    await body();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    await body();
  }
  sw.stop();
  final elapsed = sw.elapsedMicroseconds / 1000000.0;
  final value = unit == 'MiB/s'
      ? (bytesPerBody * _iterations) / elapsed / (1024 * 1024)
      : operationsPerBody * _iterations / elapsed;
  // ignore: avoid_print
  print(
    jsonEncode({
      'formatVersion': 1,
      'name': name,
      'compiler': 'dart-web',
      'throughput': {'value': value, 'unit': unit},
      'statistics': {'relativeMarginOfError': 0.0, 'samples': _iterations},
      'latency': {
        'mean': unit == 'MiB/s' ? 0.0 : 1000000.0 / value,
        'unit': 'microseconds',
      },
    }),
  );
}

void main() {
  test('IndexedDB benchmark', () async {
    final file = await openIdbBytesFileTyped(
      _path,
      chunkSize: 64 * 1024,
      databaseName: _dbName,
    );
    final seq = _pattern(_seq, seed: 7);
    final block = _pattern(_block, seed: 3);
    final rnd = Random(1234);
    final offsets = [
      for (var i = 0; i < 512; i++) rnd.nextInt(_fileSize ~/ _block) * _block,
    ];
    try {
      await file.truncate(_fileSize);
      for (var off = 0; off < _fileSize; off += _seq) {
        await file.writeAt(off, seq);
      }

      await _measure('idb.read.random4K', 'IOPS', 64, 0, () async {
        final dst = Uint8List(_block);
        for (var i = 0; i < 64; i++) {
          await file.readAt(offsets[i % offsets.length], dst);
          _sink ^= dst[0];
        }
      });
      await _measure('idb.write.random4K', 'IOPS', 64, 0, () async {
        for (var i = 0; i < 64; i++) {
          await file.writeAt(offsets[i % offsets.length], block);
        }
      });
      await _measure(
        'idb.read.sequential8MiB',
        'MiB/s',
        4,
        _fileSize,
        () async {
          for (var off = 0; off < _fileSize; off += _seq) {
            await file.readAt(off, seq);
            _sink ^= seq[0];
          }
        },
      );
      await _measure(
        'idb.write.sequential8MiB',
        'MiB/s',
        4,
        _fileSize,
        () async {
          for (var off = 0; off < _fileSize; off += _seq) {
            await file.writeAt(off, seq);
          }
        },
      );
    } finally {
      await file.close();
      await deleteIdbFile(_path, databaseName: _dbName);
      await shutdownIdbBackend();
    }
    if (_sink == 0x7fffffff) {
      throw StateError('unreachable sink');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
