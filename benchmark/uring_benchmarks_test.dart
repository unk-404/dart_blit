// Linux-only Dart io_uring benchmark.
//
// Run on Ubuntu:
//   dart run benchmark_test --output jsonl benchmark/uring_benchmarks_test.dart
//
// One measured body submits 32 independent 4 KiB operations through the Dart
// UringBytesFile backend; chart rows multiply the body rate by 32.

@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart'
    show Timeout, setUpAll, tearDownAll;

const int _fileSize = 1 << 30;
const int _block = 4096;
const int _seqBlock = 8 << 20;
const int _batch = 32;

final Directory _benchDir = Directory(
  '${Directory.current.path}${Platform.pathSeparator}.dart_tool'
  '${Platform.pathSeparator}bench_uring',
)..createSync(recursive: true);
final String _path =
    '${_benchDir.path}${Platform.pathSeparator}uring_bench.bin';

late final UringBytesFile _file;
late final List<int> _offsets;
late final List<Uint8List> _blocks;
var _sink = 0;

void _ensureFile() {
  final f = openMmapFileSync(_path);
  try {
    f.truncate(_fileSize);
    final pattern = Uint8List(_seqBlock);
    for (var i = 0; i < pattern.length; i++) {
      pattern[i] = (i * 31 + 7) & 0xFF;
    }
    for (var offset = 0; offset < _fileSize; offset += _seqBlock) {
      f.writeAt(offset, pattern);
    }
    f.flush();
  } finally {
    f.close();
  }
}

void bench(String name, dynamic Function() body) =>
    benchmark(name, body, timeout: const Timeout(Duration(minutes: 2)));

void main() {
  setUpAll(() async {
    if (!Platform.isLinux) {
      throw UnsupportedError('io_uring benchmark is Linux-only');
    }
    _ensureFile();
    _file = await openUringBytesFile(_path, entries: 64);
    final random = Random(1234);
    _offsets = [
      for (var i = 0; i < _batch; i++)
        random.nextInt(_fileSize ~/ _block) * _block,
    ];
    _blocks = [
      for (var i = 0; i < _batch; i++) Uint8List.fromList(_patternBlock(i)),
    ];
  });

  tearDownAll(() async {
    await _file.close();
    final f = File(_path);
    if (f.existsSync()) f.deleteSync();
  });

  bench('uring.read.random4K.qd32', () async {
    final counts = await _file.readMany(_offsets, _block);
    for (final n in counts) {
      _sink ^= n;
    }
  });

  bench('uring.write.random4K.qd32', () async {
    final counts = await _file.writeMany(_offsets, _blocks);
    for (final n in counts) {
      _sink ^= n;
    }
  });

  if (_sink == 0x7fffffff) print('unreachable sink=$_sink');
}

List<int> _patternBlock(int seed) =>
    [for (var i = 0; i < _block; i++) (seed + i * 17) & 0xFF];

