# Changelog

## 0.2.1

### Added

- `UnsafeBytes.alloc` / `free`: fixed-length external memory outside the Dart GC.
- Native `malloc`/`free` and Web `WebAssembly.Memory` arena backends.
- Raw int API: `unsafeAlloc`, `unsafeRead*`, `unsafeWrite*`, `unsafeFree`.
- `AsyncFile.readAtUnsafe` / `writeAtUnsafe` with explicit length.
- Bytes vs UnsafeBytes benchmark rows.

## 0.2.0

### Added

- `AsyncFile`, `BlitFile`, `FileOptions`, and the `BlitException` hierarchy.
- `blit` simple API: `open`, `read`, `write`, `append`, `copy`, `exists`, `delete`.
- `NativeBuffer`, `NativeBufferPool`, and `NativeMmapFile` in `package:blit/blit_native.dart`.
- `readMany`/`writeMany` coalesce contiguous requests; clustered writes use one read-modify-write; readMany uses concurrent backends.
- `AsyncFileNative` pooled read/write via `NativeBuffer`.
- Web `openIndexedDb`; OPFS falls back to IndexedDB.
- Cooperative `CancelToken`; `exclusive` create; `flushWith`.
- `close`/`delete` drain pending operations before closing.
- `direct` mmap selection and `PerformanceProfile` worker tuning.
- Split public entries: `blit.dart`, `blit_io.dart`, `blit_buffer.dart`, `blit_web.dart`, `blit_native.dart`.

## 0.1.7

### Added

- AsyncIO utilities in `package:blit/blit_io.dart`: `ReadBuf`, `IoSlice`,
  `AsyncRead`, `AsyncWrite`, `AsyncBufRead`, `AsyncReadExt`, `AsyncWriteExt`.
- `BufReader`, `BufWriter`, `readLine`, `readerStream`, `copy`.
- `Uint8ListReader`, `BytesAsyncReader`, `Uint8ListWriter`,
  `BytesMutAsyncWriter`, `AsyncFileReader`, `AsyncFileWriter`.

## 0.1.6

### Added

- IndexedDB backend: `openIdbBytesFile`.
- Read-only Blob backend: `openBlobBytesFile`.

## 0.1.5

### Added

- `ReadFast`.
- `benchmark/rust` with `iocp` / `uring` features.
- `file.read.pointer8MiB` / `file.write.pointer8MiB` benchmark rows.

### Changed

- Rust benchmark replaces the C benchmark in CI.
- Added Linux `UringBytesFile` benchmarks.
- Benchmark chart uses `benchcat` and bundled fonts.

## 0.1.4

### Changed

- Benchmark chart rendering moved to `benchcat` (`benchcat.toml`); CI uses
  `unk-404/benchcat@master` instead of `benchmark_svg`.

### Fixed

- Shared `io_uring` loops are now explicitly closable through
  `UringBytesFile.closeSharedLoopPool`; the Linux test suite closes its pool in
  `tearDownAll`. This prevents an idle `io_uring-reaper` isolate from keeping
  `dart test` / CI alive after the shared-loop tests finish.

## 0.1.3

### Changed

- Requires `io_uring` `^0.1.1`, which provides `UringLoopPool` /
  `UringLoopLease`.

### Fixed

- `BytesMut.splitTo` / `splitOff` now mark the source frozen, so the returned
  views survive later `BytesMut` mutations (copy-on-write), matching the README.

### Performance

- Added `BytesMut.spareView` + `advance` and unchecked put variants for
  uint8/uint16/uint32/uint64/float64/bytes/slice/repeated/uint; `Bytes` gained
  unchecked uint64/float32/float64 reads.
- Windows `IocpFile` reuses `OVERLAPPED` blocks and its single-request scratch
  buffer instead of allocating per request.
- Linux `UringBytesFile` registers a small fixed-buffer set and uses
  `READ_FIXED` / `WRITE_FIXED`, falling back to normal ops when unsupported.
- Added `openUringBytesFile(..., sharedLoop: true)` using the `io_uring`
  0.1.1 `UringLoopPool` / `UringLoopLease`; fixed buffers are unregistered
  before a lease is returned. Leases are exclusive, so this reuses reaper
  isolates for sequential open/close workloads rather than multiplexing
  concurrent files.
- Added a core Bytes/BytesMut/reader/writer benchmark suite, including a raw
  `Uint8List` baseline, merged into the main benchmark card.

### Added

- `MmapFile.readAtPointer` / `writeAtPointer` for caller-owned native buffers;
  these bypass the typed-data scratch copy (and the transparent mmap cache).

## 0.1.2

### Performance

- Buffered `MmapFile.readAt` / `writeAt` now use a transparent whole-file mmap
  cache by default; `mmapCache: false` keeps pool workers and direct-I/O files
  on the syscall path. File size and FFI argument storage are reused instead of
  queried/allocated per call.
- Added an isolate-local `PooledNativeAllocator` for uninitialized, reusable
  scratch blocks.
- `UringBytesFile` reuses `UringBuffer`s across single and batched operations.

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
  `crossOriginIsolated` and `Atomics.waitAsync` are available: 8 闂?64 KiB
  slots, `Atomics` wakeups, postMessage fallback for larger payloads and
  non-isolated pages.
- Benchmark SVG rendering now uses `bench-svg` (`bench-svg.toml` + the
  `unk-404/benchmark_svg` action) instead of a repo-local SVG generator.
- Benchmark chart compares Dart with a C counterpart implementing the same
  single-thread 8 MiB sequential and 4 KiB random/mmap operations; Dart-only
  engine rows use bench-svg placeholder tracks.

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
- Windows `IocpFile`: overlapped I/O + IOCP, QD 1闂?28 batch reads/writes.
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
  `assets/benchmarks.svg`, and Dart/Web CI workflows.
- Tests: differential fuzz, lifetime/error paths, 100k-op stress, 32 GiB sparse.

### Fixed during development

- `putUint64` little-endian limb encoding and atomic failure on short buffers.
- `ParallelBytesFile` barrier deadlock when queued work already existed.
- Windows read-only mapping `zeroize` guard and empty-file `map` consistency.





