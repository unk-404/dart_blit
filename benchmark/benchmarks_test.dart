// Core + 1 GiB file + isolate-pool benchmarks, using package:benchmark_test.
//
// Run:
//   dart run benchmark_test --compile jit,aot benchmark/benchmarks_test.dart
//   dart run benchmark_test --output jsonl benchmark/benchmarks_test.dart
//
// benchmark_test reports ops/sec + RME for the whole body.  Bodies with an
// `xN` suffix run N operations; divide ops/sec by N for per-op throughput.
// For the 8 MiB file bodies, throughput = ops/sec * 8 MiB.
// The 32 GiB workload is in random_32g_benchmarks_test.dart.

@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit.dart';
import 'package:blit/bytes_ffi.dart';
import 'package:test/test.dart'
    show Timeout, group, setUp, setUpAll, tearDown, tearDownAll;

const int _fileSize = 1 << 30;
const int _seqBlock = 8 << 20;
const int _block = 4096;

final Directory _benchDir =
    Directory('${Directory.current.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}bench')
      ..createSync(recursive: true);
final String _path =
    '${_benchDir.path}${Platform.pathSeparator}blit_benchmarks.bin';
final Random _rnd = Random(1234);
final Uint8List _seqBuf = _pattern(_seqBlock);
final Uint8List _randBuf = _pattern(_block);
late final MmapFile _file;
late final MappedRegion _readRegion;
late final MappedRegion _writeRegion;
late final Uint8List _readView;
late final Uint8List _writeView;
int _sink = 0;
var _seqOffset = 0;
var _ioIndex = 0;

Uint8List _pattern(int length) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = (i * 31 + 7) & 0xFF;
  }
  return data;
}

int _randomOffset() => _rnd.nextInt(_fileSize ~/ _block) * _block;

Future<ParallelBytesFile> _pool(int workers) async {
  return ParallelBytesFile.open(
    _path,
    create: false,
    readOnly: true,
    maxWorkers: workers,
  );
}

void _ensureFile() {
  _benchDir.createSync(recursive: true);
  final f = openMmapFileSync(_path);
  if (f.length == _fileSize) {
    f.close();
    return;
  }
  f.truncate(_fileSize, sparse: true);
  final chunk = _pattern(_seqBlock);
  for (var off = 0; off < _fileSize; off += chunk.length) {
    f.writeAt(off, chunk);
  }
  f.flush();
  f.close();
}

const _benchTimeout = Timeout(Duration(minutes: 2));

void bench(String name, dynamic Function() body) =>
    benchmark(name, body, timeout: _benchTimeout);

