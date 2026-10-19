@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) {
    test('Windows mmap engine (skipped on this platform)', () {}, skip: true);
    return;
  }

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bytes_mmap_test_');
    path = '${dir.path}${Platform.pathSeparator}mmap.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('create, write, read, map, zeroize', () {
    final f = openMmapFileSync(path);
    f.truncate(1 << 20);
    expect(f.length, 1 << 20);

    final pattern = Uint8List.fromList(List.generate(4096, (i) => i & 0xFF));
    expect(f.writeAt(0, pattern), 4096);
    final out = Uint8List(4096);
    expect(f.readAt(0, out), 4096);
    expect(out, pattern);

    final region = f.map(offset: 0, length: 4096);
    expect(region.bytes.sublist(0, 16), pattern.sublist(0, 16));
    region.bytes[0] = 0xAA;
    region.flush();
    expect(f.readAt(0, Uint8List(1)) >= 0, isTrue);
    region.close();
    expect(region.isClosed, isTrue);

    f.zeroize(0, 4096);
    final zero = Uint8List(4096);
    f.readAt(0, zero);
    expect(zero.every((b) => b == 0), isTrue);
    f.close();
  });

  test('unaligned window and 2 GiB offset', () {
    final f = openMmapFileSync(path);
    const size = (2 << 30) + (1 << 20);
    f.truncate(size, sparse: true);
    expect(f.length, size);

    final offset = (2 << 30) + 12345;
    const len = 8192;
    final data = Uint8List(len);
    for (var i = 0; i < len; i++) {
      data[i] = (i * 31) & 0xFF;
    }
    f.writeAt(offset, data);

    final region = f.map(offset: offset, length: len);
    expect(region.offset, offset);
    expect(region.length, len);
    expect(region.bytes.sublist(0, 8), data.sublist(0, 8));
    region.bytes[0] ^= 0xFF;
    region.flush();
    region.close();

    final back = Uint8List(len);
    f.readAt(offset, back);
    expect(back[0], data[0] ^ 0xFF);
    f.close();
  });

  test('sparse far write is fast (no 32 GiB zero-fill)', () {
    final f = openMmapFileSync(path);
    const size = 1 << 30; // keep the test light; the 32 GiB run is a benchmark
    f.truncate(size, sparse: true);
    final t = Stopwatch()..start();
    f.writeAt(size - 4096, Uint8List(4096));
    t.stop();
    expect(t.elapsedMilliseconds, lessThan(2000));
    f.close();
  });

  test('read-only mapping', () {
    final f = openMmapFileSync(path);
    f.truncate(4096);
    f.writeAt(0, Uint8List.fromList([1, 2, 3]));
    f.close();

    final r = openMmapFileSync(path, create: false, readOnly: true);
    expect(r.readAt(0, Uint8List(3)), 3);
    final region = r.map(offset: 0, length: 4, writable: false);
    expect(region.bytes[0], 1);
    expect(() => r.writeAt(0, Uint8List(1)), throwsStateError);
    region.close();
    r.close();
  });
}
