// AsyncIO memory utilities on the Web target.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:blit/blit_io.dart';
import 'package:test/test.dart';

void main() {
  test('AsyncIO composes on Web without native-only imports', () async {
    final data = Uint8List.fromList([1, 2, 3, 4, 5]);
    final reader = Uint8ListReader(data);
    final out = BytesMutAsyncWriter();
    expect(await reader.copyTo(out), 5);
    expect(out.freeze().toUint8List(), data);

    final exact = Uint8List(2);
    await Uint8ListReader(data.sublist(3)).readExact(ReadBuf(exact));
    expect(exact, [4, 5]);
  });
}
