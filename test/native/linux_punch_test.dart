@TestOn('linux')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory('${Directory.current.path}${Platform.pathSeparator}'
        '.dart_tool${Platform.pathSeparator}linux_punch_'
        '${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    path = '${dir.path}${Platform.pathSeparator}data.bin';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('punchHole deallocates without changing length', () {
    final file = openMmapFileSync(path);
    try {
      file.truncate(1 << 20);
      final pattern = Uint8List(4096)..fillRange(0, 4096, 0x6D);
      file.writeAt(0, pattern);
      file.writeAt(1 << 19, pattern);
      file.flush();

      file.punchHole(4096, 4096);
      file.flush();
      final out = Uint8List(4096);
      expect(file.readAt(4096, out), 4096);
      expect(out.every((b) => b == 0), isTrue);
      expect(file.length, 1 << 20);
    } finally {
      file.close();
    }
  });
}
