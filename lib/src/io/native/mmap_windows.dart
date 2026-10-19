// ignore_for_file: camel_case_types

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'mmap_base.dart';

// ---------------------------------------------------------------------------
// Win32 ffI bindings (x64, C calling convention)
// ---------------------------------------------------------------------------

typedef _CreateFileW_C = IntPtr Function(Pointer<Utf16>, Uint32, Uint32,
    Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileW = int Function(
    Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);

typedef _GetFileSizeEx_C = Int32 Function(IntPtr, Pointer<Int64>);
typedef _GetFileSizeEx = int Function(int, Pointer<Int64>);

typedef _CreateFileMappingW_C = IntPtr Function(IntPtr, Pointer<Void>, Uint32,
    Uint32, Uint32, Pointer<Utf16>);
typedef _CreateFileMappingW = int Function(
    int, Pointer<Void>, int, int, int, Pointer<Utf16>);

typedef _MapViewOfFile_C = Pointer<Uint8> Function(
    IntPtr, Uint32, Uint32, Uint32, Size);
typedef _MapViewOfFile = Pointer<Uint8> Function(int, int, int, int, int);

typedef _UnmapViewOfFile_C = Int32 Function(Pointer<Uint8>);
typedef _UnmapViewOfFile = int Function(Pointer<Uint8>);

typedef _FlushViewOfFile_C = Int32 Function(Pointer<Uint8>, Size);
typedef _FlushViewOfFile = int Function(Pointer<Uint8>, int);

typedef _FlushFileBuffers_C = Int32 Function(IntPtr);
typedef _FlushFileBuffers = int Function(int);

typedef _SetFilePointerEx_C = Int32 Function(
    IntPtr, Int64, Pointer<Int64>, Uint32);
typedef _SetFilePointerEx = int Function(int, int, Pointer<Int64>, int);

typedef _SetEndOfFile_C = Int32 Function(IntPtr);
typedef _SetEndOfFile = int Function(int);

typedef _DeviceIoControl_C = Int32 Function(IntPtr, Uint32, Pointer<Void>,
    Uint32, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _DeviceIoControl = int Function(
    int, int, Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>);

typedef _ReadFile_C = Int32 Function(
    IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _ReadFile = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);

typedef _WriteFile_C = Int32 Function(
    IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _WriteFile = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);

typedef _GetLastError_C = Uint32 Function();
typedef _GetLastError = int Function();

typedef _CloseHandle_C = Int32 Function(IntPtr);
typedef _CloseHandle = int Function(int);

typedef _Memset_C = Pointer<Void> Function(Pointer<Void>, Int32, Size);
typedef _Memset = Pointer<Void> Function(Pointer<Void>, int, int);

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _fileShareAll = 0x00000007;
const int _openExisting = 3;
const int _openAlways = 4;
const int _fileAttributeNormal = 0x80;
const int _pageReadOnly = 0x02;
const int _pageReadWrite = 0x04;
const int _fileMapRead = 0x0004;
const int _fileMapWrite = 0x0002;
const int _invalidHandle = -1;
const int _errorHandleEof = 38;
const int _fsctlSetSparse = 0x000900C4;
const int _mapAlignment = 64 * 1024;
const int _maxIoChunk = 1 << 30; // 1 GiB; ReadFile/WriteFile take a DWORD

class WindowsException implements Exception {
  final String operation;
  final int code;
  final String path;

  WindowsException(this.operation, this.code, this.path);

  @override
  String toString() => 'WindowsException: $operation failed '
      '(win32 error $code) for $path';
}

class _Win32 {
  final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary _crt = DynamicLibrary.open('msvcrt.dll');

  late final _CreateFileW createFileW =
      _k32.lookupFunction<_CreateFileW_C, _CreateFileW>('CreateFileW');
  late final _GetFileSizeEx getFileSizeEx =
      _k32.lookupFunction<_GetFileSizeEx_C, _GetFileSizeEx>('GetFileSizeEx');
  late final _CreateFileMappingW createFileMappingW =
      _k32.lookupFunction<_CreateFileMappingW_C, _CreateFileMappingW>(
          'CreateFileMappingW');
  late final _MapViewOfFile mapViewOfFile =
      _k32.lookupFunction<_MapViewOfFile_C, _MapViewOfFile>('MapViewOfFile');
  late final _UnmapViewOfFile unmapViewOfFile =
      _k32.lookupFunction<_UnmapViewOfFile_C, _UnmapViewOfFile>(
          'UnmapViewOfFile');
  late final _FlushViewOfFile flushViewOfFile =
      _k32.lookupFunction<_FlushViewOfFile_C, _FlushViewOfFile>(
          'FlushViewOfFile');
  late final _FlushFileBuffers flushFileBuffers =
      _k32.lookupFunction<_FlushFileBuffers_C, _FlushFileBuffers>(
          'FlushFileBuffers');
  late final _SetFilePointerEx setFilePointerEx =
      _k32.lookupFunction<_SetFilePointerEx_C, _SetFilePointerEx>(
          'SetFilePointerEx');
  late final _SetEndOfFile setEndOfFile =
      _k32.lookupFunction<_SetEndOfFile_C, _SetEndOfFile>('SetEndOfFile');
  late final _DeviceIoControl deviceIoControl =
      _k32.lookupFunction<_DeviceIoControl_C, _DeviceIoControl>(
          'DeviceIoControl');
  late final _ReadFile readFile =
      _k32.lookupFunction<_ReadFile_C, _ReadFile>('ReadFile');
  late final _WriteFile writeFile =
      _k32.lookupFunction<_WriteFile_C, _WriteFile>('WriteFile');
  late final _GetLastError getLastError =
      _k32.lookupFunction<_GetLastError_C, _GetLastError>('GetLastError');
  late final _CloseHandle closeHandle =
      _k32.lookupFunction<_CloseHandle_C, _CloseHandle>('CloseHandle');
  late final _Memset memset =
      _crt.lookupFunction<_Memset_C, _Memset>('memset');

  _Win32() {
    // Warm up every lazy lookupFunction once, before any operation whose
    // GetLastError we care about.  Otherwise the first lookup can reset the
    // thread's last error (observed on Dart 3.13.5).
    createFileW;
    getFileSizeEx;
    createFileMappingW;
    mapViewOfFile;
    unmapViewOfFile;
    flushViewOfFile;
    flushFileBuffers;
    setFilePointerEx;
    setEndOfFile;
    deviceIoControl;
    readFile;
    writeFile;
    getLastError;
    closeHandle;
    memset;
  }

  Never fail(String op, String path) =>
      throw WindowsException(op, getLastError(), path);
}

/// Windows implementation of [MmapFile] using pure `dart:ffi`.
final class WindowsMmapFile extends MmapFile {
  final _Win32 _win;
  final int _handle;
  final Set<WindowsMappedRegion> _regions = {};
  int _mapping = 0;
  int _size = 0;
  int _scratchCapacity = 0;
  Pointer<Uint8> _scratch = nullptr;
  bool _closed = false;

  @override
  final String path;
  @override
  final bool readOnly;

  WindowsMmapFile._(this._win, this._handle, this.path, this.readOnly);

  static Future<MmapFile> open(String path,
          {bool create = true, bool readOnly = false}) async =>
      openSync(path, create: create, readOnly: readOnly);

  static MmapFile openSync(String path,
      {bool create = true, bool readOnly = false}) {
    final win = _Win32();
    final p = path.toNativeUtf16();
    final int handle;
    try {
      handle = win.createFileW(
        p,
        readOnly ? _genericRead : (_genericRead | _genericWrite),
        _fileShareAll,
        nullptr,
        create ? _openAlways : _openExisting,
        _fileAttributeNormal,
        0,
      );
    } finally {
      malloc.free(p);
    }
    if (handle == _invalidHandle) {
      throw WindowsException('CreateFileW', win.getLastError(), path);
    }
    final file = WindowsMmapFile._(win, handle, path, readOnly);
    file._size = file._querySize();
    return file;
  }

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

  int _querySize() {
    final p = calloc<Int64>();
    try {
      if (_win.getFileSizeEx(_handle, p) == 0) {
        _win.fail('GetFileSizeEx', path);
      }
      return p.value;
    } finally {
      calloc.free(p);
    }
  }

  @override
  int get length {
    _checkOpen();
    _size = _querySize();
    return _size;
  }

  @override
  bool get isClosed => _closed;

  void _ensureMapping() {
    if (_mapping != 0) return;
    if (_size <= 0) {
      throw StateError('Cannot map an empty file; truncate it first: $path');
    }
    _mapping = _win.createFileMappingW(
      _handle,
      nullptr,
      readOnly ? _pageReadOnly : _pageReadWrite,
      0,
      0,
      nullptr,
    );
    if (_mapping == 0) _win.fail('CreateFileMappingW', path);
  }

  @override
  MappedRegion map({int offset = 0, int? length, bool writable = true}) {
    _checkOpen();
    if (writable && readOnly) {
      throw StateError('Cannot create a writable mapping for $path');
    }
    _size = _querySize();
    if (_size <= 0) {
      throw StateError('Cannot map an empty file: $path');
    }
    if (offset < 0 || offset > _size) {
      throw RangeError.range(offset, 0, _size, 'offset');
    }
    final len = length ?? (_size - offset);
    if (len < 0 || offset + len > _size) {
      throw RangeError.range(len, 0, _size - offset, 'length');
    }
    if (len == 0) throw RangeError.value(len, 'length', 'must be > 0');

    _ensureMapping();
    final base = offset - (offset % _mapAlignment);
    final delta = offset - base;
    final mapLength = len + delta;
    final ptr = _win.mapViewOfFile(
      _mapping,
      writable ? (_fileMapRead | _fileMapWrite) : _fileMapRead,
      (base ~/ 0x100000000) & 0xFFFFFFFF,
      base & 0xFFFFFFFF,
      mapLength,
    );
    if (ptr.address == 0) _win.fail('MapViewOfFile', path);
    final region = WindowsMappedRegion._(
        this, _win, ptr, mapLength, delta, offset, len, writable);
    _regions.add(region);
    return region;
  }

  void _removeRegion(WindowsMappedRegion region) {
    _regions.remove(region);
  }

  void _closeMapping() {
    for (final region in _regions.toList()) {
      region.close();
    }
    if (_mapping != 0) {
      _win.closeHandle(_mapping);
      _mapping = 0;
    }
  }

  void _ensureScratch(int needed) {
    if (needed <= _scratchCapacity) return;
    if (_scratch.address != 0) calloc.free(_scratch);
    var capacity = _scratchCapacity == 0 ? 1 << 20 : _scratchCapacity;
    while (capacity < needed) {
      capacity *= 2;
    }
    _scratch = calloc<Uint8>(capacity);
    _scratchCapacity = capacity;
  }

  int _readChunk(int offset, Pointer<Uint8> dst, int count) {
    final pos = calloc<Int64>();
    final read = calloc<Uint32>();
    try {
      if (_win.setFilePointerEx(_handle, offset, pos, 0) == 0) {
        _win.fail('SetFilePointerEx(read)', path);
      }
      final ok = _win.readFile(_handle, dst, count, read, nullptr);
      final err = _win.getLastError();
      if (ok == 0) {
        if (err == _errorHandleEof) return 0;
        throw WindowsException(
            'ReadFile(offset=$offset,count=$count,ok=$ok,err=$err)',
            err,
            path);
      }
      return read.value;
    } finally {
      calloc.free(read);
      calloc.free(pos);
    }
  }

  int _writeChunk(int offset, Pointer<Uint8> src, int count) {
    final pos = calloc<Int64>();
    final written = calloc<Uint32>();
    try {
      if (_win.setFilePointerEx(_handle, offset, pos, 0) == 0) {
        _win.fail('SetFilePointerEx(write)', path);
      }
      final ok = _win.writeFile(_handle, src, count, written, nullptr);
      final err = _win.getLastError();
      if (ok == 0) {
        throw WindowsException(
            'WriteFile(offset=$offset,count=$count,ok=$ok,err=$err)',
            err,
            path);
      }
      return written.value;
    } finally {
      calloc.free(written);
      calloc.free(pos);
    }
  }

  @override
  int readAt(int offset, Uint8List dst, {int start = 0, int? end}) {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    _size = _querySize();
    if (offset >= _size) return 0;
    final wanted = math.min(e - start, _size - offset);
    if (wanted <= 0) return 0;

    var done = 0;
    while (done < wanted) {
      final n = math.min(wanted - done, _maxIoChunk);
      _ensureScratch(n);
      final got = _readChunk(offset + done, _scratch, n);
      if (got <= 0) break;
      dst.setRange(start + done, start + done + got, _scratch.asTypedList(got));
      done += got;
      if (got < n) break;
    }
    return done;
  }

  @override
  int writeAt(int offset, Uint8List src, {int start = 0, int? end}) {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    final wanted = e - start;
    if (wanted == 0) return 0;

    var done = 0;
    while (done < wanted) {
      final n = math.min(wanted - done, _maxIoChunk);
      _ensureScratch(n);
      _scratch.asTypedList(n).setRange(0, n, src, start + done);
      final put = _writeChunk(offset + done, _scratch, n);
      done += put;
      if (put < n) break;
    }
    if (offset + done > _size) _size = offset + done;
    return done;
  }

  @override
  void truncate(int newLength, {bool sparse = true}) {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    _closeMapping();
    if (sparse && newLength > _size) {
      // Marking sparse before extending avoids NTFS zero-filling the gap when
      // a later write lands far beyond EOF (measured: 19.1s -> 0ms for 32GiB).
      _win.deviceIoControl(
          _handle, _fsctlSetSparse, nullptr, 0, nullptr, 0, nullptr, nullptr);
    }
    final newPos = calloc<Int64>();
    try {
      if (_win.setFilePointerEx(_handle, newLength, newPos, 0) == 0) {
        _win.fail('SetFilePointerEx', path);
      }
      if (_win.setEndOfFile(_handle) == 0) {
        _win.fail('SetEndOfFile', path);
      }
    } finally {
      calloc.free(newPos);
    }
    _size = newLength;
  }

  @override
  void flush() {
    _checkOpen();
    for (final region in _regions) {
      region.flush();
    }
    if (_win.flushFileBuffers(_handle) == 0) {
      _win.fail('FlushFileBuffers', path);
    }
  }

  @override
  void zeroize(int offset, int length) {
    _checkWritable();
    if (offset < 0 || length < 0 || offset + length > _size) {
      throw RangeError('zeroize range out of bounds');
    }
    if (length == 0) return;
    _ensureScratch(math.min(length, 1 << 20));
    _win.memset(_scratch.cast(), 0, _scratchCapacity);
    final zeros = _scratch.asTypedList(_scratchCapacity);
    var done = 0;
    while (done < length) {
      final n = math.min(length - done, zeros.length);
      done += writeAt(offset + done, zeros, start: 0, end: n);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closeMapping();
    if (_scratch.address != 0) {
      calloc.free(_scratch);
      _scratch = nullptr;
      _scratchCapacity = 0;
    }
    _win.closeHandle(_handle);
  }

  @override
  String toString() => 'WindowsMmapFile($path, size: $_size, '
      'readOnly: $readOnly)';
}

/// A zero-copy window returned by [WindowsMmapFile.map].
final class WindowsMappedRegion implements MappedRegion {
  final WindowsMmapFile _owner;
  final _Win32 _win;
  final Pointer<Uint8> _base;
  final int _mapLength;
  final int _delta;
  final Uint8List _all;
  @override
  final int offset;
  @override
  final int length;
  final bool _writable;
  bool _closed = false;

  WindowsMappedRegion._(this._owner, this._win, this._base, this._mapLength,
      this._delta, this.offset, this.length, this._writable)
      : _all = _base.asTypedList(_mapLength);

  @override
  Uint8List get bytes {
    if (_closed) throw StateError('Mapped region is closed');
    return Uint8List.sublistView(_all, _delta, _delta + length);
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get isWritable => _writable;

  @override
  void flush() {
    if (_closed || !_writable) return;
    if (_win.flushViewOfFile(_base, _mapLength) == 0) {
      throw WindowsException('FlushViewOfFile', _win.getLastError(), _owner.path);
    }
  }

  @override
  void zeroize() {
    if (_closed) throw StateError('Mapped region is closed');
    if (!_writable) {
      throw StateError('Cannot zeroize a read-only mapping');
    }
    _win.memset((_base + _delta).cast(), 0, length);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _win.unmapViewOfFile(_base);
    _owner._removeRegion(this);
  }
}
