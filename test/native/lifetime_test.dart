/// Lifecycle, ownership and error-path tests for the native mmap engine.
///
/// Runs on Windows and POSIX.  Tests that depend on a backend-specific detail
/// are annotated inline.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:blit/src/io/open.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bytes_lifetime_');
    path = '${dir.path}${Platform.pathSeparator}lifetime.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('MmapFile basics', () {
    test('create, truncate and length', () {
      final f = openMmapFileSync(path);
      try {
        expect(f.path, path);
        expect(f.readOnly, isFalse);
        expect(f.isClosed, isFalse);
        expect(f.length, 0);
        expect(f.readAt(0, Uint8List(16)), 0, reason: 'empty file');
        expect(f.readAt(100, Uint8List(16)), 0, reason: 'past EOF');

        f.truncate(100);
        expect(f.length, 100);
        f.truncate(100);
        expect(f.length, 100);

        f.writeAt(0, Uint8List.fromList([1, 2, 3]));
        expect(f.length, 100, reason: 'write inside EOF does not shrink');
        f.truncate(3);
        expect(f.length, 3);

        final out = Uint8List(4);
        expect(f.readAt(0, out), 3, reason: 'short read at EOF');
        expect(out.sublist(0, 3), [1, 2, 3]);
        expect(out[3], 0, reason: 'readAt only writes the bytes it read');
        expect(f.readAt(3, Uint8List(4)), 0, reason: 'exactly at EOF');
      } finally {
        f.close();
      }
    });

    test('readAt/writeAt respect start/end and extend on far writes', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(4096);

        final src = Uint8List.fromList([10, 20, 30, 40, 50]);
        expect(f.writeAt(100, src, start: 1, end: 4), 3);
        final out = Uint8List(5);
        expect(f.readAt(100, out, start: 1, end: 4), 3);
        expect(out, [0, 20, 30, 40, 0]);

        // A write past EOF grows the file; the gap reads as zeros.
        expect(f.writeAt(8192, Uint8List.fromList([7, 8])), 2);
        expect(f.length, 8194);
        final back = Uint8List(2);
        expect(f.readAt(8192, back), 2);
        expect(back, [7, 8]);
        final gap = Uint8List(16);
        expect(f.readAt(4096, gap), 16);
        expect(gap.every((b) => b == 0), isTrue);

        // Zero-length writes/reads are no-ops.
        expect(f.writeAt(0, Uint8List(0)), 0);
        expect(f.readAt(0, Uint8List(0)), 0);
        expect(f.readAt(0, Uint8List(4), start: 2, end: 2), 0);

        // Invalid ranges.
        expect(() => f.readAt(-1, Uint8List(1)), throwsRangeError);
        expect(() => f.writeAt(-1, Uint8List(1)), throwsRangeError);
        expect(
          () => f.readAt(0, Uint8List(4), start: 2, end: 1),
          throwsRangeError,
        );
        expect(() => f.readAt(0, Uint8List(4), start: -1), throwsRangeError);
        expect(() => f.writeAt(0, src, end: 6), throwsRangeError);
        expect(() => f.truncate(-1), throwsRangeError);
      } finally {
        f.close();
      }
    });

    test('zeroize clears a range and validates its bounds', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(4096);
        f.writeAt(0, Uint8List.fromList(List<int>.filled(4096, 0xAB)));
        f.zeroize(0, 1024);
        final out = Uint8List(4096);
        f.readAt(0, out);
        expect(out.sublist(0, 1024).every((b) => b == 0), isTrue);
        expect(out[1024], 0xAB);

        expect(() => f.zeroize(0, 4097), throwsRangeError);
        expect(() => f.zeroize(-1, 1), throwsRangeError);
        expect(() => f.zeroize(4096, 1), throwsRangeError);
        // A zero-length zeroize at EOF is a no-op.
        f.zeroize(4096, 0);
      } finally {
        f.close();
      }
    });

    test('async wrappers mirror the sync API', () async {
      final f = await openMmapFile(path);
      try {
        f.truncate(8);
        expect(await f.lengthAsync, 8);
        expect(await f.writeAtAsync(0, Uint8List.fromList([9, 8, 7])), 3);
        final out = Uint8List(3);
        expect(await f.readAtAsync(0, out), 3);
        expect(out, [9, 8, 7]);
        await f.truncateAsync(2);
        expect(await f.lengthAsync, 2);
        await f.flushAsync();
        await f.zeroizeAsync(0, 2);
      } finally {
        await f.closeAsync();
      }
      expect(f.isClosed, isTrue);
    });
  });

  group('MappedRegion lifetime', () {
    test('map returns a zero-copy window with offset/length', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(1 << 20);
        const offset = 65536 + 123; // crosses the Windows 64 KiB alignment
        final data = Uint8List(8192);
        for (var i = 0; i < data.length; i++) {
          data[i] = (i * 13 + 5) & 0xFF;
        }
        f.writeAt(offset, data);

        final region = f.map(offset: offset, length: data.length);
        expect(region.offset, offset);
        expect(region.length, data.length);
        expect(region.isClosed, isFalse);
        expect(region.bytes, data);

        // The view is zero-copy: mutating it mutates the file mapping.
        region.bytes[0] ^= 0xFF;
        region.flush();
        final readBack = Uint8List(1);
        expect(f.readAt(offset, readBack), 1);
        expect(readBack[0], data[0] ^ 0xFF);

        region.close();
        expect(region.isClosed, isTrue);
        expect(() => region.bytes, throwsStateError);
        region.close(); // idempotent
        expect(region.isClosed, isTrue);

        // Default length maps through EOF.
        final tail = f.map(offset: (1 << 20) - 16);
        expect(tail.length, 16);
        tail.close();
      } finally {
        f.close();
      }
    });

    test('map validates bounds and rejects empty files', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(8192);
        expect(() => f.map(offset: -1), throwsRangeError);
        expect(() => f.map(offset: 8193), throwsRangeError);
        expect(() => f.map(offset: 0, length: 8193), throwsRangeError);
        expect(() => f.map(offset: 8192, length: 1), throwsRangeError);
        expect(() => f.map(offset: 0, length: 0), throwsRangeError);
        expect(() => f.map(offset: 8192), throwsRangeError);
        expect(() => f.map(offset: 0, length: -1), throwsRangeError);

        final region = f.map(offset: 8192 - 16);
        expect(region.length, 16);
        region.close();

        f.truncate(0);
        // Backends disagree on the exception type for an empty file
        // (Windows: StateError, POSIX: RangeError); both are contractually
        // rejected.
        expect(
          () => f.map(),
          throwsA(anyOf(isA<RangeError>(), isA<StateError>())),
        );
      } finally {
        f.close();
      }
    });

    test('region.zeroize clears only its window', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(4096);
        f.writeAt(0, Uint8List.fromList(List<int>.filled(4096, 0x5A)));
        final region = f.map(offset: 1024, length: 512);
        region.zeroize();
        region.flush();
        region.close();

        final out = Uint8List(4096);
        f.readAt(0, out);
        expect(out.sublist(1024, 1536).every((b) => b == 0), isTrue);
        expect(out[1023], 0x5A);
        expect(out[1536], 0x5A);
      } finally {
        f.close();
      }
    });

    test('multiple regions coexist; closing one keeps the other', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(1 << 16);
        f.writeAt(0, Uint8List.fromList(List<int>.filled(1 << 16, 0x33)));
        final a = f.map(offset: 0, length: 4096);
        final b = f.map(offset: 1 << 15, length: 4096);
        expect(a.bytes[0], 0x33);
        expect(b.bytes[0], 0x33);
        a.close();
        expect(a.isClosed, isTrue);
        expect(b.isClosed, isFalse);
        expect(b.bytes[0], 0x33);
        b.close();
      } finally {
        f.close();
      }
    });

    test('truncate closes live regions', () {
      final f = openMmapFileSync(path);
      try {
        f.truncate(1 << 20);
        final region = f.map(offset: 0, length: 4096);
        region.bytes[0] = 42;
        f.truncate(1 << 20); // same size still invalidates windows
        expect(region.isClosed, isTrue);
        expect(() => region.bytes, throwsStateError);
        // Mapping again after truncate works.
        final after = f.map();
        expect(after.length, 1 << 20);
        after.close();
      } finally {
        f.close();
      }
    });
  });

  group('close semantics', () {
    test('file.close unmaps regions and makes everything throw StateError', () {
      final f = openMmapFileSync(path);
      f.truncate(4096);
      final region = f.map(offset: 0, length: 16);
      f.writeAt(0, Uint8List.fromList([1, 2, 3]));

      f.close();
      expect(f.isClosed, isTrue);
      expect(region.isClosed, isTrue, reason: 'owner close unmaps regions');
      expect(() => region.bytes, throwsStateError);
      region.close(); // idempotent even after the owner closed

      expect(() => f.length, throwsStateError);
      expect(() => f.map(offset: 0, length: 1), throwsStateError);
      expect(() => f.readAt(0, Uint8List(1)), throwsStateError);
      expect(() => f.writeAt(0, Uint8List(1)), throwsStateError);
      expect(() => f.truncate(1), throwsStateError);
      expect(() => f.flush(), throwsStateError);
      expect(() => f.zeroize(0, 1), throwsStateError);

      f.close();
      f.close();
      expect(f.isClosed, isTrue);
    });

    test('async wrappers surface StateError after close', () async {
      final f = openMmapFileSync(path);
      f.truncate(16);
      f.close();
      await expectLater(f.readAtAsync(0, Uint8List(1)), throwsStateError);
      await expectLater(f.writeAtAsync(0, Uint8List(1)), throwsStateError);
      await expectLater(f.truncateAsync(0), throwsStateError);
      await expectLater(f.flushAsync(), throwsStateError);
      await expectLater(f.zeroizeAsync(0, 1), throwsStateError);
      await expectLater(f.lengthAsync, throwsStateError);
      await expectLater(f.mapAsync(), throwsStateError);
    });

    test('open create:false fails on a missing file', () {
      expect(
        () => openMmapFileSync(path, create: false),
        throwsA(isA<Exception>()),
      );
      expect(
        () => openMmapFileSync('${path}_missing', create: false),
        throwsA(isA<Exception>()),
      );
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('read-only files', () {
    test('reject writes, truncate, zeroize and writable mappings', () {
      final writer = openMmapFileSync(path);
      writer.truncate(4096);
      writer.writeAt(0, Uint8List.fromList([1, 2, 3, 4]));
      writer.close();

      final ro = openMmapFileSync(path, create: false, readOnly: true);
      try {
        expect(ro.readOnly, isTrue);
        final out = Uint8List(4);
        expect(ro.readAt(0, out), 4);
        expect(out, [1, 2, 3, 4]);

        final region = ro.map(offset: 0, length: 4, writable: false);
        expect(region.bytes, [1, 2, 3, 4]);
        region.close();

        expect(
          () => ro.map(offset: 0, length: 4),
          throwsStateError,
          reason: 'default writable mapping on a read-only file',
        );
        expect(() => ro.writeAt(0, Uint8List(1)), throwsStateError);
        expect(() => ro.truncate(1), throwsStateError);
        expect(() => ro.zeroize(0, 1), throwsStateError);
      } finally {
        ro.close();
      }
    });
  });

  group('NativeBytesFile lifecycle', () {
    test(
      'openBytesFile: close makes every operation throw StateError',
      () async {
        final f = await openBytesFile(path);
        await f.writeAt(0, Uint8List.fromList([1, 2, 3]));
        expect(await f.length, 3);
        await f.close();
        expect(f.isClosed, isTrue);

        await expectLater(f.readAt(0, Uint8List(1)), throwsStateError);
        await expectLater(f.writeAt(0, Uint8List(1)), throwsStateError);
        await expectLater(f.append(Uint8List(1)), throwsStateError);
        await expectLater(f.truncate(0), throwsStateError);
        await expectLater(f.flush(), throwsStateError);
        await expectLater(f.length, throwsStateError);

        await f.close(); // idempotent
        await f.delete(); // closes (already closed) and removes the file
        expect(File(path).existsSync(), isFalse);
      },
    );

    test('openBytesFileSync lifecycle', () async {
      final f = openBytesFileSync(path);
      f.writeAtSync(0, Uint8List.fromList([7, 8]));
      final out = Uint8List(2);
      expect(f.readAtSync(0, out), 2);
      expect(out, [7, 8]);
      f.closeSync();
      expect(f.isClosed, isTrue);
      f.closeSync(); // idempotent

      expect(() => f.lengthSync, throwsStateError);
      expect(() => f.readAtSync(0, Uint8List(1)), throwsStateError);
      expect(() => f.writeAtSync(0, Uint8List(1)), throwsStateError);
      expect(() => f.truncateSync(0), throwsStateError);
      expect(() => f.flushSync(), throwsStateError);

      await f.delete();
      expect(File(path).existsSync(), isFalse);
    });
  });
}



