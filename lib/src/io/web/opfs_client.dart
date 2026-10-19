/// Main-thread client for the embedded OPFS worker.
///
/// One worker per page (lazy singleton): every `FileSystemSyncAccessHandle`
/// lives inside it, requests are FIFO, and binary payloads are transferred as
/// `ArrayBuffer` (zero structured-clone cost).  A single worker is enough
/// because the chunk server is metadata-driven — the bottleneck is OPFS I/O,
/// not the message hop — and it keeps exclusive-lock reasoning trivial (one
/// owner per chunk file).
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
  });
}

/// Result of opening a chunk/manifest file inside the worker.
typedef OpfsHandle = ({int handle, int size});

/// Capabilities reported by the worker itself.
typedef OpfsWorkerCapabilities = ({bool opfs, bool syncAccessHandle});

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

  /// Worker capabilities from the `hello` handshake (`null` before start).
  OpfsWorkerCapabilities? get capabilities => _capabilities;

  /// Whether the worker is gone (script error or explicit shutdown).
  bool get isDead => _dead;

  static Future<OpfsWorkerClient> _create() async {
    final client = _start();
    try {
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
      _instance = client;
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
