/// Pure-Dart layout rules for the OPFS chunk store.
///
/// Nothing in this file touches `dart:js_interop`, `package:web` or `dart:io`,
/// so the layout can be unit-tested on the VM as well as in a browser.
///
/// ## Logical file -> OPFS entries
///
/// ```text
/// <OPFS root>/
///   bytes-opfs/                      namespace, one per origin
///     d_<hash30>_<readable>/         one directory per logical file
///       m.a                          manifest slot A
///       m.b                          manifest slot B
///       c/
///         0.bin                      chunk 0  (<= chunkSize bytes)
///         1.bin                      chunk 1
///         ...
/// ```
///
/// The directory name is derived from the logical path (30-bit hash + a
/// readable, sanitized prefix).  A 32 GiB file with 16 MiB chunks is
/// 2048 files in one directory; the file names stay short (`2047.bin`) so
/// `getFileHandle` lookups stay cheap.
library;

import 'dart:convert';

/// Default chunk size: 16 MiB.
///
/// Rationale (see `docs/research/web.md` §7.1): 32 GiB / 16 MiB = 2048 chunk
/// files, and peak memory in the worker is one chunk, independent of file size.
const int kDefaultChunkSize = 16 * 1024 * 1024;

/// Smallest chunk size the backend accepts (tiny values are useful in tests).
const int kMinChunkSize = 8;

/// Largest chunk size the backend accepts (1 GiB).
const int kMaxChunkSize = 1024 * 1024 * 1024;

/// Hard cap on the number of chunks per file.
///
/// 2^22 chunks * 16 MiB = 64 TiB, far above any realistic web file; the cap
/// keeps a corrupt manifest from allocating an absurd bitmap.
const int kMaxChunkCount = 1 << 22;

/// Largest exact integer web offset: 2^53-1 bytes (8 PiB).
///
/// `dart2js` integers are IEEE-754 doubles (exact up to 2^53), which is what
/// the `BytesFile` contract documents.
const int kMaxLogicalLength = 9007199254740991;

/// OPFS directory that owns every `bytes` logical file for this origin.
const String kNamespaceDir = 'bytes-opfs';

/// Number of chunks needed to hold [logicalLength] bytes.
int chunkCountFor(int logicalLength, int chunkSize) {
  if (logicalLength < 0) throw RangeError.value(logicalLength, 'logicalLength');
  if (chunkSize < kMinChunkSize || chunkSize > kMaxChunkSize) {
    throw RangeError.range(
      chunkSize,
      kMinChunkSize,
      kMaxChunkSize,
      'chunkSize',
    );
  }
  if (logicalLength == 0) return 0;
  return (logicalLength + chunkSize - 1) ~/ chunkSize;
}

/// Index of the chunk that contains byte [offset].
int chunkIndexFor(int offset, int chunkSize) {
  if (offset < 0) throw RangeError.value(offset, 'offset');
  return offset ~/ chunkSize;
}

/// Byte offset of [index] within its chunk file.
int offsetInChunk(int offset, int chunkSize) => offset % chunkSize;

/// Byte offset of the start of chunk [index] in the logical file.
int chunkStartFor(int index, int chunkSize) => index * chunkSize;

/// Logical length of chunk [index] for a file of [logicalLength] bytes.
///
/// This is the number of bytes the chunk contributes to the logical file
/// (`chunkSize` for every chunk except a partial trailing one).
int chunkLogicalLength(int index, int chunkSize, int logicalLength) {
  final start = chunkStartFor(index, chunkSize);
  if (start >= logicalLength) return 0;
  final remaining = logicalLength - start;
  return remaining < chunkSize ? remaining : chunkSize;
}

/// Validates and normalizes a logical path.
///
/// Paths are relative, POSIX-like (`dir/name.bin`): no leading/trailing slash,
/// no empty segments, and no `.`/`..` segments.  Everything else — including
/// spaces, unicode and non-ASCII — is allowed; the OPFS directory name is
/// derived by hashing, so unsafe characters never reach the file system.
String normalizeLogicalPath(String path) {
  if (path.isEmpty) {
    throw ArgumentError.value(path, 'path', 'must not be empty');
  }
  if (path.length > 4096) {
    throw ArgumentError.value(path, 'path', 'longer than 4096 characters');
  }
  if (path.contains('\u0000')) {
    throw ArgumentError.value(path, 'path', 'must not contain NUL');
  }
  if (path.contains('\\')) {
    throw ArgumentError.value(
      path,
      'path',
      'must use "/" as the segment separator',
    );
  }
  final segments = path.split('/');
  for (final segment in segments) {
    if (segment.isEmpty) {
      throw ArgumentError.value(path, 'path', 'contains an empty segment');
    }
    if (segment == '.' || segment == '..') {
      throw ArgumentError.value(path, 'path', 'contains a relative segment');
    }
  }
  return path;
}

/// 30-bit hash of [path], safe on every Dart runtime.
///
/// `dart2js` integers are doubles: a classic FNV-1a would exceed 2^53 when
/// multiplying, so this uses a small multiplicand and masks to 30 bits after
/// every step (the product stays well below 2^53, hence exact everywhere).
int _pathHash30(String path) {
  var hash = 0;
  final bytes = utf8.encode(path);
  for (var i = 0; i < bytes.length; i++) {
    hash = ((hash * 31) + bytes[i]) & 0x3FFFFFFF;
  }
  return hash;
}

/// Readable, filesystem-safe prefix for debug output (`stdout.log` etc.).
String _readablePrefix(String path) {
  final slash = path.lastIndexOf('/');
  final base = slash < 0 ? path : path.substring(slash + 1);
  final buffer = StringBuffer();
  for (var i = 0; i < base.length && buffer.length < 24; i++) {
    final unit = base.codeUnitAt(i);
    final safe =
        (unit >= 0x30 && unit <= 0x39) || // 0-9
        (unit >= 0x41 && unit <= 0x5A) || // A-Z
        (unit >= 0x61 && unit <= 0x7A) || // a-z
        unit == 0x2E || // .
        unit == 0x5F || // _
        unit == 0x2D; // -
    buffer.writeCharCode(safe ? unit : 0x5F);
  }
  final text = buffer.toString();
  if (text.isEmpty) return 'file';
  return text;
}

/// OPFS directory name for the logical file at [path].
String storeDirNameFor(String path) {
  final normalized = normalizeLogicalPath(path);
  final hash = _pathHash30(normalized).toRadixString(16).padLeft(8, '0');
  return 'd_${hash}_${_readablePrefix(normalized)}';
}

/// OPFS path of the directory that stores [path]'s manifest and chunks.
String storePathFor(String path) => '$kNamespaceDir/${storeDirNameFor(path)}';

/// OPFS path of manifest slot [slot] (0 -> `m.a`, 1 -> `m.b`).
String manifestPathFor(String path, int slot) {
  if (slot != 0 && slot != 1) throw RangeError.range(slot, 0, 1, 'slot');
  return '${storePathFor(path)}/m.${slot == 0 ? 'a' : 'b'}';
}

/// OPFS path of the chunk directory for [path].
String chunkDirPathFor(String path) => '${storePathFor(path)}/c';

/// OPFS path of chunk [index] for [path].
String chunkPathFor(String path, int index) {
  if (index < 0) throw RangeError.value(index, 'index');
  return '${chunkDirPathFor(path)}/$index.bin';
}
