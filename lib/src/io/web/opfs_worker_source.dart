/// The dedicated-worker JavaScript source, embedded as a string.
///
/// ## Why embed JS instead of shipping a `.js` asset?
///
/// `createSyncAccessHandle()` only exists in a dedicated worker, so a web
/// backend *must* spawn one.  A Dart package cannot assume the host app bundles
/// an extra worker asset (it would have to be copied into every build), so the
/// worker is created from a `Blob` URL built from this string:
///
/// ```dart
/// final blob = JsBlob([source.toJS].toJS,
///     jsObject({'type': 'text/javascript'}));
/// final worker = JsWorker(jsCreateObjectURL(blob));
/// ```
///
/// Blob URLs inherit the page origin, so the worker shares the same OPFS
/// namespace, and the code is ~5 KB, evaluated once per page.
///
/// ## CSP note (important)
///
/// A page with a strict Content-Security-Policy must allow the worker:
/// `worker-src blob:` (older Chrome also consults `script-src`, so
/// `script-src 'self' blob:` is the safe combination).  If the policy blocks
/// it, `new Worker(url)` throws and the backend surfaces a clear
/// `UnsupportedError` instead of hanging.
///
/// ## Protocol
///
/// The worker is deliberately *thin*: it owns `FileSystemSyncAccessHandle`s and
/// does byte-level `read`/`write`/`truncate`/`flush`/`size`/`close` plus
/// whole-file helpers for the small manifest.  All chunk mapping, manifest
/// bookkeeping and CRC logic lives in Dart (main thread) — that keeps the code
/// testable with `dart analyze` and unit tests, and the JS small and stable.
///
/// Requests are processed strictly in arrival order (`chain`), so a
/// read-after-write issued by Dart can never be reordered by the worker.
///
/// Request shape: `{id, op, ...}` (fields named exactly like the Dart side's
/// object-literal factory).  Reply shape: `{id, ok, value}` or
/// `{id, ok: false, name, error}`.  Binary payloads are transferred
/// (`ArrayBuffer` in the transfer list), never structured-cloned.
library;

