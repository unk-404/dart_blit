/// Exact unsigned 64-bit integer, implemented as two unsigned 32-bit limbs.
///
/// This type works identically on the Dart VM, dart2js and dart2wasm:
/// - the VM's `int` is already 64-bit, but it is **signed**;
/// - dart2js has no 64-bit typed-data support and its bitwise operators are
///   32-bit, so `hi`/`lo` limbs are the only portable representation;
/// - `Uint64List`/`ByteData.getUint64` throw on dart2js.
///
/// Use [Uint64] at API boundaries and for protocol/u64 values (hashes,
/// varints, timestamps, ZIP64 fields).  Do **not** use it in a hot loop on the
/// native VM: a plain `int` is a 64-bit value there and is faster.
///
/// Both [hi] and [lo] are in `0..0xFFFFFFFF`; the value is
/// `hi * 2^32 + lo`.
library;

import 'dart:typed_data';

const int _mask32 = 0xFFFFFFFF;
const int _base32 = 0x100000000;
const int _mask16 = 0xFFFF;

/// Exact unsigned 64-bit value.
final class Uint64 implements Comparable<Uint64> {
  /// High 32 bits (`0..0xFFFFFFFF`).
  final int hi;

  /// Low 32 bits (`0..0xFFFFFFFF`).
  final int lo;

  const Uint64(this.hi, this.lo);

  static const Uint64 zero = Uint64(0, 0);
  static const Uint64 one = Uint64(0, 1);
  static const Uint64 max = Uint64(_mask32, _mask32);

  /// Creates a value from a non-negative Dart `int`.
  ///
  /// On dart2js only values up to `2^53 - 1` are exact; larger inputs are
  /// already imprecise before they reach this constructor.  Use [parse] for
  /// full-width web values.
  factory Uint64.fromInt(int value) {
    if (value < 0) {
      throw RangeError.value(value, 'value', 'must be non-negative');
    }
    return Uint64(value ~/ _base32, value % _base32);
  }

  /// Creates a value from two limbs without range checks (internal fast path).
  factory Uint64.fromLimbs(int hi, int lo) => Uint64(hi & _mask32, lo & _mask32);

  static Uint64 parse(String source, {int radix = 10}) {
    if (radix < 2 || radix > 36) {
      throw RangeError.range(radix, 2, 36, 'radix');
    }
    var result = zero;
    for (final unit in source.codeUnits) {
      int digit;
      if (unit >= 0x30 && unit <= 0x39) {
        digit = unit - 0x30;
      } else if (unit >= 0x41 && unit <= 0x5A) {
        digit = unit - 0x41 + 10;
      } else if (unit >= 0x61 && unit <= 0x7A) {
        digit = unit - 0x61 + 10;
      } else {
        throw FormatException('Invalid digit', source);
      }
      if (digit >= radix) throw FormatException('Invalid digit', source);
      result = result._mulSmall(radix)._addSmall(digit);
    }
    return result;
  }

  bool get isZero => hi == 0 && lo == 0;
  bool get isMax => hi == _mask32 && lo == _mask32;

  /// Converts to `int` only when the value is exactly representable on every
  /// target (`< 2^53`).  Otherwise throws [RangeError].
  int toInt() {
    if (hi > 0x1FFFFF) {
      throw RangeError('Uint64 value does not fit in 53 bits');
    }
    return hi * _base32 + lo;
  }

  /// Like [toInt] but wraps to the low 32 bits (never throws).
  int toInt32() => lo;

  double toDouble() => hi * 4294967296.0 + lo;

  bool get isOdd => (lo & 1) == 1;

  int get bitLength {
    var v = hi;
    if (v != 0) {
      var n = 0;
      while (v != 0) {
        v = v >> 1;
        n++;
      }
      return 32 + n;
    }
    v = lo;
    var n = 0;
    while (v != 0) {
      v = v >> 1;
      n++;
    }
    return n;
  }

  Uint64 operator +(Uint64 other) {
    final low = lo + other.lo;
    final carry = low >= _base32 ? 1 : 0;
    return Uint64((hi + other.hi + carry) & _mask32, low & _mask32);
  }

  Uint64 operator -(Uint64 other) {
    final low = lo - other.lo;
    final borrow = low < 0 ? 1 : 0;
    return Uint64((hi - other.hi - borrow) & _mask32, low & _mask32);
  }

  Uint64 operator &(Uint64 other) => Uint64(hi & other.hi, lo & other.lo);

  Uint64 operator |(Uint64 other) => Uint64(hi | other.hi, lo | other.lo);

  Uint64 operator ^(Uint64 other) => Uint64(hi ^ other.hi, lo ^ other.lo);

  Uint64 operator ~() => Uint64(~hi & _mask32, ~lo & _mask32);

  /// Logical left shift; `n` must be in `0..63`.
  Uint64 operator <<(int n) {
    if (n < 0 || n > 63) {
      throw RangeError.range(n, 0, 63, 'n');
    }
    if (n == 0) return this;
    if (n >= 32) {
      final shift = n - 32;
      return Uint64((lo << shift) & _mask32, 0);
    }
    return Uint64(
      ((hi << n) | (lo >> (32 - n))) & _mask32,
      (lo << n) & _mask32,
    );
  }

  /// Logical right shift; `n` must be in `0..63`.
  Uint64 operator >>(int n) {
    if (n < 0 || n > 63) {
      throw RangeError.range(n, 0, 63, 'n');
    }
    if (n == 0) return this;
    if (n >= 32) {
      return Uint64(0, hi >> (n - 32));
    }
    return Uint64(
      hi >> n,
      ((lo >> n) | (hi << (32 - n))) & _mask32,
    );
  }

