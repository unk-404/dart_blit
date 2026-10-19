import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bytes_file_test_');
    path = '${dir.path}${Platform.pathSeparator}data.bin';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('write/read/append/truncate async', () async {
    final f = await openBytesFile(path);
    final a = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
    expect(await f.writeAt(0, a), 1000);
    expect(await f.length, 1000);
    final b = Uint8List.fromList([1, 2, 3]);
    expect(await f.append(b), 3);
    expect(await f.length, 1003);

    final out = Uint8List(1003);
    expect(await f.readAt(0, out), 1003);
    expect(out.sublist(0, 1000), a);
    expect(out.sublist(1000), b);

    // Partial read at offset.
    final part = Uint8List(10);
    expect(await f.readAt(500, part), 10);
    expect(part, a.sublist(500, 510));

    await f.truncate(10);
    expect(await f.length, 10);
    final tail = Uint8List(10);
    expect(await f.readAt(100, tail), 0, reason: 'past EOF');
    await f.flush();
    await f.close();
    expect(f.isClosed, isTrue);
  });

  test('sync API', () async {
    final f = openBytesFileSync(path);
    final data = Uint8List.fromList([9, 8, 7, 6]);
    f.writeAtSync(0, data);
    f.appendSync(Uint8List.fromList([5]));
    expect(f.lengthSync, 5);
    final out = Uint8List(5);
    f.readAtSync(0, out);
    expect(out, [9, 8, 7, 6, 5]);
    f.flushSync();
    f.closeSync();
  });

  test('random writes at offsets', () async {
    final f = await openBytesFile(path);
    const size = 1 << 20;
    final chunk = Uint8List(4096);
    for (var i = 0; i < size ~/ chunk.length; i++) {
      chunk.fillRange(0, chunk.length, i & 0xFF);
      await f.writeAt(i * chunk.length, chunk);
    }
    expect(await f.length, size);
    final probe = Uint8List(4096);
    await f.readAt(123 * 4096, probe);
    expect(probe[0], 123);
    expect(probe[4095], 123);
    await f.close();
  });

  test('reopen and read-only', () async {
    final f = await openBytesFile(path);
    await f.writeAt(0, Uint8List.fromList([1, 2, 3]));
    await f.close();

    final r = await openBytesFile(path, create: false, readOnly: true);
    final out = Uint8List(3);
    expect(await r.readAt(0, out), 3);
    expect(out, [1, 2, 3]);
    await expectLater(r.writeAt(0, Uint8List(1)), throwsStateError);
    await r.close();
  });

  test('delete removes file', () async {
    final f = await openBytesFile(path);
    await f.writeAt(0, Uint8List.fromList([1]));
    await f.delete();
    expect(File(path).existsSync(), isFalse);
  });

  test('reopen does not truncate existing data', () async {
    var f = await openBytesFile(path);
    await f.writeAt(0, Uint8List.fromList([1, 2, 3, 4]));
    await f.close();
    f = await openBytesFile(path);
    expect(await f.length, 4);
    final out = Uint8List(4);
    await f.readAt(0, out);
    expect(out, [1, 2, 3, 4]);
    await f.close();
  });
}
