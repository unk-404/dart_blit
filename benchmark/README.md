# Benchmarks

All benchmarks use [`package:benchmark_test`](https://pub.dev/packages/benchmark_test)
0.1.2. It reports **ops/sec**, relative margin of error (RME), sample count and
JSONL, and runs the same file under JIT and AOT:

```sh
dart run benchmark_test benchmark/benchmarks_test.dart
dart run benchmark_test --compile jit,aot benchmark/benchmarks_test.dart
dart run benchmark_test --output jsonl benchmark/benchmarks_test.dart
```

Files:

| File | Workload |
|---|---|
| `benchmarks_test.dart` | core `Bytes`/`BytesMut`/`Uint64`, 1 GiB file I/O, mmap, isolate pool |
| `random_32g_benchmarks_test.dart` | 32 GiB (or `BYTES_BENCH_GB`) random 4K pread/pwrite/mmap |
| `iocp_benchmarks_test.dart` | Windows IOCP QD 1/8/32 |

The 32 GiB file is created once in `setUpAll`, filled with real data, measured,
and deleted in `tearDownAll`. `BYTES_BENCH_GB=8` runs a smaller file:

```sh
BYTES_BENCH_GB=8 dart run benchmark_test benchmark/random_32g_benchmarks_test.dart
```

## Reading the numbers

`benchmark_test` measures the whole body. The body sizes are in the names:

- `file.read.8MiB`: one 8 MiB read per op → throughput = ops/sec × 8 MiB.
- `file.read.random4K`: one 4 KiB read per op → IOPS = ops/sec.
- `mmap.read.random4K`: one 4 KiB copy per op → IOPS = ops/sec.
- `pool.read.random4K.wN`: one batch of `N × 32` 4 KiB reads per op →
  IOPS = ops/sec × N × 32.
- `pool.read.sequential4K.w4`: one coalesced batch of 32 adjacent 4 KiB reads
  per op; this exercises the adjacent-range merging in `readMany`.
- `iocp.read.random4K.qdN`: one QD-`N` batch per op → IOPS = ops/sec × N.

`benchmark_test` rounds average duration to microseconds; for sub-microsecond
bodies use the reported ops/sec, not the duration field.

## Sample 1 GiB run (JIT, Windows)

These are one local run, not guarantees:

| Body | reported ops/sec | converted |
|---|---:|---:|
| `file.read.8MiB` | ~850 | ~6.6 GiB/s |
| `file.write.8MiB` | ~574 | ~4.5 GiB/s |
| `file.read.random4K` | ~174k | 174k IOPS |
| `file.write.random4K` | ~155k | 155k IOPS |
| `pool.read.random4K.w1` | ~8.3k batches | ~264k IOPS |
| `pool.read.random4K.w16` | ~1.6k batches | ~823k IOPS |
| `pool.read.sequential4K.w4` | ~14.6k batches | ~467k IOPS |
| `iocp.read.random4K.qd8` | ~12.4k batches | ~99k IOPS |
| `iocp.read.random4K.qd32` | ~3.3k batches | ~107k IOPS |

The pool's `sequential4K` body benefits from adjacent-range coalescing. The
1 GiB pool benchmarks also use the read-only full-file mmap cache (default
limit 1 GiB); before that cache, 16 workers measured ~237k IOPS instead of
~823k. The random 4 GiB body does not use the cache (file is larger than the
limit) and measures the dispatch path.

## Caveats

- `pwrite` and mmap writes are **buffered**; the file is flushed in teardown,
  not per operation. Do not read them as durable-write numbers.
- The 32 GiB file exceeds the development machine's 16 GB RAM, so random reads
  are disk-bound; mmap cold reads also pay page faults.
- Sequential reads after the fill pass are page-cache friendly; they are a
  throughput ceiling, not a cold-disk number.
- Windows has no unprivileged drop-cache, so IOCP hot-file numbers are not cold
  device numbers.
- The pool returns transferred buffers. For hot tiny 4K reads the transfer and
  allocation cost dominates; use direct `MmapFile` for hot random access and
  the pool for disk-bound or larger operations.
- JS/Wasm targets were not validated for `benchmark_test`; CI runs JIT/AOT on
  the Windows benchmark runner only.

## CI

On push/manual runs, `.github/workflows/ci.yml` runs the core/1 GiB/pool suite,
the random 4 GiB suite, and the IOCP sweep after all tests pass, then renders
`assets/benchmarks.svg` and uploads JSONL + SVG. It commits the SVG on
push/manual only (PR runs stop after tests). Manual `workflow_dispatch` accepts
`benchmark_gb` (default 4). There is no separate benchmark workflow; for a local
32 GiB run use
`BYTES_BENCH_GB=32 dart run benchmark_test benchmark/random_32g_benchmarks_test.dart`.
`dart test` does not execute `benchmark/`.