  /// Alias for [>>] with explicit unsigned semantics (as in Dart's `>>>`).
  Uint64 operator >>>(int n) => this >> n;

  /// Low 64 bits of the product (wrapping, like Rust's `u64::wrapping_mul`).
  Uint64 operator *(Uint64 other) {
    final a0 = lo & _mask16;
    final a1 = (lo ~/ 0x10000) & _mask16;
    final a2 = hi & _mask16;
    final a3 = (hi ~/ 0x10000) & _mask16;
    final b0 = other.lo & _mask16;
    final b1 = (other.lo ~/ 0x10000) & _mask16;
    final b2 = other.hi & _mask16;
    final b3 = (other.hi ~/ 0x10000) & _mask16;

    var r0 = a0 * b0;
    var r1 = a0 * b1 + a1 * b0 + (r0 ~/ 0x10000);
    var r2 = a0 * b2 + a1 * b1 + a2 * b0 + (r1 ~/ 0x10000);
    var r3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + (r2 ~/ 0x10000);

    final w0 = r0 & _mask16;
    final w1 = r1 & _mask16;
    final w2 = r2 & _mask16;
    final w3 = r3 & _mask16;
    return Uint64((w2 | (w3 << 16)) & _mask32, (w0 | (w1 << 16)) & _mask32);
  }

  /// Wrapping multiply by a small non-negative integer (`0..2^31-1`).
  Uint64 _mulSmall(int m) {
    final low = lo * m;
    final carry = low ~/ _base32;
    return Uint64((hi * m + carry) & _mask32, low & _mask32);
  }

  Uint64 _addSmall(int v) {
    final low = lo + v;
    final carry = low >= _base32 ? 1 : 0;
    return Uint64((hi + carry) & _mask32, low & _mask32);
  }

  /// Unsigned division and remainder.
  ({Uint64 quotient, Uint64 remainder}) divMod(Uint64 divisor) {
    if (divisor.isZero) throw UnsupportedError('Division by zero');
    if (compareTo(divisor) < 0) return (quotient: zero, remainder: this);
    if (divisor == one) return (quotient: this, remainder: zero);

    var q = zero;
    var r = zero;
    for (var i = 63; i >= 0; i--) {
      final bit = i >= 32 ? (hi >> (i - 32)) & 1 : (lo >> i) & 1;
      final carry = (r.hi & 0x80000000) != 0;
      r = Uint64(
        ((r.hi << 1) | (r.lo >> 31)) & _mask32,
        (r.lo << 1) & _mask32,
      );
      if (bit == 1) r = r._addSmall(1);
      if (carry || r.compareTo(divisor) >= 0) {
        r = r - divisor;
        q = q | (one << i);
      }
    }
    return (quotient: q, remainder: r);
  }

  Uint64 operator ~/(Uint64 other) => divMod(other).quotient;

  Uint64 operator %(Uint64 other) => divMod(other).remainder;

  @override
  int compareTo(Uint64 other) {
    if (hi != other.hi) return hi < other.hi ? -1 : 1;
    if (lo != other.lo) return lo < other.lo ? -1 : 1;
    return 0;
  }

  bool operator <(Uint64 other) => compareTo(other) < 0;
  bool operator <=(Uint64 other) => compareTo(other) <= 0;
  bool operator >(Uint64 other) => compareTo(other) > 0;
  bool operator >=(Uint64 other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Uint64 && other.hi == hi && other.lo == lo;

  @override
  int get hashCode => Object.hash(hi, lo);

  @override
  String toString() => toRadixString(10);

  String toRadixString(int radix) {
    if (radix < 2 || radix > 36) {
      throw RangeError.range(radix, 2, 36, 'radix');
    }
    if (isZero) return '0';
    var h = hi;
    var l = lo;
    final digits = <int>[];
    while (h != 0 || l != 0) {
      var rem = 0;
      final curHi = rem * _base32 + h;
      final qHi = curHi ~/ radix;
      rem = curHi % radix;
      final curLo = rem * _base32 + l;
      final qLo = curLo ~/ radix;
      rem = curLo % radix;
      h = qHi;
      l = qLo;
      digits.add(rem);
    }
    final out = Uint8List(digits.length);
    for (var i = 0; i < digits.length; i++) {
      final d = digits[digits.length - 1 - i];
      out[i] = d < 10 ? 0x30 + d : 0x61 + (d - 10);
    }
    return String.fromCharCodes(out);
  }

  /// Writes this value in big-endian (default) or little-endian order.
  void writeTo(ByteData data, int offset, {Endian endian = Endian.big}) {
    if (endian == Endian.big) {
      data.setUint32(offset, hi);
      data.setUint32(offset + 4, lo);
    } else {
      data.setUint32(offset, lo, Endian.little);
      data.setUint32(offset + 4, hi, Endian.little);
    }
  }

  /// Reads a u64 from `data`; works on every target (unlike
  /// `ByteData.getUint64`, which throws on dart2js).
  static Uint64 readFrom(ByteData data, int offset,
      {Endian endian = Endian.big}) {
    if (endian == Endian.big) {
      return Uint64(data.getUint32(offset), data.getUint32(offset + 4));
    }
    return Uint64(data.getUint32(offset + 4, Endian.little),
        data.getUint32(offset, Endian.little));
  }
}
