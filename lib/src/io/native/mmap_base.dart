/// Native mmap interfaces shared by the Windows and POSIX backends.
///
/// The native engine is synchronous: `readAt`/`writeAt`/`map` block the calling
/// isolate.  Run them in a worker isolate for UI-facing code.  Offsets and
/// lengths are 64-bit `int`s on native.
library;

import 'dart:typed_data';

/// A zero-copy mapped window over a file.
abstract interface class MappedRegion {
  /// File offset of this window (not necessarily page-aligned; the backend
  /// hides the alignment delta).
  int get offset;

  /// Length of this window in bytes.
  int get length;

  /// Zero-copy mutable view over the window.
  ///
  /// The view is valid until [close] (or the owning file is closed).  Do not
  /// keep it after close: that is a use-after-unmap.
  Uint8List get bytes;

  bool get isClosed;

  /// Whether this mapping was created writable (`map(writable: true)`).
  bool get isWritable;

  /// Flushes dirty pages of this window to the OS.
  ///
  /// No-op for a read-only mapping.
  void flush();

  /// Overwrites this window with zeros using a native memset.
  void zeroize();

  /// Hints the OS to page in `[offset, offset + length)` ahead of use.
  ///
  /// Windows: `PrefetchVirtualMemory`; POSIX: `madvise(MADV_WILLNEED)`.
  /// Useful for scan/streaming windows; a no-op for an empty range.
  void prefetch({int offset = 0, int? length});

  /// Hints the OS to drop `[offset, offset + length)` from the working set.
  ///
  /// POSIX: `madvise(MADV_DONTNEED)`.  Windows currently validates the range
  /// but is a no-op for file-backed mappings, because `DiscardVirtualMemory`
  /// returns `ERROR_USER_MAPPED_FILE` for them.
  void discard({int offset = 0, int? length});

  /// Unmaps this window; idempotent.
  void close();
}

/// A native file with random access and mmap windows.
abstract class MmapFile {
  String get path;
  bool get readOnly;
  bool get isClosed;

  /// Current logical file length in bytes.
  int get length;

  /// Maps `[offset, offset + length)`.
  ///
  /// [length] defaults to `length - offset`.  The offset need not be
  /// page-aligned; the backend aligns it internally.  The file must be large
  /// enough; truncate first to extend.
  MappedRegion map({int offset = 0, int? length, bool writable = true});

  /// Reads into `dst[start..end)` at [offset]; returns bytes read.
  int readAt(int offset, Uint8List dst, {int start = 0, int? end});

  /// Writes `src[start..end)` at [offset]; returns bytes written.
  int writeAt(int offset, Uint8List src, {int start = 0, int? end});

  /// Changes logical length.  [sparse] marks the file sparse on Windows before
  /// extending, so that later far-offset writes do not zero-fill the gap.
  void truncate(int newLength, {bool sparse = true});

  /// Flushes file data to the backing store.
  void flush();

  /// Overwrites `[offset, offset + length)` with zeros.
  void zeroize(int offset, int length);

  /// Closes all windows, the mapping and the file handle; idempotent.
  void close();

  Future<int> get lengthAsync async => length;

  Future<MappedRegion> mapAsync(
          {int offset = 0, int? length, bool writable = true}) async =>
      map(offset: offset, length: length, writable: writable);

  Future<int> readAtAsync(int offset, Uint8List dst,
          {int start = 0, int? end}) async =>
      readAt(offset, dst, start: start, end: end);

  Future<int> writeAtAsync(int offset, Uint8List src,
          {int start = 0, int? end}) async =>
      writeAt(offset, src, start: start, end: end);

  Future<void> truncateAsync(int newLength, {bool sparse = true}) async =>
      truncate(newLength, sparse: sparse);

  Future<void> flushAsync() async => flush();

  Future<void> zeroizeAsync(int offset, int length) async =>
      zeroize(offset, length);

  Future<void> closeAsync() async => close();
}
