# blit

Zero-copy `Bytes` / `BytesMut` and fast random-access file I/O for Dart and
Flutter. Native I/O is pure `dart:ffi`; Web I/O uses OPFS. No C compiler, native
build hooks or native assets.

![blit benchmark card](https://raw.githubusercontent.com/unk-404/dart_blit/master/assets/benchmarks.svg)

## Why blit

- **Zero-copy `Bytes`** — a `(buffer, offset, length)` view; `slice`/`sublist`
  are O(1).
- **TypedData bridge** — `Bytes.fromTypedData` and `TypedData.asBytes()` wrap
  `Uint8List`, `ByteData`, `Int32List`, etc. without copying. `BytesLike` is a
  small zero-copy boundary interface for other byte libraries.
- **`BytesMut`** — growable buffer; `freeze()` / `splitTo()` / `splitOff()`
  return shared views with copy-on-write on later mutation.
- **Exact `Uint64`** — two 32-bit limbs; works on VM, dart2js and dart2wasm
  without `Uint64List` or `ByteData.getUint64`.
- **Reader/writer cursors** — `BytesReader` / `BytesWriter` provide
  `Buf`/`BufMut`-style fixed-width access.
- **Native file engines** — mmap, isolate pool, Windows IOCP and Linux io_uring.
- **Web backend** — OPFS chunks + double-slot manifest, with a chunk-worker
  pool and an optional cross-origin-isolated SAB ring.

Runtime dependencies are `package:ffi` and the pure-Dart `package:io_uring`
(used only by the Linux ring backend).

## Install

```bash
dart pub add blit
```

Requires Dart `^3.13.5`. A current Flutter SDK includes a compatible Dart SDK.

## Quick start

### Bytes and views

```dart
import 'dart:typed_data';
import 'package:blit/blit.dart';

final backing = Uint8List.fromList([1, 2, 3, 4]);
final bytes = Bytes.fromUint8List(backing);
final slice = bytes.slice(1, 3); // O(1), shares backing

backing[1] = 99;
print(slice[0]); // 99
```

Typed data interop is zero-copy:

```dart
final bytes = Bytes.fromTypedData(byteData); // Uint8List / ByteData / Int32List
final typed = bytes.asUint8List();            // zero-copy view
```

Other byte libraries can implement `BytesLike`:

```dart
abstract interface class BytesLike {
  int get length;
  Uint8List asUint8List();
}
```

Convert at the boundary, then stay on `Bytes` / `Uint8List` in hot loops.

For tight bit writers, avoid one `putUint8` call per bit/byte. Reserve a tail
once and write it as a `Uint8List`:

```dart
final buf = BytesMut(1 << 16);
final tail = buf.spareView(4096);
// write directly through tail[offset]
buf.advance(4096);
```

`putUint8Unchecked` / `putUint16Unchecked` / `putUint32Unchecked` /
`putUint64Unchecked` / `putFloat64Unchecked` and the array/repeated variants
are available when capacity is already guaranteed. `Bytes.getUint8Unchecked`
and the wider unchecked getters are the corresponding read-side fast paths.

### Encoding

```dart
final mut = BytesMut(16)
  ..putUint32(0x01020304)
  ..putUint64(const Uint64(0x11223344, 0x55667788));
final bytes = mut.freeze();

print(bytes.getUint32(0).toRadixString(16)); // 1020304
print(bytes.getUint64(4));                   // 1234605616436508552
```

### Random-access files

```dart
import 'dart:typed_data';
import 'package:blit/blit.dart';

final file = await openBytesFile('/tmp/data.bin');
try {
  await file.writeAt(0, Uint8List.fromList([1, 2, 3, 4]));
  await file.append(Uint8List.fromList([5, 6]));

  final out = Uint8List(6);
  await file.readAt(0, out);
} finally {
  await file.close();
}
```

`openBytesFile` is the portable async API. The synchronous companion lives in
`package:blit/bytes_ffi.dart` for native-only code.

## Native engines

Import native-only APIs from `package:blit/bytes_ffi.dart`.

### mmap

```dart
final file = openMmapFileSync('/tmp/sparse.bin');
file.truncate(32 << 30); // sparse by default on Windows
final region = file.map(offset: 30 << 30, length: 1 << 20);

region.bytes[0] = 42;
region.prefetch(offset: 0, length: 1 << 20);
region.flush();
region.close();
file.close();
```

For framework/buffer-pool hot paths, read/write caller-owned native memory
directly (no scratch copy, no transparent mmap cache):

```dart
final scratch = calloc<Uint8>(1 << 20);
file.writeAtPointer(0, scratch, 1 << 20);
file.readAtPointer(0, scratch, 1 << 20);
calloc.free(scratch);
```

Mapped windows support `prefetch()` / `discard()` hints. File-level helpers
include `punchHole` (Windows/Linux), `cloneRangeFrom` (Windows), `preallocate`
and `adviseRead` (macOS), and `cloneFileSync` (macOS `clonefile`, copy
fallback). Unsupported filesystems throw; fall back to `zeroize` or a copy.

### ReadFast

`ReadFast` selects a native read engine automatically:

```dart
final fast = await ReadFast.open('/data/archive.bin');
try {
  final block = Uint8List(4096);
  await fast.readAt(offset, block);
} finally {
  await fast.close();
}
```

Windows uses a per-worker mmap pool for files up to 1 GiB and an IOCP-backed
pool above that. Linux uses io_uring above the mmap threshold and an mmap pool
below it, falling back to the isolate pool if the kernel rejects io_uring.
`workers`, `mmapLimit`, `maxQueue`, and `preferUring` are overridable; the
selected backend is exposed as `ReadFast.engine`.

### Isolate pool

```dart
final pool = await ParallelBytesFile.open(
  '/tmp/data.bin',
  maxWorkers: 8,
  maxQueue: 64,
);

final chunks = await pool.readMany([0, 1 << 20, 2 << 20], 4096);
await pool.close();
```

`maxQueue` bounds queued + in-flight work. `readMany` merges exactly adjacent
ranges. Read-only files up to `mmapReadCacheLimit` (default 1 GiB) are mapped
once per worker for hot random reads; set the limit to `0` to disable. Mapping
is virtual: cold pages still fault from disk.

### Windows

`IocpFile` exposes overlapped I/O with queue depth 1–128:

```dart
final f = IocpFile.openSync('/tmp/data.bin', queueDepth: 32);
final data = f.readManySync(offsets, 4096);
f.close();
```

`MapViewOfFile3` placeholders can swap mapped windows without an unmap/remap
gap:

```dart
final placeholder = file.createPlaceholder(1 << 20);
final view = placeholder.map(otherFile);
view.close();
placeholder.close();
```

Direct I/O uses `FILE_FLAG_NO_BUFFERING`; `largePages: true` opts into
`MEM_LARGE_PAGES` scratch buffers when `SeLockMemoryPrivilege` is available.

### Linux io_uring

`UringBytesFile` is a pure-Dart `io_uring` backend built on `package:io_uring`.
Use the batch methods for queue depth:

```dart
final f = await openUringBytesFile('/tmp/data.bin', entries: 64);
try {
  await f.writeMany(offsets, blocks);
  final reads = await f.readMany(offsets, 4096);
  await f.flush();
} finally {
  await f.close();
}
```

Set `sharedLoop: true` to lease a ring from `package:io_uring`'s reference-counted
`UringLoopPool`. Leases are exclusive: this reuses a reaper isolate across
sequential open/close calls, while concurrent files still get separate loops.
Fixed buffers are unregistered before the lease is returned. Call
`UringBytesFile.closeSharedLoopPool(entries: ...)` when finished with shared
loops; otherwise the pool intentionally keeps an idle reaper for reuse.

`entries` must be at least the batch size. The backend is Linux-only.

### Direct I/O

For streaming files larger than RAM, open with `direct: true` (Windows
`FILE_FLAG_NO_BUFFERING`, Linux/Android `O_DIRECT`, macOS/iOS `F_NOCACHE`).
Offsets and lengths must be 4 KiB aligned. Direct I/O is intended for
sequential copy/import/export, not 4 KiB random access.

## Web backend

```dart
final file = await openBytesFile('data/big.bin');
await file.writeAt(0, header);
await file.flush();
```

On Web, `BytesFile` is backed by OPFS chunk files and a double-slot manifest.
Logical length is metadata-only until data is written, so large sparse files do
not zero-fill the whole range.

OPFS sync handles are dedicated-worker-only and exclusive per file. Chunks are
distributed across a small worker pool; one logical file serializes its writes
so the manifest stays single-writer. In a cross-origin-isolated page
(`COOP: same-origin` + `COEP: require-corp`), small reads/writes use a
`SharedArrayBuffer` ring; larger payloads and non-isolated pages fall back to
postMessage transfer.

### IndexedDB backend

IndexedDB is available as an explicit alternative when OPFS sync handles are
not usable (for example in a context that blocks dedicated workers):

```dart
import 'package:blit/src/io/web/web.dart';

final idb = await openIdbBytesFile('data/indexed.bin', chunkSize: 64 * 1024);
await idb.writeAt(0, bytes);
await idb.close();
```

The IndexedDB backend does not create one object store per file. It shares one
database (`blit-bytes`) and one store (`records`) across the origin; each
logical path is a base64 key prefix, and chunk keys are zero-padded so range
deletes are cheap. Records are sparse (missing chunks read as zero), a 128-chunk
LRU caches hot 64 KiB chunks, and reads/writes batch all touched chunks into one
IndexedDB transaction. `openIdbBytesFile` supports `create`, `readOnly`,
`chunkSize`, `databaseName`, and `storeName`.

### Blob backend

An immutable `Blob` or `File` can be exposed as a read-only `BytesFile`:

```dart
import 'dart:js_interop';
import 'package:blit/src/io/web/js.dart' show JsBlob;
import 'package:blit/src/io/web/web.dart';

final blob = JsBlob([bytes.toJS].toJS);
final file = await openBlobBytesFile(blob, cacheLimit: 8 * 1024 * 1024);
final block = Uint8List(4096);
await file.readAt(offset, block);
```

Small Blobs are materialized once and served from memory; larger ones use
`Blob.slice()` per request without copying the whole file. Writes, truncate and
delete throw `StateError`; `flush` is a no-op.

## Platform support

| Capability | Windows | Linux | macOS | Android | iOS | Web |
|---|---|---|---|---|---|---|
| `Bytes` / `BytesMut` / `Uint64` | ✅ | ✅ | ✅ | ✅* | ✅* | ✅ |
| `BytesFile` (`dart:io`) | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | — |
| mmap (`bytes_ffi.dart`) | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | — |
| `IocpFile` | ✅ | — | — | — | — | — |
| `UringBytesFile` | — | ✅ | — | — | — | — |
| `ParallelBytesFile` | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | — |
| OPFS backend | — | — | — | — | — | ✅ |
| IndexedDB backend | — | — | — | — | — | ✅ |
| Blob backend (read-only) | — | — | — | — | — | ✅ |

`*` Android/iOS are not built or run by CI; the pure-Dart core is portable, but
mobile file paths are unverified. CI covers Dart on Ubuntu/macOS/Windows and
Chrome on Ubuntu.

## Large and sparse files

| Meaning | Cost |
|---|---|
| Large logical length | metadata-only (`truncate`) |
| Large sparse file | metadata until written |
| Real data | disk/cache-bound; write only what you need |

On Windows, a non-sparse `truncate(32 GiB)` followed by a far-offset write can
zero-fill the gap. `MmapFile.truncate(..., sparse: true)` is the default and
avoids it. OPFS uses chunk files for the same reason.

## Performance

The benchmark card compares Dart with the Rust counterpart in
[`benchmark/rust`](benchmark/rust). Both implement the same six single-thread
operations: 8 MiB sequential read/write, 4 KiB random pread/pwrite, and 4 KiB
random mmap read/write. The Rust crate has feature-gated `iocp` (Windows) and
`uring` (Linux) QD32 rows; Dart-only pool, large-file and core-Bytes rows use
placeholders. The common file rows perform the same scratch copy as
`readAt`/`writeAt`.

The same card includes core `Bytes` / `BytesMut` / reader / writer rows from
[`benchmark/bytes_benchmarks_test.dart`](benchmark/bytes_benchmarks_test.dart),
including a raw `Uint8List` baseline. Those rows are Dart-only and use
placeholder Rust tracks; they are not a language comparison. CI runs this suite
alongside the native benchmarks.

The card is generated from the `benchmark/` suite with
[`benchcat`](https://github.com/unk-404/benchcat). Raw JSONL/SVG artifacts
are produced by CI; the chart is deterministic and reflects the latest default
branch run.

Random 4 KiB I/O is latency-bound; the isolate pool hides it with concurrency.
mmap pays page faults on cold random access but is memory-speed once hot.
`pwrite` numbers are page-cache writes, not durability.

## Examples

- [`example/bytes_example.dart`](example/bytes_example.dart): core APIs and native file I/O.
- [`example/bytes_web_example.dart`](example/bytes_web_example.dart): Web-safe core for dart2js/dart2wasm.
- [`flutter_example/`](https://github.com/unk-404/dart_blit/tree/master/flutter_example): repository-only Flutter example.

## Development

```sh
dart pub get
dart analyze
dart test
dart run example/bytes_example.dart
```

Chrome tests cover OPFS and Web fuzz. CI runs Dart on Ubuntu/macOS/Windows and
Chrome on Ubuntu. On push/manual branch runs, Rust benchmarks run on Windows
(`iocp`) and Ubuntu (`uring`), the Dart `UringBytesFile` benchmark runs on
Ubuntu, and the Windows chart job merges all JSONL files with benchcat, uploads
artifacts and commits the chart with `[skip ci]`. PR runs stop after tests.
`workflow_dispatch` accepts `benchmark_gb` and `BYTES_BENCH_GB` controls local
random-file benchmarks.

## Limitations

- OPFS sync handles are worker-only and exclusive per file; the Web backend is
  serialized per file. Safari/Firefox are feature-detect targets, not locally
  validated.
- Android/iOS are not built or run by CI; native mobile file paths are
  unverified.
- `IocpFile` is Windows-only; cold-device behavior above 4 GiB is not locally
  verified.
- Zeroize is `memset`-level; there is no compiler-proof `SecureZeroMemory`
  without a C shim.
- `ParallelBytesFile` does not order overlapping writes; await the previous
  write or use `flush` as a barrier.
- The API is pre-1.0; breaking changes may occur.

## License

MIT. See [LICENSE](LICENSE).
