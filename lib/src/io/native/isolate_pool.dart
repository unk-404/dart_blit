/// Automatic isolate pool for native random-access I/O.
///
/// Each worker isolate owns its own [MmapFile] handle; the pool dispatches
/// independent `readAt`/`writeAt` requests to idle workers and applies
/// backpressure through a bounded FIFO queue.  This turns the QD1 latency-bound
/// single-threaded engine into a multi-queue engine without any C code.
///
/// ## Semantics
///
/// * Requests are independent.  Overlapping writes (or a write followed by a
///   read of the same range) are **not** automatically ordered; await the write
///   before issuing the read, or use [flush] as a barrier.
/// * `truncate`, `flush` and `close` are barriers: they wait for queued and
///   in-flight requests, run on the coordinator handle, then release the queue.
/// * `readAt` copies the worker's result into the caller's buffer (one copy at
///   the isolate boundary).  Use [read] to get the transferred buffer directly.
/// * Web is intentionally unsupported: OPFS sync access handles are exclusive
///   per file, so a parallel worker pool would fight over the same lock.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../bytes_file.dart';
import 'iocp_windows.dart';
import 'mmap.dart';

/// A [BytesFile] that dispatches operations across a pool of worker isolates.
final class ParallelBytesFile implements BytesFile {
  final String path;
  final bool readOnly;
  final int maxWorkers;
  final bool useIocp;
  final bool direct;
  final int mmapReadCacheLimit;
  final MmapFile _coordinator;
  final ReceivePort _replies = ReceivePort();
  final List<_Worker> _workers = <_Worker>[];
  final List<_Job> _queue = <_Job>[];
  final Map<int, _Job> _inflight = <int, _Job>{};
  int _nextId = 1;
  bool _closed = false;
  bool _closing = false;
  final List<int> _barrierWatermarks = <int>[];
  final List<({int watermark, Completer<void> completer})> _drainWaiters =
      <({int watermark, Completer<void> completer})>[];
  Future<void> _barrierTail = Future<void>.value();

  ParallelBytesFile._(
    this.path,
    this.readOnly,
    this.maxWorkers,
    this.useIocp,
    this.direct,
    this.mmapReadCacheLimit,
    this._coordinator,
  ) {
    _replies.listen(_onReply);
  }

