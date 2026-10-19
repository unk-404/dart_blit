// Probe: validates the primitives the Web backend depends on.
//
//   1. `Worker` created from a `Blob` URL (no extra asset to bundle).
//   2. JS object literal messages built from an `external factory`, and reading
//      reply fields back with `dart:js_interop_unsafe`.
//   3. `ArrayBuffer` transfer in both directions plus `JSArrayBuffer.toDart`.
//   4. OPFS + `createSyncAccessHandle()` inside the dedicated worker.
//
// This is a real test (it guards the transport) and doubles as a fast failure
// signal if a future browser change breaks the hand-written interop layer.
@TestOn('browser')
@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:blit/src/io/web/js.dart';
import 'package:test/test.dart';

const _source = r'''
let syncOk = false;
try {
  syncOk = typeof FileSystemFileHandle !== 'undefined' &&
      typeof FileSystemFileHandle.prototype.createSyncAccessHandle === 'function';
} catch (_) {}
self.onmessage = async (e) => {
  const m = e.data;
  if (m.op === 'echo') {
    const bytes = new Uint8Array(m.buf);
    bytes[0] = (bytes[0] + 1) & 0xFF;
    self.postMessage(
        {id: m.id, ok: true, n: bytes.length, buf: bytes.buffer},
        [bytes.buffer]);
    return;
  }
  if (m.op === 'opfs') {
    const root = await navigator.storage.getDirectory();
    const fh = await root.getFileHandle('probe_interop.bin', {create: true});
    const ah = await fh.createSyncAccessHandle();
    ah.write(new Uint8Array([7, 8, 9]), {at: 0});
    const out = new Uint8Array(3);
    const n = ah.read(out, {at: 0});
    ah.truncate(0);
    ah.close();
    await root.removeEntry('probe_interop.bin');
    self.postMessage({id: m.id, ok: true, sync: syncOk, n: n, first: out[0]});
    return;
  }
  self.postMessage({id: m.id, ok: false, error: 'bad op'});
};
''';

extension type _Request._(JSObject _) implements JSObject {
  external factory _Request({int id, String op, JSArrayBuffer buf});
}

void main() {
  test('blob-url worker transport + OPFS sync access handle', () async {
    final blob = JsBlob(
      <JSAny>[_source.toJS].toJS,
      jsObject({'type': 'text/javascript'}),
    );
    final url = jsCreateObjectURL(blob);
    final worker = JsWorker(url);

    final replies = <int, Completer<Map<String, Object?>>>{};
    var nextId = 1;

    worker.onmessage = ((JSAny event) {
      final reply = (event as JSObject)['data'] as JSObject;
      final id = (reply['id'] as JSNumber).toDartInt;
      final ok = (reply['ok'] as JSBoolean).toDart;
      final buf = reply['buf'];
      replies[id]!.complete({
        'ok': ok,
        'n': (reply['n'] as JSNumber).toDartInt,
        'sync': reply['sync'] == null
            ? null
            : (reply['sync'] as JSBoolean).toDart,
        'first': reply['first'] == null
            ? null
            : (reply['first'] as JSNumber).toDartInt,
        'error': reply['error'] == null
            ? null
            : (reply['error'] as JSString).toDart,
        'bytes': buf == null
            ? null
            : (buf as JSArrayBuffer).toDart.asUint8List(),
      });
    }).toJS;

    Future<Map<String, Object?>> send(
      _Request message,
      int id, {
      List<JSAny>? transfer,
    }) {
      final completer = Completer<Map<String, Object?>>();
      replies[id] = completer;
      if (transfer == null) {
        worker.postMessage(message);
      } else {
        worker.postMessageWithTransfer(message, transfer.toJS);
      }
      return completer.future;
    }

    try {
      // 1. echo an ArrayBuffer through the worker.
      final input = Uint8List.fromList([1, 2, 3, 4]);
      final echoId = nextId++;
      final echoFuture = send(
        _Request(id: echoId, op: 'echo', buf: input.buffer.toJS),
        echoId,
        transfer: <JSAny>[input.buffer.toJS],
      );
      final echo = await echoFuture;
      expect(echo['ok'], isTrue);
      expect(echo['n'], 4);
      expect(echo['bytes'], isA<Uint8List>());
      expect((echo['bytes']! as Uint8List).toList(), [2, 2, 3, 4]);

      // 2. OPFS + sync access handle inside the worker.
      final opfsId = nextId++;
      final opfsFuture = send(_Request(id: opfsId, op: 'opfs'), opfsId);
      final opfs = await opfsFuture;
      expect(opfs['ok'], isTrue, reason: 'worker error: ${opfs['error']}');
      expect(
        opfs['sync'],
        isTrue,
        reason: 'createSyncAccessHandle is worker-only and must exist',
      );
      expect(opfs['n'], 3);
      expect(opfs['first'], 7);
    } finally {
      worker.terminate();
      jsRevokeObjectURL(url);
    }
  });
}
