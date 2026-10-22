// BlitAllocator live-set workloads; DartAllocator counterpart uses same IDs.
//
//   dart run benchmark_test --output jsonl benchmark/blit_allocator_workloads_test.dart
@TestOn('vm')
library;

import 'dart:math' as math;

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit_native.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _n = 1024;
const _timeout = Timeout(Duration(minutes: 5));
const _sizes = [64, 256, 4096];

late BlitAllocator _allocator;
late List<int> _addresses;
late List<int> _randomOrder;
var _sink = 0;

void _bench(String name, void Function() body) {
  benchmark(name, body, timeout: _timeout);
}

void _allocAll(List<int> sizes) {
  for (var i = 0; i < _n; i++) {
    _addresses[i] = _allocator.alloc(sizes[i % sizes.length]);
    _sink ^= _addresses[i];
  }
}

void _freeReverse() {
  for (var i = _n - 1; i >= 0; i--) {
    _allocator.free(_addresses[i]);
  }
}

void _freeForward() {
  for (var i = 0; i < _n; i++) {
    _allocator.free(_addresses[i]);
  }
}

void _freeRandom() {
  for (var i = 0; i < _n; i++) {
    _allocator.free(_addresses[_randomOrder[i]]);
  }
}

void main() {
  setUpAll(() {
    _allocator = BlitAllocator();
    _addresses = List<int>.filled(_n, 0);
    _randomOrder = List<int>.generate(_n, (i) => i);
    _randomOrder.shuffle(math.Random(42));
  });

  tearDownAll(() {
    _allocator.dispose();
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('work.lifo.64B', () {
    _allocAll(const [64]);
    _freeReverse();
  });

  _bench('work.fifo.64B', () {
    _allocAll(const [64]);
    _freeForward();
  });

  _bench('work.random.64B', () {
    _allocAll(const [64]);
    _freeRandom();
  });

  _bench('work.mixed.lifo', () {
    _allocAll(_sizes);
    _freeReverse();
  });
}
