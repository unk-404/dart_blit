// Pure-Dart tests for the Web backend's metadata layer (no browser needed).
//
// These run on the VM (`dart test test/web/manifest_test.dart`) *and* as part
// of `dart test -p chrome test/web`, which makes layout/manifest regressions
// cheap to catch without spinning up a browser.
import 'dart:typed_data';

import 'package:blit/src/io/web/chunk_layout.dart';
import 'package:blit/src/io/web/crc32.dart';
import 'package:blit/src/io/web/manifest.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('chunk layout', () {
    test('chunk count and logical chunk lengths', () {
      expect(chunkCountFor(0, 256), 0);
      expect(chunkCountFor(1, 256), 1);
      expect(chunkCountFor(255, 256), 1);
      expect(chunkCountFor(256, 256), 1);
      expect(chunkCountFor(257, 256), 2);
      expect(chunkCountFor(512, 256), 2);

      expect(chunkLogicalLength(0, 256, 257), 256);
      expect(chunkLogicalLength(1, 256, 257), 1);
      expect(chunkLogicalLength(2, 256, 257), 0);

      // 32 GiB / 16 MiB = 2048 chunk files, the design target.
      expect(chunkCountFor(32 * 1024 * 1024 * 1024, kDefaultChunkSize), 2048);
      expect(chunkPathFor('a/b.bin', 2047), endsWith('/c/2047.bin'));
      expect(offsetInChunk(300, 256), 44);
      expect(chunkIndexFor(300, 256), 1);
      expect(chunkStartFor(2, 256), 512);
    });

    test('chunk size bounds are enforced', () {
      expect(() => chunkCountFor(1, kMinChunkSize - 1), throwsRangeError);
      expect(() => chunkCountFor(1, kMaxChunkSize + 1), throwsRangeError);
    });

    test('path normalization accepts relative POSIX paths', () {
      expect(normalizeLogicalPath('data/hello.bin'), 'data/hello.bin');
      expect(normalizeLogicalPath('one'), 'one');
      expect(
        normalizeLogicalPath('dir/sub dir/鏂囦欢鍚?bin'),
        'dir/sub dir/鏂囦欢鍚?bin',
      );
    });

    test('path normalization rejects unsafe paths', () {
      expect(() => normalizeLogicalPath(''), throwsArgumentError);
      expect(() => normalizeLogicalPath('/absolute'), throwsArgumentError);
      expect(() => normalizeLogicalPath('trailing/'), throwsArgumentError);
      expect(() => normalizeLogicalPath('a//b'), throwsArgumentError);
      expect(() => normalizeLogicalPath('a/./b'), throwsArgumentError);
      expect(() => normalizeLogicalPath('a/../b'), throwsArgumentError);
      expect(() => normalizeLogicalPath(r'a\b'), throwsArgumentError);
      expect(() => normalizeLogicalPath('a\u0000b'), throwsArgumentError);
      expect(
        () => normalizeLogicalPath('x'.padRight(5000, 'x')),
        throwsArgumentError,
      );
    });

    test('store directory names are deterministic and safe', () {
      final name = storeDirNameFor('data/hello world.bin');
      expect(name, matches(RegExp(r'^d_[0-9a-f]{8}_[A-Za-z0-9._-]+$')));
      expect(storeDirNameFor('data/hello world.bin'), name);
      expect(storeDirNameFor('data/hello-world.bin'), isNot(name));
      // No '..' can sneak into the derived directory name.
      expect(name.contains('..'), isFalse);
      expect(storePathFor('a/b'), '$kNamespaceDir/${storeDirNameFor('a/b')}');
      expect(manifestPathFor('a/b', 0), '${storePathFor('a/b')}/m.a');
      expect(manifestPathFor('a/b', 1), '${storePathFor('a/b')}/m.b');
      expect(chunkDirPathFor('a/b'), '${storePathFor('a/b')}/c');
      expect(() => manifestPathFor('a/b', 2), throwsRangeError);
    });
  });

  group('crc32', () {
    test('known vectors', () {
      expect(Crc32.compute(_bytes([])), 0x00000000);
      expect(Crc32.compute(_bytes('123456789'.codeUnits)), 0xCBF43926);
      expect(
        Crc32.compute(
          _bytes('The quick brown fox jumps over the lazy dog'.codeUnits),
        ),
        0x414FA339,
      );
    });

    test('incremental equals one-shot', () {
      final data = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
      final oneShot = Crc32.compute(data);
      var state = Crc32.initial;
      state = Crc32.update(state, data, 0, 137);
      state = Crc32.update(state, data, 137, 700);
      state = Crc32.update(state, data, 700);
      expect(Crc32.finish(state), oneShot);
    });

    test('stays an unsigned 32-bit value (web-safe)', () {
      final data = Uint8List.fromList(List.generate(64, (i) => 255 - i));
      final value = Crc32.compute(data);
      expect(value, greaterThanOrEqualTo(0));
      expect(value, lessThanOrEqualTo(0xFFFFFFFF));
    });
  });

  group('manifest', () {
    test('encode/decode roundtrip preserves all metadata', () {
      final manifest = WebManifestState(
        path: 'data/test.bin',
        chunkSize: 256,
        logicalLength: 257,
        generation: 7,
      );
      manifest.setMaterialized(0, true);
      manifest.setCrc(0, 0xDEADBEEF);
      manifest.setMaterialized(1, true);

      final decoded = WebManifestState.tryDecode(manifest.encode());
      expect(decoded, isNotNull);
      final state = decoded!;
      expect(state.path, 'data/test.bin');
      expect(state.chunkSize, 256);
      expect(state.logicalLength, 257);
      expect(state.generation, 7);
      expect(state.chunkCount, 2);
      expect(state.isMaterialized(0), isTrue);
      expect(state.isMaterialized(1), isTrue);
      expect(state.crcOf(0), 0xDEADBEEF);
      expect(state.crcOf(1), isNull);
      expect(state.materializedCount, 2);
    });

    test('hi/lo length encoding works past 4 GiB', () {
      const length = 5 * 0x100000000 + 123;
      final manifest = WebManifestState(
        path: 'huge.bin',
        chunkSize: kDefaultChunkSize,
        logicalLength: length,
      );
      final state = WebManifestState.tryDecode(manifest.encode())!;
      expect(state.logicalLength, length);
      expect(state.chunkCount, chunkCountFor(length, kDefaultChunkSize));
    });

    test('bitmap and crc arrays grow and shrink with logical length', () {
      final manifest = WebManifestState(path: 'grow.bin', chunkSize: 64);
      expect(manifest.chunkCount, 0);
      manifest.setLogicalLength(200); // 4 chunks
      expect(manifest.chunkCount, 4);
      manifest.setMaterialized(3, true);
      manifest.setCrc(3, 0x01020304);
      expect(manifest.crcOf(3), 0x01020304);

      final state = WebManifestState.tryDecode(manifest.encode())!;
      expect(state.isMaterialized(3), isTrue);
      expect(state.isMaterialized(0), isFalse);

      manifest.setLogicalLength(100); // 2 chunks: data for chunk 3 dropped
      expect(manifest.chunkCount, 2);
      expect(manifest.isMaterialized(3), isFalse);
      expect(manifest.crcOf(3), isNull);

      manifest.setMaterialized(1, false);
      manifest.setCrc(1, 99);
      manifest.setMaterialized(1, false);
      expect(manifest.isMaterialized(1), isFalse);
      expect(manifest.crcOf(1), isNull);
    });

    test('snapshot reports bitmap/crc/generation', () {
      final manifest = WebManifestState(
        path: 'snap.bin',
        chunkSize: 64,
        logicalLength: 64,
        generation: 3,
      );
      manifest.setMaterialized(0, true);
      manifest.setCrc(0, 0x11223344);
      final snapshot = manifest.snapshot(slot: 1);
      expect(snapshot.path, 'snap.bin');
      expect(snapshot.chunkSize, 64);
      expect(snapshot.logicalLength, 64);
      expect(snapshot.generation, 3);
      expect(snapshot.slot, 1);
      expect(snapshot.chunkCount, 1);
      expect(snapshot.materializedChunks, 1);
      expect(snapshot.isMaterialized(0), isTrue);
      expect(snapshot.chunkCrc(0), 0x11223344);
      expect(snapshot.chunkCrc(1), isNull);
      expect(snapshot.toString(), contains('snap.bin'));
    });

    test('corrupt trailer, magic and version are rejected', () {
      final manifest = WebManifestState(
        path: 'corrupt.bin',
        chunkSize: 64,
        logicalLength: 128,
      );
      manifest.setMaterialized(0, true);
      final encoded = manifest.encode();

      final trailer = Uint8List.fromList(encoded);
      trailer[trailer.length - 5] ^= 0xFF;
      expect(WebManifestState.tryDecode(trailer), isNull);

      final magic = Uint8List.fromList(encoded);
      magic[0] ^= 0xFF;
      expect(WebManifestState.tryDecode(magic), isNull);

      final version = Uint8List.fromList(encoded);
      version[4] = 99;
      expect(WebManifestState.tryDecode(version), isNull);

      expect(WebManifestState.tryDecode(Uint8List(0)), isNull);
      expect(
        WebManifestState.tryDecode(Uint8List.sublistView(encoded, 0, 20)),
        isNull,
        reason: 'truncated manifests must be rejected',
      );
    });

    test('rejects a chunkCount inconsistent with logicalLength', () {
      final manifest = WebManifestState(
        path: 'count.bin',
        chunkSize: 64,
        logicalLength: 64,
      );
      final encoded = manifest.encode();
      // Rewrite chunkCount (offset 24) to 2 and fix the trailer so only the
      // invariant check can reject it.
      final mutated = Uint8List.fromList(encoded);
      final view = ByteData.sublistView(mutated);
      view.setUint32(24, 2, Endian.little);
      final trailer = Crc32.compute(mutated, 0, mutated.length - 4);
      view.setUint32(mutated.length - 4, trailer, Endian.little);
      expect(WebManifestState.tryDecode(mutated), isNull);
    });

    test('rejects an invalid path but accepts unicode paths', () {
      final unicode = WebManifestState(
        path: '鐩�褰�/褎邪泄谢.bin',
        chunkSize: 64,
        logicalLength: 10,
      );
      expect(WebManifestState.tryDecode(unicode.encode())!.path, '鐩�褰�/褎邪泄谢.bin');

      // Same-length ASCII path so only the segments need to be rewritten.
      final ascii = WebManifestState(
        path: 'aaaa/bb.bin',
        chunkSize: 64,
        logicalLength: 10,
      );
      final mutated = Uint8List.fromList(ascii.encode());
      const replacement = '../aaaaaaaX'; // 11 bytes, contains a `..` segment
      mutated.setRange(48, 48 + replacement.length, replacement.codeUnits);
      final view = ByteData.sublistView(mutated);
      view.setUint32(
        mutated.length - 4,
        Crc32.compute(mutated, 0, mutated.length - 4),
        Endian.little,
      );
      expect(WebManifestState.tryDecode(mutated), isNull);
    });

    test('generation is a full 32-bit unsigned value', () {
      final manifest = WebManifestState(
        path: 'gen.bin',
        chunkSize: 64,
        generation: 0,
      );
      manifest.generation = 0xFFFFFFFF;
      final state = WebManifestState.tryDecode(manifest.encode())!;
      expect(state.generation, 0xFFFFFFFF);
      expect(() => manifest.generation = -1, throwsRangeError);
      expect(() => manifest.generation = 0x100000000, throwsRangeError);
    });
  });
}
