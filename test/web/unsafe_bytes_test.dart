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
}
