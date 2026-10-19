// 32 GiB random 4K benchmark, benchmark_harness format.
//
// Run:
//   dart run benchmark/random_32g_benchmark.dart
//   BYTES_BENCH_GB=8 dart run benchmark/random_32g_benchmark.dart
//
// Setup fills the file once (default 32 GiB; > RAM, so reads are genuinely
// cold-ish).  Each measured iteration is one 4K operation; results are IOPS and
// MiB/s.  pwrite/mmap-write are flushed in teardown; the IOPS number itself is
// buffered for pwrite.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart';

import '_bench.dart';

final int _size = benchIntEnv('BYTES_BENCH_GB', 32) << 30;
const int _block = 4096;
final String _path = benchPath('random_g${_size >> 30}');
final Random _rnd = Random(4242);
late final Uint8List _buf;

void _ensureFile() {
  final f = openMmapFileSync(_path);
  if (f.length == _size) {
    f.close();
    return;
  }
  f.truncate(_size, sparse: true);
  final chunk = Uint8List(8 << 20);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = (i * 31 + 7) & 0xFF;
  }
  final sw = Stopwatch()..start();
  for (var off = 0; off < _size; off += chunk.length) {
    f.writeAt(off, chunk);
  }
  f.flush();
  f.close();
  print('filled ${(_size >> 30)} GiB in ${sw.elapsedMilliseconds} ms');
}

int _offset() => _rnd.nextInt(_size ~/ _block) * _block;

abstract class _FileBenchmark extends UnitBenchmark {
  _FileBenchmark(super.name, this.readOnly);

  final bool readOnly;
  late final MmapFile file;

  @override
  void setup() {
    file = openMmapFileSync(_path, create: false, readOnly: readOnly);
  }

  @override
  void teardown() {
    if (!readOnly) file.flush();
    file.close();
  }

  @override
  void report() {
    final us = measure();
    emitIops(name, 1, us);
    emitThroughput('$name.throughput', _block, us);
  }
}

class PreadRead4K extends _FileBenchmark {
  PreadRead4K() : super('random.pread.read.random4K', true);

  @override
  void run() {
    file.readAt(_offset(), _buf);
  }
}

class PwriteWrite4K extends _FileBenchmark {
  PwriteWrite4K() : super('random.pwrite.write.random4K', false);

  @override
  void run() {
    file.writeAt(_offset(), _buf);
  }
}

class MmapRead4K extends _FileBenchmark {
  MmapRead4K() : super('random.mmap.read.random4K', true);
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
    _buf.setRange(0, _block, view, _offset());
  }
}

class MmapWrite4K extends _FileBenchmark {
  MmapWrite4K() : super('random.mmap.write.random4K', false);
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
    final off = _offset();
    view.setRange(off, off + _block, _buf);
  }
}

void main() {
  _buf = Uint8List(_block);
  for (var i = 0; i < _block; i++) {
    _buf[i] = (i * 17 + 3) & 0xFF;
  }
  _ensureFile();
  print('size=${_size >> 30} GiB, block=$_block, harness=benchmark_harness');

  PreadRead4K().report();
  PwriteWrite4K().report();
  MmapRead4K().report();
  MmapWrite4K().report();

  final f = File(_path);
  if (f.existsSync()) f.deleteSync();
}
