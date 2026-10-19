// Windows IOCP engine benchmark: 4K random read/write queue-depth sweep.
//
// Run: dart run benchmark/iocp_benchmark.dart
//
// One measured iteration is a single batch of `queueDepth` independent 4K
// operations issued through `readManySync`/`writeManySync`, so the reported
// IOPS is `queueDepth / batch latency` and reflects the single-worker queue
// rather than benchmark-harness overhead.
//
// Environment:
//   BYTES_BENCH_GB   file size in GiB (default 1)
//
// Note: the benchmark file is created and then read, so the OS page cache may
// serve most of it.  The numbers are honest for this machine but are not a
// drop-the-cache cold-device measurement (Windows has no unprivileged
// equivalent of `posix_fadvise(POSIX_FADV_DONTNEED)`).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/src/io/native/iocp_windows.dart';

import '_bench.dart';

final int _fileSize = benchIntEnv('BYTES_BENCH_GB', 1) << 30;
const int _block = 4096;
final int _blockCount = _fileSize ~/ _block;
final String _path = benchPath('iocp_g${_fileSize >> 30}');
final Random _random = Random(1234);
final Uint8List _payload = _pattern(_block);
int _sink = 0;

Uint8List _pattern(int length) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = (i * 13 + 7) & 0xFF;
  }
  return data;
}

List<int> _randomOffsets(int count) => <int>[
  for (var i = 0; i < count; i++) _random.nextInt(_blockCount) * _block,
];

void _ensureFile() {
  final file = IocpFile.openSync(_path);
  if (file.length == _fileSize) {
    file.close();
    return;
  }
  print('creating $_path ($_fileSize bytes) ...');
  file.truncate(_fileSize, sparse: false);
  final chunk = _pattern(8 << 20);
  for (var offset = 0; offset < _fileSize; offset += chunk.length) {
    final length = min(chunk.length, _fileSize - offset);
    file.writeAtSync(offset, chunk, start: 0, end: length);
  }
  file.flush();
  file.close();
}

/// 4K random reads through a single IOCP handle at [queueDepth] outstanding.
final class IocpReadBenchmark extends UnitBenchmark {
  IocpReadBenchmark(this.queueDepth)
    : super('iocp.read.random4K.qd$queueDepth');

  final int queueDepth;
  late final IocpFile _file;

  @override
  void setup() {
    _file = IocpFile.openSync(
      _path,
      create: false,
      readOnly: true,
      queueDepth: queueDepth,
    );
  }

  @override
  void run() {
    final offsets = _randomOffsets(queueDepth);
    _sink ^= _file.readManySync(offsets, _block).length;
  }

  @override
  void teardown() {
    _file.close();
  }

  @override
  void report() {
    final micros = measure();
    emitIops(name, queueDepth, micros);
    emitThroughput('$name.throughput', queueDepth * _block, micros);
  }
}

/// 4K random writes through a single IOCP handle at [queueDepth] outstanding.
final class IocpWriteBenchmark extends UnitBenchmark {
  IocpWriteBenchmark(this.queueDepth)
    : super('iocp.write.random4K.qd$queueDepth');

  final int queueDepth;
  late final IocpFile _file;
  late final List<Uint8List> _blocks;

  @override
  void setup() {
    _file = IocpFile.openSync(_path, create: false, queueDepth: queueDepth);
    _blocks = List<Uint8List>.filled(queueDepth, _payload);
  }

  @override
  void run() {
    final offsets = _randomOffsets(queueDepth);
    _sink ^= _file.writeManySync(offsets, _blocks);
  }

  @override
  void teardown() {
    // Durability cost is real but belongs to the next barrier, not to the
    // per-batch IOPS this benchmark reports.
    _file.flush();
    _file.close();
  }

  @override
  void report() {
    final micros = measure();
    emitIops(name, queueDepth, micros);
    emitThroughput('$name.throughput', queueDepth * _block, micros);
  }
}

void main() {
  if (!Platform.isWindows) {
    print('SKIP  IOCP benchmark is Windows-only');
    return;
  }
  _ensureFile();
  print(
    'file: $_path ($_fileSize bytes), block: $_block, '
    'blocks: $_blockCount',
  );
  print('note: page cache may serve reads; this is not a cold-device run.');

  for (final queueDepth in <int>[1, 8, 32, 64, 128]) {
    IocpReadBenchmark(queueDepth).report();
  }
  for (final queueDepth in <int>[1, 8, 32, 64]) {
    IocpWriteBenchmark(queueDepth).report();
  }

  final file = File(_path);
  if (file.existsSync()) file.deleteSync();
  print('sink=$_sink');
}
