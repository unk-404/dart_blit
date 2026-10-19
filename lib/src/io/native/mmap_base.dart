/// Native mmap interfaces shared by the Windows and POSIX backends.
///
/// The native engine is synchronous: `readAt`/`writeAt`/`map` block the calling
/// isolate.  Run them in a worker isolate for UI-facing code.  Offsets and
/// lengths are 64-bit `int`s on native.
library;

import 'dart:ffi';
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

  /// Whether large pages are active for this file's direct-I/O scratch buffer.
  bool get usesLargePages => false;

  /// Creates a reserved placeholder window that can atomically receive mapped
  /// views via `MapViewOfFile3(MEM_REPLACE_PLACEHOLDER)`.
  ///
  /// Windows-only today; other platforms throw [UnsupportedError].
  MmapPlaceholder createPlaceholder(int length) =>
      throw UnsupportedError('placeholders are not supported on this platform');

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

  /// Reads into caller-owned native memory, bypassing the typed-data copy.
  ///
  /// This is the hot-path variant for framework/buffer-pool callers.  The
  /// destination must stay valid for the duration of the call and, for direct
  /// I/O, be 4 KiB aligned.  The transparent mmap cache is bypassed.
  int readAtPointer(int offset, Pointer<Uint8> dst, int length) =>
      throw UnsupportedError('readAtPointer is not supported on this backend');

  /// Writes from caller-owned native memory, bypassing the typed-data copy.
  ///
  /// See [readAtPointer] for alignment and lifetime requirements.
  int writeAtPointer(int offset, Pointer<Uint8> src, int length) =>
      throw UnsupportedError('writeAtPointer is not supported on this backend');

  /// Changes logical length.  [sparse] marks the file sparse on Windows before
  /// extending, so that later far-offset writes do not zero-fill the gap.
  void truncate(int newLength, {bool sparse = true});

  /// Flushes file data to the backing store.
  void flush();

  /// Overwrites `[offset, offset + length)` with zeros.
  void zeroize(int offset, int length);

  /// Deallocates `[offset, offset + length)` without writing zeros.
  ///
  /// Windows: `FSCTL_SET_ZERO_DATA`; Linux/Android: `fallocate(PUNCH_HOLE)`.
  /// Unsupported platforms throw [UnsupportedError]; callers can fall back to
  /// [zeroize].
  void punchHole(int offset, int length) =>
      throw UnsupportedError('punchHole is not supported on this platform');

  /// Clones extents from [source] into this file.
  ///
  /// Windows: `FSCTL_DUPLICATE_EXTENTS_TO_FILE` (same volume, aligned ranges).
  /// The default throws [UnsupportedError]; callers can fall back to
  /// `readAt`/`writeAt`.
  void cloneRangeFrom(
    MmapFile source, {
    int sourceOffset = 0,
    int destOffset = 0,
    int? length,
  }) => throw UnsupportedError(
    'cloneRangeFrom is not supported on this platform',
  );

  /// Preallocates physical space for at least [length] bytes.
  ///
  /// macOS uses `F_PREALLOCATE`; the default extends the file with [truncate],
  /// which may zero-fill.
  void preallocate(int length) => truncate(length);

  /// Kernel read-ahead hint for `[offset, offset + length)`.
  ///
  /// macOS uses `F_RDADVISE`; other platforms may no-op.
  void adviseRead({int offset = 0, int? length}) {}

  /// Closes all windows, the mapping and the file handle; idempotent.
  void close();

  Future<int> get lengthAsync async => length;

  Future<MappedRegion> mapAsync({
    int offset = 0,
    int? length,
    bool writable = true,
  }) async => map(offset: offset, length: length, writable: writable);

  Future<int> readAtAsync(
    int offset,
    Uint8List dst, {
    int start = 0,
    int? end,
  }) async => readAt(offset, dst, start: start, end: end);

  Future<int> writeAtAsync(
    int offset,
    Uint8List src, {
    int start = 0,
    int? end,
  }) async => writeAt(offset, src, start: start, end: end);

  Future<void> truncateAsync(int newLength, {bool sparse = true}) async =>
      truncate(newLength, sparse: sparse);

  Future<void> flushAsync() async => flush();

  Future<void> zeroizeAsync(int offset, int length) async =>
      zeroize(offset, length);

  Future<void> closeAsync() async => close();
}

/// A reserved address range that can be filled/replaced with mapped windows.
abstract interface class MmapPlaceholder {
  int get length;
  int get baseAddress;

  /// Maps [file]'s `[offset, offset + length)` into this placeholder.
  MappedRegion map(MmapFile file, {int offset = 0, bool writable = true});

  /// Releases the placeholder and its current view; idempotent.
  void close();
}
