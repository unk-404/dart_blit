/// Differential fuzz tests for the web-safe core types.
///
/// Every property is checked against a `dart:typed_data` / `List<int>`
/// reference implementation, so the exact same file runs on the Dart VM and in
/// a browser:
///
///     dart test test/bytes_fuzz_test.dart
///     dart test -p chrome test/bytes_fuzz_test.dart
///
/// This file must not import `dart:io` (it is compiled for the browser too).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:blit/bytes.dart';
import 'package:test/test.dart';

/// Number of independent differential cases in the central accessor fuzz.
const int _fuzzCases = 10000;

// ---------------------------------------------------------------------------
// Deterministic value / reference helpers.
// ---------------------------------------------------------------------------

int _u8(math.Random rnd) => rnd.nextInt(0x100);

int _u16(math.Random rnd) => rnd.nextInt(0x10000);

/// A full 32-bit value built without relying on 64-bit shifts (web-safe).
int _u32(math.Random rnd) =>
    rnd.nextInt(0x10000) * 0x10000 + rnd.nextInt(0x10000);

Endian _endian(math.Random rnd) => rnd.nextBool() ? Endian.big : Endian.little;

Uint8List _randomBytes(math.Random rnd, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rnd.nextInt(0x100);
  }
  return out;
}

List<int> _be32(int value) => <int>[
  (value ~/ 0x1000000) & 0xFF,
  (value ~/ 0x10000) & 0xFF,
  (value ~/ 0x100) & 0xFF,
  value & 0xFF,
];

List<int> _le32(int value) => _be32(value).reversed.toList(growable: false);

List<int> _encode16(int value, Endian endian) => endian == Endian.big
    ? <int>[value >> 8, value & 0xFF]
    : <int>[value & 0xFF, value >> 8];

List<int> _encode32(int value, Endian endian) =>
    endian == Endian.big ? _be32(value) : _le32(value);

List<int> _encode64(Uint64 value, Endian endian) => endian == Endian.big
    ? <int>[..._be32(value.hi), ..._be32(value.lo)]
    : <int>[..._le32(value.lo), ..._le32(value.hi)];

/// Low [nbytes] bytes of [value] in big-endian order (mirrors `putUint`).
List<int> _bigEndianN(int value, int nbytes) {
  final out = List<int>.filled(nbytes, 0);
  var v = value;
  for (var i = nbytes - 1; i >= 0; i--) {
    out[i] = v & 0xFF;
    v = v ~/ 0x100;
  }
  return out;
}

List<int> _encodeFloat64(double value, Endian endian) {
  final data = ByteData(8)..setFloat64(0, value, endian);
  return <int>[for (var i = 0; i < 8; i++) data.getUint8(i)];
}

/// Bit-exact comparison of doubles without relying on 64-bit integers: the
/// browser canonicalises NaN payloads in both paths, so compare the two 32-bit
/// words instead of the numeric value.
(int, int) _float64Words(double value) {
  final data = ByteData(8)..setFloat64(0, value, Endian.big);
  return (data.getUint32(0), data.getUint32(4));
}

int _float32Bits(double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.big);
  return data.getUint32(0);
}

double _randomDouble(math.Random rnd) {
  switch (rnd.nextInt(8)) {
    case 0:
      return 0.0;
    case 1:
      return -0.0;
    case 2:
      return double.infinity;
    case 3:
      return double.negativeInfinity;
    case 4:
      return double.nan;
    default:
      return (rnd.nextDouble() - 0.5) * 1e12;
  }
}

int _compareLists(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length.compareTo(b.length);
}

