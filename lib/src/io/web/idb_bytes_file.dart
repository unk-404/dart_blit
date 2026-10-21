/// IndexedDB-backed random-access file.
///
/// This is *not* an IndexedDB wrapper API. It maps the existing [BytesFile]
/// operations onto a shared object store:
///
/// * one database and one object store for the whole origin;
/// * each logical path gets a base64 key prefix, so files share the table
///   without aliasing or creating a table per file;
/// * fixed-size chunk records plus a small metadata record;
/// * batched transactions and an LRU chunk cache for random access.
///
/// Missing records read as zero, so `truncate`/sparse writes stay metadata-only.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import '../bytes_file.dart';
import 'chunk_layout.dart' show kMaxLogicalLength, normalizeLogicalPath;
import 'idb_layout.dart';

/// IndexedDB failure.
final class WebIndexedDbException implements Exception {
  WebIndexedDbException(this.name, this.message, {this.path});

  final String name;
  final String message;
  final String? path;

  bool get isNotFound => name == 'NotFoundError';

  @override
  String toString() =>
      'WebIndexedDbException($name${path == null ? '' : ', path=$path'}): '
      '$message';
}

/// A [BytesFile] backed by records in one shared IndexedDB object store.
final class WebIndexedDbBytesFile implements BytesFile {
  WebIndexedDbBytesFile._({
    required this.path,
    required this.readOnly,
    required this.chunkSize,
    required this._store,
    required int logicalLength,
    required this._exists,
  }) : _length = logicalLength;

  /// Logical path.
  final String path;

  /// Whether mutations are rejected.
  final bool readOnly;

  /// Fixed chunk size in bytes.
  final int chunkSize;

  final _IdbStore _store;
  int _length;
  bool _exists;
  bool _closed = false;
  bool _metaDirty = false;
  Future<void> _tail = Future<void>.value();

  static const int _cacheChunks = 128;
  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap<int, Uint8List>();

