// File I/O benchmarks on a 1 GiB file, benchmark_harness format.
//
// Run: dart run benchmark/io_benchmark.dart
//
// The file is filled once; sequential reads are page-cache friendly.  Random
// 4K numbers are IOPS; pwrite is buffered (it is flushed in teardown), so do not
// read it as a durability number.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart';

import '_bench.dart';

const int _size = 1 << 30;
const int _seqBlock = 8 << 20;
const int _randBlock = 4096;

final String _path = benchPath('io1g');
final Random _rnd = Random(1234);
late final Uint8List _seqBuf;
late final Uint8List _randBuf;

void _ensureFile() {
  final f = openMmapFileSync(_path);
  if (f.length == _size) {
    f.close();
    return;
  }
  f.truncate(_size, sparse: true);
  final chunk = Uint8List(_seqBlock);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = (i * 31 + 7) & 0xFF;
  }
  for (var off = 0; off < _size; off += _seqBlock) {
    f.writeAt(off, chunk);
  }
  f.flush();
  f.close();
}

int _randOffset() => _rnd.nextInt(_size ~/ _randBlock) * _randBlock;

abstract class _FileBenchmark extends UnitBenchmark {
  _FileBenchmark(super.name, this.readOnly);

  final bool readOnly;
  late final MmapFile file;
  var offset = 0;

  @override
  void setup() {
    file = openMmapFileSync(_path, create: false, readOnly: readOnly);
  }

  @override
  void teardown() {
    if (!readOnly) file.flush();
    file.close();
  }
}

class SequentialReadBenchmark extends _FileBenchmark {
  SequentialReadBenchmark() : super('file.read.8MiB', true);
  final Uint8List dst = Uint8List(_seqBlock);

  @override
  void run() {
    final got = file.readAt(offset, dst);
    offset = (offset + _seqBlock) % _size;
    if (got == 0) throw StateError('EOF');
  }

  @override
  void report() {
    final us = measure();
    emitThroughput(name, _seqBlock, us);
  }
}

class SequentialWriteBenchmark extends _FileBenchmark {
  SequentialWriteBenchmark() : super('file.write.8MiB', false);

  @override
  void run() {
    file.writeAt(offset, _seqBuf);
    offset = (offset + _seqBlock) % _size;
  }

  @override
  void report() {
    final us = measure();
    emitThroughput(name, _seqBlock, us);
  }
}

class RandomRead4KBenchmark extends _FileBenchmark {
  RandomRead4KBenchmark() : super('file.read.random4K', true);

  @override
  void run() {
    file.readAt(_randOffset(), _randBuf);
  }

  @override
  void report() {
    final us = measure();
    emitIops(name, 1, us);
    emitThroughput('$name.throughput', _randBlock, us);
  }
}

class RandomWrite4KBenchmark extends _FileBenchmark {
  RandomWrite4KBenchmark() : super('file.write.random4K', false);

  @override
  void run() {
    file.writeAt(_randOffset(), _randBuf);
  }

  @override
  void report() {
    final us = measure();
    emitIops(name, 1, us);
    emitThroughput('$name.throughput', _randBlock, us);
  }
}

class MmapRandomRead4KBenchmark extends _FileBenchmark {
  MmapRandomRead4KBenchmark() : super('mmap.read.random4K', true);
  late final MappedRegion region;
  late final Uint8List view;

  @override
  void setup() {
    super.setup();
    region = file.map(offset: 0, length: _size, writable: false);
    view = region.bytes;
  }

  @override
  void teardown() {
    region.close();
    super.teardown();
  }

  @override
  void run() {
    _randBuf.setRange(0, _randBlock, view, _randOffset());
  }

  @override
  void report() {
    final us = measure();
    emitIops(name, 1, us);
    emitThroughput('$name.throughput', _randBlock, us);
  }
}

class MmapRandomWrite4KBenchmark extends _FileBenchmark {
  MmapRandomWrite4KBenchmark() : super('mmap.write.random4K', false);
  late final MappedRegion region;
  late final Uint8List view;

  @override
  void setup() {
    super.setup();
    region = file.map(offset: 0, length: _size);
    view = region.bytes;
  }

  @override
  void teardown() {
    region.flush();
    region.close();
    super.teardown();
  }

  @override
  void run() {
    final off = _randOffset();
    view.setRange(off, off + _randBlock, _randBuf);
  }

  @override
  void report() {
    final us = measure();
    emitIops(name, 1, us);
    emitThroughput('$name.throughput', _randBlock, us);
  }
}

void main() {
  _seqBuf = Uint8List(_seqBlock);
  _randBuf = Uint8List(_randBlock);
  for (var i = 0; i < _seqBuf.length; i++) {
    _seqBuf[i] = (i * 17 + 3) & 0xFF;
  }
  for (var i = 0; i < _randBuf.length; i++) {
    _randBuf[i] = (i * 7 + 1) & 0xFF;
  }
  _ensureFile();

  SequentialReadBenchmark().report();
  SequentialWriteBenchmark().report();
  RandomRead4KBenchmark().report();
  RandomWrite4KBenchmark().report();
  MmapRandomRead4KBenchmark().report();
  MmapRandomWrite4KBenchmark().report();

  final f = File(_path);
  if (f.existsSync()) f.deleteSync();
}
