# blit

Zero-copy `Bytes` / `BytesMut` and high-performance random-access file I/O for
Dart and Flutter. Native I/O is pure `dart:ffi` (no C, no native build hooks);
Web I/O uses OPFS chunk files and a dedicated worker.

![blit benchmark table](https://raw.githubusercontent.com/unk-404/dart_blit/master/assets/benchmarks.svg)

## Features

- **Zero-copy `Bytes`**: `(buffer, offset, length)` views; `slice`/`sublist` are O(1).
- **`BytesMut`**: growable buffer; `freeze()`/`splitTo()`/`splitOff()` return zero-copy views with copy-on-write on later mutation.
- **`Uint64`**: exact unsigned 64-bit values as two 32-bit limbs; works on VM, dart2js and dart2wasm without `Uint64List`/`ByteData.getUint64`.
- **`BytesReader` / `BytesWriter`**: Rust `Buf`/`BufMut`-style fixed-width reads/writes, big-endian by default.
- **`BytesFile`**: async random-access interface; native `dart:io` backend plus sync API.
- **Native mmap engine** (`package:blit/bytes_ffi.dart`): `CreateFileMappingW`/`MapViewOfFile` on Windows, `mmap`/`pread`/`pwrite` on POSIX; sparse files, 64 KiB windows, zeroize.
- **Windows IOCP engine** `IocpFile`: overlapped I/O + completion port, QD 1–128 for a single worker.
- **`ParallelBytesFile`**: native isolate worker pool + FIFO queue + watermark barriers; batch 32; `readMany`/`writeMany`; default `min(32, max(2, cpus-1))` workers; read-only mmap cache for hot files up to 1 GiB.
- **Web OPFS backend**: chunk files + double-slot manifest + dedicated worker; 32 GiB logical files are metadata-only until written.
- **Hand-written Web bindings**: only `dart:js_interop` declarations for `Worker`, `Blob`, `URL` and `navigator.storage`; no `package:web` dependency.

No C compiler, native assets or `flutter config --enable-native-assets` is
required. The only native code is the operating system's own I/O API, reached
through `dart:ffi`; the only runtime dependency is `package:ffi` (for
`toNativeUtf16`/`calloc`).

## Platform support

| Capability | Windows | Linux | macOS | Android | iOS | Web |
|---|---|---|---|---|---|---|
| `Bytes`/`BytesMut`/`Uint64` | ✅ | ✅ | ✅ | ✅* | ✅* | ✅ |
| `BytesFile` (`dart:io`) | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | — |
| Native mmap (`bytes_ffi.dart`) | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | — |
| `IocpFile` | ✅ | — | — | — | — | — |
| `ParallelBytesFile` | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | — |
| OPFS backend | — | — | — | — | — | ✅ |

`*` Android/iOS are not built or run by CI; the pure-Dart core is
platform-independent, but mobile file paths are **unverified**. CI covers
Dart on Ubuntu/macOS/Windows, Chrome on Ubuntu, and Flutter desktop/Web only.
OPFS `createSyncAccessHandle` is dedicated-worker-only, takes an exclusive lock
per file, and Web file backends are serialized per file (no parallel pool).

## Install

```yaml
dependencies:
  blit: ^0.1.0
```

Requires Dart `^3.13.5`; Flutter 3.47.x includes a compatible Dart SDK.

## API examples

### Zero-copy bytes

```dart
import 'dart:typed_data';
import 'package:blit/blit.dart';

final backing = Uint8List.fromList([1, 2, 3, 4]);
final bytes = Bytes.fromUint8List(backing);
final slice = bytes.slice(1, 3); // O(1), shares backing

backing[1] = 99;
print(slice[0]); // 99
```

### Encoding

```dart
import 'package:blit/blit.dart';

final mut = BytesMut(16)
  ..putUint32(0x01020304)
  ..putUint64(const Uint64(0x11223344, 0x55667788));
final bytes = mut.freeze();

print(bytes.getUint32(0).toRadixString(16)); // 1020304
print(bytes.getUint64(4));                   // 1234605616436508552
```

### Native file

```dart
import 'dart:typed_data';
import 'package:blit/blit.dart';

final file = await openBytesFile('/tmp/data.bin');
await file.writeAt(0, Uint8List.fromList([1, 2, 3, 4]));
await file.append(Uint8List.fromList([5, 6]));

final out = Uint8List(6);
await file.readAt(0, out);
await file.close();
```

### mmap and isolate pool

```dart
import 'package:blit/bytes_ffi.dart';

final file = openMmapFileSync('/tmp/sparse.bin');
file.truncate(32 << 30); // sparse by default on Windows
final region = file.map(offset: 30 << 30, length: 1 << 20);
region.bytes[0] = 42;
region.flush();
region.close();
file.close();

final pool = await ParallelBytesFile.open('/tmp/data.bin', maxWorkers: 8);
final chunks = await pool.readMany([0, 1 << 20, 2 << 20], 4096);
await pool.close();
```

`readMany` merges exactly adjacent ranges (one syscall per sequential run).
For `readOnly: true` files up to `mmapReadCacheLimit` (default 1 GiB), each
worker maps the whole file once and serves reads from memory; hot random reads
skip the per-block `ReadFile`/`pread`. Set the limit to `0` to disable, or raise
it for a hot file that fits comfortably in the address space. Mapping is
virtual: cold pages still fault from disk.

For streaming files larger than RAM, open with `direct: true` (Windows
`FILE_FLAG_NO_BUFFERING`, Linux/Android `O_DIRECT`, macOS/iOS `F_NOCACHE`).
Offsets and lengths must be 4 KiB aligned; direct I/O bypasses the page cache
and is intended for sequential copy/import/export, not 4 KiB random access:

```dart
final stream = openMmapFileSync('/tmp/big.bin', direct: true);
final chunk = Uint8List(8 << 20); // 4 KiB aligned length
stream.readAt(0, chunk);
stream.writeAt(0, chunk);
stream.close();
```

`ParallelBytesFile.open(..., direct: true)` uses the same direct engine in its
workers. On 4K random reads direct I/O is much slower than buffered/mmap
(measured ~7k vs ~175k IOPS on 8 GiB); use it only for aligned streaming.

`IocpFile` (Windows) is available for a single worker that wants deeper queue:

```dart
final f = IocpFile.openSync('/tmp/data.bin', queueDepth: 32);
final data = f.readManySync(offsets, 4096);
f.close();
```

## 32 GiB semantics

Three different things are often conflated:

| Meaning | Cost | Implementation |
|---|---|---|
| 32 GiB logical length | metadata-only | `truncate(32 << 30)` |
| 32 GiB sparse file | metadata until written | Windows `FSCTL_SET_SPARSE`; POSIX `ftruncate` |
| 32 GiB real data | disk/cache-bound | write what you need; no 32 GiB allocation |

On Windows, a non-sparse `truncate(32 GiB)` followed by a write at 30 GiB
zero-fills the gap (measured ~19 s). `MmapFile.truncate(..., sparse: true)` is
the default and avoids it. On Web, a single 32 GiB OPFS file has the same
zero-fill cost; the backend stores 16 MiB chunks plus a manifest instead.

## Performance

`package:benchmark_test` suite in the repository's `benchmark/` directory
(repository-only, not in the published package; JIT/AOT, ops/sec + RME).
Local Windows x64, UMIS NVMe SSD, 32 logical CPUs, 16.6 GB RAM, Dart 3.13.5:

| Workload | Result |
|---|---:|
| Sequential read 1 GiB (8 MiB blocks, cached) | 7.71 GiB/s |
| Sequential write 1 GiB (8 MiB blocks, cached) | 4.55 GiB/s |
| Direct streaming write 1 GiB (`NO_BUFFERING`) | 1.9 GiB/s |
| Direct streaming read 1 GiB (`NO_BUFFERING`) | 2.7 GiB/s |
| 32 GiB 4K random pread | 7.35k IOPS / 28.7 MiB/s |
| 32 GiB 4K random pwrite | 95.6k IOPS / 373 MiB/s (buffered) |
| 32 GiB 4K random mmap read (cold) | 5.0k IOPS / 19.5 MiB/s |
| `IocpFile` 4K read, single worker QD32 (1 GiB warm) | 93k–112k IOPS (JIT), ~138k (AOT) |
| Isolate pool 4K read, 16 workers (1 GiB warm, mmap cache) | **926k IOPS / 3.5 GiB/s** |
| Isolate pool 4K read, 16 workers (32 GiB cold) | 106.7k IOPS / 417 MiB/s |
| Isolate pool 4K read, 4 workers (1 GiB warm, mmap cache) | 732k IOPS / 2.8 GiB/s |
| Isolate pool 4K sequential readMany, 4 workers (1 GiB warm) | 536k IOPS / 2.1 GiB/s |

4K cold random is QD1 disk-latency-bound; the pool hides it with worker
concurrency. `pwrite` numbers are page-cache writes, not durability. mmap cold
random pays page faults; hot/repeated access is memory-speed.

## Examples

- [`example/bytes_example.dart`](example/bytes_example.dart): zero-copy, encoding and native file I/O.
- [`example/bytes_web_example.dart`](example/bytes_web_example.dart): Web-safe core for dart2js/dart2wasm.
- [`flutter_example/`](https://github.com/unk-404/dart_blit/tree/master/flutter_example): Flutter app and widget test using `blit` (repository-only, not in the pub package).

## Tests and CI

```sh
dart pub get
dart analyze
dart test
dart run example/bytes_example.dart
```

VM tests cover bytes/Uint64 fuzz, file backends, mmap lifetime, 100k-op stress,
isolate-pool barriers and (skipped by default) 32 GiB sparse writes. Chrome
tests cover the OPFS backend and Web fuzz. CI runs Dart on
Ubuntu/macOS/Windows, Chrome on Ubuntu, Flutter desktop/Web builds, and on
push/manual runs a Windows benchmark job after all tests pass. That job renders
`assets/benchmarks.svg`, uploads the JSONL + SVG artifact, and commits the SVG
with `[skip ci]`; PR runs stop after the tests. Manual `workflow_dispatch`
accepts `benchmark_gb` (default 4; hosted Windows runners should stay small).
For a local 32 GiB run, use
`BYTES_BENCH_GB=32 dart run benchmark_test benchmark/random_32g_benchmarks_test.dart`.
The local development machine is Windows.

## Limitations

- OPFS sync handles are worker-only and exclusive per file; the Web backend is
  serialized per file. Safari/Firefox are feature-detect targets, not locally
  validated.
- Android/iOS are **not built or run by CI**; the pure-Dart core should work,
  but native file paths on mobile are unverified and not claimed as supported.
- `IocpFile` is Windows-only; cold-device behavior above 4 GiB is not locally
  verified (Windows has no unprivileged drop-cache).
- Zeroize is `memset`-level; no compiler-proof `SecureZeroMemory` without a C
  shim, which this package intentionally does not require.
- `ParallelBytesFile` does not order overlapping writes; await the previous
  write or use `flush` as a barrier.
- API is `0.x`; breaking changes may occur before `1.0`.

## License

MIT. See [LICENSE](LICENSE).
