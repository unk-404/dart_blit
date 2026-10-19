// End-to-end browser tests for the Web (OPFS) backend.
//
// Run with:  dart test -p chrome test/web
//
// Requires Chrome 102+ (dedicated-worker `createSyncAccessHandle`).  Every test
// uses a unique logical path and removes it in teardown, so repeated runs in a
// persistent browser profile do not interfere.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:blit/bytes.dart';
import 'package:blit/src/io/web/web.dart';
import 'package:test/test.dart';

final _runId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
var _pathCounter = 0;

String _newPath(String label) => 'test-$_runId/$label-${_pathCounter++}.bin';

Uint8List _pattern(int length, {int seed = 0}) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (seed + i * 31) & 0xFF;
  }
  return out;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Opens [path], registering close+delete teardowns.
Future<WebOpfsBytesFile> _openTyped(
  String path, {
  bool create = true,
  bool readOnly = false,
  int chunkSize = 64,
}) async {
  final file = await openOpfsBytesFileTyped(
    path,
    create: create,
    readOnly: readOnly,
    chunkSize: chunkSize,
  );
  addTearDown(() async {
    if (!file.isClosed) await file.close();
    await deleteOpfsFile(path);
  });
  return file;
}

void main() {
  test('capabilities: OPFS + worker sync access handle', () async {
    final caps = await probeWebStorageCapabilities();
    expect(caps.opfs, isTrue, reason: 'OPFS is required for these tests');
    expect(caps.workerError, isNull);
    expect(caps.syncAccessHandleInWorker, isTrue);
    expect(caps.canUseChunkBackend, isTrue);
    // The sync handle is dedicated-worker-only in every engine as of 2026.
    expect(
      caps.syncAccessHandleOnCurrentThread,
      isFalse,
      reason:
          'main-thread createSyncAccessHandle must not exist; '
          'capability probing must not rely on calling it',
    );
    expect(caps.quotaBytes, isNotNull);
    expect(caps.quotaBytes, greaterThan(0));
    // ignore: avoid_print
    print('WebStorageCapabilities: $caps');
  });

  test('create / write / read / append / close / reopen', () async {
    final path = _newPath('basic');
    final file = await _openTyped(path);
    expect(await file.length, 0);

    final head = _pattern(40, seed: 1);
    expect(await file.writeAt(0, head), 40);
    expect(await file.length, 40);

    final whole = Uint8List(40);
    expect(await file.readAt(0, whole), 40);
    expect(_sameBytes(whole, head), isTrue);

    final tail = _pattern(20, seed: 77);
    expect(await file.append(tail), 20);
    expect(await file.length, 60);

    final readTail = Uint8List(20);
    expect(await file.readAt(40, readTail), 20);
    expect(_sameBytes(readTail, tail), isTrue);

    // readAt honours dst[start..end).
    final window = Uint8List(10);
    expect(await file.readAt(5, window, start: 2, end: 7), 5);
    expect(window[2], head[5]);
    expect(window[6], head[9]);
    expect(window[0], 0);
    expect(window[9], 0);

    // Reading at/after EOF returns 0 and leaves the buffer alone.
    final atEof = Uint8List(4);
    expect(await file.readAt(100, atEof), 0);
    await file.flush();
    await file.close();
    expect(file.isClosed, isTrue);
    await expectLater(file.length, throwsStateError);

    // Reopen must not truncate: data + length survive.
    final reopened = await _openTyped(path, create: false);
    expect(await reopened.length, 60);
    final all = Uint8List(60);
    expect(await reopened.readAt(0, all), 60);
    expect(_sameBytes(all.sublist(0, 40), head), isTrue);
    expect(_sameBytes(all.sublist(40), tail), isTrue);
    await reopened.close();
  });

  test('cross-chunk write and read', () async {
    final path = _newPath('cross');
    const chunkSize = 64;
    final file = await _openTyped(path, chunkSize: chunkSize);
    final data = _pattern(300, seed: 13);
    expect(await file.writeAt(0, data), 300);
    expect(await file.length, 300);

    final back = Uint8List(300);
    expect(await file.readAt(0, back), 300);
    expect(_sameBytes(back, data), isTrue);

    // Window straddling a chunk boundary (64).
    final straddle = Uint8List(20);
    expect(await file.readAt(60, straddle), 20);
    expect(_sameBytes(straddle, data.sublist(60, 80)), isTrue);

    // Window straddling the last partial chunk boundary (256..300).
    final endStraddle = Uint8List(50);
    expect(await file.readAt(250, endStraddle), 50);
    expect(_sameBytes(endStraddle, data.sublist(250, 300)), isTrue);

    // Exactly at EOF: 0 bytes.
    final empty = Uint8List(8);
    expect(await file.readAt(300, empty), 0);

    final manifest = file.manifest;
    expect(manifest.chunkCount, 5); // ceil(300 / 64)
    expect(manifest.materializedChunks, 5);
    expect(manifest.logicalLength, 300);

    // In-place overwrite inside the middle of a chunk.
    final patch = Uint8List(20)..fillRange(0, 20, 0xEE);
    expect(await file.writeAt(70, patch), 20);
    final patched = Uint8List(20);
    expect(await file.readAt(70, patched), 20);
    expect(patched.every((b) => b == 0xEE), isTrue);
    await file.close();
  });

  test('two logical files interleaved', () async {
    final pathA = _newPath('interleave-a');
    final pathB = _newPath('interleave-b');
    final a = await _openTyped(pathA, chunkSize: 32);
    final b = await _openTyped(pathB, chunkSize: 32);

    final a0 = _pattern(40, seed: 10);
    final b0 = _pattern(70, seed: 200);
    expect(await a.writeAt(0, a0), 40);
    expect(await b.writeAt(0, b0), 70);
    expect(await a.append(Uint8List.fromList([1, 2, 3])), 3);
    expect(await b.append(Uint8List.fromList([9])), 1);
    expect(await a.length, 43);
    expect(await b.length, 71);

    final aBack = Uint8List(43);
    final bBack = Uint8List(71);
    expect(await a.readAt(0, aBack), 43);
    expect(await b.readAt(0, bBack), 71);
    expect(_sameBytes(aBack.sublist(0, 40), a0), isTrue);
    expect(aBack.sublist(40), [1, 2, 3]);
    expect(_sameBytes(bBack.sublist(0, 70), b0), isTrue);
    expect(bBack[70], 9);

    await a.close();
    await b.close();
    // Both stores are independent.
    expect(storePathFor(pathA), isNot(storePathFor(pathB)));
  });

  test('truncate shrinks chunks, re-extends sparse', () async {
    final path = _newPath('truncate');
    const chunkSize = 64;
    final file = await _openTyped(path, chunkSize: chunkSize);
    final data = _pattern(200, seed: 5);
    expect(await file.writeAt(0, data), 200);
    expect(file.manifest.materializedChunks, 4);

    await file.truncate(100);
    expect(await file.length, 100);
    expect(file.manifest.chunkCount, 2);
    expect(file.manifest.materializedChunks, 2);
    // Trailing partial chunk was physically truncated to 100 - 64 = 36 bytes.
    expect(await file.debugPhysicalChunkSize(1), 36);
    // Removed chunks are gone from OPFS.
    final chunkEntries = await listOpfsDirectory(chunkDirPathFor(path));
    expect(chunkEntries.toSet(), {'0.bin', '1.bin'});

    final kept = Uint8List(100);
    expect(await file.readAt(0, kept), 100);
    expect(_sameBytes(kept, data.sublist(0, 100)), isTrue);

    // Grow without writing: sparse, no new chunk files, zeros read back.
    await file.truncate(150);
    expect(await file.length, 150);
    expect(file.manifest.materializedChunks, 2);
    expect((await listOpfsDirectory(chunkDirPathFor(path))).length, 2);
    final grown = Uint8List(50);
    expect(await file.readAt(100, grown), 50);
    expect(grown.every((b) => b == 0), isTrue);

    // Writing in the grown region zero-fills the gap before the write.
    expect(await file.writeAt(120, Uint8List.fromList([1, 2, 3])), 3);
    final gap = Uint8List(20);
    expect(await file.readAt(100, gap), 20);
    expect(gap.every((b) => b == 0), isTrue);
    final written = Uint8List(3);
    expect(await file.readAt(120, written), 3);
    expect(written, [1, 2, 3]);
    // Old bytes beyond the write are still zeros (truncate dropped them).
    final after = Uint8List(27);
    expect(await file.readAt(123, after), 27);
    expect(after.every((b) => b == 0), isTrue);

    // Shrinking to zero drops every chunk but keeps the file open.
    await file.truncate(0);
    expect(await file.length, 0);
    expect(file.manifest.materializedChunks, 0);
    expect(await file.readAt(0, Uint8List(1)), 0);
    await file.close();
  });

  test('sparse write past EOF zero-fills the gap', () async {
    final path = _newPath('sparse');
    final file = await _openTyped(path, chunkSize: 64);
    expect(await file.writeAt(100, Uint8List.fromList([0xAA, 0xBB])), 2);
    expect(await file.length, 102);
    // Chunk 0 was never written, so it is not materialized.
    expect(file.manifest.isMaterialized(0), isFalse);
    expect(file.manifest.isMaterialized(1), isTrue);

    final head = Uint8List(100);
    expect(await file.readAt(0, head), 100);
    expect(head.every((b) => b == 0), isTrue);
    final tail = Uint8List(2);
    expect(await file.readAt(100, tail), 2);
    expect(tail, [0xAA, 0xBB]);
    await file.close();
  });

  test('read-only mode', () async {
    final path = _newPath('readonly');
    final writer = await _openTyped(path, chunkSize: 64);
    final data = _pattern(30, seed: 3);
    await writer.writeAt(0, data);
    await writer.close();

    final reader = await _openTyped(path, create: false, readOnly: true);
    expect(await reader.length, 30);
    final back = Uint8List(30);
    expect(await reader.readAt(0, back), 30);
    expect(_sameBytes(back, data), isTrue);
    await expectLater(reader.writeAt(0, Uint8List(1)), throwsStateError);
    await expectLater(reader.append(Uint8List(1)), throwsStateError);
    await expectLater(reader.truncate(0), throwsStateError);
    await reader.close();
  });

  test('create:false on a missing file reports NotFoundError', () async {
    final path = _newPath('missing');
    await expectLater(
      openOpfsBytesFile(path, create: false),
      throwsA(
        isA<WebFileSystemException>()
            .having((e) => e.isNotFound, 'isNotFound', isTrue)
            .having((e) => e.path, 'path', path),
      ),
    );
    // readOnly also implies create:false (dart:io FileMode.read semantics).
    await expectLater(
      openOpfsBytesFile(path, readOnly: true),
      throwsA(
        isA<WebFileSystemException>().having(
          (e) => e.isNotFound,
          'isNotFound',
          isTrue,
        ),
      ),
    );
  });

  test('delete removes manifest and chunk files', () async {
    final path = _newPath('delete');
    final file = await _openTyped(path, chunkSize: 64);
    expect(await file.writeAt(0, _pattern(128)), 128);
    await file.flush();
    final store = storePathFor(path);
    expect(
      (await listOpfsDirectory(store)).toSet(),
      containsAll(<String>{'m.a', 'm.b', 'c'}),
    );
    expect((await listOpfsDirectory(chunkDirPathFor(path))).toSet(), {
      '0.bin',
      '1.bin',
    });

    await file.delete();
    expect(file.isClosed, isTrue);
    await expectLater(
      listOpfsDirectory(store),
      throwsA(
        isA<WebFileSystemException>().having(
          (e) => e.isNotFound,
          'isNotFound',
          isTrue,
        ),
      ),
    );
    await expectLater(
      openOpfsBytesFile(path, create: false),
      throwsA(
        isA<WebFileSystemException>().having(
          (e) => e.isNotFound,
          'isNotFound',
          isTrue,
        ),
      ),
    );
  });

  test('manifest: double slot generation, bitmap and per-chunk CRC', () async {
    final path = _newPath('manifest');
    const chunkSize = 64;
    final file = await _openTyped(path, chunkSize: chunkSize);
    final data = _pattern(128, seed: 42); // two full chunks, sequential
    expect(await file.writeAt(0, data), 128);
    await file.flush();

    final manifest = await readWebFileManifest(path);
    expect(manifest, isNotNull);
    expect(manifest!.path, path);
    expect(manifest.chunkSize, chunkSize);
    expect(manifest.logicalLength, 128);
    expect(manifest.chunkCount, 2);
    expect(manifest.materializedChunks, 2);
    expect(manifest.generation, greaterThanOrEqualTo(2));
    // Sequential writes record a CRC over each chunk's logical bytes.
    expect(manifest.chunkCrc(0), _crcOf(data, 0, 64));
    expect(manifest.chunkCrc(1), _crcOf(data, 64, 128));
    expect(manifest.chunkCrc(2), isNull);

    // Two slots must both exist after two persists.
    final storeEntries = await listOpfsDirectory(storePathFor(path));
    expect(storeEntries.toSet(), containsAll(<String>{'m.a', 'm.b'}));

    final before = manifest.generation;
    await file.flush(); // clean: no new generation
    expect((await readWebFileManifest(path))!.generation, before);
    await file.writeAt(0, Uint8List.fromList([0]));
    await file.flush(); // dirty: generation advances
    expect((await readWebFileManifest(path))!.generation, before + 1);
    // A random in-place overwrite invalidates the chunk CRC.
    expect((await readWebFileManifest(path))!.chunkCrc(0), isNull);
    await file.close();
  });

  test('many chunks: LRU handle cache + full readback', () async {
    final path = _newPath('many');
    const chunkSize = 4096;
    const length = 256 * 1024; // 64 chunks
    final file = await _openTyped(path, chunkSize: chunkSize);
    final data = _pattern(length, seed: 9);
    expect(await file.writeAt(0, data), length);
    expect(await file.length, length);
    expect(file.manifest.materializedChunks, length ~/ chunkSize);
    expect(WebOpfsBytesFile.maxOpenChunkHandles, 8);

    final back = Uint8List(length);
    expect(await file.readAt(0, back), length);
    expect(_sameBytes(back, data), isTrue);
    // Spot checks at chunk boundaries.
    for (final offset in <int>[0, 4095, 4096, 12345, length - 1]) {
      expect(back[offset], data[offset]);
    }
    await file.close();
    final reopened = await _openTyped(
      path,
      create: false,
      chunkSize: chunkSize,
    );
    expect(await reopened.length, length);
    final probe = Uint8List(16);
    expect(await reopened.readAt(length - 16, probe), 16);
    expect(_sameBytes(probe, data.sublist(length - 16)), isTrue);
    await reopened.close();
  });

  test('public openBytesFile routes to the OPFS backend', () async {
    final path = _newPath('public');
    final BytesFile file = await openBytesFile(path);
    addTearDown(() async {
      if (!file.isClosed) await file.close();
      await deleteOpfsFile(path);
    });
    expect(await file.writeAt(0, Uint8List.fromList([4, 5, 6])), 3);
    expect(await file.length, 3);
    final out = Uint8List(3);
    expect(await file.readAt(0, out), 3);
    expect(out, [4, 5, 6]);
    await file.close();
  });

  test('reopen keeps the chunk size recorded in the manifest', () async {
    final path = _newPath('chunksize');
    final first = await _openTyped(path, chunkSize: 128);
    await first.writeAt(0, _pattern(10));
    await first.close();
    // A different requested chunk size must not rewrite the layout.
    final second = await _openTyped(path, create: false, chunkSize: 1024);
    expect(second.chunkSize, 128);
    await second.close();
  });

  test('concurrent writes to one file are serialized and consistent', () async {
    final path = _newPath('concurrent');
    final file = await _openTyped(path, chunkSize: 64);
    final writes = <Future<int>>[];
    for (var i = 0; i < 16; i++) {
      final block = Uint8List(32)..fillRange(0, 32, i * 16);
      writes.add(file.writeAt(i * 32, block));
    }
    final results = await Future.wait(writes);
    expect(results.every((count) => count == 32), isTrue);
    expect(await file.length, 16 * 32);
    final back = Uint8List(16 * 32);
    expect(await file.readAt(0, back), back.length);
    for (var i = 0; i < 16; i++) {
      expect(back[i * 32], i * 16);
      expect(back[i * 32 + 31], i * 16);
    }
    await file.close();
  });

  test('32 GiB logical truncate is metadata-only (no zero fill)', () async {
    final path = _newPath('32gib');
    const chunkSize = 16 * 1024 * 1024;
    const target = 32 * 1024 * 1024 * 1024;
    const offset = 30 * 1024 * 1024 * 1024;
    final file = await _openTyped(path, chunkSize: chunkSize);

    // On a single OPFS file `truncate(32 GiB)` is cheap but the first write at
    // 30 GiB zero-fills ~30 GiB (12.6 s measured).  Here truncate must only
    // rewrite the manifest and materialize nothing.
    final truncateWatch = Stopwatch()..start();
    await file.truncate(target);
    truncateWatch.stop();
    expect(await file.length, target);
    expect(file.manifest.chunkCount, 2048); // 32 GiB / 16 MiB
    expect(file.manifest.materializedChunks, 0);
    expect(
      truncateWatch.elapsedMilliseconds,
      lessThan(2000),
      reason: 'truncate is a manifest edit, not data movement',
    );

    // Reading inside the sparse region returns zeros without creating chunks.
    final probe = Uint8List(4);
    expect(await file.readAt(offset, probe), 4);
    expect(probe.every((b) => b == 0), isTrue);

    // A one-byte write at 30 GiB only touches chunk 1920.
    final writeWatch = Stopwatch()..start();
    expect(await file.writeAt(offset, Uint8List.fromList([0x5A])), 1);
    writeWatch.stop();
    expect(
      writeWatch.elapsedMilliseconds,
      lessThan(5000),
      reason: 'no zero-fill of the 30 GiB hole',
    );
    final one = Uint8List(1);
    expect(await file.readAt(offset, one), 1);
    expect(one[0], 0x5A);

    final entries = (await listOpfsDirectory(chunkDirPathFor(path)))..sort();
    expect(entries, ['1920.bin']);
    expect(await file.debugPhysicalChunkSize(1920), 1);
    await file.close();

    // The 32 GiB logical length survives a reopen (manifest hi/lo fields).
    final reopened = await _openTyped(path, create: false);
    expect(await reopened.length, target);
    expect((await readWebFileManifest(path))!.logicalLength, target);
    await reopened.close();
  });

  test('chunks are distributed across worker pool', () async {
    final path = _newPath('worker-pool');
    final file = await _openTyped(path, chunkSize: 64);
    expect(await file.writeAt(0, _pattern(256)), 256);
    final workers = file.debugChunkWorkerIndexes().toSet();
    expect(workers.length, greaterThan(1));
    expect(workers.every((index) => index >= 0), isTrue);
    await file.flush();
  });

  test('SAB ring is used when the page is cross-origin isolated', () async {
    final caps = await probeWebStorageCapabilities();
    if (!caps.crossOriginIsolated) return;
    final pool = await OpfsWorkerPool.instance();
    expect(pool.usesSabRing, isTrue);
    final path = _newPath('sab-ring');
    final file = await _openTyped(path, chunkSize: 64 * 1024);
    final data = _pattern(64 * 1024, seed: 9);
    expect(await file.writeAt(0, data), data.length);
    final back = Uint8List(data.length);
    expect(await file.readAt(0, back), data.length);
    expect(_sameBytes(back, data), isTrue);
    await file.flush();
  });
}

int _crcOf(Uint8List data, int start, int end) {
  // Local import-free CRC-32 used to cross-check the manifest values.
  var crc = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    crc ^= data[i];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
    }
    crc &= 0xFFFFFFFF;
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
