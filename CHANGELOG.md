# Changelog

## 0.1.0 - 2026-10-19

First development release.

### Added

- Zero-copy `Bytes` views (`slice`/`sublist` O(1)) and `BytesMut` with
  `freeze`/`splitTo`/`splitOff` copy-on-write semantics.
- Exact `Uint64` (hi/lo limbs) for VM, dart2js and dart2wasm, including
  arithmetic, bitwise, shifts, `parse` and `toRadixString`.
- `BytesReader`/`BytesWriter` fixed-width cursors with BE/LE support.
- `BytesFile`/`SyncBytesFile` and the native `dart:io` backend.
- Native mmap engine: Windows `CreateFileMappingW`, POSIX `mmap`/`pread`;
  sparse files, zero-copy windows, zeroize, read-only mappings.
- Windows `IocpFile`: overlapped I/O + IOCP, QD 1–128 batch reads/writes.
- `ParallelBytesFile`: isolate worker pool, automatic FIFO dispatch, batch 32,
  `readMany`/`writeMany`, watermark barriers, and adjacent-range coalescing
  (one syscall per sequential run instead of one per 4K block).
- Web OPFS backend: chunk files, double-slot manifest, CRC-32, dedicated
  worker, capability/quota probing.
- Benchmark suite (`benchmark_test`, JIT/AOT + JSONL), a generated
  `assets/benchmarks.svg`, and Dart/Flutter CI workflows.
- Tests: differential fuzz, lifetime/error paths, 100k-op stress, 32 GiB sparse.

### Fixed during development

- `putUint64` little-endian limb encoding and atomic failure on short buffers.
- `ParallelBytesFile` barrier deadlock when queued work already existed.
- Windows read-only mapping `zeroize` guard and empty-file `map` consistency.
