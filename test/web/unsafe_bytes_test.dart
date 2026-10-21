// UnsafeBytes on the Web target.
@TestOn('browser')
library;

import 'package:blit/unsafe.dart';
import 'package:test/test.dart';

void main() {
  test('UnsafeBytes alloc/view/access/free on Web', () {
    final bytes = UnsafeBytes.alloc(16);
    try {
      expect(bytes.isNull, isFalse);
      final view = bytes.view(16);
      bytes.setInt32(0, 0x01020304);
      bytes.setFloat64(8, 2.5);
      expect(bytes.getInt32(0), 0x01020304);
      expect(bytes.getFloat64(8), 2.5);
      expect(view.length, 16);
    } finally {
      bytes.free();
    }
  });
  test('batch copy/fill/compare on Web', () {
    final a = UnsafeBytes.alloc(16);
    final b = UnsafeBytes.alloc(16);
    try {
      a.view(16).setAll(0, List.generate(16, (i) => i));
      unsafeCopy(b.address, a.address, 16);
      expect(unsafeCompare(a.address, b.address, 16), 0);
      unsafeFill(b.address, 0x55, 4);
      expect(b.view(4), everyElement(0x55));
      expect(unsafeCompare(a.address, b.address, 4), isNot(0));
    } finally {
      a.free();
      b.free();
    }
  });
}
