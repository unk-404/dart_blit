/// Async random-access file abstraction shared by native and web backends.
library;

import 'dart:typed_data';

/// A random-access byte file.
///
/// Offsets and lengths are plain `int`: on native they are 64-bit, on the web
/// they are exact up to 2^53 bytes (8 PiB), far beyond any real file.
abstract interface class BytesFile {
  /// Current logical length in bytes.
  Future<int> get length;

  /// Reads into `dst[start..end)` at [offset].  Returns bytes read (0 at EOF).
  Future<int> readAt(int offset, Uint8List dst, {int start = 0, int? end});

  /// Writes `src[start..end)` at [offset].  Returns bytes written.
  Future<int> writeAt(int offset, Uint8List src, {int start = 0, int? end});

  /// Appends to the end.
  Future<int> append(Uint8List src, {int start = 0, int? end});

  /// Changes the logical length.
  Future<void> truncate(int newLength);

  /// Flushes pending writes to the backing store.
  Future<void> flush();

  /// Closes the file; further operations throw [StateError].
  Future<void> close();

  /// Closes and deletes the underlying file.
  Future<void> delete();

  bool get isClosed;
}

/// Native-only synchronous companion.  Not available on the web.
abstract interface class SyncBytesFile implements BytesFile {
  int get lengthSync;

  int readAtSync(int offset, Uint8List dst, {int start = 0, int? end});

  int writeAtSync(int offset, Uint8List src, {int start = 0, int? end});

  int appendSync(Uint8List src, {int start = 0, int? end});

  void truncateSync(int newLength);

  void flushSync();

  void closeSync();
}
