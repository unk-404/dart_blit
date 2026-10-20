// Pure-Dart tests for IndexedDB key/meta rules (no browser needed).
import 'dart:typed_data';

import 'package:blit/src/io/web/idb_layout.dart';
import 'package:test/test.dart';

void main() {
  test('file keys are unique and stable', () {
    expect(idbFileKey('a/b.bin'), isNot(idbFileKey('a/b.biN')));
    expect(idbFileKey('a/b.bin'), idbFileKey('a/b.bin'));
    expect(idbMetaKey('a/b.bin'), endsWith('!m'));
    expect(idbChunkKey('a/b.bin', 0), contains('!c0000000000000000'));
    expect(idbChunkKey('a/b.bin', 15), contains('!c000000000000000f'));
  });

  test('metadata roundtrip preserves length and chunk size', () {
    final bytes = encodeIdbMeta(3 * 1024 * 1024 * 1024 + 17, 65536);
    final meta = decodeIdbMeta(bytes)!;
    expect(meta.logicalLength, 3 * 1024 * 1024 * 1024 + 17);
    expect(meta.chunkSize, 65536);
    expect(bytes.length, 20);
  });

  test('metadata rejects corrupt/unsupported records', () {
    expect(decodeIdbMeta(Uint8List(19)), isNull);
    final good = encodeIdbMeta(42, 65536);
    good[0] = 0;
    expect(decodeIdbMeta(good), isNull);
    final badChunk = encodeIdbMeta(42, 1);
    expect(decodeIdbMeta(badChunk), isNull);
  });
}
