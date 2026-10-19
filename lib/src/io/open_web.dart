/// Web (OPFS) implementation of `openBytesFile`.
///
/// The real backend lives in `lib/src/io/web/`:
///
/// * [WebOpfsBytesFile] — chunked logical file (`BytesFile` implementation);
/// * [OpfsWorkerClient] — dedicated worker holding every
///   `FileSystemSyncAccessHandle` (`createSyncAccessHandle` is worker-only);
/// * [WebManifestState] — double-slot manifest (length, bitmap, per-chunk CRC,
///   generation);
/// * [probeWebStorageCapabilities] — OPFS/sync-handle/quota feature detection.
///
/// This file only exists so `lib/src/io/open.dart` can conditionally export a
/// web version with the same signature as the native one.
library;

import 'bytes_file.dart';
import 'web/web.dart' as web_io;

/// Opens a logical file in the Web (OPFS) backend.
///
/// * [path] is a relative, `/`-separated logical path (`data/big.bin`).
/// * [create] creates an empty file when the manifest is missing; with
///   `create: false` a missing file throws [web_io.WebFileSystemException] with
///   `name == 'NotFoundError'`.
/// * [readOnly] rejects writes/truncate/delete with [StateError] and implies
///   `create: false`.
///
/// Throws [UnsupportedError] when OPFS or worker sync access handles are
/// unavailable (for example when a Content-Security-Policy blocks `blob:`
/// workers) and [web_io.WebQuotaExceededException] when the origin is full.
Future<BytesFile> openBytesFile(
  String path, {
  bool create = true,
  bool readOnly = false,
}) => web_io.openOpfsBytesFile(path, create: create, readOnly: readOnly);
