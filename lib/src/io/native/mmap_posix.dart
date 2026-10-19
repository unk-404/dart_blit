/// POSIX mmap backend: Linux, Android, macOS and iOS.
///
/// Pure `dart:ffi` against the platform C library — no C source, no build
/// hooks.  Only exported libc symbols are used:
///
/// * `open`/`close`/`pread`/`pwrite`/`lseek`/`ftruncate`/`fsync`
/// * `mmap`/`munmap`/`msync`/`madvise`
/// * `fallocate` (Linux/Android only; optional)
/// * `getpagesize`, `memset`, `explicit_bzero` (optional), `strerror`
/// * `__errno_location` (glibc/musl) or `__error` (Darwin), plus
///   `__errno` (bionic) as a fallback
///
/// Size/offset types are 64-bit `int` in Dart on every native target.  On
/// 32-bit Linux/Android the plain libc entry points take a 32-bit `off_t`, so
/// the `*64` variants (`pread64`, `pwrite64`, `lseek64`, `ftruncate64`,
/// `mmap64`, `fallocate64`) are preferred there; on 64-bit targets and on
/// Darwin the plain names are already 64-bit clean.
///
/// `open`, `fcntl` and friends are C-variadic functions.  They are declared
/// with [VarArgs] so the call crosses the ABI correctly, including the
/// Apple ARM64 variadic convention (fixed in Dart 3.4).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'mmap_base.dart';

// ---------------------------------------------------------------------------
// C signatures.
//
// LP64 POSIX (Linux x86_64/aarch64/riscv64, macOS/iOS arm64 + x86_64):
//   size_t/ssize_t are 64-bit, off_t is int64.  ILP32 Linux/Android (armv7,
//   x86): size_t/ssize_t are 32-bit and the plain syscalls take 32-bit off_t;
//   the *64 entry points keep covering the full 32 GiB range.
// ---------------------------------------------------------------------------

typedef _OpenNative = Int32 Function(
    Pointer<Utf8>, Int32, VarArgs<(Int32,)>);
typedef _Open = int Function(Pointer<Utf8>, int, int);

typedef _CloseNative = Int32 Function(Int32);
typedef _Close = int Function(int);

typedef _PreadNative = IntPtr Function(Int32, Pointer<Void>, Size, Int64);
typedef _Pread = int Function(int, Pointer<Void>, int, int);

typedef _PwriteNative = IntPtr Function(Int32, Pointer<Void>, Size, Int64);
typedef _Pwrite = int Function(int, Pointer<Void>, int, int);

typedef _LseekNative = Int64 Function(Int32, Int64, Int32);
typedef _Lseek = int Function(int, int, int);

typedef _FtruncateNative = Int32 Function(Int32, Int64);
typedef _Ftruncate = int Function(int, int);

typedef _FcntlNative = Int32 Function(Int32, Int32, VarArgs<(Int64,)>);
typedef _Fcntl = int Function(int, int, int);

typedef _MmapNative = Pointer<Uint8> Function(
    Pointer<Void>, Size, Int32, Int32, Int32, Int64);
typedef _Mmap = Pointer<Uint8> Function(
    Pointer<Void>, int, int, int, int, int);

typedef _MunmapNative = Int32 Function(Pointer<Void>, Size);
typedef _Munmap = int Function(Pointer<Void>, int);

typedef _MsyncNative = Int32 Function(Pointer<Void>, Size, Int32);
typedef _Msync = int Function(Pointer<Void>, int, int);

typedef _MadviseNative = Int32 Function(Pointer<Void>, Size, Int32);
typedef _Madvise = int Function(Pointer<Void>, int, int);

typedef _FsyncNative = Int32 Function(Int32);
typedef _Fsync = int Function(int);

typedef _FallocateNative = Int32 Function(Int32, Int32, Int64, Int64);
typedef _Fallocate = int Function(int, int, int, int);

typedef _GetpagesizeNative = Int32 Function();
typedef _Getpagesize = int Function();

typedef _ExplicitBzeroNative = Void Function(Pointer<Void>, Size);
typedef _ExplicitBzero = void Function(Pointer<Void>, int);