/// Applies a random primitive `BytesMut` `put*` call and returns the exact
/// bytes it must have produced.
List<int> _putPrimitive(math.Random rnd, BytesMut mut) {
  switch (rnd.nextInt(7)) {
    case 0:
      final v = _u8(rnd);
      mut.putUint8(v);
      return <int>[v & 0xFF];
    case 1:
      final v = _u16(rnd);
      final endian = _endian(rnd);
      mut.putUint16(v, endian: endian);
      return _encode16(v, endian);
    case 2:
      final v = _u32(rnd);
      final endian = _endian(rnd);
      mut.putUint32(v, endian: endian);
      return _encode32(v, endian);
    case 3:
      final value = Uint64(_u32(rnd), _u32(rnd));
      final endian = _endian(rnd);
      mut.putUint64(value, endian: endian);
      return _encode64(value, endian);
    case 4:
      final v = _randomDouble(rnd);
      final endian = _endian(rnd);
      mut.putFloat64(v, endian: endian);
      return _encodeFloat64(v, endian);
    case 5:
      final nbytes = rnd.nextInt(9);
      final v = _u32(rnd);
      mut.putUint(v, nbytes);
      return _bigEndianN(v, nbytes);
    default:
      final block = _randomBytes(rnd, rnd.nextInt(8));
      mut.putSlice(block);
      return block.toList(growable: false);
  }
}

