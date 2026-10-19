import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'bytes_file.dart';

/// Baseline native file backend built on `dart:io` `RandomAccessFile`.
///
/// It works on every native platform with zero FFI and is the correctness
/// fallback for the mmap/direct-I/O engine.  `readAt`/`writeAt` reuse the file
/// position, so a single instance must not be used concurrently from multiple
/// isolates; open one instance per isolate.
final class NativeBytesFile implements SyncBytesFile {
  final RandomAccessFile _raf;
  final String path;
  final bool readOnly;
  bool _closed = false;

  NativeBytesFile._(this._raf, this.path, this.readOnly);

  static Future<NativeBytesFile> open(String path,
      {bool create = true, bool readOnly = false}) async {
    final mode = _modeFor(path, create: create, readOnly: readOnly);
    final raf = await File(path).open(mode: mode);
    return NativeBytesFile._(raf, path, readOnly);
  }

  static NativeBytesFile openSync(String path,
      {bool create = true, bool readOnly = false}) {
    final mode = _modeFor(path, create: create, readOnly: readOnly);
    final raf = File(path).openSync(mode: mode);
    return NativeBytesFile._(raf, path, readOnly);
  }

  static FileMode _modeFor(String path,
      {required bool create, required bool readOnly}) {
    if (readOnly) return FileMode.read;
    // FileMode.append creates when missing and does not truncate; on the Dart
    // runtimes tested it still honours setPosition for random writes.
    if (create) return FileMode.append;
    if (!File(path).existsSync()) {
      throw FileSystemException('File does not exist', path);
    }
    return FileMode.append;
  }

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

  @override
  Future<int> get length async {
    _checkOpen();
    return _raf.length();
  }

  @override
  int get lengthSync {
    _checkOpen();
    return _raf.lengthSync();
  }

  @override
  Future<int> readAt(int offset, Uint8List dst,
      {int start = 0, int? end}) async {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    await _raf.setPosition(offset);
    return _raf.readIntoSync(dst, start, e);
  }

  @override
  int readAtSync(int offset, Uint8List dst, {int start = 0, int? end}) {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    _raf.setPositionSync(offset);
    return _raf.readIntoSync(dst, start, e);
  }

  @override
  Future<int> writeAt(int offset, Uint8List src,
      {int start = 0, int? end}) async {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    await _raf.setPosition(offset);
    _raf.writeFromSync(src, start, e);
    return e - start;
  }

  @override
  int writeAtSync(int offset, Uint8List src, {int start = 0, int? end}) {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    _raf.setPositionSync(offset);
    _raf.writeFromSync(src, start, e);
    return e - start;
  }

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) async {
    final len = await length;
    return writeAt(len, src, start: start, end: end);
  }

  @override
  int appendSync(Uint8List src, {int start = 0, int? end}) =>
      writeAtSync(lengthSync, src, start: start, end: end);

  @override
  Future<void> truncate(int newLength) async {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    await _raf.truncate(newLength);
  }

  @override
  void truncateSync(int newLength) {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    _raf.truncateSync(newLength);
  }

  @override
  Future<void> flush() async {
    _checkOpen();
    await _raf.flush();
  }

  @override
  void flushSync() {
    _checkOpen();
    _raf.flushSync();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }

  @override
  void closeSync() {
    if (_closed) return;
    _closed = true;
    _raf.closeSync();
  }

  @override
  Future<void> delete() async {
    await close();
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  bool get isClosed => _closed;

  @override
  String toString() => 'NativeBytesFile($path, readOnly: $readOnly)';
}
