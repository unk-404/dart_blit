// Bytes vs UnsafeBytes benchmark (native run).
//
//   dart run benchmark_test --output jsonl benchmark/unsafe_bytes_benchmarks_test.dart
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit.dart';
import 'package:blit/unsafe.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _bytesLength = 1 << 20;
const _timeout = Timeout(Duration(minutes: 3));

late Bytes _bytes;
late UnsafeBytes _unsafe;
late Uint8List _backing;
var _sink = 0;
var _index = 0;

void _bench(String name, void Function() body) {
  benchmark(name, body, timeout: _timeout);
}

void main() {
  setUpAll(() {
    _backing = Uint8List(_bytesLength);
    for (var i = 0; i < _backing.length; i++) {
      _backing[i] = (i * 31 + 7) & 0xFF;
    }
    _bytes = Bytes.fromUint8List(_backing);
    _unsafe = UnsafeBytes.alloc(_bytesLength);
    _unsafe.view(_bytesLength).setAll(0, _backing);
  });

  tearDownAll(() {
    _unsafe.free();
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('BytesVsUnsafe bytes.getUint32 x4096', () {
    for (var i = 0; i < 4096; i++) {
      _sink ^= _bytes.getUint32((_index++ * 4) & 0xFFFFC);
    }
  });

  _bench('Unsafe unsafe.getUint32 x4096', () {
    for (var i = 0; i < 4096; i++) {
      _sink ^= _unsafe.getUint32((_index++ * 4) & 0xFFFFC);
    }
  });

  _bench('Bytes bytes.alloc.4KiB x64', () {
    for (var i = 0; i < 64; i++) {
      final value = Bytes.fromUint8List(Uint8List(4096));
      _sink ^= value.length;
    }
  });

  _bench('Unsafe unsafe.alloc.4KiB x64', () {
    for (var i = 0; i < 64; i++) {
      final value = UnsafeBytes.alloc(4096);
      _sink ^= value.address;
      value.free();
    }
  });
}
