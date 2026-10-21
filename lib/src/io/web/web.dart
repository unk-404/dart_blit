/// Web (OPFS) backend - public entry points for code that targets browsers.
///
/// The cross-platform entry point is
/// `package:blit/src/io/open.dart`'s `openBytesFile`; this library adds the
/// Web-only knobs and diagnostics:
///
/// ```dart
/// import 'package:blit/src/io/web/web.dart' as web_io;
///
/// final caps = await web_io.probeWebStorageCapabilities();
/// if (!caps.canUseChunkBackend) throw UnsupportedError('$caps');
///
/// final file = await web_io.openOpfsBytesFile('data/big.bin',
///     chunkSize: 16 * 1024 * 1024);
/// await file.writeAt(0, header);
/// await file.flush();
/// ```
///
/// ## Storage layout
///
/// ```text
/// OPFS: bytes-opfs/d_<hash>_<name>/m.a, m.b       manifest (double slot)
///                              /c/0.bin, 1.bin...  <= chunkSize chunks
/// ```
///
/// ## Caveats
///
/// * One instance per logical path: OPFS sync handles take an exclusive lock.
/// * `flush()`/`close()` persist the manifest; a page crash loses unflushed
///   manifest updates (chunk bytes written but not referenced read as zeros).
/// * `SharedArrayBuffer` acceleration requires `COOP: same-origin` +
///   `COEP: require-corp`; non-isolated pages transparently use postMessage.
/// * Quota is not pre-checked; `QuotaExceededError` surfaces as
///   [WebQuotaExceededException].
library;

import 'dart:async';

import '../bytes_file.dart';
import 'chunk_layout.dart';
import 'manifest.dart';
import 'opfs_client.dart';
import 'web_bytes_file.dart';

export 'blob_bytes_file.dart'
    show WebBlobBytesFile, openBlobBytesFile, openBlobBytesFileTyped;
export 'capabilities.dart';
export 'idb_bytes_file.dart'
    show
        WebIndexedDbBytesFile,
        WebIndexedDbException,
        deleteIdbFile,
        openIdbBytesFile,
        openIdbBytesFileTyped,
        shutdownIdbBackend;
export 'idb_layout.dart'
    show
        IdbMeta,
        decodeIdbMeta,
        encodeIdbMeta,
        idbChunkKey,
        idbFileKey,
        idbMetaKey,
        kIdbDatabaseName,
        kIdbDefaultChunkSize,
        kIdbMaxChunkSize,
        kIdbMinChunkSize,
        kIdbStoreName;
export 'chunk_layout.dart'
    show
        chunkCountFor,
        chunkDirPathFor,
        chunkLogicalLength,
        chunkPathFor,
        kDefaultChunkSize,
        kMaxLogicalLength,
        normalizeLogicalPath,
        storePathFor;
export 'errors.dart';
export 'manifest.dart' show WebFileManifest;
export 'opfs_client.dart' show OpfsWorkerPool;
export 'web_bytes_file.dart' show WebOpfsBytesFile;

/// Opens (or creates) a logical file backed by OPFS chunks.
///
/// * [create]: create an empty file when it does not exist (ignored when
///   [readOnly] is true, matching `dart:io`'s `FileMode.read`).
/// * [readOnly]: rejects every mutating call with a [StateError].
/// * [chunkSize]: only used when the file is created; existing files keep the
///   chunk size recorded in their manifest.  Defaults to 16 MiB.
/// * [workers]: chunk workers in the page-wide pool; the first open wins.
///   Defaults to [OpfsWorkerPool.defaultWorkers].
///
/// Throws [UnsupportedError] when the browser has no OPFS / worker sync handle,
/// [WebFileSystemException] with `NotFoundError` when [create] is false and the
/// file is missing, and [WebQuotaExceededException] when the origin is full.
Future<BytesFile> openOpfsBytesFile(
  String path, {
  bool create = true,
  bool readOnly = false,
  int chunkSize = kDefaultChunkSize,
  int? workers,
}) {
  return WebOpfsBytesFile.open(
    path,
    create: create,
    readOnly: readOnly,
    chunkSize: chunkSize,
    workers: workers,
  );
}

/// Opener with the concrete [WebOpfsBytesFile] type (for diagnostics such as
/// [WebOpfsBytesFile.debugPhysicalChunkSize]).
Future<WebOpfsBytesFile> openOpfsBytesFileTyped(
  String path, {
  bool create = true,
  bool readOnly = false,
  int chunkSize = kDefaultChunkSize,
  int? workers,
}) {
  return WebOpfsBytesFile.open(
    path,
    create: create,
    readOnly: readOnly,
    chunkSize: chunkSize,
    workers: workers,
  );
}

/// Deletes the logical file at [path] and every OPFS entry it owns.
///
/// Do not call this while another instance of the same file is open: its chunk
/// handles hold exclusive locks.  Use `BytesFile.delete()` instead when you
/// have a handle.
Future<void> deleteOpfsFile(String path) async {
  final normalized = normalizeLogicalPath(path);
  final pool = await OpfsWorkerPool.instance();
  await pool.manifest.remove(storePathFor(normalized), recursive: true);
}

/// Lists entry names of an OPFS directory (diagnostics/tests).
///
/// Throws [WebFileSystemException] with `NotFoundError` when [path] is not an
/// existing directory.
Future<List<String>> listOpfsDirectory(String path) async {
  final pool = await OpfsWorkerPool.instance();
  return pool.manifest.list(path);
}

/// Reads and decodes the newest valid manifest for [path] (`null` if none).
///
/// Useful to assert generation/CRC/bitmap state in tests and to inspect a file
/// without opening it (no sync handle, no lock).
Future<WebFileManifest?> readWebFileManifest(String path) =>
    WebOpfsBytesFile.readManifest(path);

/// Shuts the page-wide OPFS worker down and releases every handle.
///
/// Mostly useful for tests and hot-restart style teardown; subsequent opens
/// start a fresh worker.
void shutdownWebBackend() => OpfsWorkerPool.shutdownShared();

/// Conservative default chunk size for mobile (iOS memory pressure).
const int kMobileChunkSize = 8 * 1024 * 1024;

/// Number of chunk files for a logical length, for planning/UI estimates.
int chunkFilesFor(int logicalLength, {int chunkSize = kDefaultChunkSize}) =>
    chunkCountFor(logicalLength, chunkSize);
