// ignore_for_file: camel_case_types

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'mmap_base.dart';
import 'native_allocator.dart';

// ---------------------------------------------------------------------------
// Win32 ffI bindings (x64, C calling convention)
// ---------------------------------------------------------------------------

typedef _CreateFileW_C = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _CreateFileW = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);

typedef _GetFileSizeEx_C = Int32 Function(IntPtr, Pointer<Int64>);
typedef _GetFileSizeEx = int Function(int, Pointer<Int64>);

typedef _CreateFileMappingW_C = IntPtr Function(
  IntPtr,
  Pointer<Void>,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Utf16>,
);
typedef _CreateFileMappingW = int Function(
  int,
  Pointer<Void>,
  int,
  int,
  int,
  Pointer<Utf16>,
);

typedef _MapViewOfFile_C = Pointer<Uint8> Function(
  IntPtr,
  Uint32,
  Uint32,
  Uint32,
  Size,
);
typedef _MapViewOfFile = Pointer<Uint8> Function(int, int, int, int, int);

typedef _UnmapViewOfFile_C = Int32 Function(Pointer<Uint8>);
typedef _UnmapViewOfFile = int Function(Pointer<Uint8>);

typedef _FlushViewOfFile_C = Int32 Function(Pointer<Uint8>, Size);
typedef _FlushViewOfFile = int Function(Pointer<Uint8>, int);

typedef _FlushFileBuffers_C = Int32 Function(IntPtr);
typedef _FlushFileBuffers = int Function(int);

typedef _SetFilePointerEx_C = Int32 Function(
  IntPtr,
  Int64,
  Pointer<Int64>,
  Uint32,
);
typedef _SetFilePointerEx = int Function(int, int, Pointer<Int64>, int);

typedef _SetEndOfFile_C = Int32 Function(IntPtr);
typedef _SetEndOfFile = int Function(int);

