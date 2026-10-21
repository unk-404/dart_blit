// v0.2.0 AsyncFile benchmarks (browser-independent native run).
//
//   dart run benchmark_test --output jsonl benchmark/v2_benchmarks_test.dart
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit_io.dart';
import 'package:blit/blit_native.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _chunk = 8 * 1024 * 1024;
const _benchTimeout = Timeout(Duration(minutes: 3));

late Directory _dir;
late String _path;
late Uint8List _buffer;
var _sink = 0;

void _bench(String name, Future<void> Function() body) {
  benchmark(name, body, timeout: _benchTimeout);
}

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('blit_v2_bench');
    _path = '${_dir.path}${Platform.pathSeparator}data.bin';
    _buffer = Uint8List(_chunk);
    for (var i = 0; i < _buffer.length; i++) {
      _buffer[i] = i & 0xFF;
    }
    final out = await AsyncFile.open(
      _path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    for (var i = 0; i < 4; i++) {
      await out.writeAt(i * _chunk, IoSlice(_buffer));
    }
    await out.close();
  });

  tearDownAll(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('v2.read.8MiB', () async {
    final file = await AsyncFile.open(
      _path,
      options: const FileOptions(mode: FileMode.read, create: false),
    );
    try {
      for (var i = 0; i < 4; i++) {
        final out = Uint8List(_chunk);
        await file.readAt(i * _chunk, ReadBuf(out));
        _sink ^= out[0];
      }
    } finally {
      await file.close();
    }
  });

  _bench('v2.write.8MiB', () async {
    final file = await AsyncFile.open(
      _path,
      options: const FileOptions(mode: FileMode.readWrite),
    );
    try {
      for (var i = 0; i < 4; i++) {
        await file.writeAt(i * _chunk, IoSlice(_buffer));
      }
    } finally {
      await file.close();
    }
  });

  _bench('v2.nativePointer.read8MiB', () async {
    final file = await NativeMmapFile.open(_path, create: false);
    final native = NativeBuffer.allocate(_chunk);
    try {
      for (var i = 0; i < 4; i++) {
        file.readIntoNative(i * _chunk, native);
        _sink ^= native.bytes[0];
      }
    } finally {
      native.dispose();
      await file.close();
    }
  });
}
