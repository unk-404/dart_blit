/// Capability probing for the Web backend.
///
/// The backend never assumes a feature exists: OPFS is present in all engines,
/// but `createSyncAccessHandle()` is worker-only everywhere, persistent storage
/// is granted by heuristics, and pickers/observer/buckets are Chromium-only
/// (`docs/research/web.md` §1).  [probeWebStorageCapabilities] reports what the
/// current page can actually do, including a worker handshake that proves the
/// sync handle works end-to-end.
@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'js.dart';
import 'opfs_client.dart';

/// Snapshot of the Web storage capabilities of the current page.
final class WebStorageCapabilities {
  /// Creates a capability snapshot.
  const WebStorageCapabilities({
    required this.opfs,
    required this.syncAccessHandleInWorker,
    required this.syncAccessHandleOnCurrentThread,
    required this.createWritable,
    required this.fileSystemPickers,
    required this.fileSystemObserver,
    required this.storageBuckets,
    required this.sharedArrayBuffer,
    required this.crossOriginIsolated,
    required this.quotaBytes,
    required this.usageBytes,
    required this.persisted,
    this.workerError,
  });

  /// `navigator.storage.getDirectory()` exists (the OPFS namespace).
  final bool opfs;

  /// A dedicated worker successfully created a sync access handle.
  final bool syncAccessHandleInWorker;

  /// The *current* thread exposes `createSyncAccessHandle` (always `false` on
  /// the main thread, in every browser, as of 2026).
  final bool syncAccessHandleOnCurrentThread;

  /// `FileSystemFileHandle.createWritable()` exists (Safari 26+).
  final bool createWritable;

  /// `showOpenFilePicker`/`showSaveFilePicker` exist (Chromium only).
  final bool fileSystemPickers;

  /// `FileSystemObserver` exists (Chromium 133+).
  final bool fileSystemObserver;

  /// `navigator.storageBuckets` exists (Chromium 122+).
  final bool storageBuckets;

  /// `SharedArrayBuffer` exists (requires COOP/COEP isolation).
  final bool sharedArrayBuffer;

  /// `crossOriginIsolated === true`.
  final bool crossOriginIsolated;

  /// `navigator.storage.estimate().quota`, when available.
  ///
  /// Treat as a hint only: Chrome has granted a 32 GiB sparse write while
  /// reporting a 10 GiB quota (`docs/research/web.md` §4.2).
  final int? quotaBytes;

  /// `navigator.storage.estimate().usage`, when available.
  final int? usageBytes;

  /// `navigator.storage.persisted()`.
  final bool persisted;

  /// Why the worker handshake failed, when it did.
  final String? workerError;

  /// Whether the chunk backend can be used (`opfs` *and* worker sync handles).
  bool get canUseChunkBackend => opfs && syncAccessHandleInWorker;

  @override
  String toString() =>
      'WebStorageCapabilities(opfs: $opfs, '
      'syncAccessHandleInWorker: $syncAccessHandleInWorker, '
      'syncAccessHandleOnCurrentThread: $syncAccessHandleOnCurrentThread, '
      'createWritable: $createWritable, pickers: $fileSystemPickers, '
      'observer: $fileSystemObserver, buckets: $storageBuckets, '
      'sharedArrayBuffer: $sharedArrayBuffer, '
      'crossOriginIsolated: $crossOriginIsolated, quota: $quotaBytes, '
      'usage: $usageBytes, persisted: $persisted, '
      'workerError: $workerError)';
}

const String _functionType = 'function';

bool _hasFunction(JSObject? object, String name) {
  if (object == null) return false;
  final member = object[name];
  return member.isDefinedAndNotNull && member!.typeofEquals(_functionType);
}

bool _hasGlobal(String name) => globalContext[name].isDefinedAndNotNull;

JSObject? _prototypeOfGlobal(String constructor) {
  final ctor = globalContext[constructor];
  if (ctor.isUndefinedOrNull) return null;
  final prototype = (ctor! as JSObject)['prototype'];
  return prototype.isUndefinedOrNull ? null : prototype as JSObject;
}

/// Probes OPFS, worker sync handles, quota and optional Chromium-only APIs.
///
/// The worker handshake starts the page-wide OPFS worker (a `Blob`-URL
/// dedicated worker); its result is cached for later file opens.  [requestPersist]
/// calls `navigator.storage.persist()` (Firefox shows a prompt, Chrome silently
/// grants/denies).
Future<WebStorageCapabilities> probeWebStorageCapabilities({
  bool requestPersist = false,
}) async {
  final filePrototype = _prototypeOfGlobal('FileSystemFileHandle');
  final syncHere = _hasFunction(filePrototype, 'createSyncAccessHandle');
  final createWritable = _hasFunction(filePrototype, 'createWritable');

  var opfs = false;
  int? quota;
  int? usage;
  var persisted = false;
  String? workerError;
  var syncInWorker = false;

  final storage = jsStorageManager;
  opfs = _hasFunction(storage, 'getDirectory');

  if (storage != null && opfs) {
    try {
      final estimate = await jsAwait(jsCall(storage, 'estimate'));
      if (estimate != null) {
        final object = estimate as JSObject;
        quota = jsInt(object['quota']);
        usage = jsInt(object['usage']);
      }
    } catch (_) {
      // estimate() is advisory; ignore failures.
    }
    try {
      persisted = jsBool(await jsAwait(jsCall(storage, 'persisted')));
    } catch (_) {
      // persisted() can be missing/blocked in exotic contexts.
    }
    if (requestPersist) {
      try {
        persisted = jsBool(await jsAwait(jsCall(storage, 'persist')));
      } catch (_) {
        // Not granted; keep the previous value.
      }
    }
    try {
      final client = await OpfsWorkerClient.instance();
      final caps = client.capabilities ?? await client.hello();
      syncInWorker = caps.syncAccessHandle;
      if (!caps.opfs) {
        workerError = 'worker reports OPFS unavailable';
      }
    } catch (error) {
      workerError = '$error';
    }
  } else {
    workerError = 'navigator.storage.getDirectory is not available';
  }

  final navigator = jsNavigator;
  return WebStorageCapabilities(
    opfs: opfs,
    syncAccessHandleInWorker: syncInWorker,
    syncAccessHandleOnCurrentThread: syncHere,
    createWritable: createWritable,
    fileSystemPickers:
        _hasGlobal('showOpenFilePicker') && _hasGlobal('showSaveFilePicker'),
    fileSystemObserver: _hasGlobal('FileSystemObserver'),
    storageBuckets:
        navigator != null && navigator['storageBuckets'].isDefinedAndNotNull,
    sharedArrayBuffer: _hasGlobal('SharedArrayBuffer'),
    crossOriginIsolated: _protoBool(globalContext['crossOriginIsolated']),
    quotaBytes: quota,
    usageBytes: usage,
    persisted: persisted,
    workerError: workerError,
  );
}

bool _protoBool(JSAny? value) {
  if (value.isUndefinedOrNull) return false;
  try {
    return (value! as JSBoolean).toDart;
  } catch (_) {
    return false;
  }
}

/// Requests persistent storage (`navigator.storage.persist()`).
///
/// Chrome decides silently by engagement heuristics; Firefox prompts; Safari
/// does not prompt and its policy is opaque.  `false` means "best effort" — the
/// data can still be evicted under storage pressure.
Future<bool> requestPersistentStorage() async {
  final storage = jsStorageManager;
  if (storage == null) return false;
  try {
    return jsBool(await jsAwait(jsCall(storage, 'persist')));
  } catch (_) {
    return false;
  }
}
