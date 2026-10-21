// DartAllocator-only benchmark; BlitAllocator counterpart uses identical IDs.
//
//   dart run benchmark_test --output jsonl benchmark/dart_allocator_benchmarks_test.dart
@TestOn('vm')
library;

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/unsafe.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _ops = 1024;
const _timeout = Timeout(Duration(minutes: 3));

late DartAllocator _allocator;
var _sink = 0;

void _bench(String name, void Function() body) {
  benchmark(name, body, timeout: _timeout);
}

void main() {
  setUpAll(() {
    _allocator = DartAllocator();
  });

  tearDownAll(() {
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('alloc.64B', () {
    for (var i = 0; i < _ops; i++) {
      final value = _allocator.alloc(64);
      _sink ^= value.length;
      _allocator.free(value);
    }
  });

  _bench('alloc.4K', () {
    for (var i = 0; i < _ops; i++) {
      final value = _allocator.alloc(4096);
      _sink ^= value.length;
      _allocator.free(value);
    }
  });
}
