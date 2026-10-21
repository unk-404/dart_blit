// UnsafeBytes-only benchmark; the Bytes counterpart lives in
// bytes_benchmarks_test.dart and uses identical `mem.*` IDs for comparison.
//
//   dart run benchmark_test --output jsonl benchmark/unsafe_bytes_benchmarks_test.dart
@TestOn('vm')
library;

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/unsafe.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _bytesLength = 1 << 20;
const _timeout = Timeout(Duration(minutes: 3));

late UnsafeBytes _unsafe;
var _sink = 0;
var _index = 0;

void _bench(String name, void Function() body) {
  benchmark(name, body, timeout: _timeout);
}

void main() {
  setUpAll(() {
    _unsafe = UnsafeBytes.alloc(_bytesLength);
    final view = _unsafe.view(_bytesLength);
    for (var i = 0; i < view.length; i++) {
      view[i] = (i * 31 + 7) & 0xFF;
    }
  });

  tearDownAll(() {
    _unsafe.free();
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('mem.getUint32', () {
    for (var i = 0; i < 4096; i++) {
      _sink ^= _unsafe.getUint32((_index++ * 4) & 0xFFFFC);
    }
  });

  _bench('mem.read4K', () {
    final view = _unsafe.view(4096);
    for (var n = 0; n < 64; n++) {
      for (var i = 0; i < 4096; i++) {
        _sink ^= view[i];
      }
    }
  });

  _bench('mem.write4K', () {
    final view = _unsafe.view(4096);
    for (var n = 0; n < 64; n++) {
      view.fillRange(0, 4096, n & 0xFF);
      _sink ^= view[0];
    }
  });

  _bench('mem.setUint32', () {
    for (var i = 0; i < 4096; i++) {
      _unsafe.setUint32((_index++ * 4) & 0xFFFFC, i);
    }
  });

  _bench('mem.alloc4K', () {
    for (var i = 0; i < 64; i++) {
      final value = UnsafeBytes.alloc(4096);
      _sink ^= value.address;
      value.free();
    }
  });
}