typedef _MemsetNative = Pointer<Void> Function(Pointer<Void>, Int32, Size);
typedef _Memset = Pointer<Void> Function(Pointer<Void>, int, int);

typedef _PosixMemalignNative = Int32 Function(
    Pointer<Pointer<Void>>, Size, Size);
typedef _PosixMemalign = int Function(Pointer<Pointer<Void>>, int, int);

typedef _ErrnoNative = Pointer<Int32> Function();
typedef _Errno = Pointer<Int32> Function();

typedef _StrerrorNative = Pointer<Utf8> Function(Int32);
typedef _Strerror = Pointer<Utf8> Function(int);

// ---------------------------------------------------------------------------
// Constants.
// ---------------------------------------------------------------------------

/// Darwin exposes `__error`; glibc/musl expose `__errno_location`; bionic
/// exposes `__errno`.  All return `int*`.
final bool _isDarwin = Platform.isMacOS || Platform.isIOS;

// fcntl.h — Linux/Android and Darwin disagree on every creation flag.
//   Linux: O_CREAT=0o100 (0x40),  O_TRUNC=0o1000 (0x200), O_CLOEXEC=0x80000
//   Darwin: O_CREAT=0x200,        O_TRUNC=0x400,          O_CLOEXEC=0x1000000
const int _openRdonly = 0;
const int _openRdwr = 2;
final int _openCreat = _isDarwin ? 0x200 : 0x40;
final int _openCloexec = _isDarwin ? 0x1000000 : 0x80000;
final int _openDirect = _isDarwin ? 0 : 0x4000; // Linux/Android O_DIRECT
const int _mode0644 = 0x1A4;

// Darwin F_NOCACHE is 48 (XNU bsd/sys/fcntl.h); it disables the unified
// buffer cache for the descriptor.  Linux/Android use O_DIRECT instead.
const int _fNoCache = 48;
const int _directAlignment = 4096;
const int _maxDirectChunk = 8 << 20;

// mman.h.  PROT_*, MAP_SHARED match on Linux and Darwin, but MS_SYNC does
// not: Linux uses 0x4 while Darwin uses 0x10 (MS_ASYNC/MS_INVALIDATE are
// 1/2 on both).  Verified against XNU bsd/sys/mman.h.
const int _protRead = 1;
const int _protWrite = 2;
const int _mapShared = 1;
final int _msSync = _isDarwin ? 0x10 : 4;

// madvise.h.  MADV_NORMAL/RANDOM/SEQUENTIAL/WILLNEED/DONTNEED are 0..4 on
// both Linux and Darwin; only the optional values (MADV_FREE = 8 on Linux,
// 5 on Darwin) differ, so the portable subset is used here.  Verified against
// XNU bsd/sys/mman.h.
const int _madvSequential = 2;
const int _madvWillNeed = 3;
const int _madvDontNeed = 4;

// unistd.h
const int _seekEnd = 2;

// errno.h — EINTR is 4 on both Linux and Darwin.
const int _eintr = 4;

// fcntl.h
const int _fGetfl = 3;

// linux/falloc.h — only used on Linux/Android when `fallocate` is exported.
const int _fallocDefault = 0; // equivalent to posix_fallocate()'s mode

const int _defaultPageSize = 4096;
const int _maxIoChunk = 1 << 30; // 1 GiB per pread/pwrite syscall
const int _zeroizeChunk = 64 << 20; // temporary mappings used by zeroize()

/// Raised when a POSIX call fails.  [errnoCode] is the raw `errno` value.
final class PosixException implements Exception {
  final String operation;
  final int errnoCode;
  final String path;
  final String _detail;

  PosixException(this.operation, this.errnoCode, this.path)
      : _detail = _errnoText(errnoCode);

  @override
  String toString() {
    final detail = _detail.isEmpty ? '' : ': $_detail';
    return 'PosixException: $operation failed '
        '(errno $errnoCode$detail) for $path';
  }
}

