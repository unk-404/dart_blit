import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:blit/blit_io.dart';
import 'package:blit/blit_native.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}'
      '.dart_tool${Platform.pathSeparator}blit_v2_'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    path = '${dir.path}${Platform.pathSeparator}data.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('simple API write/read/append/exists/delete', () async {
    expect(await blit.exists(path), isFalse);
    await blit.write(path, Uint8List.fromList([1, 2, 3]));
    expect(await blit.exists(path), isTrue);
    expect((await blit.read(path)).toUint8List(), [1, 2, 3]);

    await blit.append(path, Uint8List.fromList([4, 5]));
    expect((await blit.read(path)).toUint8List(), [1, 2, 3, 4, 5]);

    final file = await blit.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite),
    );
    expect(await file.size, 5);
    expect((await file.readAt(1, 2)).toUint8List(), [2, 3]);
    await file.writeAt(1, Uint8List.fromList([9, 9]));
    expect((await file.readAll()).toUint8List(), [1, 9, 9, 4, 5]);
    await file.close();

    await blit.delete(path);
    expect(await blit.exists(path), isFalse);
  });

  test('writeMany merges contiguous writes', () async {
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    try {
      final counts = await file.writeMany([
        WriteRequest(0, IoSlice(Uint8List.fromList([1, 2]))),
        WriteRequest(2, IoSlice(Uint8List.fromList([3, 4]))),
        WriteRequest(4, IoSlice(Uint8List.fromList([5]))),
      ]);
      expect(counts, [2, 2, 1]);
      final out = Uint8List(5);
      await file.readAt(0, ReadBuf(out));
      expect(out, [1, 2, 3, 4, 5]);
    } finally {
      await file.close();
    }
  });
  test('NativeBufferPool reuses exact-size buffers', () {
    final pool = NativeBufferPool(maxPerSize: 1);
    final first = pool.acquire(8);
    first.bytes[0] = 42;
    pool.release(first);
    final second = pool.acquire(8);
    expect(identical(first, second), isTrue);
    expect(second.bytes[0], 42);
    pool.release(second);
    pool.clear();
    expect(pool.cached, 0);
    expect(second.isDisposed, isTrue);
  });

  test('readMany uses a concurrent read backend when available', () async {
    File(path).writeAsBytesSync(List.generate(4096, (i) => i & 0xFF));
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.read, create: false),
    );
    try {
      final a = Uint8List(1024);
      final b = Uint8List(1024);
      final counts = await file.readMany([
        ReadRequest(0, ReadBuf(a)),
        ReadRequest(2048, ReadBuf(b)),
      ]);
      expect(counts, [1024, 1024]);
      expect(a.sublist(0, 3), [0, 1, 2]);
      expect(b.sublist(0, 3), [0, 1, 2]);
    } finally {
      await file.close();
    }
  });

  test('AsyncFileNative pooled native read/write', () async {
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    final pool = NativeBufferPool(maxPerSize: 1);
    try {
      final source = NativeBuffer.allocate(4);
      try {
        source.bytes.setAll(0, [9, 8, 7, 6]);
        expect(await file.writeFromNative(0, source), 4);
      } finally {
        source.dispose();
      }
      final all = await file.readAllNative(pool: pool);
      expect(all.bytes.sublist(0, 4), [9, 8, 7, 6]);
      pool.release(all);
      expect(pool.cached, 1);
    } finally {
      pool.clear();
      await file.close();
    }
  });
  test('NativeMmapFile readAllNative uses pool', () async {
    final native = await NativeMmapFile.open(path, create: true);
    final pool = NativeBufferPool(maxPerSize: 1);
    try {
      await native.truncate(5);
      final source = NativeBuffer.allocate(5);
      try {
        source.bytes.setAll(0, [1, 2, 3, 4, 5]);
        native.writeFromNative(0, source);
      } finally {
        source.dispose();
      }
      final all = await native.readAllNative(pool: pool);
      expect(all.bytes.sublist(0, 5), [1, 2, 3, 4, 5]);
      pool.release(all);
      expect(pool.cached, 1);
    } finally {
      pool.clear();
      await native.close();
    }
  });

  test('NativeMmapFile pointer read/write', () async {
    final native = await NativeMmapFile.open(path, create: true);
    final buffer = NativeBuffer.allocate(8);
    try {
      await native.truncate(8);
      buffer.bytes.setAll(0, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(native.writeFromNative(0, buffer), 8);
      buffer.bytes.fillRange(0, 8, 0);
      expect(native.readIntoNative(0, buffer), 8);
      expect(buffer.bytes.sublist(0, 8), [1, 2, 3, 4, 5, 6, 7, 8]);
    } finally {
      buffer.dispose();
      await native.close();
    }
  });

  test('close waits for pending writes', () async {
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    final data = Uint8List.fromList([for (var i = 0; i < 4096; i++) i & 0xFF]);
    final write = file.writeAt(0, IoSlice(data));
    final close = file.close();
    await close;
    expect(await write, 4096);
    expect(File(path).lengthSync(), 4096);
    await expectLater(file.length, throwsA(isA<ClosedException>()));
  });
  test('writeMany coalesces clustered non-contiguous writes', () async {
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    try {
      final seed = Uint8List.fromList([for (var i = 0; i < 12; i++) i]);
      await file.writeAt(0, IoSlice(seed));
      final counts = await file.writeMany([
        WriteRequest(1, IoSlice(Uint8List.fromList([99]))),
        WriteRequest(5, IoSlice(Uint8List.fromList([88]))),
        WriteRequest(9, IoSlice(Uint8List.fromList([77]))),
      ]);
      expect(counts, [1, 1, 1]);
      final out = Uint8List(12);
      await file.readAt(0, ReadBuf(out));
      expect(out[0], 0);
      expect(out[1], 99);
      expect(out[4], 4);
      expect(out[5], 88);
      expect(out[8], 8);
      expect(out[9], 77);
      expect(out[11], 11);
    } finally {
      await file.close();
    }
  });

  test('readMany merges contiguous requests', () async {
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    try {
      final data = Uint8List.fromList([for (var i = 0; i < 10; i++) i]);
      await file.writeAt(0, IoSlice(data));
      final a = Uint8List(5);
      final b = Uint8List(5);
      final counts = await file.readMany([
        ReadRequest(0, ReadBuf(a)),
        ReadRequest(5, ReadBuf(b)),
      ]);
      expect(counts, [5, 5]);
      expect(a, data.sublist(0, 5));
      expect(b, data.sublist(5));
    } finally {
      await file.close();
    }
  });
  test('cancel token and exclusive create', () async {
    final token = CancelToken()..cancel('test');
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    try {
      await expectLater(
        file.readAt(0, ReadBuf(Uint8List(1)), cancel: token),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        file.writeAt(0, IoSlice(Uint8List(1)), cancel: token),
        throwsA(isA<CancelledException>()),
      );
    } finally {
      await file.close();
    }

    File(path).writeAsBytesSync([1]);
    await expectLater(
      AsyncFile.open(
        path,
        options: const FileOptions(mode: FileMode.readWrite, exclusive: true),
      ),
      throwsA(isA<BlitIOException>()),
    );
  });

  test(
    'AsyncFile batches, truncate, native buffer, closed semantics',
    () async {
      final file = await AsyncFile.open(
        path,
        options: const FileOptions(mode: FileMode.readWrite, truncate: true),
      );
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5, 6]);
      expect(
        await file.writeMany([
          WriteRequest(0, IoSlice(a)),
          WriteRequest(100, IoSlice(b)),
        ]),
        [3, 3],
      );
      expect(await file.length, 103);

      final ra = Uint8List(3);
      final rb = Uint8List(3);
      expect(
        await file.readMany([
          ReadRequest(0, ReadBuf(ra)),
          ReadRequest(100, ReadBuf(rb)),
        ]),
        [3, 3],
      );
      expect(ra, a);
      expect(rb, b);

      final native = NativeBuffer.allocate(3);
      try {
        final dst = native.readBuf();
        expect(await file.readAt(0, dst), 3);
        expect(native.bytes.sublist(0, 3), a);
      } finally {
        native.dispose();
      }

      await file.truncate(2);
      expect(await file.length, 2);
      await file.close();
      await expectLater(file.length, throwsA(isA<ClosedException>()));
    },
  );
}