  /// Opens [path] and spawns up to [maxWorkers] worker isolates.
  ///
  /// Default concurrency is `min(32, max(2, cpus - 1))`; each worker is
  /// synchronous, so more workers are how a caller gets more outstanding I/O.
  /// The 32 cap keeps isolate/mmap overhead bounded on very large machines.
  ///
  /// [direct] uses `FILE_FLAG_NO_BUFFERING` in every worker (Windows) with
  /// 4 KiB-aligned requests; use it for aligned streaming, not random access.
  ///
  /// With [readOnly] and a file no larger than [mmapReadCacheLimit], each
  /// worker maps the whole file read-only once and serves reads from the map
  /// (hot random reads avoid a `ReadFile`/`pread` syscall per block).  Set the
  /// limit to `0` to disable, or raise it for hot files that fit in the address
  /// space; mapping is virtual and does not eagerly read the file.
  static Future<ParallelBytesFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    int? maxWorkers,
    bool useIocp = false,
    bool direct = false,
    int mmapReadCacheLimit = 1 << 30,
  }) async {
    if (useIocp && direct) {
      throw ArgumentError('useIocp and direct are mutually exclusive');
    }
    if (direct && !Platform.isWindows) {
      throw UnsupportedError('Direct I/O is not implemented on this platform.');
    }
    final workers = maxWorkers ??
        math.min(32, math.max(2, Platform.numberOfProcessors - 1));
    if (workers < 1) throw RangeError.value(workers, 'maxWorkers');
    if (mmapReadCacheLimit < 0) {
      throw RangeError.value(mmapReadCacheLimit, 'mmapReadCacheLimit');
    }
    final coordinator =
        openMmapFileSync(path, create: create, readOnly: readOnly);
    final pool = ParallelBytesFile._(
      path,
      readOnly,
      workers,
      useIocp,
      direct,
      mmapReadCacheLimit,
      coordinator,
    );
    try {
      await pool._spawnWorkers();
      return pool;
    } catch (_) {
      await pool.close();
      rethrow;
    }
  }

  Future<void> _spawnWorkers() async {
    final ready = <Future<void>>[];
    for (var i = 0; i < maxWorkers; i++) {
      final readyPort = ReceivePort();
      final done = Completer<void>();
      final isolate = await Isolate.spawn(
        _workerMain,
        [readyPort.sendPort, _replies.sendPort, path, readOnly, useIocp,
         direct, mmapReadCacheLimit],
        debugName: 'bytes-worker-$i',
        onExit: readyPort.sendPort,
        onError: readyPort.sendPort,
      );
      final worker = _Worker(i, isolate, readyPort);
      _workers.add(worker);
      ready.add(done.future);
      readyPort.listen((message) {
        if (message is SendPort) {
          worker.sendPort = message;
          if (!done.isCompleted) done.complete();
        } else if (message is List && message.isNotEmpty) {
          // Isolate error/exit notifications.
          worker.failed = true;
          if (!done.isCompleted) {
            done.completeError(StateError('Worker failed to start: $message'));
          }
          _failWorker(worker, StateError('Worker $i exited: $message'));
        }
      });
    }
    await Future.wait(ready);
  }

  void _onReply(Object? message) {
    if (message is! List) return;
    if (message.length == 2 && message[0] == 'ready') return;
    final id = message[0] as int;
    final job = _inflight.remove(id);
    if (job == null) return;
    final payload = message[1];
    final error = message.length > 2 ? message[2] : null;
    final worker = _workers[job.workerIndex];
    worker.busy = false;
    if (error != null) {
      job.completer.completeError(StateError('worker error: $error'));
    } else {
      try {
        job.completer.complete(payload);
      } catch (e, st) {
        job.completer.completeError(e, st);
      }
    }
    _dispatch();
    _maybeIdle();
  }

  void _failWorker(_Worker worker, Object error) {
    if (worker.busy) {
      for (final job in _inflight.values.toList()) {
        if (job.workerIndex == worker.index) {
          _inflight.remove(job.id);
          job.completer.completeError(error);
        }
      }
      worker.busy = false;
    }
  }

  int? get _activeWatermark =>
      _barrierWatermarks.isEmpty ? null : _barrierWatermarks.first;

  void _dispatch() {
    if (_closed) return;
    final watermark = _activeWatermark;
    while (_queue.isNotEmpty) {
      // A barrier only freezes jobs submitted after it.  Jobs that were
      // already queued when the barrier was registered must keep draining,
      // otherwise the barrier can never wait for them (the old deadlock).
      if (watermark != null && _queue.first.id > watermark) break;
      _Worker? worker;
      for (final w in _workers) {
        if (!w.busy && !w.failed) {
          worker = w;
          break;
        }
      }
      if (worker == null) break;
      final job = _queue.removeAt(0);
      worker.busy = true;
      job.workerIndex = worker.index;
      _inflight[job.id] = job;
      worker.sendPort!.send(job.message);
    }
  }

  void _maybeIdle() {
    if (_inflight.isNotEmpty || _drainWaiters.isEmpty) return;
    final drained = <({int watermark, Completer<void> completer})>[];
    for (final waiter in _drainWaiters) {
      if (_queue.isEmpty || _queue.first.id > waiter.watermark) {
        drained.add(waiter);
      }
    }
    for (final waiter in drained) {
      _drainWaiters.remove(waiter);
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
  }

  Future<void> _waitBarrierDrained(int watermark) {
    if (_inflight.isEmpty &&
        (_queue.isEmpty || _queue.first.id > watermark)) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _drainWaiters.add((watermark: watermark, completer: completer));
    return completer.future;
  }

  /// Runs [action] after all jobs submitted before this call have completed.
  ///
  /// Jobs submitted after the barrier are queued and frozen (their id is above
  /// the watermark) until [action] finishes.  Multiple barriers are ordered by
  /// the smallest outstanding watermark.
  Future<T> _barrier<T>(Future<T> Function() action) {
    final watermark = _nextId - 1;
    _barrierWatermarks.add(watermark);
    _dispatch();
    _maybeIdle();
    final result = _barrierTail.then((_) async {
      try {
        await _waitBarrierDrained(watermark);
        return await action();
      } finally {
        _barrierWatermarks.remove(watermark);
        _dispatch();
        _maybeIdle();
      }
    });
    _barrierTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<Object?> _submit(String op, Map<String, Object?> args) {
    if (_closed || _closing) {
      return Future<Object?>.error(StateError('File is closed: $path'));
    }
    final id = _nextId++;
    final job = _Job(id, op, args);
    _queue.add(job);
    _dispatch();
    return job.completer.future;
  }

  @override
  Future<int> get length async {
    _checkOpen();
    return _coordinator.length;
  }

  int get lengthSync {
    _checkOpen();
    return _coordinator.length;
  }

  @override
  Future<int> readAt(int offset, Uint8List dst, {int start = 0, int? end}) async {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (start == e) return 0;
    final data = await read(offset, e - start);
    dst.setRange(start, start + data.length, data);
    return data.length;
  }

  /// Reads [length] bytes and returns the transferred buffer (no copy into a
  /// caller buffer; the buffer is allocated by the worker and transferred).
  Future<Uint8List> read(int offset, int length) async {
    _checkOpen();
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (length < 0) throw RangeError.value(length, 'length');
    if (length == 0) return Uint8List(0);
    final payload = await _submit('read', {'offset': offset, 'length': length});
    if (payload is TransferableTypedData) {
      return Uint8List.view(payload.materialize());
    }
    if (payload is Uint8List) return payload;
    throw StateError('Unexpected read payload: ${payload.runtimeType}');
  }

  /// Maximum number of ranges sent to one worker in one message.
  static const int batchSize = 32;

  /// Reads many independent ranges concurrently.
  ///
  /// Requests are grouped into batches of [batchSize] so one worker can use a
  /// deep I/O queue and one transfer covers many small reads.  Exactly adjacent
  /// ranges are coalesced into one larger read before batching, which removes
  /// most syscalls for sequential/scan workloads.  Results are in the same
  /// order as [offsets]; ranges past EOF are zero-filled.
  Future<List<Uint8List>> readMany(List<int> offsets, int length) async {
    _checkOpen();
    if (length < 0) throw RangeError.value(length, 'length');
    if (offsets.isEmpty) return <Uint8List>[];
    if (length == 0) {
      return List<Uint8List>.generate(offsets.length, (_) => Uint8List(0));
    }

    // Sort by offset, then merge exactly adjacent items into runs.  The
    // original indices are kept so the caller still gets the requested order.
    final entries = <({int offset, int index})>[
      for (var i = 0; i < offsets.length; i++)
        (offset: offsets[i], index: i),
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    final runs = <_ReadRun>[];
    for (final entry in entries) {
      if (runs.isNotEmpty) {
        final last = runs.last;
        if (entry.offset == last.offset + last.count * length) {
          last.count++;
          last.indices.add(entry.index);
          continue;
        }
      }
      runs.add(_ReadRun(entry.offset, [entry.index]));
    }

    final results = List<Uint8List?>.filled(offsets.length, null);
    final futures = <Future<Object?>>[];
    final groups = <List<_ReadRun>>[];
    for (var start = 0; start < runs.length; start += batchSize) {
      final end = math.min(start + batchSize, runs.length);
      final group = runs.sublist(start, end);
      groups.add(group);
      futures.add(_submit('readRanges', {
        'ranges': [
          for (final run in group) [run.offset, run.count * length],
        ],
      }));
    }
    final payloads = await Future.wait(futures);
    for (var g = 0; g < payloads.length; g++) {
      final payload = payloads[g];
      final data = payload is TransferableTypedData
          ? Uint8List.view(payload.materialize())
          : payload as Uint8List;
      var position = 0;
      for (final run in groups[g]) {
        for (var j = 0; j < run.count; j++) {
          final start = position + j * length;
          results[run.indices[j]] =
              Uint8List.sublistView(data, start, start + length);
        }
        position += run.count * length;
      }
    }
    return results.cast<Uint8List>();
  }

  /// Writes many independent ranges concurrently (variable block lengths).
  Future<int> writeMany(List<int> offsets, List<Uint8List> blocks) async {
    _checkWritable();
    if (offsets.length != blocks.length) {
      throw ArgumentError('offsets and blocks must have the same length');
    }
    if (offsets.isEmpty) return 0;
    var total = 0;
    final futures = <Future<Object?>>[];
    for (var start = 0; start < offsets.length; start += batchSize) {
      final end = math.min(start + batchSize, offsets.length);
      final groupOffsets = offsets.sublist(start, end);
      final groupBlocks = blocks.sublist(start, end);
      var bytes = 0;
      for (final block in groupBlocks) {
        bytes += block.length;
      }
      final joined = Uint8List(bytes);
      final lengths = <int>[];
      var position = 0;
      for (final block in groupBlocks) {
        joined.setRange(position, position + block.length, block);
        lengths.add(block.length);
        position += block.length;
      }
      futures.add(_submit('writeBatch', {
        'offsets': groupOffsets,
        'lengths': lengths,
        'data': TransferableTypedData.fromList([joined]),
      }));
    }
    final values = await Future.wait(futures);
    for (final value in values) {
      total += value as int;
    }
    return total;
  }

  @override
  Future<int> writeAt(int offset, Uint8List src, {int start = 0, int? end}) async {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (start == e) return 0;
    final copy = Uint8List.fromList(Uint8List.sublistView(src, start, e));
    final payload = await _submit(
      'write',
      {'offset': offset, 'data': TransferableTypedData.fromList([copy])},
    );
    return payload as int;
  }

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) async {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (start == e) return 0;
    return _barrier(() async {
      final len = _coordinator.length;
      return _coordinator.writeAt(len, src, start: start, end: e);
    });
  }

  @override
  Future<void> truncate(int newLength) {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    return _barrier(() async {
      _coordinator.truncate(newLength);
    });
  }

  @override
  Future<void> flush() {
    _checkOpen();
    return _barrier(() async {
      _coordinator.flush();
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_closing) {
      await _barrierTail;
      return;
    }
    _closing = true;
    try {
      await _barrier(() async {});
    } finally {
      _closed = true;
    }
    for (final worker in _workers) {
      worker.sendPort?.send({'op': 'close'});
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    for (final worker in _workers) {
      worker.isolate.kill(priority: Isolate.immediate);
      worker.readyPort.close();
    }
    _replies.close();
    _coordinator.close();
    _workers.clear();
    _queue.clear();
    _inflight.clear();
  }

  @override
  Future<void> delete() async {
    await close();
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  bool get isClosed => _closed;

  int get activeWorkers => _workers.where((w) => !w.failed).length;

  int get pending => _queue.length + _inflight.length;

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

  @override
  String toString() => 'ParallelBytesFile($path, workers: $maxWorkers, '
      'pending: $pending, closed: $_closed)';
}

final class _Worker {
  final int index;
  final Isolate isolate;
  final ReceivePort readyPort;
  SendPort? sendPort;
  bool busy = false;
  bool failed = false;

  _Worker(this.index, this.isolate, this.readyPort);
}

final class _ReadRun {
  final int offset;
  int count;
  final List<int> indices;

  _ReadRun(this.offset, this.indices) : count = indices.length;
}

final class _Job {
  final int id;
  final String op;
  final Map<String, Object?> args;
  final Completer<Object?> completer = Completer<Object?>();
  int workerIndex = -1;

  _Job(this.id, this.op, this.args);

  Map<String, Object?> get message => {'id': id, 'op': op, ...args};
}

/// Worker entrypoint: owns one [MmapFile] (or [IocpFile] on Windows) and
/// processes requests FIFO.
void _workerMain(List<Object> args) {
  final ready = args[0] as SendPort;
  final reply = args[1] as SendPort;
  final path = args[2] as String;
  final readOnly = args[3] as bool;
  final useIocp = args[4] as bool;
  final direct = args[5] as bool;
  final mmapReadCacheLimit = args[6] as int;
  final commands = ReceivePort();
  IocpFile? iocp;
  MmapFile? mmap;
  MappedRegion? readCache;
  Uint8List? readView;
  try {
    if (Platform.isWindows && useIocp) {
      iocp = IocpFile.openSync(
        path,
        create: false,
        readOnly: readOnly,
        queueDepth: ParallelBytesFile.batchSize,
      );
    } else {
      mmap = openMmapFileSync(
        path,
        create: false,
        readOnly: readOnly,
        direct: direct,
      );
      if (readOnly &&
          !direct &&
          mmapReadCacheLimit > 0 &&
          mmap.length > 0 &&
          mmap.length <= mmapReadCacheLimit) {
        try {
          readCache = mmap.map(
            offset: 0,
            length: mmap.length,
            writable: false,
          );
          readView = readCache.bytes;
        } catch (_) {
          // Mapping is an optimization; fall back to ReadFile/pread.
          readCache = null;
          readView = null;
        }
      }
    }
  } catch (e) {
    ready.send(['error', e.toString()]);
    commands.close();
    return;
  }

  int readInto(int offset, Uint8List dst, int start, int end) {
    final view = readView;
    final length = end - start;
    if (view != null && offset >= 0 && offset + length <= view.length) {
      dst.setRange(start, end, view, offset);
      return length;
    }
    return iocp?.readAtSync(offset, dst, start: start, end: end) ??
        mmap!.readAt(offset, dst, start: start, end: end);
  }

  int writeFrom(int offset, Uint8List src, int start, int end) =>
      iocp?.writeAtSync(offset, src, start: start, end: end) ??
      mmap!.writeAt(offset, src, start: start, end: end);

  void closeFile() {
    readCache?.close();
    iocp?.close();
    mmap?.close();
  }

  ready.send(commands.sendPort);
  commands.listen((message) {
    if (message is! Map) return;
    if (message['op'] == 'close') {
      closeFile();
      commands.close();
      Isolate.exit();
    }
    final id = message['id'] as int;
    final op = message['op'] as String;
    try {
      switch (op) {
        case 'read':
          final offset = message['offset'] as int;
          final length = message['length'] as int;
          final buf = Uint8List(length);
          final got = readInto(offset, buf, 0, length);
          final data = got == length ? buf : Uint8List.sublistView(buf, 0, got);
          reply.send([id, TransferableTypedData.fromList([data])]);
        case 'write':
          final offset = message['offset'] as int;
          final transferred = message['data'] as TransferableTypedData;
          final data = Uint8List.view(transferred.materialize());
          final put = writeFrom(offset, data, 0, data.length);
          reply.send([id, put]);
        case 'readBatch':
          final offsets = (message['offsets'] as List).cast<int>();
          final length = message['length'] as int;
          if (iocp != null) {
            final fileLength = iocp.length;
            var inBounds = true;
            for (final offset in offsets) {
              if (offset < 0 || offset + length > fileLength) {
                inBounds = false;
                break;
              }
            }
            if (inBounds) {
              final out = iocp.readManySync(offsets, length);
              reply.send([id, TransferableTypedData.fromList([out])]);
              return;
            }
          }
          final out = Uint8List(offsets.length * length);
          for (var i = 0; i < offsets.length; i++) {
            final start = i * length;
            final got = readInto(offsets[i], out, start, start + length);
            if (got < length) {
              out.fillRange(start + got, start + length, 0);
            }
          }
          reply.send([id, TransferableTypedData.fromList([out])]);
        case 'readRanges':
          final rawRanges = (message['ranges'] as List).cast<List>();
          final ranges = <List<int>>[
            for (final range in rawRanges)
              [range[0] as int, range[1] as int],
          ];
          final total = ranges.fold<int>(0, (sum, range) => sum + range[1]);
          if (iocp != null) {
            final firstLength = ranges.isEmpty ? 0 : ranges.first[1];
            var sameLength = true;
            var inBounds = true;
            final fileLength = iocp.length;
            for (final range in ranges) {
              if (range[1] != firstLength) sameLength = false;
              if (range[0] < 0 || range[0] + range[1] > fileLength) {
                inBounds = false;
              }
            }
            if (ranges.isNotEmpty && sameLength && inBounds) {
              final offsets = [for (final range in ranges) range[0]];
              final out = iocp.readManySync(offsets, firstLength);
              reply.send([id, TransferableTypedData.fromList([out])]);
              return;
            }
          }
          final out = Uint8List(total);
          var position = 0;
          for (final range in ranges) {
            final length = range[1];
            final got = readInto(range[0], out, position, position + length);
            if (got < length) {
              out.fillRange(position + got, position + length, 0);
            }
            position += length;
          }
          reply.send([id, TransferableTypedData.fromList([out])]);
        case 'writeBatch':
          final offsets = (message['offsets'] as List).cast<int>();
          final lengths = (message['lengths'] as List).cast<int>();
          final transferred = message['data'] as TransferableTypedData;
          final data = Uint8List.view(transferred.materialize());

          // Coalesce exactly adjacent blocks into one write: sequential
          // writeMany patterns then issue one syscall per run instead of one
          // per 4K block.
          final runOffsets = <int>[];
          final runStarts = <int>[];
          final runLengths = <int>[];
          var sourcePosition = 0;
          var i = 0;
          while (i < offsets.length) {
            final runOffset = offsets[i];
            final runStart = sourcePosition;
            var runLength = lengths[i];
            sourcePosition += lengths[i];
            while (i + 1 < offsets.length &&
                offsets[i + 1] == offsets[i] + lengths[i]) {
              i++;
              runLength += lengths[i];
              sourcePosition += lengths[i];
            }
            runOffsets.add(runOffset);
            runStarts.add(runStart);
            runLengths.add(runLength);
            i++;
          }

          if (iocp != null) {
            final blocks = <Uint8List>[];
            for (var j = 0; j < runOffsets.length; j++) {
              blocks.add(Uint8List.sublistView(
                  data, runStarts[j], runStarts[j] + runLengths[j]));
            }
            final total = iocp.writeManySync(runOffsets, blocks);
            reply.send([id, total]);
            return;
          }
          var total = 0;
          for (var j = 0; j < runOffsets.length; j++) {
            total += writeFrom(
                runOffsets[j], data, runStarts[j], runStarts[j] + runLengths[j]);
          }
          reply.send([id, total]);
        default:
          reply.send([id, null, 'unknown op $op']);
      }
    } catch (e) {
      reply.send([id, null, e.toString()]);
    }
  });
}
