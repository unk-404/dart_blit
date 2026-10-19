import 'dart:typed_data';

import 'package:blit/bytes.dart';
import 'package:test/test.dart';

final class _CustomBytesLike implements BytesLike {
  _CustomBytesLike(this.data);
  final Uint8List data;

  @override
  int get length => data.length;

  @override
  Uint8List asUint8List() => data;
}

void main() {
  test('fromTypedData is zero-copy for Uint8List', () {
    final backing = Uint8List.fromList([1, 2, 3, 4]);
    final bytes = Bytes.fromTypedData(backing);
    expect(bytes.length, 4);
    backing[1] = 99;
    expect(bytes.getUint8(1), 99);
  });

  test('fromTypedData honors ByteData offset/length', () {
    final backing = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
    final data = ByteData.sublistView(backing, 2, 5);
    final bytes = Bytes.fromTypedData(data);
    expect(bytes.toUint8List(), [2, 3, 4]);
    backing[3] = 77;
    expect(bytes.getUint8(1), 77);
  });

  test('fromTypedData works for non-byte typed lists', () {
    final ints = Int32List.fromList([0x01020304, 0]);
    final bytes = Bytes.fromTypedData(ints);
    expect(bytes.length, 8);
    ints[1] = -1;
    expect(bytes.getUint8(4), 0xFF);
    expect(bytes.getUint8(7), 0xFF);
  });

  test('TypedData.asBytes and BytesLike.toBytes are zero-copy', () {
    final backing = Uint8List.fromList([1, 2, 3]);
    final viaTyped = backing.asBytes();
    backing[0] = 42;
    expect(viaTyped.getUint8(0), 42);

    final custom = _CustomBytesLike(backing);
    final viaLike = custom.toBytes();
    backing[1] = 43;
    expect(viaLike.getUint8(1), 43);
  });

  test('Bytes and BytesMut implement BytesLike', () {
    final bytes = Bytes.fromList([1, 2, 3]);
    final mut = BytesMut.fromBytes(bytes);
    expect(bytes, isA<BytesLike>());
    expect(mut, isA<BytesLike>());
    expect(Bytes.fromBytesLike(bytes), same(bytes));
    expect(Bytes.fromBytesLike(mut).toUint8List(), [1, 2, 3]);
  });
}