void main() {
  setUpAll(() async {
    _ensureFile();
    _file = openMmapFileSync(_path, create: false, mmapCache: false);
    // `file.*` rows must measure the syscall path, same as C's ReadFile/
    // WriteFile. The explicit `_readRegion`/`_writeRegion` below measure mmap
    // separately; do not let the transparent cache leak into the file rows.
    _readRegion = _file.map(offset: 0, length: _fileSize, writable: false);
    _writeRegion = _file.map(offset: 0, length: _fileSize);
    _readView = _readRegion.bytes;
    _writeView = _writeRegion.bytes;
  });

  tearDownAll(() async {
    _readRegion.close();
    _writeRegion.close();
    _file.close();
    final f = File(_path);
    if (f.existsSync()) f.deleteSync();
    if (_sink == 0x7fffffff) print('unreachable sink=$_sink');
  });

  // -------------------------------------------------------------------------
  // Core types.  Batch sizes keep harness overhead out of the measurement.
  // -------------------------------------------------------------------------
  final bytes = Bytes.fromList(_pattern(1 << 20));
  final mut = BytesMut(4096);
  var byteIndex = 0;

  bench('core.Bytes.slice x1024', () {
    for (var i = 0; i < 1024; i++) {
      final start = (byteIndex++ * 7) & 0xFFFF;
      _sink ^= bytes.slice(start, start + 333)[0];
    }
  });

  bench('core.Bytes.getUint32 x4096', () {
    for (var i = 0; i < 4096; i++) {
      _sink ^= bytes.getUint32((byteIndex++ * 4) & 0xFFFFF);
    }
  });

  bench('core.Bytes.copyTo.4KiB x64', () {
    for (var i = 0; i < 64; i++) {
      bytes.slice(0, 4096).copyTo(_randBuf);
      _sink ^= _randBuf[4095];
    }
  });

  bench('core.BytesMut.putUint32x64', () {
    mut.clear();
    for (var i = 0; i < 64; i++) {
      mut.putUint32(i);
    }
    _sink ^= mut.asUint8List()[0];
  });

  final typed = Uint8List.fromList(_pattern(4096));
  bench('core.Bytes.fromTypedData x4096', () {
    for (var i = 0; i < 4096; i++) {
      _sink ^= Bytes.fromTypedData(typed).getUint8(0);
    }
  });

  bench('core.TypedData.asBytes x4096', () {
    for (var i = 0; i < 4096; i++) {
      _sink ^= typed.asBytes().getUint8(0);
    }
  });

  const ua = Uint64(0x12345678, 0x9ABCDEF0);
  const ub = Uint64(0x0FEDCBA9, 0x87654321);
  bench('core.Uint64.add x1024', () {
    for (var i = 0; i < 1024; i++) {
      _sink ^= (ua + ub).lo & 0xFF;
    }
  });
  bench('core.Uint64.compare x1024', () {
    for (var i = 0; i < 1024; i++) {
      _sink ^= ua.compareTo(ub) & 0xFF;
    }
  });
  bench('core.Uint64.mul x1024', () {
    for (var i = 0; i < 1024; i++) {
      _sink ^= (ua * ub).lo & 0xFF;
    }
  });

  final bigA = BigInt.parse('1234567890123456789012345678901234567890');
  final bigB = BigInt.parse('987654321098765432109876543210987654321');
  bench('core.BigInt.add x1024', () {
    for (var i = 0; i < 1024; i++) {
      _sink ^= (bigA + bigB).toInt() & 0xFF;
    }
  });

  // -------------------------------------------------------------------------
  // File I/O, 1 GiB.
  // -------------------------------------------------------------------------
  bench('file.read.8MiB', () {
    _file.readAt(_seqOffset, _seqBuf);
    _seqOffset = (_seqOffset + _seqBlock) % _fileSize;
    _sink ^= _seqBuf[0];
  });

  bench('file.write.8MiB', () {
    _file.writeAt(_seqOffset, _seqBuf);
    _seqOffset = (_seqOffset + _seqBlock) % _fileSize;
    _sink ^= _seqBuf[0];
  });

  bench('file.read.random4K', () {
    _file.readAt(_randomOffset(), _randBuf);
    _sink ^= _randBuf[0];
  });

  bench('file.write.random4K', () {
    _file.writeAt(_randomOffset(), _randBuf);
    _sink ^= _randBuf[0];
  });

  bench('mmap.read.random4K', () {
    _randBuf.setRange(0, _block, _readView, _randomOffset());
    _sink ^= _randBuf[0];
  });

  bench('mmap.write.random4K', () {
    final off = _randomOffset();
    _writeView.setRange(off, off + _block, _randBuf);
    _sink ^= _randBuf[0];
  });

  // -------------------------------------------------------------------------
  // Isolate pool.  One measured body = batch 32 per worker.  Each worker-count
  // group owns its pool only for that group; closing it releases the 1 GiB
  // mmap cache before the next group starts (important on small CI runners).
  // BYTES_BENCH_MAX_WORKERS can cap the sweep on low-core CI machines.
  // -------------------------------------------------------------------------
  final maxWorkers = int.tryParse(
        Platform.environment['BYTES_BENCH_MAX_WORKERS'] ?? '',
      ) ??
      16;
  for (final workers in [1, 2, 4, 8, 16].where((w) => w <= maxWorkers)) {
    group('pool $workers', () {
      late ParallelBytesFile pool;

      setUp(() async {
        pool = await _pool(workers);
      });
      tearDown(() async {
        await pool.close();
      });

      bench('pool.read.random4K.w$workers', () async {
        final offsets = [
          for (var i = 0; i < workers * ParallelBytesFile.batchSize; i++)
            _randomOffset(),
        ];
        final chunks = await pool.readMany(offsets, _block);
        for (final chunk in chunks) {
          _sink ^= chunk[0];
        }
      });

      if (workers == 4) {
        // Sequential readMany: coalescing turns every 32 adjacent 4K reads
        // into a single larger read.  The measured unit is one batch.
        bench('pool.read.sequential4K.w4', () async {
          final base =
              (_ioIndex++ * 4096 * 32) % (_fileSize - 4096 * 32);
          final offsets = [
            for (var i = 0; i < 32; i++) base + i * _block,
          ];
          final chunks = await pool.readMany(offsets, _block);
          for (final chunk in chunks) {
            _sink ^= chunk[0];
          }
        });
      }
    });
  }
}
