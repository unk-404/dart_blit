// v0.2.0 simple API on the Web target.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:blit/blit_web.dart';
import 'package:blit/src/io/web/js.dart';
import 'package:test/test.dart';

final _path =
    'v2-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}.bin';

void main() {
  test('blit write/read/append/delete over OPFS', () async {
    try {
      await blit.write(_path, Uint8List.fromList([1, 2, 3]));
      expect((await blit.read(_path)).toUint8List(), [1, 2, 3]);
      await blit.append(_path, Uint8List.fromList([4]));
      expect((await blit.read(_path)).toUint8List(), [1, 2, 3, 4]);
      final file = await blit.open(_path);
      expect((await file.readAt(1, 2)).toUint8List(), [2, 3]);
      await file.close();
    } finally {
      await blit.delete(_path);
    }
  });

  test('openIndexedDb simple facade', () async {
    final path = 'idb-$_path';
    final file = await openIndexedDb(path);
    try {
      await file.write(Uint8List.fromList([1, 2, 3]));
      expect((await file.readAll()).toUint8List(), [1, 2, 3]);
    } finally {
      await file.delete();
    }
  });
  test('openBlob exposes a read-only simple file', () async {
    final data = Uint8List.fromList([9, 8, 7, 6]);
    final blob = JsBlob(<JSAny>[data.toJS].toJS);
    final file = await openBlob(blob);
    try {
      expect((await file.readAll()).toUint8List(), data);
      expect((await file.readAt(1, 2)).toUint8List(), [8, 7]);
    } finally {
      await file.close();
    }
  });
}
