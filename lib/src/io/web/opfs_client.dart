/// Main-thread client for the embedded OPFS workers.
///
/// A page-wide [OpfsWorkerPool] owns several workers: chunk `i` is routed to
/// `clients[i % N]`, while the manifest is written only by `clients.first`.
/// Binary payloads are transferred as `ArrayBuffer`; in a cross-origin-isolated
/// page small reads/writes additionally use the optional SAB ring below.
@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'errors.dart';
import 'js.dart';
import 'opfs_worker_source.dart';

/// JS object literal sent to the worker.
///
/// Parameter names are the JS property names (`handle`, `at`, `len`, `size`,
/// `limit`, `buffer`, `create`, `recursive`); omitted optionals become
/// `undefined`, which the worker treats as `false`/`0`.
extension type _Request._(JSObject _) implements JSObject {
  external factory _Request({
    int? id,
    String? op,
    String? path,
    bool? create,
    bool? recursive,
    int? handle,
    int? at,
    int? len,
    int? size,
    int? limit,
    JSArrayBuffer? buffer,
    JSObject? sab,
    int? slots,
    int? payload,
    int? controlBytes,
  });
}

/// Result of opening a chunk/manifest file inside the worker.
typedef OpfsHandle = ({int handle, int size});

/// Capabilities reported by the worker itself.
typedef OpfsWorkerCapabilities = ({bool opfs, bool syncAccessHandle});

/// Optional shared-memory ring for small `read`/`write` requests.
///
/// Only created when `crossOriginIsolated` is true, `SharedArrayBuffer` exists
/// and `Atomics.waitAsync` is available.  Callers fall back to postMessage when
/// a slot cannot be reserved or the request is larger than one slot.
final class _SabRing {
  static const int slots = 8;
  static const int payload = 64 * 1024;
  static const int stride = 16;
  static const int _state = 0;
  static const int _op = 1;
  static const int _id = 2;
  static const int _handle = 3;
  static const int _atLo = 4;
  static const int _atHi = 5;
  static const int _len = 6;
  static const int _result = 7;
  static const int _error = 8;
  static const int _idleIndex = slots * stride;

  final JsSharedArrayBuffer buffer;
  final JsInt32Array control;
  final JsUint8Array data;
  final int controlBytes;
  final void Function() wake;
  int _cursor = 0;

  _SabRing._(this.buffer, this.control, this.data, this.controlBytes, this.wake);

  static bool get supported {
    if (globalContext['SharedArrayBuffer'].isUndefinedOrNull) return false;
    final isolated = globalContext['crossOriginIsolated'];
    if (isolated.isUndefinedOrNull ||
        (isolated! as JSBoolean).toDart == false) {
      return false;
    }
    final atomics = globalContext['Atomics'];
    if (atomics.isUndefinedOrNull) return false;
    final waitAsync = (atomics! as JSObject)['waitAsync'];
    return waitAsync.isDefinedAndNotNull;
  }

  static _SabRing? create(void Function() wake) {
    if (!supported) return null;
    final controlBytes = (slots * stride + 1) * 4;
    final total = controlBytes + slots * payload;
    final sab = JsSharedArrayBuffer(total);
    return _SabRing._(
      sab,
      JsInt32Array(sab, 0, slots * stride + 1),
      JsUint8Array(sab, controlBytes, slots * payload),
      controlBytes,
      wake,
    );
  }

  int _reserve(int op, int id, int handle, int at, int len) {
    for (var n = 0; n < slots; n++) {
      final slot = (_cursor + n) % slots;
      final base = slot * stride;
      if (jsAtomics.compareExchange(
              control, base + _state, 0, 1) ==
          0) {
        control[base + _op] = op;
        control[base + _id] = id;
        control[base + _handle] = handle;
        control[base + _atLo] = at & 0xFFFFFFFF;
        control[base + _atHi] = (at ~/ 0x100000000) & 0xFFFFFFFF;
        control[base + _len] = len;
        control[base + _result] = 0;
        control[base + _error] = 0;
        control[base + _state] = 2;
        _cursor = (slot + 1) % slots;
        if (jsAtomics.compareExchange(control, _idleIndex, 1, 0) == 1) {
          wake();
        }
        return slot;
      }
    }
    return -1;
  }

