/// Web-specific entry point: OPFS, IndexedDB, and Blob.
library;

import 'dart:js_interop';

import 'blit.dart';
import 'src/io/web/web.dart' as web;
import 'src/v2/async_file.dart';

export 'blit.dart';
export 'src/io/web/web.dart';

/// Opens an IndexedDB-backed file through the simple facade.
Future<BlitFile> openIndexedDb(
  String path, {
  bool create = true,
  bool readOnly = false,
  int chunkSize = web.kIdbDefaultChunkSize,
  String databaseName = web.kIdbDatabaseName,
  String storeName = web.kIdbStoreName,
}) async {
  final backend = await web.openIdbBytesFile(
    path,
    create: create,
    readOnly: readOnly,
    chunkSize: chunkSize,
    databaseName: databaseName,
    storeName: storeName,
  );
  return BlitFile.fromFile(
    AsyncFile.fromBackend(
      path,
      backend,
      options: FileOptions(
        mode: readOnly ? FileMode.read : FileMode.readWrite,
        create: create,
      ),
    ),
  );
}

/// Opens an immutable Web `Blob`/`File` through the simple facade.
Future<BlitFile> openBlob(JSObject blob, {int cacheLimit = 8 << 20}) async {
  final backend = await web.openBlobBytesFile(blob, cacheLimit: cacheLimit);
  return BlitFile.fromFile(
    AsyncFile.fromBackend(
      '<blob>',
      backend,
      options: const FileOptions(mode: FileMode.read, create: false),
    ),
  );
}

