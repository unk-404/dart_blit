// Isolate-pool concurrency benchmark, benchmark_harness format.
//
// Run: dart run benchmark/parallel_benchmark.dart
//
// One GiB file, 4K reads, batch of 32 reads per measured iteration, so the
// harness overhead is amortized and IOPS reflect the pool.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:blit/bytes_ffi.dart';

import '_bench.dart';

final int _size = benchIntEnv('BYTES_BENCH_GB', 1) << 30;
const int _block = 4096;
final String _path = benchPath('parallel_g${_size >> 30}');
final Random _rnd = Random(99);
final bool _useIocp = Platform.environment['BYTES_POOL_IOCP'] == '1';
int _sink = 0;

void _ensureFile() {
  final f = openMmapFileSync(_path);
  if (f.length == _size) {
    f.close();
    return;
  }
  f.truncate(_size, sparse: true);
  final chunk = Uint8List(8 << 20);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = (i * 13 + 5) & 0xFF;
  }
  for (var off = 0; off < _size; off += chunk.length) {
    f.writeAt(off, chunk);
  }
  f.flush();
  f.close();
}

int _offset() => _rnd.nextInt(_size ~/ _block) * _block;

class PoolBenchmark extends AsyncBenchmarkBase {
  PoolBenchmark(this.workers)
      : super('pool.read.random4K.w$workers${_useIocp ? '.iocp' : ''}');

  final int workers;
  late final ParallelBytesFile pool;

  @override
  Future<void> setup() async {
    pool = await ParallelBytesFile.open(
      _path,
      create: false,
      readOnly: true,
      maxWorkers: workers,
      useIocp: _useIocp,
    );
  }

  int get ops => workers * ParallelBytesFile.batchSize;

  @override
  Future<void> run() async {
    final offsets = [for (var i = 0; i < ops; i++) _offset()];
    final datas = await pool.readMany(offsets, _block);
    var total = 0;
    for (final data in datas) {
      total += data.length;
    }
    _sink ^= total;
  }

  @override
  Future<void> teardown() async {
    await pool.close();
  }

  @override
  Future<void> report() async {
    final us = await measure();
    emitIops(name, ops, us);
    emitThroughput('$name.throughput', ops * _block, us);
  }
}

void main() async {
  _ensureFile();
  for (final workers in [1, 2, 4, 8, 16]) {
    await PoolBenchmark(workers).report();
  }
  final f = File(_path);
  if (f.existsSync()) f.deleteSync();
  print('sink=$_sink');
}
