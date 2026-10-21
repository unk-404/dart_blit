/// The "just works" facade for v0.2.0.
library;

import 'dart:typed_data';

import '../bytes.dart';
import '../io/async_io.dart';
import 'async_file.dart';
import 'options.dart';

/// Simple random-access file facade.
final class BlitFile {
  BlitFile._(this._file);

  factory BlitFile.fromFile(AsyncFile file) => BlitFile._(file);

  final AsyncFile _file;

  String get path => _file.path;

  Future<int> get size => _file.length;

  Future<int> get length => size;

  bool get isClosed => _file.isClosed;

  int get position => _file.position;

  Future<Bytes> readAll({int? maxSize}) => _file.readToEnd(limit: maxSize);

  Future<Bytes> readAt(int offset, int length) async {
    if (length < 0) throw RangeError.value(length, 'length');
    final out = Uint8List(length);
    final n = await _file.readAt(offset, ReadBuf(out));
    return Bytes.view(out, 0, n);
  }

  Future<void> write(Object data) async {
    final bytes = _asBytes(data);
    await _file.truncate(0);
    await _file.writeAt(0, IoSlice(bytes));
  }

  Future<void> writeAt(int offset, Object data) async {
    await _file.writeAt(offset, IoSlice(_asBytes(data)));
  }

  Future<void> append(Object data) async {
    await _file.append(IoSlice(_asBytes(data)));
  }

  Future<void> flush() => _file.flush();

  Future<void> truncate(int newLength) => _file.truncate(newLength);

  Future<void> close() => _file.close();

  Future<void> delete() => _file.delete();
}

/// Simple top-level API.
final class Blit {
  const Blit();

  Future<BlitFile> open(
    String path, {
    FileOptions options = const FileOptions(mode: FileMode.readWrite),
  }) async => BlitFile._(await AsyncFile.open(path, options: options));

  Future<Bytes> read(String path, {int? maxSize}) async {
    final file = await open(
      path,
      options: const FileOptions(mode: FileMode.read, create: false),
    );
    try {
      return await file.readAll(maxSize: maxSize);
    } finally {
      await file.close();
    }
  }

  Future<void> write(String path, Object data) async {
    final file = await open(
      path,
      options: const FileOptions(mode: FileMode.write, truncate: true),
    );
    try {
      await file.write(data);
    } finally {
      await file.close();
    }
  }

  Future<void> append(String path, Object data) async {
    final file = await open(
      path,
      options: const FileOptions(mode: FileMode.readWrite),
    );
    try {
      await file.append(data);
    } finally {
      await file.close();
    }
  }

  Future<bool> exists(String path) async {
    try {
      final file = await open(
        path,
        options: const FileOptions(mode: FileMode.read, create: false),
      );
      await file.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> copy(String from, String to) async {
    final data = await read(from);
    await write(to, data);
  }

  Future<void> delete(String path) async {
    final file = await open(
      path,
      options: const FileOptions(mode: FileMode.readWrite, create: false),
    );
    try {
      await file.delete();
    } finally {
      if (!file.isClosed) await file.close();
    }
  }
}

/// The default "just works" API.
const blit = Blit();

Uint8List _asBytes(Object data) {
  if (data is Bytes) return data.asUint8List();
  if (data is Uint8List) return data;
  if (data is ByteData) {
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
  if (data is TypedData) {
    return Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
  }
  if (data is List<int>) return Uint8List.fromList(data);
  throw ArgumentError.value(data, 'data', 'expected bytes');
}
