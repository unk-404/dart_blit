/// The OPFS manifest: logical length, materialized-chunk bitmap, per-chunk
/// CRC-32 and a generation counter.
///
/// ## Why a manifest at all?
///
/// OPFS has no `truncate`-a-huge-file-that-stays-sparse story that is fast and
/// portable (writing near the end of a 32 GiB file zero-fills everything before
/// it — 12.6 s on Windows, see `docs/research/web.md` §2.3).  So a logical file
/// is a *set of chunks* plus this manifest, and `truncate` is a metadata edit.
///
/// ## Binary format (little endian, no 64-bit integer access needed)
///
/// ```text
/// offset size  field
///      0    4   magic  0x42 'B', 0x59 'Y', 0x57 'W', 0x31 '1'
///      4    4   version (1)
///      8    4   chunkSize
///     12    4   logicalLength lo   (low 32 bits)
///     16    4   logicalLength hi   (high 32 bits; value < 2^53)
///     20    4   generation
///     24    4   chunkCount
///     28    4   flags (bit 0: per-chunk CRC array is present)
///     32    4   pathByteLength
///     36    4   dataBitmapBytes
///     40    4   crcBitmapBytes
///     44    4   reserved (0)
///     48    n   logical path, UTF-8
///    ...    m   data bitmap      (bit i set => chunk i exists in OPFS)
///    ...    m   crc-valid bitmap (bit i set => crc[i] is meaningful)
///    ...  4*k  per-chunk CRC-32 (only meaningful where the crc bitmap is set)
///    ...    4   trailer CRC-32 of every preceding byte
/// ```
///
/// Lengths are split hi/lo on purpose: `ByteData.getUint64` throws
/// `UnsupportedError` on `dart2js`, while two `getUint32` calls work on every
/// target (`docs/research/web.md` §6.4).
///
/// Two slots (`m.a`, `m.b`) are written alternately and the reader picks the
/// highest generation whose trailer CRC validates.  That is the pure-OPFS
/// double-slot commit scheme recommended in `docs/research/web.md` §7.2 and it
/// avoids relying on `FileSystemHandle.move()`, which is Chromium-only.
// ignore_for_file: prefer_initializing_formals
library;

import 'dart:convert';
import 'dart:typed_data';

import 'chunk_layout.dart';
import 'crc32.dart';

/// Magic bytes at the start of every manifest (`'BYW1'`).
const int kManifestMagic = 0x31575942;

/// Current manifest version.
const int kManifestVersion = 1;

const int _headerSize = 48;
const int _maxManifestBytes = 64 * 1024 * 1024;

/// Flags bit 0: per-chunk CRC array present.
const int _flagChunkCrc = 0x1;

/// Mutable in-memory manifest state owned by [WebOpfsBytesFile].
///
/// Not exported from the package's public API; use [WebFileManifest] for a
/// read-only snapshot.
final class WebManifestState {
  /// Creates a manifest for [path] with the given [chunkSize].
  WebManifestState({
    required String path,
    required this.chunkSize,
    int logicalLength = 0,
    int generation = 0,
  }) : path = normalizeLogicalPath(path),
       _logicalLength = logicalLength,
       _generation = generation {
    if (chunkSize < kMinChunkSize || chunkSize > kMaxChunkSize) {
      throw RangeError.range(
        chunkSize,
        kMinChunkSize,
        kMaxChunkSize,
        'chunkSize',
      );
    }
    if (logicalLength < 0 || logicalLength > kMaxLogicalLength) {
      throw RangeError.range(
        logicalLength,
        0,
        kMaxLogicalLength,
        'logicalLength',
      );
    }
    _resize(chunkCountFor(logicalLength, chunkSize));
  }

  /// Logical path this manifest belongs to.
  final String path;

  /// Chunk size in bytes (fixed for the lifetime of the logical file).
  final int chunkSize;

