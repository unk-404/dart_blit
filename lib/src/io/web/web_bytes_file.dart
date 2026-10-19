/// The Web backend: a logical random-access file stored as OPFS chunks plus a
/// double-slot manifest.
///
/// ## Why chunks?
///
/// A single 32 GiB OPFS file cannot be written randomly: `truncate(32 GiB)` is
/// metadata-cheap, but the first write near the end materializes every zero
/// before it (measured 12 597 ms on Windows; `docs/research/web.md` §2.3).  So a
/// logical file of length `L` is:
///
/// * `ceil(L / chunkSize)` *chunk files*, each written sequentially and never
///   extended past `chunkSize`;
/// * a small manifest with the logical length, a materialized-chunk bitmap,
///   per-chunk CRC-32 and a commit generation.
///
/// `truncate` is a manifest edit plus removal/truncation of the trailing chunk,
/// so growing to 32 GiB costs O(1) instead of 12 s.  Unmaterialized chunks read
/// as zeros (sparse semantics, matching `dart:io`).
///
/// ## Threading and locking
///
/// `createSyncAccessHandle()` is dedicated-worker-only, so every handle lives in
/// [OpfsWorkerClient]'s worker.  A sync handle takes an exclusive lock on its
/// file, which is why handles are cached per *chunk* (LRU, 8 open at a time)
/// and only touched by this file instance.  Two instances on the *same* logical
/// path would fight over the same chunk files; open one instance per path.
///
/// ## Durability
///
/// `writeAt`/`append` update the manifest in memory; `flush`, `truncate` and
/// `close` persist it (alternating `m.a`/`m.b`, so a crash leaves at least one
/// valid slot).  Reads always see unflushed writes of the same instance.
// ignore_for_file: prefer_initializing_formals
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../bytes_file.dart';
import 'chunk_layout.dart';
import 'crc32.dart';
import 'errors.dart';
import 'manifest.dart';
import 'opfs_client.dart';

/// A [BytesFile] backed by Origin Private File System chunks.
final class WebOpfsBytesFile implements BytesFile {
  WebOpfsBytesFile._({
    required this.path,
    required this.readOnly,
    required this.chunkSize,
    required OpfsWorkerClient client,
    required WebManifestState manifest,
    required int slot,
  }) : _client = client,
       _manifest = manifest,
       _loadedSlot = slot;

  /// Maximum number of chunk handles kept open per file.
  static const int maxOpenChunkHandles = 8;

  /// Logical path (normalized, `/`-separated).
  final String path;

  /// Whether writes are rejected with [StateError].
  final bool readOnly;

  /// Chunk size in bytes (stored in the manifest; fixed per logical file).
  final int chunkSize;

  final OpfsWorkerClient _client;
  final WebManifestState _manifest;
  final int _loadedSlot;
  final Map<int, int> _chunkHandles = <int, int>{};
  final List<int> _lru = <int>[];
  final Map<int, int> _crcState = <int, int>{};
  final Map<int, int> _crcNext = <int, int>{};

  Future<void> _tail = Future<void>.value();
  bool _closed = false;
  bool _manifestDirty = false;

