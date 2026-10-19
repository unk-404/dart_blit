// Uint64 representation benchmarks (benchmark_harness format).
//
// Run: dart run benchmark/uint64_benchmark.dart

import 'package:blit/bytes.dart';

import '_bench.dart';

int sink = 0;

class IntAddBenchmark extends UnitBenchmark {
  IntAddBenchmark() : super('int.add');
  var _v = 0x123456789ABCDEF0;

  @override
  void run() {
    _v = (_v + 0x0FEDCBA987654321) & 0x7FFFFFFFFFFFFFFF;
    sink ^= _v & 0xFF;
  }
}

class Uint64AddBenchmark extends UnitBenchmark {
  Uint64AddBenchmark() : super('Uint64.add');
  var _v = const Uint64(0x12345678, 0x9ABCDEF0);
  static const _add = Uint64(0x0FEDCBA9, 0x87654321);

  @override
  void run() {
    _v = _v + _add;
    sink ^= _v.lo & 0xFF;
  }
}

class Uint64CompareBenchmark extends UnitBenchmark {
  Uint64CompareBenchmark() : super('Uint64.compare');
  final Uint64 _a = const Uint64(0x12345678, 0x9ABCDEF0);
  final Uint64 _b = const Uint64(0x0FEDCBA9, 0x87654321);

  @override
  void run() {
    sink ^= _a.compareTo(_b) & 0xFF;
  }
}

class Uint64MulBenchmark extends UnitBenchmark {
  Uint64MulBenchmark() : super('Uint64.mul');
  var _v = const Uint64(0x12345678, 0x9ABCDEF0);
  static const _mul = Uint64(0x0FEDCBA9, 0x87654321);

  @override
  void run() {
    _v = _v * _mul;
    sink ^= _v.lo & 0xFF;
  }
}

class BigIntAddBenchmark extends UnitBenchmark {
  BigIntAddBenchmark() : super('BigInt.add');
  var _v = BigInt.parse('123456789ABCDEF0', radix: 16);
  static final _add = BigInt.parse('0FEDCBA987654321', radix: 16);

  @override
  void run() {
    _v = (_v + _add) & ((BigInt.one << 64) - BigInt.one);
    sink ^= _v.toInt() & 0xFF;
  }
}

void main() {
  IntAddBenchmark().report();
  Uint64AddBenchmark().report();
  Uint64CompareBenchmark().report();
  Uint64MulBenchmark().report();
  BigIntAddBenchmark().report();
  print('sink=$sink');
}
