// BlitAllocator-only benchmark; DartAllocator counterpart uses identical IDs.
//
//   dart run benchmark_test --output jsonl benchmark/blit_allocator_benchmarks_test.dart
@TestOn('vm')
library;

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit_native.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _ops = 1024;
const _timeout = Timeout(Duration(minutes: 3));

late BlitAllocator _allocator;
var _sink = 0;

void _bench(String name, void Function() body) {
  benchmark(name, body, timeout: _timeout);
}

void main() {
  setUpAll(() {
    _allocator = BlitAllocator(arenaSize: 64 * 1024 * 1024);
  });

  tearDownAll(() {
    _allocator.dispose();
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('alloc.64B', () {
    for (var i = 0; i < _ops; i++) {
      final address = _allocator.alloc(64);
      _sink ^= address;
      _allocator.free(address);
    }
  });

  _bench('alloc.4K', () {
    for (var i = 0; i < _ops; i++) {
      final address = _allocator.alloc(4096);
      _sink ^= address;
      _allocator.free(address);
    }
  });
}
