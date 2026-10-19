import 'dart:io';

import 'package:benchmark_harness/benchmark_harness.dart';

/// Common benchmark helpers.
///
/// Every benchmark reports through `benchmark_harness`'s `PrintEmitterV2`
/// (`name(Metric): value unit`) so CI can parse a stable format.  A human
/// readable line is printed as well.

/// One `run()` per measured iteration.
///
/// `BenchmarkBase.exercise()` defaults to 10 `run()` calls, which would make
/// the score 10× the per-operation latency.  Every sync benchmark in this
/// directory extends this class so `measure()` is µs per operation.
abstract class UnitBenchmark extends BenchmarkBase {
  const UnitBenchmark(super.name);

  @override
  void exercise() {
    run();
  }
}

abstract class ThroughputBenchmark extends UnitBenchmark {
  final int bytesPerRun;

  const ThroughputBenchmark(super.name, this.bytesPerRun);

  @override
  void report() {
    final us = measure();
    emitThroughput(name, bytesPerRun, us);
  }
}

abstract class AsyncThroughputBenchmark extends AsyncBenchmarkBase {
  final int bytesPerRun;

  const AsyncThroughputBenchmark(super.name, this.bytesPerRun);

  @override
  Future<void> report() async {
    final us = await measure();
    emitThroughput(name, bytesPerRun, us);
  }
}

void emitThroughput(String name, int bytes, double micros) {
  final mibs = bytes / (micros / 1e6) / (1 << 20);
  const PrintEmitterV2()
      .emit(name, mibs, metric: 'Throughput', unit: 'MiB/s');
  print('    ${(mibs / 1024).toStringAsFixed(2)} GiB/s');
}

void emitIops(String name, int ops, double micros) {
  final iops = ops * 1e6 / micros;
  const PrintEmitterV2().emit(name, iops, metric: 'IOPS', unit: 'ops/s');
  print('    ${iops.toStringAsFixed(0)} ops/s');
}

void emitLatency(String name, int ops, double micros) {
  final us = micros / ops;
  const PrintEmitterV2().emit(name, us, metric: 'Latency', unit: 'us/op');
  print('    ${us.toStringAsFixed(2)} us/op');
}

String benchPath(String name) =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}bytes_bench_$name.bin';

int benchIntEnv(String name, int fallback) {
  final value = Platform.environment[name];
  return value == null ? fallback : (int.tryParse(value) ?? fallback);
}
