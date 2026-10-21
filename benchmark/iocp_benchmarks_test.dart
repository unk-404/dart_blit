// Windows IOCP queue-depth sweep, package:benchmark_test.
//
// Run: dart run benchmark_test benchmark/iocp_benchmarks_test.dart
//
// One measured body is a batch of `queueDepth` independent 4K reads.  The
// reported ops/sec is 4K ops per second, not batches.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart'
    show Timeout, setUpAll, tearDownAll, test;

const int _size = 1 << 30;
const int _block = 4096;
final Directory _benchDir =
    Directory('${Directory.current.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}bench')
      ..createSync(recursive: true);
final String _path =
    '${_benchDir.path}${Platform.pathSeparator}blit_iocp_bench.bin';
final Random _rnd = Random(99);
final Map<int, IocpFile> _files = <int, IocpFile>{};
int _sink = 0;

void _ensureFile() {
  _benchDir.createSync(recursive: true);
  final f = IocpFile.openSync(_path);
  if (f.length == _size) {
    f.close();
    return;
  }
  f.truncate(_size, sparse: false);
  final chunk = Uint8List(8 << 20);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = (i * 13 + 7) & 0xFF;
  }
  for (var off = 0; off < _size; off += chunk.length) {
    f.writeAtSync(off, chunk);
  }
  f.flush();
  f.close();
}

List<int> _offsets(int count) =>
    [for (var i = 0; i < count; i++) _rnd.nextInt(_size ~/ _block) * _block];

void main() {
  setUpAll(() {
    if (!Platform.isWindows) return;
    _ensureFile();
    for (final qd in [1, 8, 32]) {
      _files[qd] = IocpFile.openSync(
        _path,
        create: false,
        queueDepth: qd,
      );
    }
  });

  tearDownAll(() {
    if (_sink == 0x7fffffff) print('unreachable sink=$_sink');
    for (final file in _files.values) {
      file.close();
    }
    final f = File(_path);
    if (f.existsSync()) f.deleteSync();
  });

  if (!Platform.isWindows) {
    test('IOCP is Windows-only', () {},
        skip: 'IocpFile requires Windows overlapped I/O');
    return;
  }

  const timeout = Timeout(Duration(minutes: 2));
  final blocks = <int, List<Uint8List>>{
    for (final qd in [1, 8, 32])
      qd: [
        for (var i = 0; i < qd; i++)
          Uint8List(_block)..fillRange(0, _block, (i + qd) & 0xFF),
      ],
  };
  for (final qd in [1, 8, 32]) {
    benchmark('iocp.read.random4K.qd$qd', () {
      final file = _files[qd]!;
      _sink ^= file.readManySync(_offsets(qd), _block)[0];
    }, timeout: timeout);

    benchmark('iocp.write.random4K.qd$qd', () {
      final file = _files[qd]!;
      _sink ^= file.writeManySync(_offsets(qd), blocks[qd]!);
    }, timeout: timeout);
  }
}

