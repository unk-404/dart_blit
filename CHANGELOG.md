# Changelog

## 0.1.1

### Added

- TypedData interop: `Bytes.fromTypedData`, `TypedData.asBytes()`,
  `Bytes.fromBytesLike`, and the `BytesLike` boundary interface; `Bytes` and
  `BytesMut` implement `BytesLike` without copying.
- `MmapFile.punchHole` (Windows `FSCTL_SET_ZERO_DATA`, Linux
  `fallocate(PUNCH_HOLE)`), Windows `cloneRangeFrom`
  (`FSCTL_DUPLICATE_EXTENTS_TO_FILE`), macOS `preallocate`
  (`F_PREALLOCATE`) / `adviseRead` (`F_RDADVISE`), and `cloneFileSync`
  (`clonefile` on macOS/iOS, copy fallback elsewhere).
- Linux `UringBytesFile` / `openUringBytesFile`: pure-Dart `package:io_uring`
  SQ/CQ rings, batched `readMany`/`writeMany`, no `liburing` or C shim.
- Windows `MmapPlaceholder` via `VirtualAlloc2` + `MapViewOfFile3`
  (`MEM_RESERVE_PLACEHOLDER` / `MEM_REPLACE_PLACEHOLDER`), for gap-free window
  replacement on Windows 10 1803+.
- Windows direct-I/O `largePages: true` opt-in (`MEM_LARGE_PAGES` scratch,
  privilege-checked with normal-page fallback).
- `ParallelBytesFile.maxQueue` backpressure for queued + in-flight jobs.
- Web OPFS worker-per-chunk pool: `OpfsWorkerPool` routes chunk `i` to
  `workers[i % N]` (default 4), keeps the manifest single-writer, and caches
  each chunk handle in its owning worker.
- Optional Web SAB ring for small `read`/`write` calls when
  `crossOriginIsolated` and `Atomics.waitAsync` are available: 8 × 64 KiB
  slots, `Atomics` wakeups, postMessage fallback for larger payloads and
  non-isolated pages.
- Benchmark SVG rendering now uses `bench-svg` (`bench-svg.toml` + the
  `unk-404/benchmark_svg` action) instead of a repo-local SVG generator.

## 0.1.0

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
- `MappedRegion.prefetch()` / `discard()`: Windows `PrefetchVirtualMemory`
  (discard is a no-op for file-backed maps), POSIX `madvise(MADV_WILLNEED /
  MADV_DONTNEED)`.
- `Bytes.getUint8/16/32Unchecked` and
  `BytesReader.readUint8/16/32/64Unchecked` hot-path methods (caller checks
  bounds once).
- Direct I/O: `openMmapFileSync(..., direct: true)` /
  `ParallelBytesFile.open(..., direct: true)` via Windows
  `FILE_FLAG_NO_BUFFERING` + `VirtualAlloc`, Linux/Android `O_DIRECT`, and
  macOS/iOS `F_NOCACHE`; aligned scratch buffers and 4 KiB-aligned streaming
  reads/writes.
- `ParallelBytesFile`: isolate worker pool (default up to 32), automatic FIFO
  dispatch, batch 32, `readMany`/`writeMany`, watermark barriers,
  adjacent-range coalescing, and a read-only full-file mmap cache for hot files
  (default limit 1 GiB).
- Web OPFS backend: chunk files, double-slot manifest, CRC-32, dedicated
  worker, capability/quota probing.
- Benchmark suite (`benchmark_test`, JIT/AOT + JSONL), a generated
  `assets/benchmarks.svg`, and Dart/Flutter CI workflows.
- Tests: differential fuzz, lifetime/error paths, 100k-op stress, 32 GiB sparse.

### Fixed during development

- `putUint64` little-endian limb encoding and atomic failure on short buffers.
- `ParallelBytesFile` barrier deadlock when queued work already existed.
- Windows read-only mapping `zeroize` guard and empty-file `map` consistency.
