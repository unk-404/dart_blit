/// Native mmap-backed [BytesFile] with pointer read/write.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../address_io.dart';
import '../bytes_file.dart';
import 'mmap.dart';
import 'native_buffer.dart';

/// Wraps a native mmap file without exposing engine names to the simple API.
final class NativeMmapFile implements BytesFile, AddressIo {
  NativeMmapFile._(this._file);

  final MmapFile _file;

  static Future<NativeMmapFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    bool direct = false,
    bool largePages = false,
  }) async => NativeMmapFile._(
    await openMmapFile(
      path,
      create: create,
      readOnly: readOnly,
      direct: direct,
      largePages: largePages,
    ),
  );

  @override
  Future<int> get length async => _file.length;

  @override
  Future<int> readAt(
    int offset,
    Uint8List dst, {
    int start = 0,
    int? end,
  }) async => _file.readAt(offset, dst, start: start, end: end);

  @override
  Future<int> writeAt(
    int offset,
    Uint8List src, {
    int start = 0,
    int? end,
  }) async => _file.writeAt(offset, src, start: start, end: end);

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) async =>
      _file.writeAt(_file.length, src, start: start, end: end);

  @override
  Future<void> truncate(int newLength) async => _file.truncate(newLength);

  @override
  Future<void> flush() async => _file.flush();

  @override
  Future<void> close() async => _file.close();

  @override
  Future<void> delete() async {
    _file.close();
    final f = File(_file.path);
    if (await f.exists()) await f.delete();
  }

  @override
  bool get isClosed => _file.isClosed;

  @override
  bool get supportsConcurrentReads => false;

  @override
  int readAtAddress(int offset, int address, int length) =>
      _file.readAtPointer(offset, Pointer<Uint8>.fromAddress(address), length);

  @override
  int writeAtAddress(int offset, int address, int length) =>
      _file.writeAtPointer(offset, Pointer<Uint8>.fromAddress(address), length);

  /// Zero-copy read into caller-owned native memory.
  int readAtPointer(int offset, Pointer<Uint8> dst, int length) =>
      _file.readAtPointer(offset, dst, length);

  /// Zero-copy write from caller-owned native memory.
  int writeAtPointer(int offset, Pointer<Uint8> src, int length) =>
      _file.writeAtPointer(offset, src, length);

  /// Convenience wrapper for [NativeBuffer].
  int readIntoNative(int offset, NativeBuffer buffer) =>
      readAtPointer(offset, buffer.pointer, buffer.length);

  int writeFromNative(int offset, NativeBuffer buffer) =>
      writeAtPointer(offset, buffer.pointer, buffer.length);

  /// Reads the whole file into a native buffer, optionally from [pool].
  ///
  /// The caller owns the returned buffer and must [NativeBuffer.dispose] it or
  /// release it to [pool].
  Future<NativeBuffer> readAllNative({NativeBufferPool? pool}) async {
    final length = await this.length;
    final buffer = pool?.acquire(length) ?? NativeBuffer.allocate(length);
    try {
      final n = readIntoNative(0, buffer);
      if (n != length) {
        throw StateError('short native read: $n of $length');
      }
      return buffer;
    } catch (_) {
      pool?.release(buffer);
      rethrow;
    }
  }
}
