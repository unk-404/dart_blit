/// Pure-Dart layout/key/meta rules for the IndexedDB backend.
///
/// The IndexedDB store is shared by every `blit` file in the origin:
///
/// ```text
/// database: blit-bytes
/// object store: records
///   "<file-key>!m"                 metadata (length + chunk size)
///   "<file-key>!c0000000000000000" chunk 0
///   "<file-key>!c0000000000000001" chunk 1
/// ```
///
/// `<file-key>` is the URL-safe base64 of the logical path, so two paths never
/// alias and no path character has to be escaped. The key suffix is a
/// zero-padded hex chunk index, which keeps IndexedDB key order numeric.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Default IndexedDB chunk size (64 KiB).
///
/// 16 KiB reduces read-modify-write cost for 4 KiB random writes; 64 KiB keeps
/// an 8 MiB sequential row to 128 records and a 1 GiB file to 16384 records.
const int kIdbDefaultChunkSize = 64 * 1024;

/// Smallest accepted chunk size (tiny values are useful in tests).
const int kIdbMinChunkSize = 8;

/// Largest accepted chunk size.
const int kIdbMaxChunkSize = 8 * 1024 * 1024;

/// Default database name; shared by all logical files.
const String kIdbDatabaseName = 'blit-bytes';

/// Default object store; shared by all logical files.
const String kIdbStoreName = 'records';

const int _metaMagic = 0x424c4954; // 'BLIT'
const int _metaVersion = 1;
const int _metaBytes = 20;

/// Stable key prefix for [path].
String idbFileKey(String path) =>
    base64Url.encode(utf8.encode(path)).replaceAll('=', '');

/// Metadata record key for [path].
String idbMetaKey(String path) => '${idbFileKey(path)}!m';

/// Chunk record key for [path], [index].
String idbChunkKey(String path, int index) =>
    '${idbFileKey(path)}!c${index.toRadixString(16).padLeft(16, '0')}';

/// Encodes logical length and chunk size into a 20-byte metadata record.
Uint8List encodeIdbMeta(int logicalLength, int chunkSize) {
  if (logicalLength < 0) throw RangeError.value(logicalLength, 'length');
  final data = ByteData(_metaBytes);
  data.setUint32(0, _metaMagic, Endian.little);
  data.setUint32(4, _metaVersion, Endian.little);
  data.setUint32(8, chunkSize, Endian.little);
  data.setUint32(12, logicalLength & 0xFFFFFFFF, Endian.little);
  data.setUint32(16, logicalLength ~/ 0x100000000, Endian.little);
  return data.buffer.asUint8List();
}

/// Decoded metadata.
typedef IdbMeta = ({int logicalLength, int chunkSize});

/// Decodes a metadata record, returning `null` on bad magic/version/size.
IdbMeta? decodeIdbMeta(Uint8List bytes) {
  if (bytes.length < _metaBytes) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != _metaMagic) return null;
  if (data.getUint32(4, Endian.little) != _metaVersion) return null;
  final chunkSize = data.getUint32(8, Endian.little);
  if (chunkSize < kIdbMinChunkSize || chunkSize > kIdbMaxChunkSize) {
    return null;
  }
  final lo = data.getUint32(12, Endian.little);
  final hi = data.getUint32(16, Endian.little);
  return (logicalLength: hi * 0x100000000 + lo, chunkSize: chunkSize);
}
