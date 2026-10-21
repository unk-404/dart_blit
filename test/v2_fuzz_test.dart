import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blit/blit_io.dart';
import 'package:test/test.dart';

void main() {
  test('AsyncFile differential fuzz vs in-memory oracle', () async {
    final dir = await Directory.systemTemp.createTemp('blit_v2_fuzz_');
    final path = '${dir.path}${Platform.pathSeparator}data.bin';
    final rnd = Random(12345);
    final file = await AsyncFile.open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, truncate: true),
    );
    var oracle = Uint8List(0);

    Uint8List grow(int length) {
      if (length <= oracle.length) return oracle;
      final next = Uint8List(length)..setRange(0, oracle.length, oracle);
      oracle = next;
      return next;
    }

    try {
      for (var step = 0; step < 300; step++) {
        final op = rnd.nextInt(3);
        if (op == 0) {
          final offset = rnd.nextInt(8192);
          final length = rnd.nextInt(512) + 1;
          final data = Uint8List.fromList([
            for (var i = 0; i < length; i++) rnd.nextInt(256),
          ]);
          final end = offset + length;
          grow(end);
          oracle.setRange(offset, end, data);
          final n = await file.writeAt(offset, IoSlice(data));
          expect(n, length);
        } else if (op == 1) {
          final length = rnd.nextInt(8192);
          await file.truncate(length);
          if (length < oracle.length) {
            oracle = Uint8List.sublistView(oracle, 0, length);
          } else {
            grow(length);
          }
        } else {
          final offset = rnd.nextInt(8192);
          final length = rnd.nextInt(1024);
          final out = Uint8List(length);
          final n = await file.readAt(offset, ReadBuf(out));
          expect(await file.length, oracle.length);
          if (offset >= oracle.length) {
            expect(n, 0);
            continue;
          }
          final want = min(length, oracle.length - offset);
          expect(n, want);
          expect(out.sublist(0, n), oracle.sublist(offset, offset + n));
          expect(out.sublist(n), everyElement(0));
        }
        expect(await file.length, oracle.length);
      }
    } finally {
      await file.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