  int _logicalLength;
  int _generation;
  Uint8List _dataBits = Uint8List(0);
  Uint8List _crcBits = Uint8List(0);
  Uint32List _crcs = Uint32List(0);

  /// Logical length in bytes.
  int get logicalLength => _logicalLength;

  /// Number of chunks that cover [logicalLength].
  int get chunkCount => chunkCountFor(_logicalLength, chunkSize);

  /// Commit generation; incremented on every persisted manifest.
  int get generation => _generation;

  set generation(int value) {
    if (value < 0 || value > 0xFFFFFFFF) {
      throw RangeError.range(value, 0, 0xFFFFFFFF, 'generation');
    }
    _generation = value;
  }

  /// Sets the logical length, growing/shrinking the per-chunk arrays.
  ///
  /// This is pure metadata: no OPFS file is touched.  Callers are responsible
  /// for removing/truncating chunk files that fall outside the new length.
  void setLogicalLength(int value) {
    if (value < 0 || value > kMaxLogicalLength) {
      throw RangeError.range(value, 0, kMaxLogicalLength, 'logicalLength');
    }
    _logicalLength = value;
    _resize(chunkCountFor(value, chunkSize));
  }

  /// Whether chunk [index] currently exists in OPFS.
  bool isMaterialized(int index) {
    if (index < 0 || index >= chunkCount) return false;
    return (_dataBits[index >> 3] & (1 << (index & 7))) != 0;
  }

  /// Marks chunk [index] as existing (`true`) or not (`false`).
  void setMaterialized(int index, bool value) {
    if (index < 0 || index >= chunkCount) return;
    final byte = index >> 3;
    final mask = 1 << (index & 7);
    if (value) {
      _dataBits[byte] |= mask;
    } else {
      _dataBits[byte] &= ~mask & 0xFF;
      setCrc(index, null);
    }
  }

  /// Number of chunks that exist in OPFS.
  int get materializedCount {
    var count = 0;
    for (var i = 0; i < chunkCount; i++) {
      if (isMaterialized(i)) count++;
    }
    return count;
  }

  /// Stored CRC-32 of chunk [index], or `null` when unknown.
  ///
  /// The CRC covers the chunk's *logical* bytes (see [chunkLogicalLength]) and
  /// is only recorded when those bytes were written strictly in order from the
  /// chunk start; random in-place overwrites invalidate it (a chunk-level CRC
  /// cannot be updated without re-reading the whole chunk).
  int? crcOf(int index) {
    if (index < 0 || index >= chunkCount) return null;
    if ((_crcBits[index >> 3] & (1 << (index & 7))) == 0) return null;
    return _crcs[index];
  }

  /// Stores (or clears, with `null`) the CRC-32 of chunk [index].
  void setCrc(int index, int? value) {
    if (index < 0 || index >= chunkCount) return;
    final byte = index >> 3;
    final mask = 1 << (index & 7);
    if (value == null) {
      _crcBits[byte] &= ~mask & 0xFF;
      _crcs[index] = 0;
    } else {
      if (value < 0 || value > 0xFFFFFFFF) {
        throw RangeError.range(value, 0, 0xFFFFFFFF, 'crc');
      }
      _crcBits[byte] |= mask;
      _crcs[index] = value;
    }
  }

  void _resize(int count) {
    final dataBytes = (count + 7) >> 3;
    final crcBytes = dataBytes;
    if (count == 0) {
      _dataBits = Uint8List(0);
      _crcBits = Uint8List(0);
      _crcs = Uint32List(0);
      return;
    }
    final newData = Uint8List(dataBytes);
    final newCrcBits = Uint8List(crcBytes);
    final newCrcs = Uint32List(count);
    final oldCount = _crcs.length;
    if (oldCount > 0) {
      final copyData = oldCount < count ? _dataBits.length : dataBytes;
      newData.setRange(0, copyData, _dataBits);
      newCrcBits.setRange(0, copyData, _crcBits);
      final copyCrcs = oldCount < count ? oldCount : count;
      newCrcs.setRange(0, copyCrcs, _crcs);
    }
    _dataBits = newData;
    _crcBits = newCrcBits;
    _crcs = newCrcs;
  }

