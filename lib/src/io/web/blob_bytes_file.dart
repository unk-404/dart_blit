/// Read-only random access over a Web `Blob` / `File`.
///
/// Blobs are immutable, so this backend exposes only the read side of
/// [BytesFile]. Small blobs (up to [cacheLimit]) are materialized once and then
/// served from memory; larger blobs are read with `Blob.slice()` + `arrayBuffer`
/// per request, avoiding a whole-file copy.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../bytes_file.dart';
import 'js.dart';

/// A read-only [BytesFile] over an immutable Web Blob.
final class WebBlobBytesFile implements BytesFile {
  WebBlobBytesFile._(this._blob, this._cacheLimit) : _length = _blob.size;

  final JsBlob _blob;
  final int _cacheLimit;
  final int _length;
  Uint8List? _whole;
  bool _closed = false;

  /// Blob size in bytes.
  @override
  Future<int> get length async => _length;

  /// Creates a read-only file over [blob].
  ///
  /// [cacheLimit] is the largest Blob materialized into memory on first read;
  /// use `0` to always read through `slice()`. Default 8 MiB.
  static WebBlobBytesFile fromBlob(JSObject blob, {int cacheLimit = 8 << 20}) {
    if (cacheLimit < 0) throw RangeError.value(cacheLimit, 'cacheLimit');
    return WebBlobBytesFile._(jsBlobFromObject(blob), cacheLimit);
  }

  @override
  Future<int> readAt(
    int offset,
    Uint8List dst, {
    int start = 0,
    int? end,
  }) async {
    if (_closed) throw StateError('Blob is closed');
    final stop = end ?? dst.length;
    RangeError.checkValidRange(start, stop, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (start == stop || offset >= _length) return 0;
    final want = (stop - start) < (_length - offset)
        ? stop - start
        : _length - offset;
    if (want <= 0) return 0;

    if (_cacheLimit > 0 && _whole == null && _length <= _cacheLimit) {
      final buffer = await _blob.arrayBuffer().toDart;
      _whole = buffer.toDart.asUint8List();
    }
    final whole = _whole;
    if (whole != null) {
      dst.setRange(start, start + want, whole, offset);
      return want;
    }

    final slice = _blob.slice(offset, offset + want);
    final buffer = await slice.arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();
    final n = bytes.length < want ? bytes.length : want;
    dst.setRange(start, start + n, bytes);
    return n;
  }

  Never _readOnly() => throw StateError('Blob is read-only');

  @override
  Future<int> writeAt(
    int offset,
    Uint8List src, {
    int start = 0,
    int? end,
  }) async => _readOnly();

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) async =>
      _readOnly();

  @override
  Future<void> truncate(int newLength) async => _readOnly();

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    _closed = true;
    _whole = null;
  }

  @override
  Future<void> delete() async => _readOnly();

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsConcurrentReads => true;
}

/// Opens a read-only [BytesFile] over a Web Blob/File.
Future<WebBlobBytesFile> openBlobBytesFileTyped(
  JSObject blob, {
  int cacheLimit = 8 << 20,
}) async => WebBlobBytesFile.fromBlob(blob, cacheLimit: cacheLimit);

/// Opens a read-only [BytesFile] over a Web Blob/File.
Future<BytesFile> openBlobBytesFile(
  JSObject blob, {
  int cacheLimit = 8 << 20,
}) => openBlobBytesFileTyped(blob, cacheLimit: cacheLimit);


