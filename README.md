# blit

Zero-copy `Bytes` / `BytesMut`, async file I/O, and Web storage for Dart and
Flutter. Native I/O is pure `dart:ffi`; Web I/O uses OPFS, IndexedDB, and Blob.
No C compiler, native build hooks, or native assets.

![blit benchmark card](https://raw.githubusercontent.com/unk-404/dart_blit/master/assets/benchmarks.svg)

## Why blit

- **Zero-copy `Bytes`** - a `(buffer, offset, length)` view; `slice`/`sublist`
  are O(1).
- **`BytesMut`** - growable buffer; `freeze()` / `splitTo()` / `splitOff()`
  return shared views with copy-on-write on later mutation.
- **Exact `Uint64`** - two 32-bit limbs; works on VM, dart2js, and dartwasm.
- **AsyncFile** - one random-access API across IOCP, io_uring, mmap, isolate
  pools, OPFS, IndexedDB, and Blob.
- **AsyncIO** - `ReadBuf`, `AsyncRead`/`AsyncWrite`, buffered readers/writers,
  `readExact`, `readToEnd`, `copy`, and typed-data adapters.
- **Native zero-copy** - `NativeBuffer` and pointer read/write on the native
  mmap backend.
- **Simple API** - `blit.read` / `blit.write` / `blit.open` for default use.

Runtime dependencies are `package:ffi` and the pure-Dart `package:io_uring`
(used only by the Linux ring backend).

## Install

```bash
dart pub add blit
```

Requires Dart `^3.13.5`.

## Simple API

```dart
import 'package:blit/blit.dart';

await blit.write('data.bin', bytes);
final data = await blit.read('data.bin');
await blit.append('data.bin', tail);
await blit.copy('data.bin', 'backup.bin');

final file = await blit.open('data.bin');
final head = await file.readAt(0, 4096);
await file.writeAt(0, head);
await file.close();
```

`blit.open` defaults to read-write and creates a missing file. Use
`FileOptions` for explicit mode:

```dart
final file = await blit.open(
  'data.bin',
  options: const FileOptions(
    mode: FileMode.read,
    create: false,
    durability: Durability.full,
    profile: PerformanceProfile.throughput,
  ),
);
```

## Core bytes

```dart
import 'dart:typed_data';
import 'package:blit/blit.dart';

final backing = Uint8List.fromList([1, 2, 3, 4]);
final bytes = Bytes.fromUint8List(backing);
final slice = bytes.slice(1, 3); // O(1), shares backing

backing[1] = 99;
print(slice[0]); // 99
```

Typed-data interop is zero-copy:

```dart
final bytes = Bytes.fromTypedData(byteData);
final typed = bytes.asUint8List();
```

Other byte libraries can implement `BytesLike`:

```dart
abstract interface class BytesLike {
  int get length;
  Uint8List asUint8List();
}
```

For direct writer tails:

```dart
final buf = BytesMut(1 << 16);
final tail = buf.spareView(4096);
// write through tail[offset]
buf.advance(4096);
```

## AsyncFile

```dart
import 'package:blit/blit_io.dart';

final file = await AsyncFile.open(
  'data.bin',
  options: const FileOptions(mode: FileMode.readWrite),
);

final dst = Uint8List(1 << 20);
final n = await file.readAt(offset, ReadBuf(dst));
await file.writeAt(offset, IoSlice(dst, end: n));
await file.flush();
await file.close();
```

Batch requests:

```dart
await file.readMany([
  ReadRequest(0, ReadBuf(a)),
  ReadRequest(1 << 20, ReadBuf(b)),
]);

await file.writeMany([
  WriteRequest(0, IoSlice(a)),
  WriteRequest(1 << 20, IoSlice(b)),
]);
```

Errors use one hierarchy:

```text
BlitException
  - BlitIOException
  - EndOfFileException
  - ClosedException
  - PermissionException
  - QuotaExceededException
  - UnsupportedException
```

## AsyncIO

```dart
import 'package:blit/blit_io.dart';

final file = await AsyncFile.open(
  'data.bin',
  options: const FileOptions(mode: FileMode.read),
);
final reader = BufReader(file, capacity: 64 * 1024);
final line = await readLine(reader);

final dst = BytesMutAsyncWriter();
await reader.copyTo(dst);
```

Available:

- `ReadBuf`, `IoSlice`
- `AsyncRead`, `AsyncWrite`, `AsyncBufRead`
- `readExact`, `readToEnd`, `readU8..U64`, `writeAll`, `writeUint*`, `copy`
- `BufReader`, `BufWriter`, `readLine`, `readerStream`
- `Uint8ListReader`, `BytesAsyncReader`, `Uint8ListWriter`,
  `BytesMutAsyncWriter`

## Unsafe external memory

`UnsafeBytes` is a fixed-length allocation handle outside the Dart GC. The
length is not stored in the handle; callers pass it to every length-bearing
operation. `free` releases through the allocator header.

```dart
final bytes = UnsafeBytes.alloc(64);

final view = bytes.view(64);
bytes.setInt32(0, 42);
bytes.setFloat64(8, 1.5);
bytes.free();
```

Native uses `malloc`/`free`; Web uses a `WebAssembly.Memory` arena. The handle
is an `int` extension type, so allocation does not add a Dart object. There are
no bounds, lifetime, alignment, double-free, or use-after-free checks. This is
not a C ABI layer and does not define struct layouts.

`AsyncFile.readAtUnsafe` and `writeAtUnsafe` accept an `UnsafeBytes` plus an
explicit length.

## Native zero-copy

```dart
import 'package:blit/blit_native.dart';

final native = await NativeMmapFile.open('data.bin', create: false);
final buffer = NativeBuffer.allocate(1 << 20);
try {
  native.readIntoNative(offset, buffer);
  native.writeFromNative(offset, buffer);
} finally {
  buffer.dispose();
  await native.close();
}
```

`NativeBufferPool` reuses exact-size buffers. Pointer paths are native-only and
bypass the typed-data copy.

## Web

```dart
import 'package:blit/blit_web.dart';

await blit.write('data.bin', bytes);
final data = await blit.read('data.bin');

final blobFile = await openBlob(blob);
final all = await blobFile.readAll();
await blobFile.close();
```

OPFS is the default file backend. IndexedDB and Blob APIs are available from
`package:blit/blit_web.dart`.

## Platform support

| Capability | Windows | Linux | macOS | Android | iOS | Web |
|---|---|---|---|---|---|---|
| `Bytes` / `BytesMut` / `Uint64` | yes | yes | yes | partial | partial | yes |
| `AsyncFile` | yes | yes | yes | partial | partial | yes |
| AsyncIO utilities | yes | yes | yes | partial | partial | yes |
| Native zero-copy | yes | yes | yes | partial | partial | no |
| OPFS / IndexedDB / Blob | no | no | no | no | no | yes |

`partial` means the pure-Dart core is portable, but Android/iOS native file
paths are not built or validated by CI.

## Performance

The chart at the top is generated from CI benchmark results. Native engines:

- Windows: IOCP, mmap, isolate pools
- Linux: io_uring, mmap, isolate pools
- POSIX: `pread`/`pwrite`, mmap
- Web: OPFS worker pool, IndexedDB transactions, Blob slices

Use `PerformanceProfile` and `FileOptions` to select a policy instead of
referencing engine classes directly.

## Development

```bash
dart analyze
dart test
dart test -p chrome test/web
```

CI runs Dart tests on Ubuntu/macOS/Windows, Chrome Web tests, native/Rust
benchmarks, and renders the benchmark SVG.

## Limitations

- Ordinary Dart `Uint8List` cannot be pinned; true zero-copy requires
  `NativeBuffer` or another native-backed view.
- `FileOptions.direct` requires aligned offsets and lengths.
- Overlapping writes are serialized; do not assume a specific completion order.
- iOS/Android native paths are not validated by CI.


