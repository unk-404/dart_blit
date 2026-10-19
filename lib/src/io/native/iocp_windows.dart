/// Windows overlapped I/O engine driven by an I/O completion port (IOCP).
///
/// The synchronous `MmapFile` engine is a QD1 engine: every `readAt` call
/// submits one `ReadFile` and blocks until it completes.  On an NVMe drive that
/// leaves most of the device queue idle, so sequential batches pay the full
/// per-request latency.  This file implements the same kind of handle with
/// `FILE_FLAG_OVERLAPPED`, associates it with a private completion port, and
/// keeps up to [IocpFile.queueDepth] reads/writes in flight before reaping the
/// completions with `GetQueuedCompletionStatus`.  A single worker isolate can
/// therefore reach QD 32–128 without any C code or extra isolates.
///
/// ## Design
///
/// * One `OVERLAPPED` (32 bytes on x64) is `calloc`ed per request; only the
///   `Offset` (byte 16) / `OffsetHigh` (byte 20) fields are written.  Windows
///   zeroes nothing else, so the whole block starts zeroed and `hEvent` is NULL.
/// * A single contiguous `calloc` block backs the whole batch (one allocation
///   per batch instead of one per request).  `readManySync` copies that block
///   into a `Uint8List` exactly once, preserving request order; `writeManySync`
///   copies the caller's blocks into it exactly once before dispatching.
/// * `Map<int, int>` maps the `OVERLAPPED` address to the request index, so
///   completions can arrive in any order.
/// * Completions are always reaped from the port: a `ReadFile`/`WriteFile` that
///   finishes synchronously still queues a packet for an IOCP-associated
///   handle.  Only an immediate failure (other than `ERROR_IO_PENDING`) does
///   not.
/// * `GetLastError` is read immediately after every failing call; on error the
///   batch is drained before the buffers are freed, so Windows never writes into
///   released memory.
///
/// Every function pointer is looked up and warmed up in the [_Win32]
/// constructor, before any operation whose `GetLastError` we care about.
library;

// ignore_for_file: camel_case_types

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Win32 FFI bindings (x64, C calling convention)
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

typedef _CreateIoCompletionPort_C = IntPtr Function(
  IntPtr,
  IntPtr,
  IntPtr,
  Uint32,
);
typedef _CreateIoCompletionPort = int Function(int, int, int, int);