String _errnoText(int code) {
  if (code == 0) return '';
  final libc = _cachedLibc;
  if (libc == null) return '';
  try {
    return libc.strerrorText(code) ?? '';
  } catch (_) {
    // Diagnostics must never mask the original failure.
    return '';
  }
}

/// Resolves an optional symbol.  The concrete Dart signature is applied at
/// the call site with [Pointer.asFunction], so every lookup still gets a
/// statically typed native function signature.
Pointer<NativeFunction<NF>>? _tryNative<NF extends Function>(
    DynamicLibrary lib, String symbol) {
  if (!lib.providesSymbol(symbol)) return null;
  try {
    return lib.lookup<NativeFunction<NF>>(symbol);
  } on ArgumentError {
    return null;
  }
}

/// Fetches `libc`.  `DynamicLibrary.process()` covers glibc/musl/bionic and
/// libSystem in the common case; explicit names are only a fallback.
DynamicLibrary _loadLibc() {
  final process = DynamicLibrary.process();
  if (process.providesSymbol('mmap') &&
      process.providesSymbol('open') &&
      process.providesSymbol('pread')) {
    return process;
  }
  final candidates = _isDarwin
      ? const <String>['/usr/lib/libSystem.B.dylib', 'libSystem.B.dylib']
      : const <String>['libc.so.6', 'libc.so'];
  for (final name in candidates) {
    try {
      final lib = DynamicLibrary.open(name);
      if (lib.providesSymbol('mmap')) return lib;
    } on ArgumentError {
      // Try the next candidate.
    }
  }
  throw StateError(
      'bytes: cannot load the POSIX C library for the mmap backend');
}

_Libc? _cachedLibc;

_Libc get _posixLibc {
  final cached = _cachedLibc;
  if (cached != null) return cached;
  try {
    return _cachedLibc = _Libc._(_loadLibc());
  } on ArgumentError catch (e) {
    throw StateError('bytes: POSIX libc is missing a required symbol ($e)');
  }
}

/// Resolved libc entry points.  Every pointer is looked up once in the
/// constructor ("warm-up"): a lazy [DynamicLibrary.lookupFunction] can run
/// between a failing syscall and the `errno` read and clobber the error value.
class _Libc {
  late final _Open open;
  late final _Close close;
  late final _Pread pread;
  late final _Pwrite pwrite;
  late final _Lseek lseek;
  late final _Ftruncate ftruncate;
  late final _Fcntl fcntl;
  late final _Mmap mmap;
  late final _Munmap munmap;
  late final _Msync msync;
  late final _Madvise madvise;
  late final _Fsync fsync;
  late final _Fallocate? fallocate;
  late final _ExplicitBzero? explicitBzero;
  late final _Errno? _errnoFn;
  late final _Getpagesize? _getpagesize;
  late final _Strerror strerror;
  late final _Memset memset;
  late final _PosixMemalign posixMemalign;
  late final int pageSize;

