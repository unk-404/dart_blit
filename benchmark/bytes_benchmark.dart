// Core `Bytes` / `BytesMut` microbenchmarks (benchmark_harness format).
//
// Run: dart run benchmark/bytes_benchmark.dart

import 'dart:typed_data';

import 'package:blit/bytes.dart';

import '_bench.dart';

int sink = 0;

class SliceBenchmark extends UnitBenchmark {
  SliceBenchmark() : super('Bytes.slice');
  final Bytes _bytes =
      Bytes.fromList(Uint8List.fromList(List.generate(1 << 20, (i) => i)));
  var _i = 0;

  @override
  void run() {
    final start = (_i++ * 7) & 0xFFFF;
    final s = _bytes.slice(start, start + 333);
    sink ^= s[0];
  }
}

class GetUint32Benchmark extends UnitBenchmark {
  GetUint32Benchmark() : super('Bytes.getUint32');
  final Bytes _bytes =
      Bytes.fromList(Uint8List.fromList(List.generate(1 << 20, (i) => i)));
  var _i = 0;

  @override
  void run() {
    sink ^= _bytes.getUint32((_i++ * 4) & 0xFFFFF);
  }
}

class CopyToBenchmark extends UnitBenchmark {
  CopyToBenchmark() : super('Bytes.copyTo(4KiB)');
  late final Bytes _bytes;
  final Uint8List _dst = Uint8List(4096);

  @override
  void setup() {
    _bytes = Bytes.fromList(
      Uint8List.fromList(List.generate(1 << 20, (i) => (i * 31 + 7) & 0xFF)),
    );
  }

  @override
  void run() {
    _bytes.slice(0, 4096).copyTo(_dst);
    sink ^= _dst[0] ^ _dst[4095];
  }
}

class BytesMutPutBenchmark extends UnitBenchmark {
  BytesMutPutBenchmark() : super('BytesMut.putUint32 x64');
  final BytesMut _mut = BytesMut(4096);

  @override
  void run() {
    _mut.clear();
    for (var i = 0; i < 64; i++) {
      _mut.putUint32(i);
    }
    sink ^= _mut.asUint8List()[0];
  }
}

void main() {
  SliceBenchmark().report();
  GetUint32Benchmark().report();
  CopyToBenchmark().report();
  BytesMutPutBenchmark().report();
  print('sink=$sink');
}