/// JavaScript source of the OPFS worker.
const String kOpfsWorkerSource = r'''
'use strict';

// id -> FileSystemSyncAccessHandle
const handles = new Map();
let nextHandleId = 1;
let rootPromise = null;

// Optional SharedArrayBuffer ring; null unless the page is cross-origin
// isolated and the client sent `sabInit`.
const SAB_STRIDE = 16;
let sabControl = null;
let sabData = null;
let sabSlots = 0;
let sabPayload = 0;
let sabIdle = 0;

function sabInit(m) {
  sabSlots = m.slots | 0;
  sabPayload = m.payload | 0;
  sabControl = new Int32Array(m.sab, 0, sabSlots * SAB_STRIDE + 1);
  sabData = new Uint8Array(m.sab, m.controlBytes | 0, sabSlots * sabPayload);
  sabIdle = sabSlots * SAB_STRIDE;
  Atomics.store(sabControl, sabIdle, 1);
  return {};
}

function sabDrain() {
  if (!sabControl) return;
  for (;;) {
    let found = false;
    for (let i = 0; i < sabSlots; i++) {
      const base = i * SAB_STRIDE;
      if (Atomics.load(sabControl, base) !== 2) continue;
      found = true;
      const op = Atomics.load(sabControl, base + 1);
      const handle = Atomics.load(sabControl, base + 3);
      const at = Atomics.load(sabControl, base + 4) +
          Atomics.load(sabControl, base + 5) * 4294967296;
      const len = Atomics.load(sabControl, base + 6);
      const off = i * sabPayload;
      let n = -1;
      let err = 0;
      try {
        const h = handleFor(handle);
        if (op === 1) {
          n = h.read(sabData.subarray(off, off + len), {at: at});
        } else if (op === 2) {
          n = h.write(sabData.subarray(off, off + len), {at: at});
        } else {
          throw new Error('unknown SAB op: ' + op);
        }
      } catch (_) {
        n = -1;
        err = 1;
      }
      Atomics.store(sabControl, base + 7, n);
      Atomics.store(sabControl, base + 8, err);
      Atomics.store(sabControl, base, 3);
      Atomics.notify(sabControl, base, 1);
    }
    if (!found) {
      Atomics.store(sabControl, sabIdle, 1);
      // Re-check after publishing idle to close the lost-wake window.
      let pending = false;
      for (let i = 0; i < sabSlots; i++) {
        if (Atomics.load(sabControl, i * SAB_STRIDE) === 2) {
          pending = true;
          break;
        }
      }
      if (!pending) break;
      Atomics.store(sabControl, sabIdle, 0);
    }
  }
}

function root() {
  if (!rootPromise) {
    if (!navigator.storage || typeof navigator.storage.getDirectory !== 'function') {
      throw new Error('OPFS is not available (navigator.storage.getDirectory missing)');
    }
    rootPromise = navigator.storage.getDirectory();
  }
  return rootPromise;
}

function splitPath(path) {
  const text = String(path);
  const parts = text.split('/').filter(function (s) { return s.length > 0; });
  if (parts.length === 0) throw new Error('empty OPFS path: ' + text);
  return parts;
}

async function parentDir(path, create) {
  const parts = splitPath(path);
  let dir = await root();
  for (let i = 0; i < parts.length - 1; i++) {
    dir = await dir.getDirectoryHandle(parts[i], {create: !!create});
  }
  return {dir: dir, name: parts[parts.length - 1]};
}

async function fileHandleFor(path, create) {
  const parent = await parentDir(path, create);
  return parent.dir.getFileHandle(parent.name, {create: !!create});
}

function handleFor(id) {
  const handle = handles.get(id);
  if (!handle) throw new Error('unknown sync access handle id: ' + id);
  return handle;
}

const ops = {
  // Capability handshake; the main thread cannot call createSyncAccessHandle.
  async hello() {
    let opfs = false;
    let syncAccessHandle = false;
    try {
      opfs = !!(navigator.storage && typeof navigator.storage.getDirectory === 'function');
    } catch (_) {}
    try {
      syncAccessHandle = typeof FileSystemFileHandle !== 'undefined' &&
          typeof FileSystemFileHandle.prototype.createSyncAccessHandle === 'function';
    } catch (_) {}
    return {opfs: opfs, syncAccessHandle: syncAccessHandle};
  },

  async open(m) {
    const fh = await fileHandleFor(m.path, !!m.create);
    const handle = await fh.createSyncAccessHandle();
    const id = nextHandleId++;
    handles.set(id, handle);
    return {handle: id, size: handle.getSize()};
  },

  async read(m) {
    const handle = handleFor(m.handle);
    const length = m.len | 0;
    const buffer = new Uint8Array(length);
    const n = handle.read(buffer, {at: m.at | 0});
    return {value: {n: n, buffer: buffer.buffer}, transfer: [buffer.buffer]};
  },

  async write(m) {
    const handle = handleFor(m.handle);
    const view = new Uint8Array(m.buffer);
    const n = handle.write(view, {at: m.at | 0});
    return {n: n};
  },

  async truncate(m) {
    handleFor(m.handle).truncate(m.size);
    return {};
  },

  async flush(m) {
    handleFor(m.handle).flush();
    return {};
  },

  async size(m) {
    return {size: handleFor(m.handle).getSize()};
  },

  async closeHandle(m) {
    const handle = handles.get(m.handle);
    if (handle) {
      handles.delete(m.handle);
      try {
        handle.close();
      } catch (_) {}
    }
    return {};
  },

  // Reads a whole (small) file into a transferred buffer; used for manifests.
  async readAll(m) {
    const limit = m.limit || 8388608;
    const fh = await fileHandleFor(m.path, false);
    const handle = await fh.createSyncAccessHandle();
    try {
      const size = handle.getSize();
      if (size > limit) {
        throw new Error('file too large to read whole: ' + size + ' > ' + limit);
      }
      const buffer = new Uint8Array(size);
      let n = 0;
      if (size > 0) n = handle.read(buffer, {at: 0});
      return {value: {n: n, buffer: buffer.buffer}, transfer: [buffer.buffer]};
    } finally {
      try {
        handle.close();
      } catch (_) {}
    }
  },

  // Atomically-ish replaces a whole (small) file: flush before close.
  async writeAll(m) {
    const fh = await fileHandleFor(m.path, true);
    const handle = await fh.createSyncAccessHandle();
    try {
      handle.truncate(0);
      if (m.buffer && m.buffer.byteLength > 0) {
        handle.write(new Uint8Array(m.buffer), {at: 0});
      }
      handle.flush();
    } finally {
      try {
        handle.close();
      } catch (_) {}
    }
    return {};
  },

  async exists(m) {
    try {
      await fileHandleFor(m.path, false);
      return {exists: true};
    } catch (e) {
      if (e && e.name === 'NotFoundError') return {exists: false};
      throw e;
    }
  },

  async remove(m) {
    const parent = await parentDir(m.path, false);
    try {
      await parent.dir.removeEntry(parent.name, {recursive: !!m.recursive});
      return {removed: true};
    } catch (e) {
      if (e && e.name === 'NotFoundError') return {removed: false};
      throw e;
    }
  },

  async list(m) {
    const parts = splitPath(m.path);
    let dir = await root();
    for (let i = 0; i < parts.length; i++) {
      dir = await dir.getDirectoryHandle(parts[i], {create: false});
    }
    const names = [];
    for await (const name of dir.keys()) names.push(name);
    return {names: names};
  }
};

let chain = Promise.resolve();

self.onmessage = function (event) {
  const m = event.data;
  if (m.op === 'sabInit') {
    try {
      const value = sabInit(m);
      self.postMessage({id: m.id, ok: true, value: value});
    } catch (e) {
      self.postMessage({
        id: m.id,
        ok: false,
        name: String((e && e.name) || 'Error'),
        error: String((e && e.message) || e)
      });
    }
    return;
  }
  if (m.op === 'sabWake') {
    sabDrain();
    return;
  }
  chain = chain.then(async function () {
    try {
      const op = ops[m.op];
      if (!op) throw new Error('unknown op: ' + m.op);
      const result = await op(m);
      const hasValue = result && typeof result === 'object' && 'value' in result;
      const value = hasValue ? result.value : result;
      const transfer = (result && result.transfer) || [];
      self.postMessage({
        id: m.id,
        ok: true,
        value: value === undefined ? null : value
      }, transfer);
    } catch (e) {
      self.postMessage({
        id: m.id,
        ok: false,
        name: String((e && e.name) || 'Error'),
        error: String((e && e.message) || e)
      });
    }
  }).catch(function () {});
};
''';
