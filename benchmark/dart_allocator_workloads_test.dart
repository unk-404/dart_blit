// DartAllocator live-set workloads; BlitAllocator counterpart uses same IDs.
//
//   dart run benchmark_test --output jsonl benchmark/dart_allocator_workloads_test.dart
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/unsafe.dart';
import 'package:test/test.dart' show TestOn, Timeout, setUpAll, tearDownAll;

const _n = 1024;
const _timeout = Timeout(Duration(minutes: 5));
const _sizes = [64, 256, 4096];

late DartAllocator _allocator;
late List<Uint8List?> _live;
late List<int> _randomOrder;
var _sink = 0;

void _bench(String name, void Function() body) {
  benchmark(name, body, timeout: _timeout);
}

void _allocAll(List<int> sizes) {
  for (var i = 0; i < _n; i++) {
    final value = _allocator.alloc(sizes[i % sizes.length]);
    _live[i] = value;
    _sink ^= value.length;
  }
}

void main() {
  setUpAll(() {
    _allocator = DartAllocator();
    _live = List<Uint8List?>.filled(_n, null);
    _randomOrder = List<int>.generate(_n, (i) => i);
    _randomOrder.shuffle(math.Random(42));
  });

  tearDownAll(() {
    if (_sink < 0) throw StateError('unreachable sink');
  });

  _bench('work.lifo.64B', () {
    _allocAll(const [64]);
    for (var i = _n - 1; i >= 0; i--) {
      _allocator.free(_live[i]!);
    }
  });

  _bench('work.fifo.64B', () {
    _allocAll(const [64]);
    for (var i = 0; i < _n; i++) {
      _allocator.free(_live[i]!);
    }
  });

  _bench('work.random.64B', () {
    _allocAll(const [64]);
    for (var i = 0; i < _n; i++) {
      _allocator.free(_live[_randomOrder[i]]!);
    }
  });

  _bench('work.mixed.lifo', () {
    _allocAll(_sizes);
    for (var i = _n - 1; i >= 0; i--) {
      _allocator.free(_live[i]!);
    }
  });
}