  /// Opens or creates [path] in the shared IndexedDB store.
  static Future<WebIndexedDbBytesFile> open(
    String path, {
    bool create = true,
    bool readOnly = false,
    int chunkSize = kIdbDefaultChunkSize,
    String databaseName = kIdbDatabaseName,
    String storeName = kIdbStoreName,
  }) async {
    final normalized = normalizeLogicalPath(path);
    if (chunkSize < kIdbMinChunkSize || chunkSize > kIdbMaxChunkSize) {
      throw RangeError.range(
        chunkSize,
        kIdbMinChunkSize,
        kIdbMaxChunkSize,
        'chunkSize',
      );
    }
    final store = await _IdbStore.open(databaseName, storeName);
    final metaBytes = await store.get(idbMetaKey(normalized));
    final meta = metaBytes == null ? null : decodeIdbMeta(metaBytes);
    if (meta == null) {
      if (!create || readOnly) {
        throw WebIndexedDbException(
          'NotFoundError',
          'No IndexedDB metadata for $normalized',
          path: normalized,
        );
      }
      final file = WebIndexedDbBytesFile._(
        path: normalized,
        readOnly: readOnly,
        chunkSize: chunkSize,
        store: store,
        logicalLength: 0,
        exists: false,
      );
      await file._persistMeta();
      file._exists = true;
      return file;
    }
    return WebIndexedDbBytesFile._(
      path: normalized,
      readOnly: readOnly,
      chunkSize: meta.chunkSize,
      store: store,
      logicalLength: meta.logicalLength,
      exists: true,
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsConcurrentReads => true;

  @override
  Future<int> get length async {
    _checkOpen();
    return _length;
  }

  void _checkOpen() {
    if (_closed) throw StateError('File is closed: $path');
  }

  void _checkWritable() {
    _checkOpen();
    if (readOnly) throw StateError('File is read-only: $path');
  }

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

  Future<void> _persistMeta() async {
    await _store.putMany({idbMetaKey(path): encodeIdbMeta(_length, chunkSize)});
    _metaDirty = false;
  }

  Uint8List _cachedChunk(int index) {
    final cached = _cache.remove(index);
    if (cached == null) return Uint8List(chunkSize);
    _cache[index] = cached; // touch for LRU
    return cached;
  }

  void _putCache(int index, Uint8List bytes) {
    _cache.remove(index);
    _cache[index] = bytes;
    while (_cache.length > _cacheChunks) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<void> _loadChunks(
    Iterable<int> indices, {
    bool readOnly = false,
  }) async {
    final missing = <int>[];
    for (final index in indices) {
      if (!_cache.containsKey(index)) missing.add(index);
    }
    if (missing.isEmpty) return;
    final keys = <String>[
      for (final index in missing) idbChunkKey(path, index),
    ];
    final values = await _store.getMany(keys);
    for (var i = 0; i < missing.length; i++) {
      final raw = values[i];
      if (raw == null) continue;
      final chunk = Uint8List(chunkSize);
      final n = math.min(raw.length, chunkSize);
      chunk.setRange(0, n, raw);
      _putCache(missing[i], chunk);
    }
    // Do not cache absent chunks here: a sparse file must not fill the LRU
    // with zero blocks.
    if (readOnly) return;
  }

  @override
  Future<int> readAt(
    int offset,
    Uint8List dst, {
    int start = 0,
    int? end,
  }) async {
    final e = end ?? dst.length;
    RangeError.checkValidRange(start, e, dst.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (e == start) return 0;
    _checkOpen();
    return _serialize(() async {
      if (offset >= _length) return 0;
      final want = math.min(e - start, _length - offset);
      if (want <= 0) return 0;
      final first = offset ~/ chunkSize;
      final last = (offset + want - 1) ~/ chunkSize;
      await _loadChunks([
        for (var i = first; i <= last; i++) i,
      ], readOnly: true);
      var done = 0;
      while (done < want) {
        final absolute = offset + done;
        final index = absolute ~/ chunkSize;
        final inChunk = absolute % chunkSize;
        final take = math.min(want - done, chunkSize - inChunk);
        final cached = _cache[index];
        if (cached == null) {
          dst.fillRange(start + done, start + done + take, 0);
        } else {
          dst.setRange(start + done, start + done + take, cached, inChunk);
        }
        done += take;
      }
      return done;
    });
  }

  @override
  Future<int> writeAt(
    int offset,
    Uint8List src, {
    int start = 0,
    int? end,
  }) async {
    final e = end ?? src.length;
    RangeError.checkValidRange(start, e, src.length);
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (start == e) return 0;
    _checkWritable();
    return _serialize(() async {
      final length = e - start;
      final newEnd = offset + length;
      if (newEnd > kMaxLogicalLength) {
        throw RangeError.value(newEnd, 'offset', 'web offset exceeds 2^53');
      }
      if (newEnd > _length) _length = newEnd;
      final first = offset ~/ chunkSize;
      final last = (newEnd - 1) ~/ chunkSize;
      final partial = <int>[];
      for (var index = first; index <= last; index++) {
        final chunkStart = index * chunkSize;
        final covers = offset <= chunkStart && newEnd >= chunkStart + chunkSize;
        if (!covers) partial.add(index);
      }
      if (partial.isNotEmpty) {
        await _loadChunks(partial, readOnly: false);
      }
      final dirty = <int, Uint8List>{};
      var done = 0;
      while (done < length) {
        final absolute = offset + done;
        final index = absolute ~/ chunkSize;
        final inChunk = absolute % chunkSize;
        final take = math.min(length - done, chunkSize - inChunk);
        final chunk = dirty[index] ?? _cachedChunk(index);
        chunk.setRange(inChunk, inChunk + take, src, start + done);
        dirty[index] = chunk;
        done += take;
      }
      await _store.putMany({
        for (final entry in dirty.entries)
          idbChunkKey(path, entry.key): entry.value,
      });
      for (final entry in dirty.entries) {
        _putCache(entry.key, entry.value);
      }
      _metaDirty = true;
      return length;
    });
  }

  @override
  Future<int> append(Uint8List src, {int start = 0, int? end}) =>
      writeAt(_length, src, start: start, end: end);

  @override
  Future<void> truncate(int newLength) async {
    _checkWritable();
    if (newLength < 0) throw RangeError.value(newLength, 'newLength');
    await _serialize(() async {
      final oldLength = _length;
      _length = newLength;
      _metaDirty = true;
      if (newLength < oldLength) {
        final remainder = newLength % chunkSize;
        final boundary = newLength ~/ chunkSize;
        if (remainder != 0) {
          await _loadChunks([boundary]);
          final chunk = _cachedChunk(boundary);
          chunk.fillRange(remainder, chunkSize, 0);
          await _store.putMany({idbChunkKey(path, boundary): chunk});
          _putCache(boundary, chunk);
        }
        final firstDeleted = remainder == 0 ? boundary : boundary + 1;
        final oldLast = (oldLength + chunkSize - 1) ~/ chunkSize - 1;
        if (firstDeleted <= oldLast) {
          await _store.deleteChunkRange(
            idbChunkKey(path, firstDeleted),
            idbChunkKey(path, oldLast),
          );
        }
        _cache.removeWhere((index, _) => index >= firstDeleted);
      }
      await _persistMeta();
    });
  }

  @override
  Future<void> flush() async {
    _checkOpen();
    if (!_metaDirty) return;
    await _serialize(() async {
      if (!_metaDirty) return;
      await _store.putMany({
        idbMetaKey(path): encodeIdbMeta(_length, chunkSize),
      });
      _metaDirty = false;
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await _tail;
    if (_closed) return;
    if (_metaDirty) {
      await _store.putMany({
        idbMetaKey(path): encodeIdbMeta(_length, chunkSize),
      });
      _metaDirty = false;
    }
    _closed = true;
    _cache.clear();
  }

  @override
  Future<void> delete() async {
    await close();
    await _store.deleteKeys(idbFileKey(path), path: path);
    _exists = false;
  }

  /// Whether this logical file has metadata in the store.
  bool get exists => _exists;

  @override
  String toString() =>
      'WebIndexedDbBytesFile($path, length: $_length, chunk: $chunkSize)';
}

final class _IdbStore {
  _IdbStore(this.db, this.storeName);

  final JSObject db;
  final String storeName;
  static final Map<String, Future<_IdbStore>> _instances = {};

  static Future<_IdbStore> open(String databaseName, String storeName) {
    final key = '$databaseName/$storeName';
    return _instances.putIfAbsent(key, () async {
      final db = await _openDatabase(databaseName, storeName);
      return _IdbStore(db, storeName);
    });
  }

  static Future<JSObject> _openDatabase(String name, String storeName) {
    final factory = globalContext['indexedDB'];
    if (factory.isUndefinedOrNull) {
      throw UnsupportedError('IndexedDB is unavailable in this context');
    }
    final request = (factory! as JSObject).callMethodVarArgs<JSObject>(
      'open'.toJS,
      [name.toJS, 1.toJS],
    );
    final completer = Completer<JSObject>();
    request['onupgradeneeded'] = ((JSAny event) {
      final db = request['result'] as JSObject;
      final names = db['objectStoreNames'] as JSObject;
      final hasStore = names.callMethodVarArgs<JSBoolean>('contains'.toJS, [
        storeName.toJS,
      ]).toDart;
      if (!hasStore) {
        db.callMethodVarArgs<JSObject>('createObjectStore'.toJS, [
          storeName.toJS,
        ]);
      }
    }).toJS;
    request['onsuccess'] = ((JSAny event) {
      completer.complete(request['result'] as JSObject);
    }).toJS;
    request['onerror'] = ((JSAny event) {
      completer.completeError(_requestError(request, null));
    }).toJS;
    return completer.future;
  }

  Future<void> _transaction(
    String mode,
    void Function(JSObject store) body,
  ) async {
    final tx = db.callMethodVarArgs<JSObject>('transaction'.toJS, [
      storeName.toJS,
      mode.toJS,
    ]);
    final store = tx.callMethodVarArgs<JSObject>('objectStore'.toJS, [
      storeName.toJS,
    ]);
    final done = Completer<void>();
    tx['oncomplete'] = ((JSAny event) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx['onerror'] = ((JSAny event) {
      if (!done.isCompleted) done.completeError(_transactionError(tx));
    }).toJS;
    tx['onabort'] = ((JSAny event) {
      if (!done.isCompleted) {
        done.completeError(
          WebIndexedDbException('AbortError', 'Transaction aborted'),
        );
      }
    }).toJS;
    try {
      body(store);
      await done.future;
    } catch (error) {
      try {
        tx.callMethod('abort'.toJS);
      } catch (_) {}
      rethrow;
    }
  }

  Future<Uint8List?> get(String key) async {
    final values = await getMany([key]);
    return values.single;
  }

  Future<List<Uint8List?>> getMany(List<String> keys) async {
    if (keys.isEmpty) return const [];
    final out = List<Uint8List?>.filled(keys.length, null);
    await _transaction('readonly', (store) {
      for (var i = 0; i < keys.length; i++) {
        final request = store.callMethodVarArgs<JSObject>('get'.toJS, [
          keys[i].toJS,
        ]);
        request['onsuccess'] = ((JSAny event) {
          out[i] = _asBytes(request['result']);
        }).toJS;
      }
    });
    return out;
  }

  Future<void> putMany(Map<String, Uint8List> values) async {
    if (values.isEmpty) return;
    await _transaction('readwrite', (store) {
      for (final entry in values.entries) {
        store.callMethodVarArgs<JSObject>('put'.toJS, [
          entry.value.toJS,
          entry.key.toJS,
        ]);
      }
    });
  }

  Future<void> deleteChunkRange(String lower, String upper) async {
    final range = _keyRange(lower, upper);
    await _transaction('readwrite', (store) {
      store.callMethodVarArgs<JSObject>('delete'.toJS, [range]);
    });
  }

  Future<void> deleteKeys(String fileKey, {String? path}) async {
    final lower = '$fileKey!';
    final range = _keyRange(lower, '$lower\uffff');
    await _transaction('readwrite', (store) {
      store.callMethodVarArgs<JSObject>('delete'.toJS, [range]);
    });
  }

  JSObject _keyRange(String lower, String upper) {
    final ctor = globalContext['IDBKeyRange'];
    if (ctor.isUndefinedOrNull) {
      throw UnsupportedError('IDBKeyRange is unavailable');
    }
    return (ctor! as JSObject).callMethodVarArgs<JSObject>('bound'.toJS, [
      lower.toJS,
      upper.toJS,
    ]);
  }

  static Uint8List? _asBytes(JSAny? value) {
    if (value.isUndefinedOrNull) return null;
    final any = value!;
    if (any.isA<JSUint8Array>()) return (any as JSUint8Array).toDart;
    if (any.isA<JSArrayBuffer>()) {
      return (any as JSArrayBuffer).toDart.asUint8List();
    }
    return null;
  }

  static WebIndexedDbException _requestError(JSObject request, String? path) {
    final error = request['error'];
    if (error.isUndefinedOrNull) {
      return WebIndexedDbException('UnknownError', 'IndexedDB request failed');
    }
    final object = error as JSObject;
    final name = _string(object['name']) ?? 'UnknownError';
    final message = _string(object['message']) ?? 'IndexedDB request failed';
    return WebIndexedDbException(name, message, path: path);
  }

  static WebIndexedDbException _transactionError(JSObject tx) {
    final error = tx['error'];
    if (error.isUndefinedOrNull) {
      return WebIndexedDbException(
        'AbortError',
        'IndexedDB transaction failed',
      );
    }
    final object = error as JSObject;
    return WebIndexedDbException(
      _string(object['name']) ?? 'UnknownError',
      _string(object['message']) ?? 'IndexedDB transaction failed',
    );
  }

  static String? _string(JSAny? value) {
    if (value.isUndefinedOrNull) return null;
    return (value! as JSString).toDart;
  }
}

/// Opens an IndexedDB-backed file in the shared `blit-bytes` store.
Future<WebIndexedDbBytesFile> openIdbBytesFileTyped(
  String path, {
  bool create = true,
  bool readOnly = false,
  int chunkSize = kIdbDefaultChunkSize,
  String databaseName = kIdbDatabaseName,
  String storeName = kIdbStoreName,
}) => WebIndexedDbBytesFile.open(
  path,
  create: create,
  readOnly: readOnly,
  chunkSize: chunkSize,
  databaseName: databaseName,
  storeName: storeName,
);

/// Opens an IndexedDB-backed file as a [BytesFile].
Future<BytesFile> openIdbBytesFile(
  String path, {
  bool create = true,
  bool readOnly = false,
  int chunkSize = kIdbDefaultChunkSize,
  String databaseName = kIdbDatabaseName,
  String storeName = kIdbStoreName,
}) => openIdbBytesFileTyped(
  path,
  create: create,
  readOnly: readOnly,
  chunkSize: chunkSize,
  databaseName: databaseName,
  storeName: storeName,
);

/// Deletes every record belonging to [path] from the shared store.
Future<void> deleteIdbFile(
  String path, {
  String databaseName = kIdbDatabaseName,
  String storeName = kIdbStoreName,
}) async {
  final normalized = normalizeLogicalPath(path);
  final store = await _IdbStore.open(databaseName, storeName);
  await store.deleteKeys(idbFileKey(normalized), path: normalized);
}

/// Closes cached IndexedDB connections (tests/hot restart).
Future<void> shutdownIdbBackend() async {
  for (final entry in _IdbStore._instances.values) {
    final store = await entry;
    try {
      store.db.callMethod('close'.toJS);
    } catch (_) {}
  }
  _IdbStore._instances.clear();
}