  _Libc._(DynamicLibrary lib) {
    // On ILP32 Linux/Android the legacy names take a 32-bit off_t.
    final bool needsOffT64 = sizeOf<IntPtr>() == 4;

    open = lib.lookupFunction<_OpenNative, _Open>('open');
    close = lib.lookupFunction<_CloseNative, _Close>('close');

    pread = needsOffT64
        ? (_tryNative<_PreadNative>(lib, 'pread64')?.asFunction<_Pread>() ??
            lib.lookupFunction<_PreadNative, _Pread>('pread'))
        : lib.lookupFunction<_PreadNative, _Pread>('pread');
    pwrite = needsOffT64
        ? (_tryNative<_PwriteNative>(lib, 'pwrite64')?.asFunction<_Pwrite>() ??
            lib.lookupFunction<_PwriteNative, _Pwrite>('pwrite'))
        : lib.lookupFunction<_PwriteNative, _Pwrite>('pwrite');
    lseek = needsOffT64
        ? (_tryNative<_LseekNative>(lib, 'lseek64')?.asFunction<_Lseek>() ??
            lib.lookupFunction<_LseekNative, _Lseek>('lseek'))
        : lib.lookupFunction<_LseekNative, _Lseek>('lseek');
    ftruncate = needsOffT64
        ? (_tryNative<_FtruncateNative>(lib, 'ftruncate64')
                ?.asFunction<_Ftruncate>() ??
            lib.lookupFunction<_FtruncateNative, _Ftruncate>('ftruncate'))
        : lib.lookupFunction<_FtruncateNative, _Ftruncate>('ftruncate');

    fcntl = lib.lookupFunction<_FcntlNative, _Fcntl>('fcntl');

    mmap = needsOffT64
        ? (_tryNative<_MmapNative>(lib, 'mmap64')?.asFunction<_Mmap>() ??
            lib.lookupFunction<_MmapNative, _Mmap>('mmap'))
        : lib.lookupFunction<_MmapNative, _Mmap>('mmap');
    munmap = lib.lookupFunction<_MunmapNative, _Munmap>('munmap');
    msync = lib.lookupFunction<_MsyncNative, _Msync>('msync');
    madvise = lib.lookupFunction<_MadviseNative, _Madvise>('madvise');
    fsync = lib.lookupFunction<_FsyncNative, _Fsync>('fsync');

    // Not available on Darwin; not available on every libc build elsewhere.
    fallocate = needsOffT64
        ? (_tryNative<_FallocateNative>(lib, 'fallocate64')
                ?.asFunction<_Fallocate>() ??
            _tryNative<_FallocateNative>(lib, 'fallocate')
                ?.asFunction<_Fallocate>())
        : _tryNative<_FallocateNative>(lib, 'fallocate')
            ?.asFunction<_Fallocate>();

    // explicit_bzero is the wipe that compilers may not elide (glibc >= 2.25,
    // musl, Darwin).  bionic does not export it; fall back to memset.
    explicitBzero = _tryNative<_ExplicitBzeroNative>(lib, 'explicit_bzero')
        ?.asFunction<_ExplicitBzero>();
    memset = lib.lookupFunction<_MemsetNative, _Memset>('memset');
    posixMemalign = lib.lookupFunction<_PosixMemalignNative, _PosixMemalign>(
        'posix_memalign');
    strerror = lib.lookupFunction<_StrerrorNative, _Strerror>('strerror');

    _errnoFn = _isDarwin
        ? (_tryNative<_ErrnoNative>(lib, '__error')?.asFunction<_Errno>() ??
            _tryNative<_ErrnoNative>(lib, '__errno_location')
                ?.asFunction<_Errno>())
        : (_tryNative<_ErrnoNative>(lib, '__errno_location')
                ?.asFunction<_Errno>() ??
            _tryNative<_ErrnoNative>(lib, '__errno')?.asFunction<_Errno>());

    // getpagesize() exists on glibc, musl, bionic and libSystem; sysconf would
    // need a platform-specific _SC_PAGESIZE constant.
    _getpagesize = _tryNative<_GetpagesizeNative>(lib, 'getpagesize')
        ?.asFunction<_Getpagesize>();
    final int rawPageSize = _getpagesize?.call() ?? 0;
    pageSize = rawPageSize > 0 ? rawPageSize : _defaultPageSize;
  }

  /// Current thread's `errno` (0 when the platform lookup failed).
  int get errno => _errnoFn?.call().value ?? 0;

  String? strerrorText(int code) {
    final p = strerror(code);
    if (p.address == 0) return null;
    return p.toDartString();
  }

  /// Wipes [length] bytes at [pointer] with a native call.
  void zeroMemory(Pointer<Void> pointer, int length) {
    final bzero = explicitBzero;
    if (bzero != null) {
      bzero(pointer, length);
    } else {
      memset(pointer, 0, length);
    }
  }
}

// ---------------------------------------------------------------------------
// PosixMmapFile
// ---------------------------------------------------------------------------

/// POSIX implementation of [MmapFile] using pure `dart:ffi`.
///
/// The file descriptor is opened with `O_CLOEXEC` and `pread`/`pwrite` are
/// used everywhere, so there is no shared file offset and no `O_APPEND`
/// interference.  `truncate` closes every live window first: a mapping past
/// the new EOF would raise `SIGBUS` on access.
final class PosixMmapFile extends MmapFile {
  final _Libc _libc;
  final int _fd;
  final int _statusFlags;
  final bool direct;
  final Set<PosixMappedRegion> _regions = <PosixMappedRegion>{};
  int _size;
  int _scratchCapacity = 0;
  Pointer<Uint8> _scratch = nullptr;
  bool _closed = false;