typedef _GetQueuedCompletionStatus_C = Int32 Function(
  IntPtr,
  Pointer<Uint32>,
  Pointer<IntPtr>,
  Pointer<Pointer<Void>>,
  Uint32,
);
typedef _GetQueuedCompletionStatus = int Function(
  int,
  Pointer<Uint32>,
  Pointer<IntPtr>,
  Pointer<Pointer<Void>>,
  int,
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

typedef _GetFileSizeEx_C = Int32 Function(IntPtr, Pointer<Int64>);
typedef _GetFileSizeEx = int Function(int, Pointer<Int64>);

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

typedef _FlushFileBuffers_C = Int32 Function(IntPtr);
typedef _FlushFileBuffers = int Function(int);

typedef _CancelIoEx_C = Int32 Function(IntPtr, Pointer<Void>);
typedef _CancelIoEx = int Function(int, Pointer<Void>);

typedef _GetLastError_C = Uint32 Function();
typedef _GetLastError = int Function();

typedef _CloseHandle_C = Int32 Function(IntPtr);
typedef _CloseHandle = int Function(int);

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _fileShareAll = 0x00000007;
const int _openExisting = 3;
const int _openAlways = 4;
const int _fileAttributeNormal = 0x80;
const int _fileFlagOverlapped = 0x40000000;
const int _invalidHandleValue = -1;
const int _errorHandleEof = 38;
const int _errorIoPending = 997;
const int _errorOperationAborted = 995;
const int _fsctlSetSparse = 0x000900C4;

/// `OVERLAPPED` is 32 bytes on x64: Internal@0, InternalHigh@8, Offset@16,
/// OffsetHigh@20, hEvent@24.  We only ever touch Offset/OffsetHigh.
const int _overlappedSize = 32;

/// ReadFile/WriteFile take a DWORD byte count; single-request helpers chunk
/// through this many bytes at a time so the native scratch stays bounded.
const int _scratchChunk = 8 << 20;

/// Upper bound for one `GetQueuedCompletionStatus` wait.  A correct batch
/// always has one packet per outstanding request, so this only fires on a
/// programming error / dead device and turns a hang into a diagnosable error.
const int _completionTimeoutMs = 120000;

/// Bound used while draining after an error or during `close()`.
const int _drainTimeoutMs = 5000;

/// Thrown when a Win32 call on an [IocpFile] fails.
class IocpException implements Exception {
  /// The API that failed, e.g. `ReadFile` or `GetQueuedCompletionStatus`.
  final String op;

  /// The Win32 error code (`GetLastError`).
  final int code;

  /// File path the failing handle was opened for.
  final String path;

  /// File offset of the failing request, when one is known.
  final int? offset;

  const IocpException(this.op, this.code, this.path, {this.offset});

  @override
  String toString() =>
      'IocpException: $op failed (win32 error $code)'
      '${offset == null ? '' : ' at offset $offset'} for $path';
}

class _Win32 {
  final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');

  late final _CreateFileW createFileW = _k32
      .lookupFunction<_CreateFileW_C, _CreateFileW>('CreateFileW');
  late final _CreateIoCompletionPort createIoCompletionPort = _k32
      .lookupFunction<_CreateIoCompletionPort_C, _CreateIoCompletionPort>(
        'CreateIoCompletionPort',
      );
  late final _GetQueuedCompletionStatus getQueuedCompletionStatus = _k32
      .lookupFunction<_GetQueuedCompletionStatus_C, _GetQueuedCompletionStatus>(
        'GetQueuedCompletionStatus',
      );
  late final _ReadFile readFile = _k32.lookupFunction<_ReadFile_C, _ReadFile>(
    'ReadFile',
  );
  late final _WriteFile writeFile = _k32
      .lookupFunction<_WriteFile_C, _WriteFile>('WriteFile');
  late final _GetFileSizeEx getFileSizeEx = _k32
      .lookupFunction<_GetFileSizeEx_C, _GetFileSizeEx>('GetFileSizeEx');
  late final _SetFilePointerEx setFilePointerEx = _k32
      .lookupFunction<_SetFilePointerEx_C, _SetFilePointerEx>(
        'SetFilePointerEx',
      );
  late final _SetEndOfFile setEndOfFile = _k32
      .lookupFunction<_SetEndOfFile_C, _SetEndOfFile>('SetEndOfFile');
  late final _DeviceIoControl deviceIoControl = _k32
      .lookupFunction<_DeviceIoControl_C, _DeviceIoControl>('DeviceIoControl');
  late final _FlushFileBuffers flushFileBuffers = _k32
      .lookupFunction<_FlushFileBuffers_C, _FlushFileBuffers>(
        'FlushFileBuffers',
      );
  late final _CancelIoEx cancelIoEx = _k32
      .lookupFunction<_CancelIoEx_C, _CancelIoEx>('CancelIoEx');
  late final _GetLastError getLastError = _k32
      .lookupFunction<_GetLastError_C, _GetLastError>('GetLastError');
  late final _CloseHandle closeHandle = _k32
      .lookupFunction<_CloseHandle_C, _CloseHandle>('CloseHandle');

  _Win32() {
    // Warm up every lazy lookupFunction once, before any operation whose
    // GetLastError we care about.  Otherwise the first lookup can reset the
    // thread's last error (observed on Dart 3.13.5).
    createFileW;
    createIoCompletionPort;
    getQueuedCompletionStatus;
    readFile;
    writeFile;
    getFileSizeEx;
    setFilePointerEx;
    setEndOfFile;
    deviceIoControl;
    flushFileBuffers;
    cancelIoEx;
    getLastError;
    closeHandle;
  }

  Never fail(String op, String path, {int? offset}) =>
      throw IocpException(op, getLastError(), path, offset: offset);
}

/// One outstanding (or about-to-be-submitted) request in a batch.
final class _BatchRequest {
  final int index;

  /// Offset in the file.
  final int offset;

  /// Pointer into the batch's single contiguous buffer.
  final Pointer<Uint8> buffer;

  /// Number of bytes to transfer (a DWORD, so <= 1 GiB by construction).
  final int length;

  /// `true` for WriteFile, `false` for ReadFile.
  final bool isWrite;

  /// Bytes actually transferred, filled in by the reaper.
  int completedBytes = 0;

  _BatchRequest(
    this.index,
    this.offset,
    this.buffer,
    this.length,
    this.isWrite,
  );
}

/// A random-access Windows file doing overlapped I/O through a private IOCP.
///
/// All methods are synchronous; use [open] for an async-typed entry point.
/// The instance is meant to be used from one isolate at a time.  The batch
/// methods ([readManySync] / [writeManySync]) keep up to [queueDepth] requests
/// in flight, which is what turns a QD1 latency-bound engine into a
/// queue-driven one.
final class IocpFile {
  final _Win32 _win;
  final int _handle;
  final int _iocp;
  final Map<int, int> _outstanding = <int, int>{};

  /// OVERLAPPED blocks for reads that failed with `ERROR_HANDLE_EOF`.  They
  /// are only released after the handles are closed (see [close]).
  final List<int> _parkedOverlapped = <int>[];

  int _length = 0;
  bool _closed = false;

  /// File path this handle was opened for.
  final String path;

  /// Whether the handle was opened with `GENERIC_READ` only.
  final bool readOnly;

  /// Maximum number of requests kept in flight per batch, clamped to 1..128.
  final int queueDepth;

  IocpFile._(
    this._win,
    this._handle,
    this._iocp,
    this.path,
    this.readOnly,
    this.queueDepth,
  );

  /// Opens [path] and prepares an IOCP-backed handle.
  ///
  /// [queueDepth] is the per-batch in-flight cap, clamped to `1..128`.
  static Future<IocpFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    int queueDepth = 32,
  }) async => openSync(
    path,
    create: create,
    readOnly: readOnly,
    queueDepth: queueDepth,
  );

  /// Synchronous variant of [open].
  static IocpFile openSync(
    String path, {
    bool create = true,
    bool readOnly = false,
    int queueDepth = 32,
  }) {
    final depth = queueDepth.clamp(1, 128);
    final win = _Win32();
    final nativePath = path.toNativeUtf16();
    final int handle;
    int createError = 0;
    try {
      handle = win.createFileW(
        nativePath,
        readOnly ? _genericRead : (_genericRead | _genericWrite),
        _fileShareAll,
        nullptr,
        create ? _openAlways : _openExisting,
        _fileAttributeNormal | _fileFlagOverlapped,
        0,
      );
      // Read GetLastError before any other FFI call (malloc.free below can
      // clobber the thread's last error on some builds).
      if (handle == _invalidHandleValue) createError = win.getLastError();
    } finally {
      malloc.free(nativePath);
    }
    if (handle == _invalidHandleValue) {
      throw IocpException('CreateFileW', createError, path);
    }
    // NumberOfConcurrentThreads = 0 => one per processor; we block in this
    // isolate, so the actual concurrency is bounded by queueDepth.
    final iocp = win.createIoCompletionPort(_invalidHandleValue, 0, 0, 0);
    if (iocp == 0) {
      final err = win.getLastError();
      win.closeHandle(handle);
      throw IocpException('CreateIoCompletionPort(create)', err, path);
    }
    if (win.createIoCompletionPort(handle, iocp, 0, 0) == 0) {
      final err = win.getLastError();
      win.closeHandle(handle);
      win.closeHandle(iocp);
      throw IocpException('CreateIoCompletionPort(associate)', err, path);
    }
    final file = IocpFile._(win, handle, iocp, path, readOnly, depth);
    try {
      file._length = file._querySize();
    } catch (_) {
      file.close();
      rethrow;
    }
    return file;
  }

  /// Whether [close] has run.
  bool get isClosed => _closed;

  /// Current file size in bytes (re-queried from the OS, then cached).
  int get length {
    _checkOpen();
    _length = _querySize();
    return _length;
  }

  int _querySize() {
    final size = calloc<Int64>();
    try {
      if (_win.getFileSizeEx(_handle, size) == 0) {
        _win.fail('GetFileSizeEx', path);
      }
      return size.value;
    } finally {
      calloc.free(size);
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

  /// Submits one overlapped operation.
  ///
  /// Returns `true` when a completion packet is expected (always, except for a
  /// read that fails immediately with `ERROR_HANDLE_EOF`, which Windows does
  /// not queue).
  bool _submit(_BatchRequest request) {
    final overlapped = calloc<Uint8>(_overlappedSize);
    // OFFSET is written as two DWORDs at byte 16 / 20 of the zeroed block.
    final fields = overlapped.cast<Uint32>();
    fields[4] = request.offset & 0xFFFFFFFF;
    fields[5] = (request.offset >> 32) & 0xFFFFFFFF;
    _outstanding[overlapped.address] = request.index;

    final int ok;
    final overlappedPtr = overlapped.cast<Void>();
    if (request.isWrite) {
      ok = _win.writeFile(
        _handle,
        request.buffer,
        request.length,
        nullptr,
        overlappedPtr,
      );
    } else {
      ok = _win.readFile(
        _handle,
        request.buffer,
        request.length,
        nullptr,
        overlappedPtr,
      );
    }
    if (ok != 0) return true; // Completed synchronously; packet still queued.
    final err = _win.getLastError();
    // 997 = ERROR_IO_PENDING.  Zero is the other "packet is coming" case:
    // Windows sometimes reports a synchronously completed overlapped request
    // as FALSE/ERROR_SUCCESS (observed on Win11 + NTFS), and a clobbered
    // thread-last-error by the VM shows up the same way.  Treating both as
    // pending is the only safe choice: the packet was queued in every observed
    // case, and a genuinely failed request then surfaces as a completion with
    // its real status in the port.
    if (err == _errorIoPending || err == 0) return true;
    if (!request.isWrite && err == _errorHandleEof) {
      // Read past EOF.  Windows may or may not queue a packet for this; the
      // OVERLAPPED is parked and freed only after the handle is closed, so a
      // late packet can never scribble on reused memory.
      _outstanding.remove(overlapped.address);
      _parkedOverlapped.add(overlapped.address);
      request.completedBytes = 0;
      return false;
    }
    _outstanding.remove(overlapped.address);
    calloc.free(overlapped);
    throw IocpException(
      request.isWrite ? 'WriteFile' : 'ReadFile',
      err,
      path,
      offset: request.offset,
    );
  }

  /// Runs [requests] through the completion port with at most [queueDepth]
  /// outstanding operations.
  ///
  /// On failure the batch is drained (cancelling pending I/O) before this
  /// throws, so no caller buffer can be written after it is freed.
  void _runBatch(List<_BatchRequest> requests) {
    if (requests.isEmpty) return;
    final bytes = calloc<Uint32>();
    final key = calloc<IntPtr>();
    final slot = calloc<Pointer<Void>>();
    var issued = 0;
    IocpException? failure;
    try {
      while (true) {
        if (failure == null) {
          while (issued < requests.length && _outstanding.length < queueDepth) {
            final request = requests[issued];
            try {
              _submit(request);
            } on IocpException catch (error) {
              failure = error;
            }
            issued++;
          }
        }
        if (_outstanding.isEmpty) break;

        bytes.value = 0;
        key.value = 0;
        slot.value = nullptr;
        final ok = _win.getQueuedCompletionStatus(
          _iocp,
          bytes,
          key,
          slot,
          _completionTimeoutMs,
        );
        final err = ok == 0 ? _win.getLastError() : 0;
        final overlapped = slot.value;
        if (overlapped.address == 0) {
          // The wait itself failed (timeout or a broken port).
          failure ??= IocpException('GetQueuedCompletionStatus', err, path);
          break;
        }
        final index = _outstanding.remove(overlapped.address);
        if (index == null) {
          // A late packet for a parked EOF request: leave its OVERLAPPED
          // allocated (close() releases it) rather than freeing memory that
          // Windows may still reference.
          continue;
        }
        calloc.free(overlapped.cast<Uint8>());
        final request = requests[index];
        if (ok != 0) {
          request.completedBytes = bytes.value;
        } else if (err == _errorHandleEof || err == _errorOperationAborted) {
          request.completedBytes = 0;
        } else {
          failure ??= IocpException(
            request.isWrite ? 'WriteFile' : 'ReadFile',
            err,
            path,
            offset: request.offset,
          );
        }
      }
    } finally {
      calloc.free(bytes);
      calloc.free(key);
      calloc.free(slot);
      if (_outstanding.isNotEmpty) _drainOutstanding(cancel: true);
    }
    if (failure != null) throw failure;
  }

  /// Waits for every tracked request, optionally cancelling it first.
  ///
  /// Used defensively after an error and from [close]; a correct synchronous
  /// caller never has outstanding requests here.
  void _drainOutstanding({bool cancel = false}) {
    if (_outstanding.isEmpty) return;
    if (cancel) _win.cancelIoEx(_handle, nullptr);
    final bytes = calloc<Uint32>();
    final key = calloc<IntPtr>();
    final slot = calloc<Pointer<Void>>();
    try {
      while (_outstanding.isNotEmpty) {
        bytes.value = 0;
        key.value = 0;
        slot.value = nullptr;
        _win.getQueuedCompletionStatus(
          _iocp,
          bytes,
          key,
          slot,
          _drainTimeoutMs,
        );
        final overlapped = slot.value;
        if (overlapped.address == 0) return; // Port unusable; stop waiting.
        if (_outstanding.remove(overlapped.address) != null) {
          calloc.free(overlapped.cast<Uint8>());
        }
      }
    } finally {
      calloc.free(bytes);
      calloc.free(key);
      calloc.free(slot);
    }
  }

  /// Reads [blockLength] bytes at every offset in [offsets] with up to
  /// [queueDepth] requests in flight.
  ///
  /// The returned buffer concatenates the blocks in [offsets] order (block `i`
  /// at `i * blockLength`).  Every range must satisfy
  /// `offset + blockLength <= length`; otherwise [RangeError] is thrown.
  ///
  /// A short completion (only possible if the file is truncated concurrently)
  /// leaves the corresponding bytes zeroed.
  Uint8List readManySync(List<int> offsets, int blockLength) {
    _checkOpen();
    if (blockLength < 0) {
      throw RangeError.value(blockLength, 'blockLength');
    }
    if (offsets.isEmpty || blockLength == 0) return Uint8List(0);
    _length = _querySize();
    for (var i = 0; i < offsets.length; i++) {
      final offset = offsets[i];
      if (offset < 0) throw RangeError.value(offset, 'offsets[$i]');
      if (offset + blockLength > _length) {
        throw RangeError(
          'offsets[$i] = $offset + blockLength $blockLength '
          'exceeds file length $_length',
        );
      }
    }
    final total = offsets.length * blockLength;
    final buffer = calloc<Uint8>(total);
    try {
      final requests = <_BatchRequest>[
        for (var i = 0; i < offsets.length; i++)
          _BatchRequest(
            i,
            offsets[i],
            buffer + i * blockLength,
            blockLength,
            false,
          ),
      ];
      _runBatch(requests);
      // One copy out of the native batch buffer; the result must own its
      // memory because the calloc block is freed in the finally below.
      final result = Uint8List(total);
      result.setAll(0, buffer.asTypedList(total));
      return result;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Writes every block in [blocks] at the matching offset in [offsets].
  ///
  /// All blocks are copied into one contiguous buffer (a single copy) before
  /// dispatching, then written with up to [queueDepth] requests in flight.
  /// Returns the total number of bytes written.  Writes may extend the file.
  int writeManySync(List<int> offsets, List<Uint8List> blocks) {
    _checkWritable();
    if (offsets.length != blocks.length) {
      throw ArgumentError('offsets and blocks must have the same length');
    }
    var total = 0;
    var maxEnd = _length;
    for (var i = 0; i < offsets.length; i++) {
      final offset = offsets[i];
      if (offset < 0) throw RangeError.value(offset, 'offsets[$i]');
      total += blocks[i].length;
      if (offset + blocks[i].length > maxEnd) {
        maxEnd = offset + blocks[i].length;
      }
    }
    if (total == 0) return 0;
    final buffer = calloc<Uint8>(total);
    try {
      var cursor = 0;
      final requests = <_BatchRequest>[];
      for (var i = 0; i < offsets.length; i++) {
        final block = blocks[i];
        if (block.isEmpty) continue;
        final target = buffer + cursor;
        target.asTypedList(block.length).setAll(0, block);
        requests.add(
          _BatchRequest(
            requests.length,
            offsets[i],
            target,
            block.length,
            true,
          ),
        );
        cursor += block.length;
      }
      _runBatch(requests);
      if (maxEnd > _length) _length = maxEnd;
      var written = 0;
      for (final request in requests) {
        written += request.completedBytes;
      }
      return written;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Reads at most `end - start` bytes from [offset] into [dst].
  ///
  /// Clamps at EOF like the mmap engine and returns the number of bytes read
  /// (0 when [offset] is at or past the end of file).
  int readAtSync(int offset, Uint8List dst, {int start = 0, int? end}) {
    _checkOpen();
    final stop = end ?? dst.length;
    RangeError.checkValidRange(start, stop, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    _length = _querySize();
    if (offset >= _length) return 0;
    final wanted = math.min(stop - start, _length - offset);
    if (wanted <= 0) return 0;
    // Bounded scratch: a single huge read is chunked instead of duplicating
    // the whole destination in native memory.
    final capacity = math.min(wanted, _scratchChunk);
    final scratch = calloc<Uint8>(capacity);
    try {
      var done = 0;
      while (done < wanted) {
        final chunk = math.min(wanted - done, capacity);
        final request = _BatchRequest(0, offset + done, scratch, chunk, false);
        _runBatch(<_BatchRequest>[request]);
        final got = request.completedBytes;
        if (got <= 0) break;
        dst.setRange(
          start + done,
          start + done + got,
          scratch.asTypedList(got),
        );
        done += got;
        if (got < chunk) break;
      }
      return done;
    } finally {
      calloc.free(scratch);
    }
  }

  /// Writes `src[start..end)` at [offset] and returns the number of bytes
  /// written.  Writes may extend the file.
  int writeAtSync(int offset, Uint8List src, {int start = 0, int? end}) {
    _checkWritable();
    final stop = end ?? src.length;
    RangeError.checkValidRange(start, stop, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    final wanted = stop - start;
    if (wanted == 0) return 0;
    final capacity = math.min(wanted, _scratchChunk);
    final scratch = calloc<Uint8>(capacity);
    try {
      var done = 0;
      while (done < wanted) {
        final chunk = math.min(wanted - done, capacity);
        scratch.asTypedList(chunk).setRange(0, chunk, src, start + done);
        final request = _BatchRequest(0, offset + done, scratch, chunk, true);
        _runBatch(<_BatchRequest>[request]);
        final put = request.completedBytes;
        done += put;
        if (put < chunk) break;
      }
      if (offset + done > _length) _length = offset + done;
      return done;
    } finally {
      calloc.free(scratch);
    }
  }

  /// Sets the file length, optionally marking the file sparse first.
  ///
  /// Marking sparse before extending avoids NTFS zero-filling the gap when a
  /// later write lands far beyond EOF (same trick as the mmap engine).
  void truncate(int newLength, {bool sparse = true}) {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    _drainOutstanding();
    if (sparse && newLength > _length) {
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
    final position = calloc<Int64>();
    try {
      if (_win.setFilePointerEx(_handle, newLength, position, 0) == 0) {
        _win.fail('SetFilePointerEx', path);
      }
      if (_win.setEndOfFile(_handle) == 0) {
        _win.fail('SetEndOfFile', path);
      }
    } finally {
      calloc.free(position);
    }
    _length = newLength;
  }

  /// Flushes the file's buffered data to disk (`FlushFileBuffers`).
  ///
  /// A read-only handle has nothing to flush; `FlushFileBuffers` would fail
  /// with `ERROR_ACCESS_DENIED` there, so this is a no-op in that case.
  void flush() {
    _checkOpen();
    if (readOnly) return;
    if (_win.flushFileBuffers(_handle) == 0) {
      _win.fail('FlushFileBuffers', path);
    }
  }

  /// Drains any outstanding requests and releases the handle and port.
  ///
  /// Idempotent: calling it again is a no-op.  The file is unusable afterwards.
  void close() {
    if (_closed) return;
    _closed = true;
    _drainOutstanding(cancel: true);
    _win.closeHandle(_handle);
    _win.closeHandle(_iocp);
    // No further completions can reach this port now, so parked OVERLAPPED
    // blocks can be released.
    for (final address in _parkedOverlapped) {
      calloc.free(Pointer<Uint8>.fromAddress(address));
    }
    _parkedOverlapped.clear();
  }

  @override
  String toString() =>
      'IocpFile($path, size: $_length, '
      'readOnly: $readOnly, queueDepth: $queueDepth, closed: $_closed)';
}
