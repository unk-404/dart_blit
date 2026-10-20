// Read-only Web Blob backend tests.
//
// Run: dart test -p chrome test/web/blob_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:blit/src/io/web/js.dart';
import 'package:blit/src/io/web/web.dart';
import 'package:test/test.dart';

Uint8List _pattern(int n, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (seed + i * 17) & 0xFF]);

void main() {
  test('reads Blob slices and clamps at EOF', () async {
    final data = _pattern(10000);
    final blob = JsBlob(<JSAny>[data.toJS].toJS);
    final file = await openBlobBytesFile(blob, cacheLimit: 4096);
    try {
      expect(await file.length, 10000);
      final whole = Uint8List(10000);
      expect(await file.readAt(0, whole), 10000);
      expect(whole, data);

      final part = Uint8List(300);
      expect(await file.readAt(512, part), 300);
      expect(part, data.sublist(512, 812));

      final past = Uint8List(100);
      expect(await file.readAt(9990, past), 10);
      expect(past.sublist(0, 10), data.sublist(9990));
      expect(past.sublist(10), everyElement(0));
      expect(await file.readAt(10000, past), 0);

      await expectLater(
        file.writeAt(0, Uint8List(1)),
        throwsA(isA<StateError>()),
      );
      await expectLater(file.truncate(0), throwsA(isA<StateError>()));
    } finally {
      await file.close();
      expect(file.isClosed, isTrue);
    }
  });

  test('small Blob is cached; large path slices without whole copy', () async {
    final smallData = _pattern(2048, seed: 3);
    final small = JsBlob(<JSAny>[smallData.toJS].toJS);
    final smallFile = await openBlobBytesFile(small, cacheLimit: 4096);
    final a = Uint8List(64);
    final b = Uint8List(64);
    await smallFile.readAt(16, a);
    await smallFile.readAt(16, b);
    expect(a, smallData.sublist(16, 80));
    expect(b, a);
    await smallFile.close();

    final largeData = _pattern(16384, seed: 9);
    final large = JsBlob(<JSAny>[largeData.toJS].toJS);
    final largeFile = await openBlobBytesFile(large, cacheLimit: 0);
    final out = Uint8List(256);
    expect(await largeFile.readAt(8000, out), 256);
    expect(out, largeData.sublist(8000, 8256));
    await largeFile.close();
  });
}