void main() {
  group('Bytes', () {
    test('getUint8/16/32/64 + float match ByteData in $_fuzzCases cases', () {
      final rnd = math.Random(0x51EED);
      for (var iter = 0; iter < _fuzzCases; iter++) {
        // Random view into a random backing buffer (exercises the offset).
        final backing = _randomBytes(rnd, rnd.nextInt(40));
        final offset = rnd.nextInt(backing.length + 1);
        final length = rnd.nextInt(backing.length - offset + 1);
        final view = Bytes.view(backing, offset, length);
        final ref = ByteData.sublistView(backing, offset, offset + length);

        expect(view.length, length);
        expect(view.isEmpty, length == 0);

        // --- 8-bit ---------------------------------------------------------
        if (length > 0) {
          final i = rnd.nextInt(length);
          expect(view[i], ref.getUint8(i));
          expect(view.getUint8(i), ref.getUint8(i));
          expect(() => view[length], throwsRangeError);
          expect(() => view[-1], throwsRangeError);
        } else {
          expect(() => view[0], throwsRangeError);
        }

        // --- 16-bit --------------------------------------------------------
        if (length >= 2) {
          final i = rnd.nextInt(length - 1);
          expect(view.getUint16(i), ref.getUint16(i));
          expect(
            view.getUint16(i, endian: Endian.little),
            ref.getUint16(i, Endian.little),
          );
          expect(() => view.getUint16(length - 1), throwsRangeError);
          expect(() => view.getUint16(-1), throwsRangeError);
        } else {
          expect(() => view.getUint16(0), throwsRangeError);
        }

        // --- 32-bit --------------------------------------------------------
        if (length >= 4) {
          final i = rnd.nextInt(length - 3);
          expect(view.getUint32(i), ref.getUint32(i));
          expect(
            view.getUint32(i, endian: Endian.little),
            ref.getUint32(i, Endian.little),
          );
          expect(() => view.getUint32(length - 3), throwsRangeError);
        } else {
          expect(() => view.getUint32(0), throwsRangeError);
        }

        // --- 64-bit --------------------------------------------------------
        if (length >= 8) {
          final i = rnd.nextInt(length - 7);
          expect(
            view.getUint64(i),
            Uint64(ref.getUint32(i), ref.getUint32(i + 4)),
          );
          expect(
            view.getUint64(i, endian: Endian.little),
            Uint64(
              ref.getUint32(i + 4, Endian.little),
              ref.getUint32(i, Endian.little),
            ),
          );
          expect(() => view.getUint64(length - 7), throwsRangeError);
        } else {
          expect(() => view.getUint64(0), throwsRangeError);
        }

        // --- floats (bit-exact, NaN-safe) ----------------------------------
        if (length >= 4) {
          final i = rnd.nextInt(length - 3);
          expect(
            _float32Bits(view.getFloat32(i)),
            _float32Bits(ref.getFloat32(i)),
          );
          expect(
            _float32Bits(view.getFloat32(i, endian: Endian.little)),
            _float32Bits(ref.getFloat32(i, Endian.little)),
          );
        }
        if (length >= 8) {
          final i = rnd.nextInt(length - 7);
          expect(
            _float64Words(view.getFloat64(i)),
            _float64Words(ref.getFloat64(i)),
          );
          expect(
            _float64Words(view.getFloat64(i, endian: Endian.little)),
            _float64Words(ref.getFloat64(i, Endian.little)),
          );
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('slice/copyTo/indexOf/compareTo match Uint8List in 3000 cases', () {
      final rnd = math.Random(0x51CE);
      for (var iter = 0; iter < 3000; iter++) {
        final backing = _randomBytes(rnd, rnd.nextInt(64));
        final start = rnd.nextInt(backing.length + 1);
        final end = start + rnd.nextInt(backing.length - start + 1);
        final view = Bytes.view(backing, start, end - start);
        final ref = backing.sublist(start, end);

        // Slice equivalence.
        final a = rnd.nextInt(ref.length + 1);
        final b = a + rnd.nextInt(ref.length - a + 1);
        expect(view.slice(a, b).toUint8List(), ref.sublist(a, b));
        expect(view.sublist(a, b).toUint8List(), ref.sublist(a, b));
        expect(view.slice(a).toUint8List(), ref.sublist(a));
        if (a < b) {
          expect(() => view.slice(b, a), throwsRangeError);
        }
        expect(() => view.slice(-1), throwsRangeError);
        expect(() => view.slice(0, ref.length + 1), throwsRangeError);

        // copyTo equivalence, including every valid start offset.
        final dstStart = rnd.nextInt(4);
        final dst = Uint8List(ref.length + 4);
        view.copyTo(dst, dstStart);
        expect(dst.sublist(dstStart, dstStart + ref.length), ref);
        expect(
          () => view.copyTo(Uint8List(ref.length + 1), 2),
          throwsRangeError,
        );

        // indexOf equivalence over [from, to).
        final probe = rnd.nextInt(0x100);
        final from = rnd.nextInt(ref.length + 1);
        final to = from + rnd.nextInt(ref.length - from + 1);
        var expectedIndex = -1;
        for (var i = from; i < to; i++) {
          if (ref[i] == probe) {
            expectedIndex = i;
            break;
          }
        }
        expect(view.indexOf(probe, from, to), expectedIndex);

        // compareTo / equality vs the reference list.
        final other = Bytes.fromList(_randomBytes(rnd, rnd.nextInt(70)));
        final otherRef = other.toUint8List();
        expect(view.compareTo(other), _compareLists(ref, otherRef));
        expect(other.compareTo(view), _compareLists(otherRef, ref));
        expect(view == Bytes.fromList(ref), true);
        expect(view.hashCode, Bytes.fromList(ref).hashCode);
        expect(view == other, _compareLists(ref, otherRef) == 0);
      }
    });
  });

  group('BytesMut', () {
    test('put*/freeze/split/truncate match a reference list in 5000 cases', () {
      final rnd = math.Random(0xB17E);
      for (var iter = 0; iter < 5000; iter++) {
        final mut = BytesMut(rnd.nextInt(8));
        final expected = <int>[];
        final steps = 1 + rnd.nextInt(12);
        for (var step = 0; step < steps; step++) {
          final kind = rnd.nextInt(15);
          if (kind <= 6) {
            expected.addAll(_putPrimitive(rnd, mut));
          } else if (kind == 7) {
            final block = Bytes.fromList(_randomBytes(rnd, rnd.nextInt(8)));
            mut.putBytes(block);
            expected.addAll(block.toUint8List());
          } else if (kind == 8) {
            final block = _randomBytes(rnd, rnd.nextInt(8));
            mut.putSlice(block);
            expected.addAll(block);
          } else if (kind == 9) {
            final byte = _u8(rnd);
            final count = rnd.nextInt(6);
            mut.putRepeated(byte, count);
            expected.addAll(List<int>.filled(count, byte));
          } else if (kind == 10) {
            // freeze() returns a stable view; the next mutation must copy.
            final frozen = mut.freeze();
            final snapshot = expected.toList(growable: false);
            final extra = _u8(rnd);
            mut.putUint8(extra);
            expected.add(extra);
            expect(frozen.toUint8List(), snapshot);
            expect(mut.isUnique, isTrue);
          } else if (kind == 11) {
            final at = rnd.nextInt(expected.length + 1);
            final head = mut.splitTo(at);
            expect(head.toUint8List(), expected.sublist(0, at));
            expected.removeRange(0, at);
          } else if (kind == 12) {
            final at = rnd.nextInt(expected.length + 1);
            final tail = mut.splitOff(at);
            expect(tail.toUint8List(), expected.sublist(at));
            expected.removeRange(at, expected.length);
          } else if (kind == 13) {
            final newLength = rnd.nextInt(expected.length + 1);
            mut.truncate(newLength);
            expected.removeRange(newLength, expected.length);
          } else {
            if (rnd.nextBool()) {
              mut.clear();
              expected.clear();
            } else {
              final extra = rnd.nextInt(64);
              mut.reserve(extra);
              expect(mut.capacity, greaterThanOrEqualTo(mut.length));
            }
          }
        }
        expect(mut.length, expected.length);
        expect(mut.asUint8List(), expected);
        expect(mut.toUint8List(), expected);
        expect(mut.capacity, greaterThanOrEqualTo(mut.length));
      }
    });

    test('error paths leave the buffer untouched', () {
      final mut = BytesMut.fromUint8List(Uint8List.fromList([1, 2, 3]));
      expect(() => mut.truncate(4), throwsRangeError);
      expect(() => mut.truncate(-1), throwsRangeError);
      expect(() => mut.splitTo(4), throwsRangeError);
      expect(() => mut.splitTo(-1), throwsRangeError);
      expect(() => mut.splitOff(4), throwsRangeError);
      expect(() => mut.splitOff(-1), throwsRangeError);
      expect(() => mut.putRepeated(1, -1), throwsRangeError);
      expect(() => mut.putUint(1, 9), throwsRangeError);
      expect(() => mut.putUint(1, -1), throwsRangeError);
      expect(() => mut.reserve(-1), throwsRangeError);
      expect(mut.toUint8List(), [1, 2, 3]);
      mut.truncate(1);
      expect(mut.toUint8List(), [1]);
    });
  });

  group('BytesReader', () {
    test('cursor semantics match a reference position in 3000 runs', () {
      final rnd = math.Random(0x5EAD);
      for (var iter = 0; iter < 3000; iter++) {
        final backing = _randomBytes(rnd, rnd.nextInt(65));
        final view = Bytes.fromUint8List(backing);
        var pos = rnd.nextInt(backing.length + 1);
        final reader = BytesReader(view, pos);
        final steps = 1 + rnd.nextInt(12);

        for (var step = 0; step < steps; step++) {
          switch (rnd.nextInt(11)) {
            case 0:
              if (reader.remaining >= 1) {
                expect(reader.readUint8(), backing[pos]);
                pos++;
              } else {
                expect(() => reader.readUint8(), throwsRangeError);
              }
            case 1:
              if (reader.remaining >= 2) {
                final endian = _endian(rnd);
                final expected = endian == Endian.big
                    ? (backing[pos] << 8) | backing[pos + 1]
                    : (backing[pos + 1] << 8) | backing[pos];
                expect(reader.readUint16(endian: endian), expected);
                pos += 2;
              } else {
                expect(() => reader.readUint16(), throwsRangeError);
              }
            case 2:
              if (reader.remaining >= 4) {
                final endian = _endian(rnd);
                var expected = 0;
                for (var i = 0; i < 4; i++) {
                  final b = backing[pos + (endian == Endian.big ? i : 3 - i)];
                  expected = expected * 0x100 + b;
                }
                expect(reader.readUint32(endian: endian), expected);
                pos += 4;
              } else {
                expect(() => reader.readUint32(), throwsRangeError);
              }
            case 3:
              if (reader.remaining >= 8) {
                final endian = _endian(rnd);
                final words = <int>[];
                for (var w = 0; w < 2; w++) {
                  var word = 0;
                  for (var i = 0; i < 4; i++) {
                    final index = pos + w * 4 + i;
                    final b = endian == Endian.big
                        ? backing[index]
                        : backing[pos + w * 4 + (3 - i)];
                    word = word * 0x100 + b;
                  }
                  words.add(word);
                }
                expect(
                  reader.readUint64(endian: endian),
                  endian == Endian.big
                      ? Uint64(words[0], words[1])
                      : Uint64(words[1], words[0]),
                );
                pos += 8;
              } else {
                expect(() => reader.readUint64(), throwsRangeError);
              }
            case 4:
              final n = rnd.nextInt(reader.remaining + 2);
              if (n <= reader.remaining) {
                expect(
                  reader.readBytes(n).toUint8List(),
                  backing.sublist(pos, pos + n),
                );
                pos += n;
              } else {
                expect(() => reader.readBytes(n), throwsRangeError);
              }
            case 5:
              final n = rnd.nextInt(reader.remaining + 2);
              final dst = Uint8List(n + 2);
              if (n <= reader.remaining) {
                expect(reader.readInto(dst, 1, 1 + n), n);
                expect(dst.sublist(1, 1 + n), backing.sublist(pos, pos + n));
                pos += n;
              } else {
                expect(() => reader.readInto(dst, 1, 1 + n), throwsRangeError);
              }
            case 6:
              final n = rnd.nextInt(reader.remaining + 2);
              if (n <= reader.remaining) {
                reader.advance(n);
                pos += n;
              } else {
                expect(() => reader.advance(n), throwsRangeError);
              }
            case 7:
              final n = rnd.nextInt(reader.remaining + 2);
              if (n <= reader.remaining) {
                reader.skip(n);
                pos += n;
              } else {
                expect(() => reader.skip(n), throwsRangeError);
              }
            case 8:
              final peekAt = rnd.nextInt(4) - 2;
              final index = pos + peekAt;
              if (index >= 0 && index < backing.length) {
                expect(reader.peekUint8(peekAt), backing[index]);
              } else {
                expect(() => reader.peekUint8(peekAt), throwsRangeError);
              }
            case 9:
              expect(reader.chunk().toUint8List(), backing.sublist(pos));
            default:
              expect(reader.buffer, view);
              expect(reader.position, pos);
              expect(reader.hasRemaining, pos < backing.length);
          }
          expect(reader.position, pos);
          expect(reader.remaining, backing.length - pos);
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('constructor validates the starting position', () {
      final bytes = Bytes.fromList([1, 2, 3]);
      expect(() => BytesReader(bytes, 4), throwsRangeError);
      expect(() => BytesReader(bytes, -1), throwsRangeError);
      expect(BytesReader(bytes, 3).remaining, 0);
      expect(BytesReader(bytes).chunk().length, 3);
    });
  });

  group('BytesWriter', () {
    test('put* matches a reference buffer in 5000 cases', () {
      final rnd = math.Random(0xB17EF);
      for (var iter = 0; iter < 5000; iter++) {
        final capacity = rnd.nextInt(33);
        final offset = rnd.nextInt(capacity + 1);
        final dst = Uint8List(capacity);
        final writer = BytesWriter(dst, offset);
        final expected = Uint8List(capacity); // all zero
        var pos = offset;
        final steps = rnd.nextInt(10);

        for (var step = 0; step < steps; step++) {
          // Each case yields the bytes the operation must write.
          var op = rnd.nextInt(7);
          if (op == 3 && writer.remaining < 8) {
            op = 6; // putUint64 is tested for its size check separately.
          }
          final List<int> encoded;
          final void Function() apply;
          switch (op) {
            case 0:
              final v = _u8(rnd);
              encoded = <int>[v];
              apply = () => writer.putUint8(v);
            case 1:
              final v = _u16(rnd);
              final endian = _endian(rnd);
              encoded = _encode16(v, endian);
              apply = () => writer.putUint16(v, endian: endian);
            case 2:
              final v = _u32(rnd);
              final endian = _endian(rnd);
              encoded = _encode32(v, endian);
              apply = () => writer.putUint32(v, endian: endian);
            case 3:
              final value = Uint64(_u32(rnd), _u32(rnd));
              final endian = _endian(rnd);
              encoded = _encode64(value, endian);
              apply = () => writer.putUint64(value, endian: endian);
            case 4:
              final v = _randomDouble(rnd);
              final endian = _endian(rnd);
              encoded = _encodeFloat64(v, endian);
              apply = () => writer.putFloat64(v, endian: endian);
            case 5:
              final nbytes = rnd.nextInt(9);
              final v = _u32(rnd);
              encoded = _bigEndianN(v, nbytes);
              apply = () => writer.putUint(v, nbytes);
            case 6:
              final block = _randomBytes(rnd, rnd.nextInt(8));
              encoded = block.toList(growable: false);
              apply = () => writer.putSlice(block);
            default:
              throw StateError('unreachable');
          }

          if (encoded.length > writer.remaining) {
            final before = writer.position;
            expect(apply, throwsRangeError);
            expect(
              writer.position,
              before,
              reason: 'failed put must not advance the cursor',
            );
            continue;
          }
          apply();
          expected.setRange(pos, pos + encoded.length, encoded);
          pos += encoded.length;
          expect(writer.position, pos);
        }

        expect(writer.finish(), expected.sublist(0, pos));
        // The writer must never touch bytes outside [offset, position).
        if (pos < capacity) {
          expect(dst.sublist(pos), List<int>.filled(capacity - pos, 0));
        }
        if (offset > 0 && pos > offset) {
          expect(dst.sublist(0, offset), List<int>.filled(offset, 0));
        }
      }
    });

    test('overflow and construction errors', () {
      final dst = Uint8List(4);
      expect(() => BytesWriter(dst, 5), throwsRangeError);
      expect(() => BytesWriter(dst, -1), throwsRangeError);

      final oneByte = BytesWriter(Uint8List(1));
      expect(() => oneByte.putUint16(1), throwsRangeError);
      expect(oneByte.position, 0);

      final twoBytes = BytesWriter(Uint8List(2));
      expect(() => twoBytes.putUint32(1), throwsRangeError);
      expect(twoBytes.position, 0);

      final writer = BytesWriter(dst);
      expect(() => writer.putFloat64(1.0), throwsRangeError);
      expect(writer.position, 0);
      expect(() => writer.putSlice(Uint8List(5)), throwsRangeError);
      expect(writer.position, 0);
      expect(() => writer.putRepeated(1, 5), throwsRangeError);
      expect(writer.position, 0);
      expect(() => writer.putUint(1, 5), throwsRangeError);
      expect(writer.position, 0);
      expect(() => writer.putUint(1, -1), throwsRangeError);
      expect(() => writer.putUint(1, 9), throwsRangeError);
      // putUint64 validates the full 8 bytes before writing, so a failure is
      // atomic even when 4..7 bytes are still free.
      final eightByteDst = Uint8List(4);
      final eightByteWriter = BytesWriter(eightByteDst);
      expect(
        () => eightByteWriter.putUint64(const Uint64(1, 2)),
        throwsRangeError,
      );
      expect(eightByteWriter.position, 0);
      expect(eightByteDst, [0, 0, 0, 0]);

      final empty = BytesWriter(Uint8List(0));
      expect(empty.remaining, 0);
      expect(empty.hasRemaining, isFalse);
      expect(() => empty.putUint8(1), throwsRangeError);
      expect(empty.finish(), isEmpty);
    });

    test('writer over a sub-range is limited to that range', () {
      final dst = Uint8List(8);
      final writer = BytesWriter(dst, 2);
      writer.putUint32(0xDEADBEEF);
      expect(writer.position, 6);
      expect(dst, [0, 0, 0xDE, 0xAD, 0xBE, 0xEF, 0, 0]);
      expect(() => writer.putUint32(1), throwsRangeError);
      expect(writer.position, 6);
    });
  });

  group('putUint64 little-endian regression', () {
    test('encodes standard LE limbs and round-trips', () {
      const value = Uint64(0x11223344, 0x55667788);
      const expected = <int>[
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, //
      ];

      final mut = BytesMut()..putUint64(value, endian: Endian.little);
      expect(mut.toUint8List(), expected);
      expect(mut.freeze().getUint64(0, endian: Endian.little), value);

      final dst = Uint8List(8);
      BytesWriter(dst).putUint64(value, endian: Endian.little);
      expect(dst, expected);
      expect(
        Bytes.fromUint8List(dst).getUint64(0, endian: Endian.little),
        value,
      );
    });
  });

  group('Bytes factories and edges', () {
    test('views, copies and empty values', () {
      expect(Bytes.empty.length, 0);
      expect(Bytes.empty.isEmpty, isTrue);
      expect(() => Bytes.empty[0], throwsRangeError);
      expect(() => Bytes.empty.getUint16(0), throwsRangeError);
      expect(Bytes.empty.slice(0, 0).length, 0);
      expect(() => Bytes.empty.slice(0, 1), throwsRangeError);

      final one = Bytes.fromList([0xAB]);
      expect(one.getUint8(0), 0xAB);
      expect(() => one.getUint16(0), throwsRangeError);
      expect(() => one.getUint32(0), throwsRangeError);
      expect(() => one.getUint64(0), throwsRangeError);
      expect(() => one.getFloat32(0), throwsRangeError);
      expect(() => one.getFloat64(0), throwsRangeError);

      // fromByteData shares the buffer.
      final data = ByteData(4)..setUint32(0, 0xDEADBEEF);
      final fromData = Bytes.fromByteData(data);
      expect(fromData.getUint32(0), 0xDEADBEEF);
      data.setUint32(0, 1);
      expect(fromData.getUint32(0), 1);

      // fromByteBuffer covers the whole buffer.
      final bufferView = ByteData(4)..setUint32(0, 0x01020304);
      expect(Bytes.fromByteBuffer(bufferView.buffer).getUint32(0), 0x01020304);

      // copyOf copies; fromUint8List does not.
      final src = Uint8List.fromList([1, 2, 3, 4]);
      final copy = Bytes.copyOf(src, 1, 3);
      final shared = Bytes.fromUint8List(src);
      src[1] = 99;
      expect(copy.toUint8List(), [2, 3]);
      expect(shared.getUint8(1), 99);
      expect(() => Bytes.copyOf(src, 3, 1), throwsRangeError);
      expect(() => Bytes.view(src, 3, 2), throwsRangeError);
      expect(() => Bytes.view(src, -1), throwsRangeError);

      // Maximum u64 and comparison helpers.
      final max = Bytes.fromList(List<int>.filled(8, 0xFF));
      expect(max.getUint64(0), Uint64.max);
      expect(max.getUint64(0).toInt32(), 0xFFFFFFFF);
      expect(max.compareTo(Bytes.fromList(List<int>.filled(8, 0xFE))), 1);
      expect(max.compareTo(max), 0);
      expect(Bytes.fromList([1, 2]).compareTo(Bytes.fromList([1, 2, 0])), -1);

      // copyTo exact fit and overflow.
      final dst = Uint8List(4);
      Bytes.fromList([1, 2]).copyTo(dst, 2);
      expect(dst, [0, 0, 1, 2]);
      expect(
        () => Bytes.fromList([1, 2]).copyTo(Uint8List(3), 2),
        throwsRangeError,
      );
    });
  });
}
