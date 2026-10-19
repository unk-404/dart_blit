// POSIX mmap backend tests.  They only run on Linux and macOS/OS X; the
// Windows job still loads the suite (so the file must compile) but skips it.
@TestOn('linux || mac-os')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/mmap.dart';
import 'package:blit/src/io/native/mmap_posix.dart';
import 'package:test/test.dart';

const int _pageSize = 4096;

Uint8List _pattern(int length, {int seed = 0}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 37 + seed) & 0xFF;
  }
  return bytes;
}

void main() {
  late Directory tempDir;
  late String path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bytes_posix_');
    path = '${tempDir.path}/data.bin';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('create, write, read, truncate, close', () {
    final file = PosixMmapFile.openSync(path);
    expect(file.path, path);
    expect(file.readOnly, isFalse);
    expect(file.isClosed, isFalse);
    expect(file.length, 0);

    final data = _pattern(1000);
    expect(file.writeAt(0, data), data.length);
    expect(file.length, data.length);

    final out = Uint8List(data.length);
    expect(file.readAt(0, out), data.length);
    expect(out, equals(data));

    // Writes past EOF extend the file and leave a zero-filled (sparse) gap.
    expect(file.writeAt(4096, Uint8List.fromList(const [1, 2, 3])), 3);
    expect(file.length, 4099);
    final gap = Uint8List(16);
    expect(file.readAt(1000, gap), 16);
    expect(gap.sublist(0, 16), everyElement(0));

    file.truncate(500);
    expect(file.length, 500);
    expect(file.readAt(1000, gap), 0);

    file.truncate(2048, sparse: true);
    expect(file.length, 2048);
    final zeros = Uint8List(64);
    expect(file.readAt(1024, zeros), 64);
    expect(zeros, everyElement(0));

    file.flush();
    file.close();
    file.close(); // idempotent
    expect(file.isClosed, isTrue);
    expect(File(path).lengthSync(), 2048);

    expect(() => file.length, throwsStateError);
    expect(() => file.readAt(0, Uint8List(1)), throwsStateError);
    expect(() => file.writeAt(0, Uint8List(1)), throwsStateError);
    expect(() => file.map(), throwsStateError);
  });

  test('readAt clamps at EOF, validates ranges and refuses negative offsets',
      () {
    final file = PosixMmapFile.openSync(path);
    final data = _pattern(100);
    file.writeAt(0, data);

    final partial = Uint8List(50);
    expect(file.readAt(80, partial), 20);
    expect(partial.sublist(0, 20), equals(data.sublist(80)));
    expect(partial.sublist(20, 50), everyElement(0));

    expect(file.readAt(100, partial), 0);
    expect(file.readAt(100000, partial), 0);

    expect(() => file.readAt(-1, partial), throwsRangeError);
    expect(() => file.readAt(0, partial, start: 10, end: 60),
        throwsRangeError);

    // start/end slice writes and reads.
    final src = Uint8List.fromList(List.generate(32, (i) => i + 1));
    expect(file.writeAt(200, src, start: 8, end: 24), 16);
    final roundTrip = Uint8List(16);
    expect(file.readAt(200, roundTrip), 16);
    expect(roundTrip, equals(src.sublist(8, 24)));

    file.close();
  });

  test('map returns a zero-copy window; unaligned offsets are hidden', () {
    final data = _pattern(3 * _pageSize + 123);
    File(path).writeAsBytesSync(data);

    final file = PosixMmapFile.openSync(path);
    final whole = file.map();
    expect(whole.offset, 0);
    expect(whole.length, data.length);
    expect(whole.bytes, equals(data));
    whole.close();
    expect(whole.isClosed, isTrue);
    expect(() => whole.bytes, throwsStateError);

    // Offset crosses a page boundary: base is aligned down, delta is hidden.
    const offset = _pageSize + 7;
    const length = _pageSize + 31;
    final region = file.map(offset: offset, length: length);
    expect(region.offset, offset);
    expect(region.length, length);
    expect(region.bytes, equals(data.sublist(offset, offset + length)));

    // Writing through `bytes` must be visible to pread after flush.
    region.bytes[0] = 0xAA;
    region.bytes[1] = 0xBB;
    region.flush();
    region.close();

    final check = Uint8List(2);
    expect(file.readAt(offset, check), 2);
    expect(check, equals(const [0xAA, 0xBB]));
    file.close();
  });

  test('read-only files reject writes, truncate, zeroize and writable maps',
      () {
    final data = _pattern(64);
    File(path).writeAsBytesSync(data);

    final file = PosixMmapFile.openSync(path, readOnly: true);
    expect(file.readOnly, isTrue);
    expect(file.length, data.length);

    final out = Uint8List(data.length);
    expect(file.readAt(0, out), data.length);
    expect(out, equals(data));

    expect(() => file.writeAt(0, Uint8List(1)), throwsStateError);
    expect(() => file.truncate(1), throwsStateError);
    expect(() => file.zeroize(0, 1), throwsStateError);
    expect(() => file.map(writable: true), throwsStateError);

    final region = file.map(writable: false);
    expect(region.bytes, equals(data));
    expect(() => region.zeroize(), throwsStateError);
    region.flush(); // no-op for read-only windows
    region.close();

    file.close();
  });

  test('zeroize writes zeros without touching the surrounding bytes', () {
    final file = PosixMmapFile.openSync(path);
    final data = _pattern(8192, seed: 5);
    file.writeAt(0, data);

    file.zeroize(1000, 5000);
    final out = Uint8List(8192);
    expect(file.readAt(0, out), 8192);
    for (var i = 0; i < out.length; i++) {
      final inRange = i >= 1000 && i < 6000;
      expect(out[i], inRange ? 0 : data[i], reason: 'byte $i');
    }
    expect(() => file.zeroize(8192, 1), throwsRangeError);

    // Region-level zeroize uses the native wipe too.
    final region = file.map(offset: 100, length: 16);
    region.zeroize();
    region.flush();
    region.close();
    final tail = Uint8List(18);
    expect(file.readAt(99, tail), 18);
    expect(tail[0], data[99]);
    expect(tail.sublist(1, 17), everyElement(0));
    expect(tail[17], data[116]);

    file.close();
  });

  test('truncate with sparse: false still produces a valid file', () {
    final file = PosixMmapFile.openSync(path);
    file.truncate(8192, sparse: false);
    expect(file.length, 8192);
    final out = Uint8List(8192);
    expect(file.readAt(0, out), 8192);
    expect(out, everyElement(0));
    file.writeAt(0, Uint8List.fromList(const [9, 9]));
    final check = Uint8List(4);
    expect(file.readAt(0, check), 4);
    expect(check, equals(const [9, 9, 0, 0]));
    file.close();
  });

  test('maps a window at a > 2 GiB unaligned offset', () {
    const twoGiB = 1 << 31;
    const size = twoGiB + (1 << 16);
    const offset = twoGiB + 123;
    const length = 200;

    final file = PosixMmapFile.openSync(path);
    file.truncate(size); // sparse: metadata-only on ext4/APFS/overlayfs
    expect(file.length, size);

    final region = file.map(offset: offset, length: length);
    expect(region.offset, offset);
    expect(region.length, length);
    expect(region.bytes, everyElement(0));

    region.bytes[0] = 0x11;
    region.bytes[length - 1] = 0x22;
    region.flush();

    final probe = Uint8List(1);
    expect(file.readAt(offset, probe), 1);
    expect(probe[0], 0x11);
    expect(file.readAt(offset + length - 1, probe), 1);
    expect(probe[0], 0x22);
    expect(file.readAt(size - 1, probe), 1); // still sparse past the window
    expect(probe[0], 0);

    region.close();
    expect(file.length, size);
    file.close();
  });

  test('truncate closes every live window', () {
    final file = PosixMmapFile.openSync(path);
    file.writeAt(0, _pattern(3 * _pageSize));
    final first = file.map(offset: 0, length: _pageSize);
    final second = file.map(offset: _pageSize, length: _pageSize);
    expect(first.isClosed, isFalse);
    expect(second.isClosed, isFalse);

    file.truncate(_pageSize);
    expect(first.isClosed, isTrue);
    expect(second.isClosed, isTrue);
    expect(() => first.bytes, throwsStateError);
    expect(file.length, _pageSize);
    file.close();
  });

  test('open(create: false) on a missing file throws PosixException', () {
    expect(
      () => PosixMmapFile.openSync(path, create: false),
      throwsA(isA<PosixException>()),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('async open and async wrappers', () async {
    final file = await PosixMmapFile.open(path);
    expect(file, isA<PosixMmapFile>());
    expect(await file.writeAtAsync(0, Uint8List.fromList(const [1, 2, 3])), 3);
    expect(await file.lengthAsync, 3);

    final out = Uint8List(3);
    expect(await file.readAtAsync(0, out), 3);
    expect(out, equals(const [1, 2, 3]));

    await file.truncateAsync(6, sparse: true);
    expect(await file.lengthAsync, 6);
    await file.zeroizeAsync(0, 2);
    expect(await file.readAtAsync(0, out), 3);
    expect(out, equals(const [0, 0, 3]));

    final region = await file.mapAsync(offset: 1, length: 2);
    expect(region.bytes, equals(const [0, 3]));
    region.close();

    await file.flushAsync();
    await file.closeAsync();
    expect(file.isClosed, isTrue);
  });

  test('openMmapFile factory selects the POSIX backend', () async {
    final sync = openMmapFileSync(path);
    expect(sync, isA<PosixMmapFile>());
    sync.close();

    final async = await openMmapFile(path);
    expect(async, isA<PosixMmapFile>());
    expect(async.path, path);
    async.close();
  });

  test('madvise hints are advisory and safe', () {
    File(path).writeAsBytesSync(_pattern(4 * _pageSize));
    final file = PosixMmapFile.openSync(path);
    final region = file.map(writable: false) as PosixMappedRegion;
    region.adviseSequential();
    region.adviseWillNeed();
    region.adviseDontNeed();
    expect(region.bytes.length, 4 * _pageSize);
    region.close();
    expect(() => region.adviseSequential(), throwsStateError);
    file.close();
  });
}
