import 'dart:math';
import 'dart:typed_data';

import 'package:blit/bytes.dart';
import 'package:test/test.dart';

final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

BigInt toBig(Uint64 v) => (BigInt.from(v.hi) << 32) | BigInt.from(v.lo);

Uint64 fromBig(BigInt value) {
  final v = value & _mask64;
  return Uint64((v >> 32).toInt(), (v & BigInt.from(0xFFFFFFFF)).toInt());
}

void main() {
  group('Uint64 basics', () {
    test('constants and fromInt', () {
      expect(Uint64.zero.isZero, isTrue);
      expect(Uint64.one, const Uint64(0, 1));
      expect(Uint64.max, const Uint64(0xFFFFFFFF, 0xFFFFFFFF));
      expect(Uint64.fromInt(0x123456789A), const Uint64(0x12, 0x3456789A));
      expect(() => Uint64.fromInt(-1), throwsRangeError);
    });

    test('toInt is checked; toDouble is approximate', () {
      expect(const Uint64(0, 42).toInt(), 42);
      expect(const Uint64(0x1FFFFF, 0xFFFFFFFF).toInt(),
          0x1FFFFF * 0x100000000 + 0xFFFFFFFF);
      expect(() => const Uint64(0x200000, 0).toInt(), throwsRangeError);
      expect(Uint64.max.toDouble(), closeTo(18446744073709551616.0, 1e4));
    });

    test('bitLength', () {
      expect(Uint64.zero.bitLength, 0);
      expect(Uint64.one.bitLength, 1);
      expect(const Uint64(0, 0x80000000).bitLength, 32);
      expect(const Uint64(1, 0).bitLength, 33);
      expect(Uint64.max.bitLength, 64);
    });

    test('comparison and equality', () {
      expect(const Uint64(0, 1) < const Uint64(0, 2), isTrue);
      expect(const Uint64(1, 0) > const Uint64(0, 0xFFFFFFFF), isTrue);
      expect(const Uint64(1, 2), const Uint64(1, 2));
      expect(const Uint64(1, 2).hashCode, const Uint64(1, 2).hashCode);
    });

    test('toString and parse', () {
      expect(Uint64.zero.toString(), '0');
      expect(Uint64.max.toString(), '18446744073709551615');
      expect(Uint64.parse('18446744073709551615'), Uint64.max);
      expect(Uint64.parse('deadbeef', radix: 16), const Uint64(0, 0xDEADBEEF));
    });

    test('byte order helpers', () {
      final bd = ByteData(8);
      const v = Uint64(0x11223344, 0x55667788);
      v.writeTo(bd, 0);
      expect(bd.getUint32(0), 0x11223344);
      expect(bd.getUint32(4), 0x55667788);
      expect(Uint64.readFrom(bd, 0), v);
      v.writeTo(bd, 0, endian: Endian.little);
      expect(bd.getUint32(0, Endian.little), 0x55667788);
      expect(bd.getUint32(4, Endian.little), 0x11223344);
      expect(Uint64.readFrom(bd, 0, endian: Endian.little), v);
    });
  });

  group('Uint64 arithmetic (fuzz vs BigInt)', () {
    final rnd = Random(1234567);
    int limb() => rnd.nextInt(1 << 16) * (1 << 16) + rnd.nextInt(1 << 16);
    Uint64 next() => Uint64(limb(), limb());

    test('add/sub/mul/bitwise', () {
      for (var i = 0; i < 2000; i++) {
        final a = next();
        final b = next();
        final ba = toBig(a);
        final bb = toBig(b);
        expect(toBig(a + b), (ba + bb) & _mask64, reason: 'add $a $b');
        expect(toBig(a - b), (ba - bb) & _mask64, reason: 'sub $a $b');
        expect(toBig(a * b), (ba * bb) & _mask64, reason: 'mul $a $b');
        expect(toBig(a & b), ba & bb);
        expect(toBig(a | b), ba | bb);
        expect(toBig(a ^ b), ba ^ bb);
        expect(toBig(~a), (~ba) & _mask64);
      }
    });

    test('shifts', () {
      for (var i = 0; i < 500; i++) {
        final a = next();
        final ba = toBig(a);
        for (var n = 0; n <= 63; n++) {
          expect(toBig(a << n), (ba << n) & _mask64, reason: 'shl $a $n');
          expect(toBig(a >> n), ba >> n, reason: 'shr $a $n');
          expect(toBig(a >>> n), ba >> n);
        }
      }
    });

    test('divMod', () {
      for (var i = 0; i < 2000; i++) {
        final a = next();
        var b = next();
        if (b.isZero) b = Uint64.one;
        final ba = toBig(a);
        final bb = toBig(b);
        final qr = a.divMod(b);
        expect(toBig(qr.quotient), ba ~/ bb, reason: 'div $a $b');
        expect(toBig(qr.remainder), ba % bb, reason: 'rem $a $b');
        expect(a ~/ b, qr.quotient);
        expect(a % b, qr.remainder);
      }
    });

    test('parse/toString roundtrip', () {
      for (var i = 0; i < 500; i++) {
        final a = next();
        expect(Uint64.parse(a.toString()), a);
        expect(Uint64.parse(a.toRadixString(16), radix: 16), a);
      }
    });

    test('range errors', () {
      expect(() => Uint64.one << 64, throwsRangeError);
      expect(() => Uint64.one >> -1, throwsRangeError);
      expect(() => Uint64.one.divMod(Uint64.zero), throwsUnsupportedError);
    });
  });
}
