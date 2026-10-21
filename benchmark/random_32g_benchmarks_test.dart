// 32 GiB (or BYTES_BENCH_GB) random 4K benchmark, package:benchmark_test.
//
// Run:
//   dart run benchmark_test benchmark/random_32g_benchmarks_test.dart
//   BYTES_BENCH_GB=8 dart run benchmark_test benchmark/random_32g_benchmarks_test.dart
//
// One measured body is one 4K operation.  The 30 s fill happens once in
// setUpAll; Windows has no unprivileged drop-cache, so reads may be served by
// the page cache.  pwrite/mmap-write are flushed in tearDownAll, not per op.

@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart' show Timeout, setUpAll, tearDownAll;

final int _size =
    ((int.tryParse(Platform.environment['BYTES_BENCH_GB'] ?? '') ?? 32)) << 30;
final Directory _benchDir =
    Directory('${Directory.current.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}bench')
      ..createSync(recursive: true);
final String _path =
    '${_benchDir.path}${Platform.pathSeparator}blit_random_g${_size >> 30}.bin';
final Random _rnd = Random(4242);
final Uint8List _buf = _pattern(4096);
late final MmapFile _file;
late final MappedRegion _readRegion;
late final MappedRegion _writeRegion;
late final Uint8List _readView;
late final Uint8List _writeView;
int _sink = 0;

Uint8List _pattern(int length) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = (i * 17 + 3) & 0xFF;
  }
  return data;
}

int _offset() => _rnd.nextInt(_size ~/ 4096) * 4096;

void _ensureFile() {
  _benchDir.createSync(recursive: true);
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
  for (var off = 0; off < _size; off += chunk.length) {
    f.writeAt(off, chunk);
  }
  f.flush();
  f.close();
}

void main() {
  setUpAll(() {
    _ensureFile();
    _file = openMmapFileSync(_path, create: false);
    _readRegion = _file.map(offset: 0, length: _size, writable: false);
    _writeRegion = _file.map(offset: 0, length: _size);
    _readView = _readRegion.bytes;
    _writeView = _writeRegion.bytes;
  });

  tearDownAll(() {
    if (_sink == 0x7fffffff) print('unreachable sink=$_sink');
    _readRegion.close();
    _writeRegion.close();
    _file.close();
    final f = File(_path);
    if (f.existsSync()) f.deleteSync();
  });

  const timeout = Timeout(Duration(minutes: 5));

  benchmark('random${_size >> 30}g.pread.read.random4K', () {
    _file.readAt(_offset(), _buf);
    _sink ^= _buf[0];
  }, timeout: timeout);

  benchmark('random${_size >> 30}g.pwrite.write.random4K', () {
    _file.writeAt(_offset(), _buf);
    _sink ^= _buf[0];
  }, timeout: timeout);

  benchmark('random${_size >> 30}g.mmap.read.random4K', () {
    _buf.setRange(0, 4096, _readView, _offset());
    _sink ^= _buf[0];
  }, timeout: timeout);

  benchmark('random${_size >> 30}g.mmap.write.random4K', () {
    final off = _offset();
    _writeView.setRange(off, off + 4096, _buf);
    _sink ^= _buf[0];
  }, timeout: timeout);
}

