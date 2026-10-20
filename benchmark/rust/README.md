# Rust benchmark (replacement for `benchmark/c/blit_bench.c`)

Emits **benchmark_test-compatible JSONL** so benchcat / `benchmark_test` can put
Rust and Dart runs in one chart. Same operation names as the legacy C harness;
the optional IOCP / io_uring rows are the Rust engine counterparts of the Dart
`IocpFile` rows.

## Rows

Always emitted (1 GiB file, body = 1 operation, so `ops/sec` == IOPS):

| name | body |
|---|---|
| `file.read.8MiB` | pread 8 MiB into a native scratch buffer, then copy to the destination buffer |
| `file.write.8MiB` | copy the source buffer to scratch, then pwrite 8 MiB |
| `file.read.random4K` | pread 4 KiB at a xorshift-random aligned offset, then copy out |
| `file.write.random4K` | copy 4 KiB in, then pwrite at a random aligned offset |
| `mmap.read.random4K` | 4 KiB `copy_from_slice` from a `memmap2` read-only map |
| `mmap.write.random4K` | 4 KiB `copy_from_slice` into a `memmap2` writable map, `flush()` at the end |

Feature-gated engine rows (**one body = `QD` = 32 independent 4 KiB ops**, so
`throughput.value` is **bodies/sec**; benchcat's rows do `value * 32` for IOPS):

| feature | OS | names |
|---|---|---|
| `iocp` | Windows | `iocp.read.random4K.qd32`, `iocp.write.random4K.qd32` |
| `uring` | Linux | `uring.read.random4K.qd32`, `uring.write.random4K.qd32` |

## Build / run

```sh
# Six shared rows (any OS)
cargo run --release

# Windows: + 2 IOCP rows (raw Win32 IOCP, QD 32)
cargo run --release --features iocp

# Linux: + 2 io_uring rows (QD 32)
cargo run --release --features uring
```

This machine has no network for the crates.io index; the commands above were run
with `--offline` (all crates were already in the local cargo cache):

```sh
cargo run --release --features iocp --offline
```

CLI: `bytes-bench-rust [PATH] [--file PATH] [--keep] [--help]`.
`PATH` defaults to `bench-rust.bin`; a 1 GiB file is created and seeded (8 MiB
pattern) only when missing or the wrong size. `*.bin` and `target/` are
gitignored.

For benchcat:

```sh
cargo run --release --features iocp --offline --manifest-path benchmark/rust/Cargo.toml > bench-rust.jsonl
```

## Methodology notes (important for a fair chart)

* **Copy semantics mirror the C harness**, which mirrors the Dart engine: the
  syscall goes into a native scratch buffer and is copied to the destination
  (and the reverse for writes). A "read straight into the destination" Rust
  implementation would be faster but not comparable.
* **IOCP/io_uring harvest**: one batch = 32 submissions, then completions are
  reaped with `GetQueuedCompletionStatus` / `io_uring` CQEs. The Windows harvest
  is one syscall per completion, matching the Dart `IocpFile`
  (`_runBatch` calls `GetQueuedCompletionStatus` per packet). Draining with
  `GetQueuedCompletionStatusEx` (up to 32 CQEs per call) is the next
  optimization; it would change the comparison from "same algorithm in Rust" to
  "better engine".
* **Latency**: for the six shared rows `latency.mean` is per operation; for the
  engine rows it is per **batch of 32**, because bodies/sec is the measured unit.
* `statistics.relativeMarginOfError` is `0.0` and `samples` is the operation (or
  body) count: one timed run per row, same as `blit_bench.c` (no RME sampling).
* Allocations: the shared rows reuse the scratch/destination buffers across
  iterations. The Dart engine allocates/zeroes its per-batch buffer inside the
  measured call, so the Rust engine rows are marginally optimistic on memory
  traffic (~128 KiB zero/copy per body); the dominant cost is syscall + harvest.

## Local run (Windows, Dart/Flutter SDK machine, 2026-10-20)

`cargo run --release --features iocp --offline` → 8 rows, exit 0, e.g.:

```
file.read.8MiB       677.4 ops/s   (×8 MiB ≈ 5.4 GiB/s, hot cache)
file.write.8MiB      432.0 ops/s
file.read.random4K   293 879 IOPS
file.write.random4K  253 044 IOPS
mmap.read.random4K   833 376 IOPS
mmap.write.random4K  698 481 IOPS
iocp.read.random4K.qd32   4 800 bodies/s  (153 600 4 KiB IOPS)
iocp.write.random4K.qd32  5 137 bodies/s  (164 390 4 KiB IOPS)
```

Takeaway: on a hot page cache, QD32 IOCP with one `GetQueuedCompletionStatus`
per completion is *not* faster than 32 independent synchronous preads — the
per-completion syscall dominates. The Dart `IocpFile` has the same structure, so
the Dart/Rust IOCP rows should be read as "same algorithm, different runtime",
not as "IOCP is always faster".

`uring` rows are compiled on Linux only and were **not executed on this
machine** (Windows host, no WSL); they are syntax-checked by `rustfmt` only.
