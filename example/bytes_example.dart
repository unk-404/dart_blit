import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes.dart';

Future<void> main() async {
  // Zero-copy view and O(1) slicing.
  final backing = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
  final bytes = Bytes.fromUint8List(backing);
  final slice = bytes.slice(2, 6);
  backing[2] = 99;
  print('slice[0] = ${slice[0]} (99: shared buffer)');

  // BE/LE readers and u64.
  final mut = BytesMut(16)
    ..putUint32(0x01020304)
    ..putUint64(Uint64(0x11223344, 0x55667788));
  final b = mut.freeze();
  print('u32 = 0x${b.getUint32(0).toRadixString(16)}');
  print('u64 = ${b.getUint64(4)}');

  // Native random-access file in the OS temp directory.
  final dir = await Directory.systemTemp.createTemp('blit_example_');
  final path = '${dir.path}${Platform.pathSeparator}demo.bin';
  final file = await openBytesFile(path);
  await file.writeAt(0, Uint8List.fromList([1, 2, 3, 4]));
  await file.append(Uint8List.fromList([5, 6]));
  final out = Uint8List(6);
  await file.readAt(0, out);
  print('file length = ${await file.length}, bytes = $out');
  await file.delete();
  await dir.delete();

  print('slice = $slice, mut = $mut');
}