  @override
  final String path;
  @override
  final bool readOnly;

  PosixMmapFile._(this._libc, this._fd, this.path, this.readOnly, this._size,
      this._statusFlags, this.direct);

  static Future<MmapFile> open(String path,
          {bool create = true, bool readOnly = false, bool direct = false}) async =>
      openSync(
          path, create: create, readOnly: readOnly, direct: direct);

  static MmapFile openSync(String path,
      {bool create = true, bool readOnly = false, bool direct = false}) {
    final libc = _posixLibc;
    final int flags = (readOnly ? _openRdonly : _openRdwr) |
        (create ? _openCreat : 0) |
        _openCloexec |
        (_isDarwin ? 0 : (direct ? _openDirect : 0));
    final cPath = path.toNativeUtf8();
    final int fd;
    try {
      fd = libc.open(cPath, flags, _mode0644);
    } finally {
      malloc.free(cPath);
    }
    if (fd < 0) throw PosixException('open', libc.errno, path);
    if (direct && _isDarwin) {
      // F_NOCACHE is per-descriptor; it bypasses the unified buffer cache.
      if (libc.fcntl(fd, _fNoCache, 1) < 0) {
        final e = libc.errno;
        libc.close(fd);
        throw PosixException('fcntl(F_NOCACHE)', e, path);
      }
    }
    // Capture the descriptor's status flags once for diagnostics (and to
    // prove the fd really is not append-mode).
    final statusFlags = libc.fcntl(fd, _fGetfl, 0);
    final file = PosixMmapFile._(libc, fd, path, readOnly, 0,
        statusFlags < 0 ? 0 : statusFlags, direct);
    try {
      file._size = file._querySize();
    } catch (_) {
      file.close();
      rethrow;
    }
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
    // lseek(SEEK_END) only reads the size: pread/pwrite never depend on the
    // shared file offset, so moving it is harmless.
    final size = _libc.lseek(_fd, 0, _seekEnd);
    if (size < 0) throw PosixException('lseek', _libc.errno, path);
    return size;
  }

  @override
  int get length {
    _checkOpen();
    _size = _querySize();
    return _size;
  }

  @override
  bool get isClosed => _closed;

  bool _isMapFailed(Pointer<Uint8> pointer) {
    final address = pointer.address;
    if (address == -1) return true; // MAP_FAILED on LP64
    // On ILP32 the address surfaces as either -1 or 0xFFFFFFFF.
    return sizeOf<IntPtr>() == 4 && (address & 0xFFFFFFFF) == 0xFFFFFFFF;
  }