  Future<int> _wait(int slot) async {
    final base = slot * stride;
    while (jsAtomics.load(control, base + _state) != 3) {
      final result = jsAtomics.waitAsync(control, base + _state, 2);
      final isAsync = (result['async'] as JSBoolean).toDart;
      if (isAsync) {
        await (result['value'] as JSPromise<JSAny?>).toDart;
      } else {
        final value = (result['value'] as JSString).toDart;
        if (value != 'not-equal') {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    final n = control[base + _result];
    final error = control[base + _error];
    control[base + _state] = 0;
    if (error != 0) {
      throw WebFileSystemException(
        'IOError',
        'SAB ring operation failed (code $error)',
      );
    }
    return n;
  }

  Future<Uint8List?> read(int id, int handle, int at, int len) async {
    if (len < 0 || len > payload) return null;
    final slot = _reserve(1, id, handle, at, len);
    if (slot < 0) return null;
    final n = await _wait(slot);
    if (n < 0) return null;
    final slice = data.subarray(slot * payload, slot * payload + n).slice();
    final arrayBuffer = slice.buffer as JSArrayBuffer;
    return arrayBuffer.toDart.asUint8List();
  }

  Future<int?> write(int id, int handle, int at, Uint8List bytes) async {
    if (bytes.length > payload) return null;
    final slot = _reserve(2, id, handle, at, bytes.length);
    if (slot < 0) return null;
    final view = JsUint8Array(
        bytes.buffer.toJS, bytes.offsetInBytes, bytes.length);
    data.set(view, slot * payload);
    return _wait(slot);
  }
}

/// Owns the dedicated worker that holds every `FileSystemSyncAccessHandle`.
final class OpfsWorkerClient {
  OpfsWorkerClient._(this._worker, this._blobUrl);

  static OpfsWorkerClient? _instance;
  static Future<OpfsWorkerClient>? _pending;

  final JsWorker _worker;
  final String _blobUrl;
  final Map<int, Completer<JSAny?>> _pendingReplies = {};
  int _nextId = 1;
  bool _dead = false;
  String? _deadReason;
  OpfsWorkerCapabilities? _capabilities;
  _SabRing? _sab;

  /// Returns the page-wide worker client, creating it on first use.
  ///
  /// Throws [UnsupportedError] when the browser has no OPFS or when the worker
  /// cannot be started (for example a CSP without `worker-src blob:`).
  static Future<OpfsWorkerClient> instance() {
    final existing = _instance;
    if (existing != null && !existing._dead) return Future.value(existing);
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<OpfsWorkerClient> future;
    future = _create().whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
    _pending = future;
    return future;
  }

  /// Initializes the optional SAB ring; failures fall back to postMessage.
  Future<void> _initSab() async {
    final ring = _SabRing.create(() {
      _worker.postMessage(jsObject(<String, Object?>{'op': 'sabWake'}));
    });
    if (ring == null) return;
    try {
      await _request(
        op: 'sabInit',
        sab: ring.buffer,
        slots: _SabRing.slots,
        payload: _SabRing.payload,
        controlBytes: ring.controlBytes,
      );
      _sab = ring;
    } catch (_) {
      // Keep the postMessage path.
    }
  }

  /// Worker capabilities from the `hello` handshake (`null` before start).
  OpfsWorkerCapabilities? get capabilities => _capabilities;

  /// Whether the worker is gone (script error or explicit shutdown).
  bool get isDead => _dead;

  static Future<OpfsWorkerClient> _create() async {
    final client = await createIsolated();
    _instance = client;
    return client;
  }

  /// Creates an independent worker that is not the shared singleton.
  ///
  /// Used by [OpfsWorkerPool] so different chunks can hold different sync
  /// access handles in parallel.
  static Future<OpfsWorkerClient> createIsolated() async {
    final client = _start();
    try {
      await client._initSab();
      final caps = await client.hello();
      if (!caps.opfs) {
        client._failAll('OPFS is unavailable in this browser');
        throw UnsupportedError(
          'The Web backend requires the Origin Private File System '
          '(navigator.storage.getDirectory); it is missing in this context.',
        );
      }
      if (!caps.syncAccessHandle) {
        client._failAll('createSyncAccessHandle is unavailable');
        throw UnsupportedError(
          'The Web backend requires FileSystemFileHandle.createSyncAccessHandle '
          'inside a dedicated worker; this browser does not expose it.',
        );
      }
      return client;
    } catch (_) {
      client.shutdown();
      rethrow;
    }
  }

  static OpfsWorkerClient _start() {
    final blob = JsBlob(
      <JSAny>[kOpfsWorkerSource.toJS].toJS,
      jsObject({'type': 'text/javascript'}),
    );
    final url = jsCreateObjectURL(blob);
    final JsWorker worker;
    try {
      worker = JsWorker(url);
    } catch (error) {
      jsRevokeObjectURL(url);
      throw UnsupportedError(
        'Could not start the OPFS worker from a Blob URL. A strict CSP must '
        'allow "worker-src blob:" (and "script-src blob:" on older Chrome). '
        'Underlying error: $error',
      );
    }
    final client = OpfsWorkerClient._(worker, url);
    client._wire();
    return client;
  }

  void _wire() {
    _worker.onmessage = ((JSAny event) {
      _onMessage(event);
    }).toJS;
    _worker.onmessageerror = ((JSAny event) {
      _failAll('worker message could not be deserialized');
    }).toJS;
    _worker.onerror = ((JSAny event) {
      final object = event as JSObject;
      final type = object['type'];
      final message = object['message'];
      final reason = message.isUndefinedOrNull ? '$type' : '$message';
      _failAll('worker error: $reason');
    }).toJS;
  }

  void _onMessage(JSAny event) {
    final JSObject reply;
    try {
      reply = (event as JSObject)['data'] as JSObject;
      final id = (reply['id'] as JSNumber).toDartInt;
      final completer = _pendingReplies.remove(id);
      if (completer == null) return;
      final ok = (reply['ok'] as JSBoolean).toDart;
      if (!ok) {
        final name = _stringOf(reply['name']) ?? 'Error';
        final message = _stringOf(reply['error']) ?? 'unknown worker error';
        completer.completeError(_errorFrom(name, message));
      } else {
        completer.complete(reply['value']);
      }
    } catch (error) {
      // A malformed reply is a programming error in the worker: fail loudly
      // rather than leaving callers waiting forever.
      _failAll('malformed worker reply: $error');
    }
  }

  static String? _stringOf(JSAny? value) {
    if (value == null) return null;
    try {
      return (value as JSString).toDart;
    } catch (_) {
      return value.dartify()?.toString();
    }
  }

  static WebFileSystemException _errorFrom(String name, String message) =>
      name == 'QuotaExceededError'
      ? WebQuotaExceededException(message)
      : WebFileSystemException(name, message);

  /// Marks the client dead, releases the worker (and with it every exclusive
  /// chunk lock it held) and fails all in-flight requests.
  void _failAll(String reason) {
    _dead = true;
    _deadReason = reason;
    _worker.terminate();
    jsRevokeObjectURL(_blobUrl);
    final pending = _pendingReplies.values.toList(growable: false);
    _pendingReplies.clear();
    for (final completer in pending) {
      completer.completeError(WebFileSystemException('AbortError', reason));
    }
  }

  Future<JSAny?> _request({
    required String op,
    String? path,
    bool? create,
    bool? recursive,
    int? handle,
    int? at,
    int? len,
    int? size,
    int? limit,
    Uint8List? bytes,
    JSObject? sab,
    int? slots,
    int? payload,
    int? controlBytes,
  }) {
    if (_dead) {
      return Future.error(
        WebFileSystemException(
          'AbortError',
          'OPFS worker is not running: ${_deadReason ?? '?'}',
        ),
      );
    }
    final id = _nextId++;
    final completer = Completer<JSAny?>();
    _pendingReplies[id] = completer;
    final request = _Request(
      id: id,
      op: op,
      path: path,
      create: create,
      recursive: recursive,
      handle: handle,
      at: at,
      len: len,
      size: size,
      limit: limit,
      buffer: bytes?.buffer.toJS,
      sab: sab,
      slots: slots,
      payload: payload,
      controlBytes: controlBytes,
    );
    try {
      if (bytes == null) {
        _worker.postMessage(request);
      } else {
        // Transfer rather than clone.  Callers pass freshly allocated exact
        // buffers (see [write]'s contract), so the whole buffer belongs here.
        _worker.postMessageWithTransfer(
          request,
          <JSAny>[bytes.buffer.toJS].toJS,
        );
      }
    } catch (error, stack) {
      _pendingReplies.remove(id);
      return Future.error(
        WebFileSystemException('AbortError', 'postMessage failed: $error'),
        stack,
      );
    }
    return completer.future;
  }

  /// `hello`: reports OPFS and worker-only sync-handle support.
  Future<OpfsWorkerCapabilities> hello() async {
    final value = await _request(op: 'hello');
    final object = value as JSObject;
    final caps = (
      opfs: (object['opfs'] as JSBoolean).toDart,
      syncAccessHandle: (object['syncAccessHandle'] as JSBoolean).toDart,
    );
    _capabilities = caps;
    return caps;
  }

  /// Opens (and exclusively locks) a file, returning its sync handle id.
  Future<OpfsHandle> open(String path, {bool create = true}) async {
    final value = await _request(op: 'open', path: path, create: create);
    final object = value as JSObject;
    return (
      handle: (object['handle'] as JSNumber).toDartInt,
      size: (object['size'] as JSNumber).toDartInt,
    );
  }

  /// Reads up to [length] bytes at [at]; the returned list is a fresh buffer.
  Future<Uint8List> read(int handle, int at, int length) async {
    if (length <= 0) return Uint8List(0);
    final ring = _sab;
    if (ring != null && length <= _SabRing.payload) {
      final value = await ring.read(_nextId++, handle, at, length);
      if (value != null) return value;
    }
    final value = await _request(
      op: 'read',
      handle: handle,
      at: at,
      len: length,
    );
    final object = value as JSObject;
    final n = (object['n'] as JSNumber).toDartInt;
    final all = (object['buffer'] as JSArrayBuffer).toDart.asUint8List();
    return n == all.length ? all : Uint8List.sublistView(all, 0, n);
  }

  /// Writes [bytes] at [at] and returns the number of bytes written.
  ///
  /// Takes ownership of `bytes.buffer`: the buffer is transferred to the
  /// worker, so [bytes] must not be used afterwards and must be an exact,
  /// freshly allocated list (the chunk writer copies user data into one).
  Future<int> write(int handle, int at, Uint8List bytes) async {
    if (bytes.isEmpty) return 0;
    final ring = _sab;
    if (ring != null && bytes.length <= _SabRing.payload) {
      final value = await ring.write(_nextId++, handle, at, bytes);
      if (value != null) return value;
    }
    final value = await _request(
      op: 'write',
      handle: handle,
      at: at,
      bytes: bytes,
    );
    return ((value as JSObject)['n'] as JSNumber).toDartInt;
  }

  /// Resizes the underlying chunk file to [size] bytes.
  Future<void> truncate(int handle, int size) =>
      _request(op: 'truncate', handle: handle, size: size);

  /// Flushes pending writes of the handle to the backing store.
  Future<void> flush(int handle) => _request(op: 'flush', handle: handle);

  /// Current physical size of the handle's file.
  Future<int> size(int handle) async {
    final value = await _request(op: 'size', handle: handle);
    return ((value as JSObject)['size'] as JSNumber).toDartInt;
  }

  /// Closes and unlocks a handle (idempotent).
  Future<void> closeHandle(int handle) =>
      _request(op: 'closeHandle', handle: handle);

  /// Reads a whole file (manifest-sized) into memory.
  Future<Uint8List> readAll(String path, {int limit = 8 * 1024 * 1024}) async {
    final value = await _request(op: 'readAll', path: path, limit: limit);
    final object = value as JSObject;
    final n = (object['n'] as JSNumber).toDartInt;
    final all = (object['buffer'] as JSArrayBuffer).toDart.asUint8List();
    return n == all.length ? all : Uint8List.sublistView(all, 0, n);
  }

  /// Replaces a whole file (used for manifest slots).
  Future<void> writeAll(String path, Uint8List bytes) =>
      _request(op: 'writeAll', path: path, bytes: Uint8List.fromList(bytes));

  /// Whether [path] exists as a file.
  Future<bool> exists(String path) async {
    final value = await _request(op: 'exists', path: path);
    return ((value as JSObject)['exists'] as JSBoolean).toDart;
  }

  /// Removes a file or directory (recursively if [recursive]); returns whether
  /// anything was removed.
  Future<bool> remove(String path, {bool recursive = false}) async {
    final value = await _request(
      op: 'remove',
      path: path,
      recursive: recursive,
    );
    return ((value as JSObject)['removed'] as JSBoolean).toDart;
  }

  /// Lists entry names inside directory [path].
  Future<List<String>> list(String path) async {
    final value = await _request(op: 'list', path: path);
    final names = (value as JSObject)['names'] as JSArray<JSString>;
    return names.toDart.map((name) => name.toDart).toList(growable: false);
  }

  /// Shuts down the page-wide worker (if it was ever started).
  ///
  /// A later [instance] call creates a fresh worker; every handle from the old
  /// one is closed (the exclusive locks are released when it terminates).
  static void shutdownShared() {
    final existing = _instance;
    _instance = null;
    _pending = null;
    existing?.shutdown();
  }

  /// Terminates the worker, releases every sync-access-handle lock and revokes
  /// the Blob URL.
  ///
  /// This is an abrupt teardown: close the files you care about first so their
  /// chunk handles are flushed and their manifests persisted.
  void shutdown() => _failAll('OPFS worker was shut down');
}

/// Page-wide pool: one manifest writer worker plus N chunk workers.
///
/// OPFS sync access handles are exclusive per file, so chunk files can be
/// handled in parallel as long as each chunk is owned by exactly one worker.
final class OpfsWorkerPool {
  OpfsWorkerPool._(this.clients);

  static OpfsWorkerPool? _instance;
  static Future<OpfsWorkerPool>? _pending;

  final List<OpfsWorkerClient> clients;

  /// Number of chunk workers to create by default.
  static const int defaultWorkers = 4;

  OpfsWorkerClient get manifest => clients.first;

  OpfsWorkerClient clientForChunk(int index) =>
      clients[index % clients.length];

  bool get isDead => clients.any((client) => client.isDead);

  /// Whether the SAB ring negotiated successfully in every worker.
  bool get usesSabRing => clients.every((client) => client._sab != null);

  static Future<OpfsWorkerPool> instance({int? workers}) {
    final existing = _instance;
    if (existing != null && !existing.isDead) return Future.value(existing);
    final pending = _pending;
    if (pending != null) return pending;
    final count = workers ?? defaultWorkers;
    if (count < 1) throw RangeError.value(count, 'workers');
    late final Future<OpfsWorkerPool> future;
    future = _create(count).whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
    _pending = future;
    return future;
  }

  static Future<OpfsWorkerPool> _create(int count) async {
    final created = <OpfsWorkerClient>[];
    try {
      for (var i = 0; i < count; i++) {
        created.add(await OpfsWorkerClient.createIsolated());
      }
      final pool = OpfsWorkerPool._(List.unmodifiable(created));
      _instance = pool;
      return pool;
    } catch (_) {
      for (final client in created) {
        client.shutdown();
      }
      rethrow;
    }
  }

  static void shutdownShared() {
    final existing = _instance;
    _instance = null;
    _pending = null;
    if (existing == null) return;
    for (final client in existing.clients) {
      client.shutdown();
    }
  }
}