  /// Opens the logical file at [path].
  ///
  /// * `create: true` creates an empty file when the manifest is missing.
  /// * `readOnly: true` rejects every mutating call with a [StateError] and
  ///   implies `create: false` (matching `dart:io`'s `FileMode.read`).
  /// * [chunkSize] applies only to newly created files; an existing file keeps
  ///   the chunk size recorded in its manifest.
  static Future<WebOpfsBytesFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    int chunkSize = kDefaultChunkSize,
  }) async {
    final normalized = normalizeLogicalPath(path);
    if (chunkSize < kMinChunkSize || chunkSize > kMaxChunkSize) {
      throw RangeError.range(
        chunkSize,
        kMinChunkSize,
        kMaxChunkSize,
        'chunkSize',
      );
    }
    final client = await OpfsWorkerClient.instance();
    final loaded = await _loadBestManifest(client, normalized);
    final WebManifestState manifest;
    if (loaded == null) {
      if (!create || readOnly) {
        throw WebFileSystemException(
          'NotFoundError',
          'File does not exist',
          path: normalized,
        );
      }
      manifest = WebManifestState(path: normalized, chunkSize: chunkSize);
    } else {
      manifest = loaded.state;
    }
    final file = WebOpfsBytesFile._(
      path: normalized,
      readOnly: readOnly,
      chunkSize: manifest.chunkSize,
      client: client,
      manifest: manifest,
      slot: loaded?.slot ?? -1,
    );
    if (loaded == null) {
      // Materialize the store directory and slot A so `create` is durable.
      await file._persist();
    }
    return file;
  }

  /// Reads and decodes the newest valid manifest for [path] without opening the
  /// file (no sync handle is taken, so no lock is involved).
  static Future<WebFileManifest?> readManifest(String path) async {
    final normalized = normalizeLogicalPath(path);
    final client = await OpfsWorkerClient.instance();
    final loaded = await _loadBestManifest(client, normalized);
    return loaded?.state.snapshot(slot: loaded.slot);
  }

  /// Reads one manifest slot, returning `null` when it does not exist.
  static Future<Uint8List?> _readManifestSlot(
    OpfsWorkerClient client,
    String path,
    int slot,
  ) async {
    try {
      return await client.readAll(
        manifestPathFor(path, slot),
        limit: 64 * 1024 * 1024,
      );
    } on WebFileSystemException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// Reads both manifest slots and returns the newest valid one.
  static Future<({WebManifestState state, int slot})?> _loadBestManifest(
    OpfsWorkerClient client,
    String path,
  ) async {
    final slotABytes = await _readManifestSlot(client, path, 0);
    final slotBBytes = await _readManifestSlot(client, path, 1);
    final slots = <Uint8List?>[slotABytes, slotBBytes];
    WebManifestState? best;
    var bestGeneration = -1;
    var bestSlot = 0;
    var anySlot = false;
    var anyCorrupt = false;
    for (var slot = 0; slot < slots.length; slot++) {
      final bytes = slots[slot];
      if (bytes == null) continue;
      anySlot = true;
      final state = WebManifestState.tryDecode(bytes);
      if (state == null) {
        anyCorrupt = true;
        continue;
      }
      if (state.path != path) {
        throw WebFileSystemException(
          'CorruptManifestError',
          'Manifest path mismatch: stored "${state.path}", expected "$path"',
          path: path,
        );
      }
      if (state.generation > bestGeneration) {
        best = state;
        bestGeneration = state.generation;
        bestSlot = slot;
      }
    }
    if (best != null) return (state: best, slot: bestSlot);
    if (anySlot && anyCorrupt) {
      throw WebFileSystemException(
        'CorruptManifestError',
        'Every manifest slot is corrupt (bad magic/version/size/CRC)',
        path: path,
      );
    }
    return null;
  }

  /// OPFS path of the directory holding this file's manifest and chunks.
  String get storePath => storePathFor(path);

  /// Manifest slot this file was loaded from (`-1` when newly created).
  int get loadedSlot => _loadedSlot;

  @override
  bool get isClosed => _closed;

  @override
  Future<int> get length async {
    _checkOpen();
    return _manifest.logicalLength;
  }

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

  /// Runs [body] after every previously queued operation on this file.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await body());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  @override
  Future<int> readAt(
    int offset,
    Uint8List dst, {
    int start = 0,
    int? end,
  }) async {
    _checkOpen();
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    return _serialize(() => _readImpl(offset, dst, start, e));
  }

  Future<int> _readImpl(int offset, Uint8List dst, int start, int end) async {
    final logicalLength = _manifest.logicalLength;
    if (offset >= logicalLength) return 0;
    final want = math.min(end - start, logicalLength - offset);
    if (want <= 0) return 0;
    var done = 0;
    while (done < want) {
      final absolute = offset + done;
      final index = chunkIndexFor(absolute, chunkSize);
      final inChunk = offsetInChunk(absolute, chunkSize);
      final take = math.min(want - done, chunkSize - inChunk);
      if (_manifest.isMaterialized(index)) {
        final read = await _readChunkInto(
          index,
          inChunk,
          dst,
          start + done,
          take,
        );
        if (read < take) {
          dst.fillRange(start + done + read, start + done + take, 0);
        }
      } else {
        dst.fillRange(start + done, start + done + take, 0);
      }
      done += take;
    }
    return done;
  }

  Future<int> _readChunkInto(
    int index,
    int inChunk,
    Uint8List dst,
    int dstStart,
    int length,
  ) async {
    final int handle;
    try {
      handle = await _acquireChunk(index, create: false);
    } on WebFileSystemException catch (error) {
      if (error.isNotFound) {
        // A bitmap bit survived a crash but the file is gone: sparse read.
        _manifest.setMaterialized(index, false);
        _manifestDirty = true;
        return 0;
      }
      rethrow;
    }
    final data = await _client.read(handle, inChunk, length);
    dst.setRange(dstStart, dstStart + data.length, data);
    return data.length;
  }

  @override
  Future<int> writeAt(
    int offset,
    Uint8List src, {
    int start = 0,
    int? end,
  }) async {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (start == e) return 0;
    return _serialize(() => _writeImpl(offset, src, start, e));
  }

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) async {
    _checkWritable();
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (start == e) return 0;
    return _serialize(() => _writeImpl(_manifest.logicalLength, src, start, e));
  }

  Future<int> _writeImpl(int offset, Uint8List src, int start, int end) async {
    final length = end - start;
    final newEnd = offset + length;
    if (newEnd > kMaxLogicalLength) {
      throw RangeError.value(
        newEnd,
        'offset',
        'web offsets must stay below 2^53 bytes',
      );
    }
    if (newEnd > _manifest.logicalLength) _growTo(newEnd);
    var done = 0;
    while (done < length) {
      final absolute = offset + done;
      final index = chunkIndexFor(absolute, chunkSize);
      final inChunk = offsetInChunk(absolute, chunkSize);
      final take = math.min(length - done, chunkSize - inChunk);
      // Copy so the user's buffer is never detached by the transfer to the
      // worker, and so each message owns exactly its bytes.
      final piece = Uint8List(take);
      piece.setRange(0, take, src, start + done);
      final handle = await _acquireChunk(index, create: true);
      // CRC is folded before the transfer (the buffer is detached afterwards).
      _updateChunkCrc(index, inChunk, piece);
      final int written;
      try {
        written = await _client.write(handle, inChunk, piece);
      } catch (_) {
        _invalidateChunkCrc(index);
        rethrow;
      }
      if (written != take) {
        _invalidateChunkCrc(index);
        throw WebFileSystemException(
          'IOError',
          'short write: wrote $written of $take bytes',
          path: path,
        );
      }
      _manifest.setMaterialized(index, true);
      done += take;
    }
    _manifestDirty = true;
    return length;
  }

  /// Grows the logical length (sparse: no chunk is created).
  void _growTo(int newLength) {
    final oldLength = _manifest.logicalLength;
    if (newLength <= oldLength) return;
    final oldLastChunk = oldLength == 0 ? -1 : (oldLength - 1) ~/ chunkSize;
    _manifest.setLogicalLength(newLength);
    if (oldLength > 0 && oldLength % chunkSize != 0) {
      // The trailing chunk now exposes more logical bytes: any CRC recorded for
      // the old extent no longer describes the chunk.
      _invalidateChunkCrc(oldLastChunk);
    }
    _manifestDirty = true;
  }

  @override
  Future<void> truncate(int newLength) async {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    if (newLength > kMaxLogicalLength) {
      throw RangeError.value(newLength, 'newLength');
    }
    return _serialize(() async {
      final current = _manifest.logicalLength;
      if (newLength == current) return;
      if (newLength < current) {
        await _shrink(newLength);
      } else {
        _growTo(newLength);
      }
      await _persist();
    });
  }

  /// Drops/truncates chunks that fall beyond [newLength] and resizes metadata.
  Future<void> _shrink(int newLength) async {
    final oldChunkCount = _manifest.chunkCount;
    final remainder = newLength % chunkSize;
    final partialIndex = remainder == 0 ? -1 : newLength ~/ chunkSize;
    final removeFrom = remainder == 0
        ? newLength ~/ chunkSize
        : partialIndex + 1;

    for (var index = removeFrom; index < oldChunkCount; index++) {
      if (_manifest.isMaterialized(index)) {
        await _closeChunkHandle(index);
        try {
          await _client.remove(chunkPathFor(path, index));
        } on WebFileSystemException catch (error) {
          if (!error.isNotFound) rethrow;
        }
      }
      _manifest.setMaterialized(index, false);
      _manifest.setCrc(index, null);
      _crcState.remove(index);
      _crcNext.remove(index);
    }

    if (partialIndex >= 0 && _manifest.isMaterialized(partialIndex)) {
      await _closeChunkHandle(partialIndex);
      try {
        final opened = await _client.open(
          chunkPathFor(path, partialIndex),
          create: false,
        );
        try {
          await _client.truncate(opened.handle, remainder);
          await _client.flush(opened.handle);
        } finally {
          await _client.closeHandle(opened.handle);
        }
      } on WebFileSystemException catch (error) {
        if (!error.isNotFound) rethrow;
        _manifest.setMaterialized(partialIndex, false);
      }
      _manifest.setCrc(partialIndex, null);
    }
    if (partialIndex >= 0) {
      _crcState.remove(partialIndex);
      _crcNext.remove(partialIndex);
    }
    _manifest.setLogicalLength(newLength);
    _manifestDirty = true;
  }

  @override
  Future<void> flush() async {
    _checkOpen();
    return _serialize(() async {
      for (final handle in _chunkHandles.values) {
        await _client.flush(handle);
      }
      if (_manifestDirty) await _persist();
    });
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return _serialize(() async {
      final handles = _chunkHandles.values.toList(growable: false);
      _chunkHandles.clear();
      _lru.clear();
      for (final handle in handles) {
        try {
          await _client.flush(handle);
        } catch (_) {
          // Best effort: still try to release the lock.
        }
        try {
          await _client.closeHandle(handle);
        } catch (_) {
          // The worker may already be gone; nothing else we can do.
        }
      }
      if (_manifestDirty) await _persist();
    });
  }

  @override
  Future<void> delete() {
    _closed = true;
    return _serialize(() async {
      final handles = _chunkHandles.values.toList(growable: false);
      _chunkHandles.clear();
      _lru.clear();
      for (final handle in handles) {
        try {
          await _client.closeHandle(handle);
        } catch (_) {
          // Ignore: removal below drops the whole directory.
        }
      }
      _crcState.clear();
      _crcNext.clear();
      await _client.remove(storePath, recursive: true);
      _manifestDirty = false;
    });
  }

  /// Persists the manifest into the slot that is *not* the current generation.
  Future<void> _persist() async {
    final next = (_manifest.generation + 1) & 0xFFFFFFFF;
    _manifest.generation = next;
    final slot = next.isEven ? 1 : 0;
    await _client.writeAll(manifestPathFor(path, slot), _manifest.encode());
    _manifestDirty = false;
  }

  Future<int> _acquireChunk(int index, {required bool create}) async {
    final cached = _chunkHandles[index];
    if (cached != null) {
      _touchChunk(index);
      return cached;
    }
    while (_chunkHandles.length >= maxOpenChunkHandles && _lru.isNotEmpty) {
      final evict = _lru.removeAt(0);
      final handle = _chunkHandles.remove(evict);
      if (handle != null) {
        try {
          await _client.flush(handle);
        } catch (_) {}
        try {
          await _client.closeHandle(handle);
        } catch (_) {}
      }
    }
    final opened = await _client.open(
      chunkPathFor(path, index),
      create: create,
    );
    _chunkHandles[index] = opened.handle;
    _lru.add(index);
    return opened.handle;
  }

  void _touchChunk(int index) {
    _lru.remove(index);
    _lru.add(index);
  }

  Future<void> _closeChunkHandle(int index) async {
    final handle = _chunkHandles.remove(index);
    _lru.remove(index);
    if (handle == null) return;
    try {
      await _client.flush(handle);
    } catch (_) {}
    try {
      await _client.closeHandle(handle);
    } catch (_) {}
  }

  void _updateChunkCrc(int index, int inChunk, Uint8List bytes) {
    if (inChunk == 0) {
      _manifest.setCrc(index, null);
      _crcState[index] = Crc32.initial;
    } else {
      final expected = _crcNext[index];
      if (expected == null || expected != inChunk) {
        _invalidateChunkCrc(index);
        return;
      }
    }
    final state = Crc32.update(_crcState[index]!, bytes);
    final next = inChunk + bytes.length;
    _crcState[index] = state;
    _crcNext[index] = next;
    final logicalChunkLength = chunkLogicalLength(
      index,
      chunkSize,
      _manifest.logicalLength,
    );
    if (next == chunkSize || next == logicalChunkLength) {
      _manifest.setCrc(index, Crc32.finish(state));
      _crcState.remove(index);
      _crcNext.remove(index);
    }
  }

  void _invalidateChunkCrc(int index) {
    if (index < 0) return;
    _manifest.setCrc(index, null);
    _crcState.remove(index);
    _crcNext.remove(index);
  }

  /// Physical size of chunk [index]'s OPFS file (0 when it does not exist).
  ///
  /// Diagnostic hook for tests: it temporarily releases this instance's handle
  /// on the chunk because a sync access handle is exclusive.
  Future<int> debugPhysicalChunkSize(int index) async {
    _checkOpen();
    return _serialize(() async {
      await _closeChunkHandle(index);
      try {
        final opened = await _client.open(
          chunkPathFor(path, index),
          create: false,
        );
        try {
          return await _client.size(opened.handle);
        } finally {
          await _client.closeHandle(opened.handle);
        }
      } on WebFileSystemException catch (error) {
        if (error.isNotFound) return 0;
        rethrow;
      }
    });
  }

  /// In-memory manifest snapshot (diagnostics; does not re-read OPFS).
  WebFileManifest get manifest => _manifest.snapshot(slot: _loadedSlot);

  @override
  String toString() =>
      'WebOpfsBytesFile($path, chunkSize: $chunkSize, logicalLength: '
      '${_manifest.logicalLength}, readOnly: $readOnly)';
}