  /// Serializes this manifest (including the trailer CRC-32).
  Uint8List encode() {
    final pathBytes = utf8.encode(path);
    final dataBytes = _dataBits.length;
    final crcBytes = _crcBits.length;
    final total =
        _headerSize +
        pathBytes.length +
        dataBytes +
        crcBytes +
        4 * _crcs.length +
        4;
    if (total > _maxManifestBytes) {
      throw StateError('manifest too large: $total bytes');
    }
    final out = Uint8List(total);
    final data = ByteData.sublistView(out);
    final logicalLo = _logicalLength % 0x100000000;
    final logicalHi = _logicalLength ~/ 0x100000000;
    data.setUint32(0, kManifestMagic, Endian.little);
    data.setUint32(4, kManifestVersion, Endian.little);
    data.setUint32(8, chunkSize, Endian.little);
    data.setUint32(12, logicalLo, Endian.little);
    data.setUint32(16, logicalHi, Endian.little);
    data.setUint32(20, _generation, Endian.little);
    data.setUint32(24, chunkCount, Endian.little);
    data.setUint32(28, _flagChunkCrc, Endian.little);
    data.setUint32(32, pathBytes.length, Endian.little);
    data.setUint32(36, dataBytes, Endian.little);
    data.setUint32(40, crcBytes, Endian.little);
    data.setUint32(44, 0, Endian.little);
    var offset = _headerSize;
    out.setRange(offset, offset + pathBytes.length, pathBytes);
    offset += pathBytes.length;
    out.setRange(offset, offset + dataBytes, _dataBits);
    offset += dataBytes;
    out.setRange(offset, offset + crcBytes, _crcBits);
    offset += crcBytes;
    for (var i = 0; i < _crcs.length; i++) {
      data.setUint32(offset, _crcs[i], Endian.little);
      offset += 4;
    }
    final trailer = Crc32.compute(out, 0, total - 4);
    data.setUint32(total - 4, trailer, Endian.little);
    return out;
  }

