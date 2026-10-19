import 'dart:typed_data';

import 'package:blit/bytes.dart';
import 'package:test/test.dart';

void main() {
  group('Bytes', () {
    test('fromUint8List is zero-copy', () {
      final backing = Uint8List.fromList([1, 2, 3, 4]);
      final bytes = Bytes.fromUint8List(backing);
      backing[0] = 42;
      expect(bytes[0], 42);
      expect(bytes.length, 4);
    });

    test('slice is O(1) and shares memory', () {
      final backing = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final bytes = Bytes.fromUint8List(backing);
      final slice = bytes.slice(2, 5);
      expect(slice.length, 3);
      expect(slice[0], 3);
      backing[2] = 99;
      expect(slice[0], 99);
      expect(slice.slice(1, 3).toUint8List(), [4, 5]);
    });

    test('uint16/uint32 big and little endian', () {
      final b = Bytes.fromList(
          [0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]);
      expect(b.getUint16(0), 0x0102);
      expect(b.getUint16(0, endian: Endian.little), 0x0201);
      expect(b.getUint32(0), 0x01020304);
      expect(b.getUint32(0, endian: Endian.little), 0x04030201);
      expect(b.getUint32(4), 0xFFFFFFFF);
      expect(b.getUint32(4), 4294967295);
    });

    test('uint64 exact on every target', () {
      final b = Bytes.fromList([
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, //
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
      ]);
      expect(b.getUint64(0), const Uint64(0x11223344, 0x55667788));
      final le = b.getUint64(0, endian: Endian.little);
      expect(le, const Uint64(0x88776655, 0x44332211));
    });

    test('copyTo, equality, hashCode, indexOf', () {
      final a = Bytes.fromList([1, 2, 3]);
      final b = Bytes.fromList([1, 2, 3]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.indexOf(2), 1);
      expect(a.indexOf(2, 2), -1);
      final dst = Uint8List(5);
      a.copyTo(dst, 1);
      expect(dst, [0, 1, 2, 3, 0]);
    });

    test('fromString is UTF-8', () {
      expect(Bytes.fromString('hé').toUint8List(), [0x68, 0xC3, 0xA9]);
    });
  });

  group('BytesMut', () {
    test('put/get roundtrip', () {
      final m = BytesMut(4)
        ..putUint8(0xAB)
        ..putUint16(0x1234)
        ..putUint32(0xDEADBEEF)
        ..putUint64(const Uint64(0x01020304, 0x05060708));
      expect(m.length, 15);
      final b = m.freeze();
      expect(b.getUint8(0), 0xAB);
      expect(b.getUint16(1), 0x1234);
      expect(b.getUint32(3), 0xDEADBEEF);
      expect(b.getUint64(7), const Uint64(0x01020304, 0x05060708));
    });

    test('freeze view is stable after mutation (copy-on-write)', () {
      final m = BytesMut(2)..putUint8(1)..putUint8(2);
      final frozen = m.freeze();
      m.putUint8(3);
      expect(frozen.toUint8List(), [1, 2]);
      expect(m.toUint8List(), [1, 2, 3]);
      expect(m.isUnique, isTrue);
    });

    test('splitTo and splitOff are views', () {
      final m = BytesMut.fromUint8List(Uint8List.fromList([1, 2, 3, 4, 5]));
      final first = m.splitTo(2);
      expect(first.toUint8List(), [1, 2]);
      expect(m.toUint8List(), [3, 4, 5]);
      final tail = m.splitOff(2);
      expect(m.toUint8List(), [3, 4]);
      expect(tail.toUint8List(), [5]);
    });

    test('grows and compacts', () {
      final m = BytesMut(1);
      for (var i = 0; i < 100; i++) {
        m.putUint8(i);
      }
      expect(m.length, 100);
      expect(m.asUint8List()[99], 99);
      m.reserve(1000);
      expect(m.capacity, greaterThanOrEqualTo(1100));
      expect(m.asUint8List()[50], 50);
    });

    test('uint64 little-endian put/get roundtrip', () {
      const v = Uint64(0x11223344, 0x55667788);
      final m = BytesMut()..putUint64(v, endian: Endian.little);
      expect(m.toUint8List(),
          [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]);
      expect(m.freeze().getUint64(0, endian: Endian.little), v);

      final dst = Uint8List(8);
      BytesWriter(dst).putUint64(v, endian: Endian.little);
      expect(dst, [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]);
      expect(Bytes.fromUint8List(dst).getUint64(0, endian: Endian.little), v);
    });

    test('putUint64 insufficient space is atomic', () {
      final dst = Uint8List(7);
      final w = BytesWriter(dst);
      expect(() => w.putUint64(Uint64.one), throwsRangeError);
      expect(w.position, 0);
      expect(dst.every((b) => b == 0), isTrue);
    });

    test('putUint arbitrary width', () {
      final m = BytesMut(8)..putUint(0x0102030405, 5);
      expect(m.toUint8List(), [1, 2, 3, 4, 5]);
    });
  });

  group('reader/writer', () {
    test('roundtrip', () {
      final dst = Uint8List(32);
      final w = BytesWriter(dst)
        ..putUint8(1)
        ..putUint16(0x0203)
        ..putUint32(0x04050607)
        ..putUint64(const Uint64(0x08090A0B, 0x0C0D0E0F));
      final r = BytesReader(Bytes.fromUint8List(w.finish()));
      expect(r.readUint8(), 1);
      expect(r.readUint16(), 0x0203);
      expect(r.readUint32(), 0x04050607);
      expect(r.readUint64(), const Uint64(0x08090A0B, 0x0C0D0E0F));
      expect(r.hasRemaining, isFalse);
    });

    test('readBytes is a view and advances', () {
      final r = BytesReader(Bytes.fromList([1, 2, 3, 4]));
      expect(r.readBytes(2).toUint8List(), [1, 2]);
      expect(r.remaining, 2);
      expect(r.chunk().toUint8List(), [3, 4]);
      r.skip(2);
      expect(r.hasRemaining, isFalse);
    });
  });
}
