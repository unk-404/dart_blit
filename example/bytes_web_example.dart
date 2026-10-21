// Web-safe example: compiles with `dart compile js` and runs in any browser.
//
// This file must not import `dart:ffi` or native-only `blit_native.dart`;
// only `package:blit/blit.dart` and `package:blit/blit_buffer.dart` are web-portable.
import 'package:blit/bytes.dart';

void main() {
  // Zero-copy view over a literal byte payload.
  final payload = Bytes.fromString('hello bytes');
  final tail = payload.slice(6); // O(1), shares `payload`'s buffer.
  print('payload = ${payload.length} bytes, tail = ${_asString(tail)}');

  // BytesMut encoding at API boundaries.
  final mut = BytesMut(12)
    ..putUint32(0xDEADBEEF)
    ..putUint64(Uint64.parse('18446744073709551615'));
  final encoded = mut.freeze();
  print('u32 = 0x${encoded.getUint32(0).toRadixString(16)}');
  print('u64 = ${encoded.getUint64(4)}');

  // Uint64 is exact on dart2js / dart2wasm too (no Uint64List involved).
  final max = encoded.getUint64(4);
  final wrapped = max + Uint64.one;
  print('max + 1 (wrapping) = $wrapped');
  print('max >> 32 = 0x${(max >> 32).toRadixString(16)}');
}

String _asString(Bytes bytes) => String.fromCharCodes(bytes.asUint8List());

