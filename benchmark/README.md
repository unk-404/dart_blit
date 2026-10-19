# Benchmarks

All benchmarks use [`package:benchmark_harness`](https://pub.dev/packages/benchmark_harness)
and report a stable, greppable line:

```
name(Metric): value unit
```

Run from the repository root with Dart 3.13.5:

```sh
dart run benchmark/bytes_benchmark.dart
dart run benchmark/uint64_benchmark.dart
dart run benchmark/io_benchmark.dart          # 1 GiB file
dart run benchmark/parallel_benchmark.dart    # isolate pool, 1/2/4/8/16 workers
dart run benchmark/iocp_benchmark.dart        # Windows IOCP QD sweep
dart run benchmark/random_32g_benchmark.dart  # 32 GiB file, ~30 s fill
BYTES_BENCH_GB=8 dart run benchmark/random_32g_benchmark.dart
```

`BYTES_POOL_IOCP=1` switches the pool benchmark to the optional IOCP worker
engine; the default is the mmap batch engine (faster for multi-worker hot
files in our measurements).

The 32 GiB benchmark creates the file under the system temp directory, fills it
with real data, measures, and deletes it.  `BYTES_BENCH_GB` overrides the size.

## What is measured

| File | Workload | Metric |
|---|---|---|
| `bytes_benchmark` | slice, getUint32, copyTo, BytesMut.putUint32 | latency (µs/op) |
| `uint64_benchmark` | int add, Uint64 add/compare/mul, BigInt add | latency (µs/op) |
| `io_benchmark` | 8 MiB sequential read/write, 4K random read/write, mmap 4K | MiB/s, IOPS |
| `parallel_benchmark` | pool of 1–16 workers, 4K reads, batch 32 | IOPS, MiB/s |
| `iocp_benchmark` | Windows single-worker QD 1–128, 4K random read/write | IOPS, MiB/s |
| `random_32g_benchmark` | 32 GiB file, 4K random pread/pwrite/mmap | IOPS, MiB/s |

## Caveats

- `pwrite`/mmap-write IOPS are **buffered**; the file is flushed in teardown,
  not per operation.  Do not use these numbers as durable-write numbers.
- The 32 GiB file exceeds the 16 GB RAM of the development machine, so random
  reads are disk-bound; mmap cold reads pay page faults.
- Sequential reads after the fill/write pass are page-cache friendly.  They are
  a throughput ceiling, not a cold-disk number.
- The isolate pool's `read` returns a transferred buffer.  For hot, tiny 4K
  reads the transfer/allocation cost dominates; use direct `MmapFile` for hot
  random access and the pool for cold/disk-bound or larger operations.
- `IocpFile` is Windows-only; its numbers depend on page cache (Windows has no
  unprivileged drop-cache).

## Latest measured results (2026-10-19)

Windows, UMIS NVMe SSD, 32 logical CPUs, 16.6 GB RAM, Dart 3.13.5:

| Benchmark | Result |
|---|---:|
| Sequential read 1 GiB (8 MiB blocks, cached) | 7.71 GiB/s |
| Sequential write 1 GiB (8 MiB blocks, cached) | 4.55 GiB/s |
| 32 GiB 4K random pread | 7.35k IOPS / 28.7 MiB/s |
| 32 GiB 4K random pwrite | 95.6k IOPS / 373 MiB/s (buffered) |
| 32 GiB 4K random mmap read | 5.0k IOPS / 19.5 MiB/s (cold) |
| 32 GiB 4K random mmap write | 5.0k IOPS / 19.4 MiB/s (cold) |
| Isolate pool 4K read, 1 worker | 10.6k IOPS (1 GiB warm, batch 32) |
| Isolate pool 4K read, 16 workers | **194.4k IOPS / 759 MiB/s** (1 GiB warm, batch 32) |
| Isolate pool 4K read, 16 workers (32 GiB cold) | **106.7k IOPS / 417 MiB/s** |
| `IocpFile` 4K read, 1 worker QD8/QD32 (1 GiB warm) | 97k / **102k** IOPS |
| `IocpFile` 4K write, 1 worker QD8/QD32 (1 GiB warm) | 113k / **114k** IOPS |

The pool scales near-linearly on a warm 1 GiB file; on a 32 GiB cold file it
reaches 106.7k IOPS because the disk itself becomes the shared bottleneck.
Batch size 32 (`ParallelBytesFile.batchSize`) amortizes the isolate transfer
and lets one worker issue a deeper queue.
