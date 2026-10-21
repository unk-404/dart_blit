import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit_io.dart';
import 'package:test/test.dart';

void main() {
  group('memory AsyncIO', () {
    test('readExact/readToEnd/numeric helpers', () async {
      final data = Uint8List.fromList([
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0xFF,
      ]);
      final reader = Uint8ListReader(data);

      expect(await reader.readU8(), 0x01);
      expect(await reader.readU16(), 0x0203);
      expect(await reader.readU32(), 0x04050607);
      expect(await reader.readU8(), 0x08);

      final tail = await reader.readToEnd();
      expect(tail.toUint8List(), [0xFF]);

      final eofReader = Uint8ListReader(Uint8List(1));
      await expectLater(
        eofReader.readExact(ReadBuf(Uint8List(2))),
        throwsA(isA<UnexpectedEof>()),
      );
    });

    test('writeAll and copy preserve bytes', () async {
      final data = Uint8List.fromList([
        for (var i = 0; i < 10000; i++) i & 0xFF,
      ]);
      final reader = Uint8ListReader(data);
      final target = BytesMutAsyncWriter();
      final n = await reader.copyTo(target);
      expect(n, data.length);
      expect(target.freeze().toUint8List(), data);

      final fixed = Uint8List(4);
      final writer = Uint8ListWriter(fixed);
      await writer.writeAll(IoSlice(Uint8List.fromList([1, 2, 3, 4])));
      expect(fixed, [1, 2, 3, 4]);
      await expectLater(
        writer.writeAll(IoSlice(Uint8List(1))),
        throwsA(isA<RangeError>()),
      );
    });

    test('take and chain', () async {
      final a = Uint8ListReader(Uint8List.fromList([1, 2, 3, 4]));
      final b = Uint8ListReader(Uint8List.fromList([5, 6]));
      final chained = a.take(3).chain(b);
      final out = await chained.readToEnd();
      expect(out.toUint8List(), [1, 2, 3, 5, 6]);
    });

    test('BufReader readLine and BufWriter flush', () async {
      final source = Uint8ListReader(
        Uint8List.fromList('one\ntwo\r\nthree'.codeUnits),
      );
      final buffered = BufReader(source, capacity: 3);
      expect(await readLine(buffered), 'one');
      expect(await readLine(buffered), 'two');
      expect(await readLine(buffered), 'three');
      expect(await readLine(buffered), isNull);

      final target = BytesMutAsyncWriter();
      final writer = BufWriter(target, capacity: 4);
      await writer.writeAll(
        IoSlice(Uint8List.fromList('hello world'.codeUnits)),
      );
      expect(target.mut.length, 8);
      await writer.flush();
      expect(target.freeze().toUint8List(), 'hello world'.codeUnits);
    });

    test('readToEnd limit and readerStream', () async {
      final reader = Uint8ListReader(Uint8List.fromList([1, 2, 3, 4, 5]));
      await expectLater(
        reader.readToEnd(limit: 3),
        throwsA(isA<LimitExceeded>()),
      );

      final chunks = await readerStream(
        Uint8ListReader(Uint8List.fromList([1, 2, 3, 4, 5])),
        bufferSize: 2,
      ).toList();
      expect(chunks.expand((e) => e).toList(), [1, 2, 3, 4, 5]);
    });
  });

  group('AsyncFile adapters', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}async_io_'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      path = '${dir.path}${Platform.pathSeparator}data.bin';
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('sequential read and write over AsyncFile', () async {
      final data = Uint8List.fromList([
        for (var i = 0; i < 4096; i++) i & 0xFF,
      ]);
      File(path).writeAsBytesSync(data);

      final reader = await AsyncFile.open(
        path,
        options: const FileOptions(mode: FileMode.read, create: false),
      );
      final roundtrip = await reader.readToEnd();
      expect(roundtrip.toUint8List(), data);
      await reader.close();

      final target = '${dir.path}${Platform.pathSeparator}out.bin';
      final writer = await AsyncFile.open(
        target,
        options: const FileOptions(mode: FileMode.readWrite, truncate: true),
      );
      await writer.writeAll(IoSlice(data));
      await writer.flush();
      await writer.close();
      expect(File(target).readAsBytesSync(), data);
    });
  });
}