typedef _DeviceIoControl_C = Int32 Function(
  IntPtr,
  Uint32,
  Pointer<Void>,
  Uint32,
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _DeviceIoControl = int Function(
  int,
  int,
  Pointer<Void>,
  int,
  Pointer<Void>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

typedef _ReadFile_C = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _ReadFile = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

typedef _WriteFile_C = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _WriteFile = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

typedef _GetLastError_C = Uint32 Function();
typedef _GetLastError = int Function();

typedef _CloseHandle_C = Int32 Function(IntPtr);
typedef _CloseHandle = int Function(int);

typedef _Memset_C = Pointer<Void> Function(Pointer<Void>, Int32, Size);
typedef _Memset = Pointer<Void> Function(Pointer<Void>, int, int);

typedef _VirtualAlloc_C = Pointer<Uint8> Function(
  Pointer<Void>,
  Size,
  Uint32,
  Uint32,
);
typedef _VirtualAlloc = Pointer<Uint8> Function(Pointer<Void>, int, int, int);

typedef _VirtualFree_C = Int32 Function(Pointer<Void>, Size, Uint32);
typedef _VirtualFree = int Function(Pointer<Void>, int, int);

typedef _VirtualAlloc2_C = Pointer<Uint8> Function(
  IntPtr,
  Pointer<Void>,
  Size,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
);
typedef _VirtualAlloc2 = Pointer<Uint8> Function(
  int,
  Pointer<Void>,
  int,
  int,
  int,
  Pointer<Void>,
  int,
);

typedef _MapViewOfFile3_C = Pointer<Uint8> Function(
  IntPtr,
  IntPtr,
  Pointer<Void>,
  Uint64,
  Size,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
);
typedef _MapViewOfFile3 = Pointer<Uint8> Function(
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
  int,
  Pointer<Void>,
  int,
);

typedef _UnmapViewOfFile2_C = Int32 Function(IntPtr, Pointer<Void>, Uint32);
typedef _UnmapViewOfFile2 = int Function(int, Pointer<Void>, int);

typedef _GetLargePageMinimum_C = Size Function();
typedef _GetLargePageMinimum = int Function();

final class _MemoryRangeEntry extends Struct {
  external Pointer<Void> virtualAddress;

  @Size()
  external int numberOfBytes;
}

typedef _PrefetchVirtualMemory_C = Int32 Function(
  IntPtr,
  Size,
  Pointer<_MemoryRangeEntry>,
  Uint32,
);
typedef _PrefetchVirtualMemory = int Function(
  int,
  int,
  Pointer<_MemoryRangeEntry>,
  int,
);

final class _FileZeroDataInformation extends Struct {
  @Int64()
  external int fileOffset;

  @Int64()
  external int beyondFinalZero;
}

final class _DuplicateExtentsData extends Struct {
  @IntPtr()
  external int fileHandle;

  @Int64()
  external int sourceFileOffset;

  @Int64()
  external int targetFileOffset;

  @Int64()
  external int byteCount;
}

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
const int _fsctlSetZeroData = 0x000980C8;
const int _fsctlDuplicateExtents = 0x00098344;
const int _cloneAlignment = 4096;
const int _fileFlagNoBuffering = 0x20000000;
const int _memCommit = 0x00001000;
const int _memReserve = 0x00002000;
const int _memRelease = 0x00008000;
const int _memReservePlaceholder = 0x00040000;
const int _memReplacePlaceholder = 0x00004000;
const int _memPreservePlaceholder = 0x00000002;
const int _memLargePages = 0x20000000;
const int _pageNoAccess = 0x01;
const int _directAlignment = 4096;
const int _maxDirectChunk = 8 << 20;
const int _mapAlignment = 64 * 1024;
const int _maxIoChunk = 1 << 30; // 1 GiB; ReadFile/WriteFile take a DWORD

class WindowsException implements Exception {
  final String operation;
  final int code;
  final String path;

  WindowsException(this.operation, this.code, this.path);

  @override
  String toString() =>
      'WindowsException: $operation failed '
      '(win32 error $code) for $path';
}

class _Win32 {
  final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary _crt = DynamicLibrary.open('msvcrt.dll');

  late final _CreateFileW createFileW = _k32
      .lookupFunction<_CreateFileW_C, _CreateFileW>('CreateFileW');
  late final _GetFileSizeEx getFileSizeEx = _k32
      .lookupFunction<_GetFileSizeEx_C, _GetFileSizeEx>('GetFileSizeEx');
  late final _CreateFileMappingW createFileMappingW = _k32
      .lookupFunction<_CreateFileMappingW_C, _CreateFileMappingW>(
        'CreateFileMappingW',
      );
  late final _MapViewOfFile mapViewOfFile = _k32
      .lookupFunction<_MapViewOfFile_C, _MapViewOfFile>('MapViewOfFile');
  late final _UnmapViewOfFile unmapViewOfFile = _k32
      .lookupFunction<_UnmapViewOfFile_C, _UnmapViewOfFile>('UnmapViewOfFile');
  late final _FlushViewOfFile flushViewOfFile = _k32
      .lookupFunction<_FlushViewOfFile_C, _FlushViewOfFile>('FlushViewOfFile');
  late final _FlushFileBuffers flushFileBuffers = _k32
      .lookupFunction<_FlushFileBuffers_C, _FlushFileBuffers>(
        'FlushFileBuffers',
      );
  late final _SetFilePointerEx setFilePointerEx = _k32
      .lookupFunction<_SetFilePointerEx_C, _SetFilePointerEx>(
        'SetFilePointerEx',
      );
  late final _SetEndOfFile setEndOfFile = _k32
      .lookupFunction<_SetEndOfFile_C, _SetEndOfFile>('SetEndOfFile');
  late final _DeviceIoControl deviceIoControl = _k32
      .lookupFunction<_DeviceIoControl_C, _DeviceIoControl>('DeviceIoControl');
  late final _ReadFile readFile = _k32.lookupFunction<_ReadFile_C, _ReadFile>(
    'ReadFile',
  );
  late final _WriteFile writeFile = _k32
      .lookupFunction<_WriteFile_C, _WriteFile>('WriteFile');
  late final _GetLastError getLastError = _k32
      .lookupFunction<_GetLastError_C, _GetLastError>('GetLastError');
  late final _CloseHandle closeHandle = _k32
      .lookupFunction<_CloseHandle_C, _CloseHandle>('CloseHandle');
  late final _Memset memset = _crt.lookupFunction<_Memset_C, _Memset>('memset');

  late final _VirtualAlloc virtualAlloc = _k32
      .lookupFunction<_VirtualAlloc_C, _VirtualAlloc>('VirtualAlloc');
  late final _VirtualFree virtualFree = _k32
      .lookupFunction<_VirtualFree_C, _VirtualFree>('VirtualFree');
  late final _VirtualAlloc2? virtualAlloc2;
  late final _MapViewOfFile3? mapViewOfFile3;
  late final _UnmapViewOfFile2? unmapViewOfFile2;
  late final _GetLargePageMinimum? getLargePageMinimum;
  late final _PrefetchVirtualMemory prefetchVirtualMemory = _k32
      .lookupFunction<_PrefetchVirtualMemory_C, _PrefetchVirtualMemory>(
        'PrefetchVirtualMemory',
      );

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
    virtualAlloc;
    virtualFree;
    try {
      virtualAlloc2 = _k32.lookupFunction<_VirtualAlloc2_C, _VirtualAlloc2>(
        'VirtualAlloc2',
      );
    } on ArgumentError {
      virtualAlloc2 = null;
    }
    try {
      mapViewOfFile3 = _k32.lookupFunction<_MapViewOfFile3_C, _MapViewOfFile3>(
        'MapViewOfFile3',
      );
    } on ArgumentError {
      mapViewOfFile3 = null;
    }
    try {
      unmapViewOfFile2 = _k32
          .lookupFunction<_UnmapViewOfFile2_C, _UnmapViewOfFile2>(
            'UnmapViewOfFile2',
          );
    } on ArgumentError {
      unmapViewOfFile2 = null;
    }
    getLargePageMinimum = _k32
        .lookupFunction<_GetLargePageMinimum_C, _GetLargePageMinimum>(
          'GetLargePageMinimum',
        );
    prefetchVirtualMemory;
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
  Pointer<Int64> _ioPosition = nullptr;
  Pointer<Uint32> _ioCount = nullptr;
  MappedRegion? _ioMapRegion;
  bool _closed = false;

  @override
  final String path;
  @override
  final bool readOnly;
  final bool direct;
  final bool _largePagesRequested;
  final bool _mmapCache;
  bool _largePagesActive = false;

  WindowsMmapFile._(
    this._win,
    this._handle,
    this.path,
    this.readOnly,
    this.direct,
    this._largePagesRequested,
    this._mmapCache,
  );

  @override
  bool get usesLargePages => _largePagesActive;

  static Future<MmapFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    bool direct = false,
    bool largePages = false,
    bool mmapCache = true,
  }) async => openSync(
    path,
    create: create,
    readOnly: readOnly,
    direct: direct,
    largePages: largePages,
    mmapCache: mmapCache,
  );

  static MmapFile openSync(
    String path, {
    bool create = true,
    bool readOnly = false,
    bool direct = false,
    bool largePages = false,
    bool mmapCache = true,
  }) {
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
        _fileAttributeNormal | (direct ? _fileFlagNoBuffering : 0),
        0,
      );
    } finally {
      malloc.free(p);
    }
    if (handle == _invalidHandle) {
      throw WindowsException('CreateFileW', win.getLastError(), path);
    }
    final file = WindowsMmapFile._(
      win,
      handle,
      path,
      readOnly,
      direct,
      largePages,
      mmapCache,
    );
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
  MmapPlaceholder createPlaceholder(int length) {
    _checkOpen();
    if (length <= 0) throw RangeError.value(length, 'length');
    final alloc = _win.virtualAlloc2;
    final map3 = _win.mapViewOfFile3;
    if (alloc == null || map3 == null) {
      throw UnsupportedError(
        'MapViewOfFile3/VirtualAlloc2 are unavailable (Windows 10 1803+)',
      );
    }
    final base = alloc(
      -1,
      nullptr,
      length,
      _memReserve | _memReservePlaceholder,
      _pageNoAccess,
      nullptr,
      0,
    );
    if (base.address == 0) {
      _win.fail('VirtualAlloc2(placeholder)', path);
    }
    return WindowsMmapPlaceholder._(this, base, length);
  }

  MappedRegion _mapIntoPlaceholder(
    Pointer<Uint8> base,
    int offset,
    int length,
    bool writable,
  ) {
    _checkOpen();
    _size = _querySize();
    if (offset < 0 || length <= 0 || offset + length > _size) {
      throw RangeError('placeholder map range out of bounds');
    }
    final map3 = _win.mapViewOfFile3;
    if (map3 == null) {
      throw UnsupportedError('MapViewOfFile3 is unavailable');
    }
    _ensureMapping();
    final pointer = map3(
      _mapping,
      -1,
      base.cast(),
      offset,
      length,
      _memReplacePlaceholder,
      writable ? _pageReadWrite : _pageReadOnly,
      nullptr,
      0,
    );
    if (pointer.address == 0) {
      _win.fail('MapViewOfFile3', path);
    }
    final region = WindowsMappedRegion._(
      this,
      _win,
      pointer,
      length,
      0,
      offset,
      length,
      writable,
      true,
    );
    _regions.add(region);
    return region;
  }

  @override
  MappedRegion map({int offset = 0, int? length, bool writable = true}) {
    _checkOpen();
    if (direct) {
      throw UnsupportedError(
        'Direct I/O files cannot be memory-mapped; use readAt/writeAt.',
      );
    }
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
      this,
      _win,
      ptr,
      mapLength,
      delta,
      offset,
      len,
      writable,
    );
    _regions.add(region);
    return region;
  }

  void _removeRegion(WindowsMappedRegion region) {
    _regions.remove(region);
  }

  void _closeMapping() {
    _ioMapRegion = null;
    for (final region in _regions.toList()) {
      region.close();
    }
    if (_mapping != 0) {
      _win.closeHandle(_mapping);
      _mapping = 0;
    }
  }

  void _dropIoMap() {
    final region = _ioMapRegion;
    _ioMapRegion = null;
    region?.close();
  }

  MappedRegion? _ensureIoMap() {
    if (!_mmapCache || direct || _size <= 0) return null;
    final current = _ioMapRegion;
    if (current != null && !current.isClosed && current.length == _size) {
      return current;
    }
    _dropIoMap();
    try {
      final region = map(offset: 0, length: _size, writable: !readOnly);
      _ioMapRegion = region;
      return region;
    } catch (_) {
      return null;
    }
  }

  void _ensureScratch(int needed) {
    if (needed <= _scratchCapacity) return;
    _freeScratch();
    var capacity = _scratchCapacity == 0 ? 1 << 20 : _scratchCapacity;
    while (capacity < needed) {
      capacity *= 2;
    }
    _largePagesActive = false;
    if (direct && _largePagesRequested) {
      final minimum = _win.getLargePageMinimum?.call() ?? 0;
      if (minimum > 0) {
        final largeCapacity = ((capacity + minimum - 1) ~/ minimum) * minimum;
        final large = _win.virtualAlloc(
          nullptr,
          largeCapacity,
          _memCommit | _memReserve | _memLargePages,
          _pageReadWrite,
        );
        if (large.address != 0) {
          _scratch = large;
          capacity = largeCapacity;
          _largePagesActive = true;
        }
      }
    }
    if (_scratch.address == 0) {
      _scratch = direct
          ? _win.virtualAlloc(
              nullptr,
              capacity,
              _memCommit | _memReserve,
              _pageReadWrite,
            )
          : nativeScratchAllocator.allocate<Uint8>(capacity);
    }
    if (_scratch.address == 0) {
      throw WindowsException(direct ? 'VirtualAlloc' : 'calloc', -1, path);
    }
    _scratchCapacity = capacity;
  }

  void _freeScratch() {
    if (_scratch.address == 0) return;
    if (direct) {
      _win.virtualFree(_scratch.cast(), 0, _memRelease);
    } else {
      nativeScratchAllocator.free(_scratch);
    }
    _scratch = nullptr;
    _scratchCapacity = 0;
  }

  void _freeIoScratch() {
    if (_ioPosition.address != 0) {
      calloc.free(_ioPosition);
      _ioPosition = nullptr;
    }
    if (_ioCount.address != 0) {
      calloc.free(_ioCount);
      _ioCount = nullptr;
    }
  }

  int _readChunk(int offset, Pointer<Uint8> dst, int count) {
    _ioPosition = _ioPosition.address == 0 ? calloc<Int64>() : _ioPosition;
    _ioCount = _ioCount.address == 0 ? calloc<Uint32>() : _ioCount;
    if (_win.setFilePointerEx(_handle, offset, _ioPosition, 0) == 0) {
      _win.fail('SetFilePointerEx(read)', path);
    }
    final ok = _win.readFile(_handle, dst, count, _ioCount, nullptr);
    final err = _win.getLastError();
    if (ok == 0) {
      if (err == _errorHandleEof) return 0;
      throw WindowsException(
        'ReadFile(offset=$offset,count=$count,ok=$ok,err=$err)',
        err,
        path,
      );
    }
    return _ioCount.value;
  }

  int _writeChunk(int offset, Pointer<Uint8> src, int count) {
    _ioPosition = _ioPosition.address == 0 ? calloc<Int64>() : _ioPosition;
    _ioCount = _ioCount.address == 0 ? calloc<Uint32>() : _ioCount;
    if (_win.setFilePointerEx(_handle, offset, _ioPosition, 0) == 0) {
      _win.fail('SetFilePointerEx(write)', path);
    }
    final ok = _win.writeFile(_handle, src, count, _ioCount, nullptr);
    final err = _win.getLastError();
    if (ok == 0) {
      throw WindowsException(
        'WriteFile(offset=$offset,count=$count,ok=$ok,err=$err)',
        err,
        path,
      );
    }
    return _ioCount.value;
  }

  @override
  int readAt(int offset, Uint8List dst, {int start = 0, int? end}) {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    final requested = e - start;
    if (offset >= _size || offset + requested > _size) {
      _size = _querySize();
      if (offset >= _size) return 0;
    }
    final wanted = math.min(requested, _size - offset);
    if (wanted <= 0) return 0;

    final cache = _ensureIoMap();
    if (cache != null && offset + wanted <= cache.length) {
      dst.setRange(start, start + wanted, cache.bytes, offset);
      return wanted;
    }

    if (direct) {
      if (offset % _directAlignment != 0 || wanted % _directAlignment != 0) {
        throw ArgumentError(
          'Direct I/O read requires 4 KiB aligned offset and length '
          '(offset=$offset, length=$wanted).',
        );
      }
      var done = 0;
      while (done < wanted) {
        final n = math.min(wanted - done, _maxDirectChunk);
        _ensureScratch(n);
        final got = _readChunk(offset + done, _scratch, n);
        if (got <= 0) break;
        dst.setRange(
          start + done,
          start + done + got,
          _scratch.asTypedList(got),
        );
        done += got;
        if (got < n) break;
      }
      return done;
    }

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

    if (direct &&
        (offset % _directAlignment != 0 || wanted % _directAlignment != 0)) {
      throw ArgumentError(
        'Direct I/O write requires 4 KiB aligned offset and length '
        '(offset=$offset, length=$wanted).',
      );
    }

    final cache = _ensureIoMap();
    if (cache != null && offset + wanted <= cache.length) {
      cache.bytes.setRange(offset, offset + wanted, src, start);
      return wanted;
    }

    var done = 0;
    while (done < wanted) {
      final maxChunk = direct ? _maxDirectChunk : _maxIoChunk;
      final n = math.min(wanted - done, maxChunk);
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
  int readAtPointer(int offset, Pointer<Uint8> dst, int length) {
    _checkOpen();
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (length < 0) throw RangeError.value(length, 'length');
    if (length == 0) return 0;
    if (offset >= _size) {
      _size = _querySize();
      if (offset >= _size) return 0;
    }
    final wanted = math.min(length, _size - offset);
    if (direct &&
        (offset % _directAlignment != 0 || wanted % _directAlignment != 0)) {
      throw ArgumentError(
        'Direct I/O read requires 4 KiB aligned offset and length '
        '(offset=$offset, length=$wanted).',
      );
    }
    var done = 0;
    while (done < wanted) {
      final maxChunk = direct ? _maxDirectChunk : _maxIoChunk;
      final n = math.min(wanted - done, maxChunk);
      final got = _readChunk(offset + done, dst + done, n);
      if (got <= 0) break;
      done += got;
      if (got < n) break;
    }
    return done;
  }

  @override
  int writeAtPointer(int offset, Pointer<Uint8> src, int length) {
    _checkWritable();
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (length < 0) throw RangeError.value(length, 'length');
    if (length == 0) return 0;
    if (direct &&
        (offset % _directAlignment != 0 || length % _directAlignment != 0)) {
      throw ArgumentError(
        'Direct I/O write requires 4 KiB aligned offset and length '
        '(offset=$offset, length=$length).',
      );
    }
    var done = 0;
    while (done < length) {
      final maxChunk = direct ? _maxDirectChunk : _maxIoChunk;
      final n = math.min(length - done, maxChunk);
      final put = _writeChunk(offset + done, src + done, n);
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
        _handle,
        _fsctlSetSparse,
        nullptr,
        0,
        nullptr,
        0,
        nullptr,
        nullptr,
      );
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
    _ioMapRegion?.flush();
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
  void punchHole(int offset, int length) {
    _checkWritable();
    if (offset < 0 || length < 0 || offset + length > _size) {
      throw RangeError('punchHole range out of bounds');
    }
    if (length == 0) return;
    _closeMapping();
    final info = calloc<_FileZeroDataInformation>();
    final bytes = calloc<Uint32>();
    try {
      info.ref.fileOffset = offset;
      info.ref.beyondFinalZero = offset + length;
      final ok = _win.deviceIoControl(
        _handle,
        _fsctlSetZeroData,
        info.cast(),
        sizeOf<_FileZeroDataInformation>(),
        nullptr,
        0,
        bytes,
        nullptr,
      );
      if (ok == 0) _win.fail('FSCTL_SET_ZERO_DATA', path);
    } finally {
      calloc.free(bytes);
      calloc.free(info);
    }
  }

  @override
  void cloneRangeFrom(
    MmapFile source, {
    int sourceOffset = 0,
    int destOffset = 0,
    int? length,
  }) {
    _checkWritable();
    if (source is! WindowsMmapFile) {
      throw ArgumentError.value(source, 'source', 'must be a WindowsMmapFile');
    }
    source._checkOpen();
    final n = length ?? (source._size - sourceOffset);
    if (sourceOffset < 0 ||
        destOffset < 0 ||
        n < 0 ||
        sourceOffset + n > source._size) {
      throw RangeError('cloneRangeFrom range out of bounds');
    }
    if (n == 0) return;
    if (sourceOffset % _cloneAlignment != 0 ||
        destOffset % _cloneAlignment != 0 ||
        n % _cloneAlignment != 0) {
      throw ArgumentError(
        'cloneRangeFrom requires 4 KiB aligned source, dest and length',
      );
    }
    _closeMapping();
    final data = calloc<_DuplicateExtentsData>();
    final bytes = calloc<Uint32>();
    try {
      data.ref.fileHandle = source._handle;
      data.ref.sourceFileOffset = sourceOffset;
      data.ref.targetFileOffset = destOffset;
      data.ref.byteCount = n;
      final ok = _win.deviceIoControl(
        _handle,
        _fsctlDuplicateExtents,
        data.cast(),
        sizeOf<_DuplicateExtentsData>(),
        nullptr,
        0,
        bytes,
        nullptr,
      );
      if (ok == 0) _win.fail('FSCTL_DUPLICATE_EXTENTS_TO_FILE', path);
    } finally {
      calloc.free(bytes);
      calloc.free(data);
    }
    if (destOffset + n > _size) _size = destOffset + n;
  }

  @override
  void preallocate(int length) => truncate(length, sparse: false);

  @override
  void adviseRead({int offset = 0, int? length}) {}

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closeMapping();
    _freeScratch();
    _freeIoScratch();
    _win.closeHandle(_handle);
  }

  @override
  String toString() =>
      'WindowsMmapFile($path, size: $_size, '
      'readOnly: $readOnly)';
}

/// A reserved placeholder that accepts `MapViewOfFile3` replacements.
final class WindowsMmapPlaceholder implements MmapPlaceholder {
  final WindowsMmapFile _owner;
  final Pointer<Uint8> _base;
  final int _length;
  MappedRegion? _current;
  bool _closed = false;

  WindowsMmapPlaceholder._(this._owner, this._base, this._length);

  @override
  int get length => _length;

  @override
  int get baseAddress => _base.address;

  @override
  MappedRegion map(MmapFile file, {int offset = 0, bool writable = true}) {
    if (_closed) throw StateError('Placeholder is closed');
    if (file is! WindowsMmapFile) {
      throw ArgumentError.value(file, 'file', 'must be a WindowsMmapFile');
    }
    _current?.close();
    final region = file._mapIntoPlaceholder(_base, offset, _length, writable);
    _current = region;
    return region;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _current?.close();
    _current = null;
    _owner._win.virtualFree(_base.cast(), 0, _memRelease);
  }
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
  final bool _view3;
  bool _closed = false;

  WindowsMappedRegion._(
    this._owner,
    this._win,
    this._base,
    this._mapLength,
    this._delta,
    this.offset,
    this.length,
    this._writable, [
    this._view3 = false,
  ]) : _all = _base.asTypedList(_mapLength);

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
      throw WindowsException(
        'FlushViewOfFile',
        _win.getLastError(),
        _owner.path,
      );
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

  ({int offset, int length}) _hintRange(int offset, int? length) {
    if (_closed) throw StateError('Mapped region is closed');
    if (offset < 0 || offset > this.length) {
      throw RangeError.range(offset, 0, this.length, 'offset');
    }
    final n = length ?? (this.length - offset);
    if (n < 0 || offset + n > this.length) {
      throw RangeError.range(n, 0, this.length - offset, 'length');
    }
    return (offset: offset, length: n);
  }

  @override
  void prefetch({int offset = 0, int? length}) {
    final range = _hintRange(offset, length);
    if (range.length == 0) return;
    final entry = calloc<_MemoryRangeEntry>();
    try {
      entry.ref.virtualAddress = (_base + _delta + range.offset).cast<Void>();
      entry.ref.numberOfBytes = range.length;
      final ok = _win.prefetchVirtualMemory(-1, 1, entry, 0);
      if (ok == 0) {
        throw WindowsException(
          'PrefetchVirtualMemory',
          _win.getLastError(),
          _owner.path,
        );
      }
    } finally {
      calloc.free(entry);
    }
  }

  @override
  void discard({int offset = 0, int? length}) {
    // Windows returns ERROR_USER_MAPPED_FILE for file-backed mapped ranges,
    // so DiscardVirtualMemory cannot be used here.  Keep the call advisory and
    // validate the range, then let the OS evict pages normally.
    _hintRange(offset, length);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_view3) {
      final unmap = _win.unmapViewOfFile2;
      if (unmap == null ||
          unmap(-1, _base.cast(), _memPreservePlaceholder) == 0) {
        _win.unmapViewOfFile(_base);
      }
    } else {
      _win.unmapViewOfFile(_base);
    }
    _owner._removeRegion(this);
  }
}