  @override
  MappedRegion map({int offset = 0, int? length, bool writable = true}) {
    _checkOpen();
    if (direct) {
      throw UnsupportedError(
          'Direct I/O files cannot be memory-mapped; use readAt/writeAt.');
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
    final requested = length ?? (_size - offset);
    if (requested < 0 || requested > _size - offset) {
      throw RangeError.range(requested, 0, _size - offset, 'length');
    }
    if (requested == 0) {
      throw RangeError.value(requested, 'length', 'must be > 0');
    }

    // mmap(2) requires a page-aligned file offset; the window start is
    // aligned down here and the delta is hidden behind a sublist view.
    final pageSize = _libc.pageSize;
    final base = offset - (offset % pageSize);
    final delta = offset - base;
    final mapLength = requested + delta;
    final prot = writable ? (_protRead | _protWrite) : _protRead;
    final pointer = _libc.mmap(
        nullptr, mapLength, prot, _mapShared, _fd, base);
    if (_isMapFailed(pointer)) {
      throw PosixException('mmap', _libc.errno, path);
    }
    final region = PosixMappedRegion._(
        this, _libc, pointer, mapLength, delta, offset, requested, writable);
    _regions.add(region);
    return region;
  }

  void _removeRegion(PosixMappedRegion region) {
    _regions.remove(region);
  }

  void _closeRegions() {
    for (final region in _regions.toList(growable: false)) {
      region.close();
    }
  }

  void _ensureScratch(int needed) {
    if (needed <= _scratchCapacity) return;
    _freeScratch();
    var capacity = _scratchCapacity == 0 ? 1 << 20 : _scratchCapacity;
    while (capacity < needed) {
      capacity *= 2;
    }
    if (direct) {
      final out = calloc<Pointer<Void>>();
      try {
        final rc = _libc.posixMemalign(out, _directAlignment, capacity);
        _scratch = out.value.cast<Uint8>();
        if (rc != 0 || _scratch.address == 0) {
          _scratch = nullptr;
          _scratchCapacity = 0;
          throw StateError('bytes: posix_memalign($capacity) failed ($rc) '
              'for $path');
        }
      } finally {
        calloc.free(out);
      }
    } else {
      _scratch = calloc<Uint8>(capacity);
    }
    if (_scratch.address == 0) {
      _scratchCapacity = 0;
      throw StateError('bytes: out of memory allocating $capacity-byte '
          'scratch buffer for $path');
    }
    _scratchCapacity = capacity;
  }

  void _freeScratch() {
    if (_scratch.address == 0) return;
    if (direct) {
      malloc.free(_scratch);
    } else {
      calloc.free(_scratch);
    }
    _scratch = nullptr;
    _scratchCapacity = 0;
  }

  int _readChunk(int offset, Pointer<Uint8> dst, int count) {
    while (true) {
      final got = _libc.pread(_fd, dst.cast(), count, offset);
      if (got >= 0) return got;
      final errnoCode = _libc.errno;
      if (errnoCode != _eintr) {
        throw PosixException('pread', errnoCode, path);
      }
      // A signal interrupted the call before any data was transferred.
    }
  }

  int _writeChunk(int offset, Pointer<Uint8> src, int count) {
    while (true) {
      final put = _libc.pwrite(_fd, src.cast(), count, offset);
      if (put >= 0) return put;
      final errnoCode = _libc.errno;
      if (errnoCode != _eintr) {
        throw PosixException('pwrite', errnoCode, path);
      }
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

    if (direct) {
      if (offset % _directAlignment != 0 ||
          wanted % _directAlignment != 0) {
        throw ArgumentError(
            'Direct I/O read requires 4 KiB aligned offset and length '
            '(offset=$offset, length=$wanted).');
      }
      var done = 0;
      while (done < wanted) {
        final n = math.min(wanted - done, _maxDirectChunk);
        _ensureScratch(n);
        final got = _readChunk(offset + done, _scratch, n);
        if (got <= 0) break;
        dst.setRange(start + done, start + done + got,
            _scratch.asTypedList(got));
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
      dst.setRange(
          start + done, start + done + got, _scratch.asTypedList(got));
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
        (offset % _directAlignment != 0 ||
            wanted % _directAlignment != 0)) {
      throw ArgumentError(
          'Direct I/O write requires 4 KiB aligned offset and length '
          '(offset=$offset, length=$wanted).');
    }

    var done = 0;
    while (done < wanted) {
      final maxChunk = direct ? _maxDirectChunk : _maxIoChunk;
      final n = math.min(wanted - done, maxChunk);
      _ensureScratch(n);
      _scratch.asTypedList(n).setRange(0, n, src, start + done);
      final put = _writeChunk(offset + done, _scratch, n);
      if (put <= 0) break;
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
    _size = _querySize();
    final oldSize = _size;
    // A mapping that extends past the new EOF faults with SIGBUS on access.
    _closeRegions();
    if (_libc.ftruncate(_fd, newLength) < 0) {
      throw PosixException('ftruncate', _libc.errno, path);
    }
    _size = newLength;

    // POSIX ftruncate extends sparsely by default, so `sparse: true` needs no
    // extra syscall.  `sparse: false` asks for really allocated blocks via
    // fallocate(2), which only exists on Linux/Android and only on some
    // filesystems; ENOTSUP/ENOSYS/EINVAL degrade to a sparse file.
    final fallocate = _libc.fallocate;
    if (!sparse && newLength > oldSize && fallocate != null) {
      final rc = fallocate(_fd, _fallocDefault, 0, newLength);
      if (rc < 0) {
        final errnoCode = _libc.errno;
        const eNotSup = 95; // EOPNOTSUPP (a.k.a. ENOTSUP)
        const eNoSys = 38; // ENOSYS
        const eInval = 22; // EINVAL
        if (errnoCode != eNotSup &&
            errnoCode != eNoSys &&
            errnoCode != eInval) {
          throw PosixException('fallocate', errnoCode, path);
        }
      }
    }
  }

  @override
  void flush() {
    _checkOpen();
    for (final region in _regions.toList(growable: false)) {
      region.flush();
    }
    if (_libc.fsync(_fd) < 0) {
      throw PosixException('fsync', _libc.errno, path);
    }
  }

  @override
  void zeroize(int offset, int length) {
    _checkWritable();
    _size = _querySize();
    if (offset < 0 || length < 0 || length > _size - offset) {
      throw RangeError('zeroize range out of bounds');
    }
    if (length == 0) return;
    // memset/explicit_bzero through a temporary shared mapping avoids a
    // user-space zero buffer copy; the dirty pages go back through the page
    // cache like any other MAP_SHARED write.
    var done = 0;
    while (done < length) {
      final n = math.min(length - done, _zeroizeChunk);
      final region = map(offset: offset + done, length: n, writable: true);
      try {
        region.zeroize();
      } finally {
        region.close();
      }
      done += n;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closeRegions();
    _freeScratch();
    _libc.close(_fd);
  }

  @override
  String toString() => 'PosixMmapFile($path, size: $_size, '
      'readOnly: $readOnly, '
      'flags: 0x${_statusFlags.toRadixString(16)})';
}

/// A zero-copy window returned by [PosixMmapFile.map].
final class PosixMappedRegion implements MappedRegion {
  final PosixMmapFile _owner;
  final _Libc _libc;
  final Pointer<Uint8> _base;
  final int _mapLength;
  final int _delta;
  final bool _writable;
  final Uint8List _all;
  @override
  final int offset;
  @override
  final int length;
  bool _closed = false;

  PosixMappedRegion._(this._owner, this._libc, this._base, this._mapLength,
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
    if (_libc.msync(_base.cast(), _mapLength, _msSync) < 0) {
      throw PosixException('msync', _libc.errno, _owner.path);
    }
  }

  @override
  void zeroize() {
    if (_closed) throw StateError('Mapped region is closed');
    if (!_writable) {
      throw StateError('Cannot zeroize a read-only mapping');
    }
    _libc.zeroMemory((_base + _delta).cast(), length);
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
    _libc.madvise((_base + _delta + range.offset).cast(), range.length,
        _madvWillNeed);
  }

  @override
  void discard({int offset = 0, int? length}) {
    final range = _hintRange(offset, length);
    if (range.length == 0) return;
    _libc.madvise((_base + _delta + range.offset).cast(), range.length,
        _madvDontNeed);
  }

  /// Hints that this window will be read sequentially (`MADV_SEQUENTIAL`).
  void adviseSequential() => _advise(_madvSequential);

  /// Asks the kernel to prefetch this window (`MADV_WILLNEED`).
  void adviseWillNeed() => _advise(_madvWillNeed);

  /// Drops the window's resident pages (`MADV_DONTNEED`).  Safe for read-only
  /// windows; for writable windows flush first — dirty MAP_SHARED pages are
  /// written back by the kernel, but flushing makes that ordering explicit.
  void adviseDontNeed() => _advise(_madvDontNeed);

  void _advise(int advice) {
    if (_closed) throw StateError('Mapped region is closed');
    // Advisory calls never fail the operation; ignore the return value.
    _libc.madvise(_base.cast(), _mapLength, advice);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    // munmap drops the pages; msync is the caller-controlled durability step.
    _libc.munmap(_base.cast(), _mapLength);
    _owner._removeRegion(this);
  }
}
