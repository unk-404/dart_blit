/// Automatic native read engine selection.
///
/// [ReadFast] is a read-optimized [BytesFile] facade.  It chooses a backend
/// from the platform and file size, then keeps the chosen engine visible for
/// diagnostics:
///
/// * Windows: mmap-backed isolate pool for files up to 1 GiB, IOCP-backed pool
///   above that.
/// * Linux: io_uring for files above the mmap threshold, otherwise an
///   mmap-backed isolate pool.
/// * Other native platforms: mmap-backed isolate pool.
///
/// The facade is deliberately conservative: an engine that fails to open falls
/// back to the isolate pool rather than failing the read.  Writes are delegated
/// only to backends that support them; the default open is read-only.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes_file.dart';
import 'native/isolate_pool.dart';
import 'native/uring_file.dart';

/// Selected backend for [ReadFast].
enum ReadFastEngine {
  /// Per-worker read-only mapping inside [ParallelBytesFile].
  mmapPool,

  /// Windows IOCP-backed [ParallelBytesFile].
  iocpPool,

  /// Linux [UringBytesFile].
  ioUring,

  /// Plain [ParallelBytesFile] without a per-worker mapping.
  isolatePool,
}

/// A read-optimized [BytesFile] with automatic backend selection.
final class ReadFast implements BytesFile {
  ReadFast._(this._backend, this.engine, this.workers, this.mappedReadOnly);

  final BytesFile _backend;

  /// Backend selected at open time.
  final ReadFastEngine engine;

  /// Worker count used by the selected pool (1 for io_uring).
  final int workers;

  /// Whether the read-only backend maps the file per worker.
  final bool mappedReadOnly;

  @override
  Future<int> get length => _backend.length;

  @override
  Future<int> readAt(int offset, Uint8List dst, {int start = 0, int? end}) =>
      _backend.readAt(offset, dst, start: start, end: end);

  @override
  Future<int> writeAt(int offset, Uint8List src, {int start = 0, int? end}) =>
      _backend.writeAt(offset, src, start: start, end: end);

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) =>
      _backend.append(src, start: start, end: end);

  @override
  Future<void> truncate(int newLength) => _backend.truncate(newLength);

  @override
  Future<void> flush() => _backend.flush();

  @override
  Future<void> close() => _backend.close();

  @override
  Future<void> delete() => _backend.delete();

  @override
  bool get isClosed => _backend.isClosed;

  @override
  bool get supportsConcurrentReads => _backend.supportsConcurrentReads;

  /// Batched read when the selected backend supports it.
  ///
  /// The isolate-pool backend returns one transferred buffer per offset.  The
  /// io_uring backend uses one native buffer per block and copies it back here,
  /// so callers get the same ownership semantics as [ParallelBytesFile].
  Future<List<Uint8List>> readMany(List<int> offsets, int blockLength) async {
    final backend = _backend;
    if (backend is ParallelBytesFile) {
      return backend.readMany(offsets, blockLength);
    }
    if (backend is UringBytesFile) {
      final out = <Uint8List>[];
      for (final offset in offsets) {
        final buffer = Uint8List(blockLength);
        await backend.readAt(offset, buffer);
        out.add(buffer);
      }
      return out;
    }
    final out = <Uint8List>[];
    for (final offset in offsets) {
      final buffer = Uint8List(blockLength);
      await backend.readAt(offset, buffer);
      out.add(buffer);
    }
    return out;
  }

  /// Opens [path] with an automatically selected read engine.
  ///
  /// [workers] overrides the CPU/file-size-derived worker count.  [mmapLimit]
  /// is the largest file mapped per worker (default 1 GiB); larger files use
  /// IOCP on Windows or io_uring on Linux.  [preferUring] can be disabled for
  /// diagnostics or when the kernel rejects io_uring.
  static Future<ReadFast> open(
    String path, {
    bool create = false,
    bool readOnly = true,
    int? workers,
    int mmapLimit = 1 << 30,
    int? maxQueue,
    bool preferUring = true,
  }) async {
    if (mmapLimit < 0) throw RangeError.value(mmapLimit, 'mmapLimit');
    final file = File(path);
    final size = file.existsSync() ? file.lengthSync() : 0;
    final cpuWorkers = math.min(
      32,
      math.max(4, Platform.numberOfProcessors - 1),
    );
    final selectedWorkers =
        workers ?? (size <= 64 << 20 ? math.min(8, cpuWorkers) : cpuWorkers);
    if (selectedWorkers < 1) {
      throw RangeError.value(selectedWorkers, 'workers');
    }
    final queue = maxQueue ?? selectedWorkers * 4;

    if (readOnly && preferUring && Platform.isLinux && size > mmapLimit) {
      try {
        final uring = await UringBytesFile.open(
          path,
          create: create,
          readOnly: true,
          entries: math.max(64, selectedWorkers * 8),
        );
        return ReadFast._(uring, ReadFastEngine.ioUring, 1, false);
      } on Object {
        // Kernel/filesystem may not support io_uring; fall through.
      }
    }

    final useIocp = Platform.isWindows && size > mmapLimit;
    final pool = await ParallelBytesFile.open(
      path,
      create: create,
      readOnly: readOnly,
      maxWorkers: selectedWorkers,
      useIocp: useIocp,
      mmapReadCacheLimit: readOnly && size <= mmapLimit ? size : 0,
      maxQueue: queue,
    );
    final engine = useIocp
        ? ReadFastEngine.iocpPool
        : (readOnly && size <= mmapLimit
              ? ReadFastEngine.mmapPool
              : ReadFastEngine.isolatePool);
    return ReadFast._(
      pool,
      engine,
      selectedWorkers,
      engine == ReadFastEngine.mmapPool,
    );
  }
}