  /// Decodes a manifest, returning `null` when the bytes are not a valid
  /// manifest (bad magic, unsupported version, wrong size, CRC mismatch...).
  static WebManifestState? tryDecode(Uint8List bytes) {
    if (bytes.length < _headerSize + 4) return null;
    if (bytes.length > _maxManifestBytes) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != kManifestMagic) return null;
    if (data.getUint32(4, Endian.little) != kManifestVersion) return null;
    final chunkSize = data.getUint32(8, Endian.little);
    if (chunkSize < kMinChunkSize || chunkSize > kMaxChunkSize) return null;
    final lengthLo = data.getUint32(12, Endian.little);
    final lengthHi = data.getUint32(16, Endian.little);
    final logicalLength = lengthHi * 0x100000000 + lengthLo;
    if (logicalLength > kMaxLogicalLength) return null;
    final generation = data.getUint32(20, Endian.little);
    final chunkCount = data.getUint32(24, Endian.little);
    if (chunkCount > kMaxChunkCount) return null;
    if (chunkCount != chunkCountFor(logicalLength, chunkSize)) return null;
    final flags = data.getUint32(28, Endian.little);
    if ((flags & _flagChunkCrc) == 0) return null;
    final pathBytes = data.getUint32(32, Endian.little);
    final dataBytes = data.getUint32(36, Endian.little);
    final crcBytes = data.getUint32(40, Endian.little);
    final expectedDataBytes = (chunkCount + 7) >> 3;
    if (dataBytes != expectedDataBytes || crcBytes != expectedDataBytes) {
      return null;
    }
    final expectedTotal =
        _headerSize + pathBytes + dataBytes + crcBytes + 4 * chunkCount + 4;
    if (expectedTotal != bytes.length) return null;
    final trailerOffset = expectedTotal - 4;
    if (data.getUint32(trailerOffset, Endian.little) !=
        Crc32.compute(bytes, 0, trailerOffset)) {
      return null;
    }
    String path;
    try {
      path = utf8.decode(bytes.sublist(_headerSize, _headerSize + pathBytes));
    } on FormatException {
      return null;
    }
    if (path.isEmpty) return null;
    final WebManifestState state;
    try {
      state = WebManifestState(
        path: path,
        chunkSize: chunkSize,
        logicalLength: logicalLength,
        generation: generation,
      );
    } on ArgumentError {
      // A corrupt path (empty segment, `..`, NUL...) is not a valid manifest.
      return null;
    }
    var offset = _headerSize + pathBytes;
    state._dataBits.setRange(0, dataBytes, bytes, offset);
    offset += dataBytes;
    state._crcBits.setRange(0, crcBytes, bytes, offset);
    offset += crcBytes;
    for (var i = 0; i < chunkCount; i++) {
      state._crcs[i] = data.getUint32(offset, Endian.little);
      offset += 4;
    }
    return state;
  }

  /// Immutable snapshot for diagnostics and tests.
  WebFileManifest snapshot({int slot = 0}) => WebFileManifest._(
    path: path,
    chunkSize: chunkSize,
    logicalLength: _logicalLength,
    generation: _generation,
    slot: slot,
    dataBitmap: Uint8List.fromList(_dataBits),
    crcBitmap: Uint8List.fromList(_crcBits),
    crcs: Uint32List.fromList(_crcs),
  );
}

/// Immutable, read-only view of a web file's manifest.
final class WebFileManifest {
  WebFileManifest._({
    required this.path,
    required this.chunkSize,
    required this.logicalLength,
    required this.generation,
    required this.slot,
    required Uint8List dataBitmap,
    required Uint8List crcBitmap,
    required Uint32List crcs,
  }) : _dataBitmap = dataBitmap,
       _crcBitmap = crcBitmap,
       _crcs = crcs;

  /// Logical path.
  final String path;

  /// Chunk size in bytes.
  final int chunkSize;

  /// Logical length in bytes.
  final int logicalLength;

  /// Commit generation this snapshot was loaded from/written as.
  final int generation;

  /// Manifest slot this snapshot came from (`0` -> `m.a`, `1` -> `m.b`,
  /// `-1` -> the file was created by the current instance and no slot was
  /// read).
  final int slot;

  final Uint8List _dataBitmap;
  final Uint8List _crcBitmap;
  final Uint32List _crcs;

  /// Number of chunks covering [logicalLength].
  int get chunkCount => chunkCountFor(logicalLength, chunkSize);

  /// Number of chunks currently materialized in OPFS.
  int get materializedChunks {
    var count = 0;
    for (var i = 0; i < chunkCount; i++) {
      if (isMaterialized(i)) count++;
    }
    return count;
  }

  /// Whether chunk [index] exists.
  bool isMaterialized(int index) {
    if (index < 0 || index >= chunkCount) return false;
    return (_dataBitmap[index >> 3] & (1 << (index & 7))) != 0;
  }

  /// Stored CRC-32 of chunk [index], or `null` when unknown.
  int? chunkCrc(int index) {
    if (index < 0 || index >= chunkCount) return null;
    if ((_crcBitmap[index >> 3] & (1 << (index & 7))) == 0) return null;
    return _crcs[index];
  }

  @override
  String toString() =>
      'WebFileManifest(path: $path, chunkSize: $chunkSize, '
      'logicalLength: $logicalLength, chunkCount: $chunkCount, '
      'materialized: $materializedChunks, generation: $generation, '
      'slot: ${slot < 0 ? 'new' : (slot == 0 ? 'm.a' : 'm.b')})';
}
