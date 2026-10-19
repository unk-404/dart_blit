/// Minimal, hand-written Web bindings for the small surface `blit` needs.
///
/// We intentionally do not depend on `package:web`: the backend only touches
/// `Worker`, `Blob`, `URL`, `navigator.storage`, and event objects.  Keeping
/// these declarations local makes the supported surface explicit and avoids a
/// transitive dependency that moves at its own pace.
@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// `globalThis` (`window` on the main thread, `self` in a worker).
JSObject get jsGlobal => globalContext;

/// `globalThis.navigator`, or null in a non-browser JS context.
JSObject? get jsNavigator {
  final value = globalContext['navigator'];
  return value.isUndefinedOrNull ? null : value as JSObject;
}

/// `navigator.storage`, or null when the Storage API is unavailable.
JSObject? get jsStorageManager {
  final navigator = jsNavigator;
  if (navigator == null) return null;
  final value = navigator['storage'];
  return value.isUndefinedOrNull ? null : value as JSObject;
}

/// A DOM `Blob` constructor (must be invoked with `new`).
@JS('Blob')
extension type JsBlob._(JSObject _) implements JSObject {
  external factory JsBlob(JSArray<JSAny> parts, [JSObject? options]);
}

/// A DOM `Worker` with only the members used by the OPFS client.
@JS('Worker')
extension type JsWorker._(JSObject _) implements JSObject {
  external factory JsWorker(String url);

  external set onmessage(JSFunction? callback);
  external set onmessageerror(JSFunction? callback);
  external set onerror(JSFunction? callback);

  external void postMessage(JSAny? message);

  @JS('postMessage')
  external void postMessageWithTransfer(
      JSAny? message, JSArray<JSAny> transfer);

  external void terminate();
}

/// `URL.createObjectURL(blob)`.
@JS('URL.createObjectURL')
external String jsCreateObjectURL(JSObject blob);

/// `URL.revokeObjectURL(url)`.
@JS('URL.revokeObjectURL')
external void jsRevokeObjectURL(String url);

/// `SharedArrayBuffer` (only constructible in a cross-origin-isolated page).
@JS('SharedArrayBuffer')
extension type JsSharedArrayBuffer._(JSObject _) implements JSObject {
  external factory JsSharedArrayBuffer(int byteLength);
}

/// `Int32Array` view over a SAB.
@JS('Int32Array')
extension type JsInt32Array._(JSObject _) implements JSObject {
  external factory JsInt32Array(JSAny buffer, [int byteOffset, int length]);

  external int get length;
  external int operator [](int index);
  external void operator []=(int index, int value);
}

/// `Uint8Array` view over a SAB (or a regular ArrayBuffer).
@JS('Uint8Array')
extension type JsUint8Array._(JSObject _) implements JSObject {
  external factory JsUint8Array(JSAny buffer, [int byteOffset, int length]);

  external int get length;
  external int operator [](int index);
  external void operator []=(int index, int value);

  external JsUint8Array subarray(int begin, [int? end]);
  external JsUint8Array slice([int begin, int? end]);
  external JSAny get buffer;
  external void set(JSObject source, [int offset]);
}

/// `Atomics` (SAB-only; `waitAsync` needs Chrome 87+ / Safari 16.4+).
@JS('Atomics')
external JsAtomics get jsAtomics;

extension type JsAtomics._(JSObject _) implements JSObject {
  external int load(JSObject array, int index);
  external int store(JSObject array, int index, int value);
  external int notify(JSObject array, int index, int count);
  external int compareExchange(
      JSObject array, int index, int expected, int replacement);
  external JSObject waitAsync(JSObject array, int index, int value);
}

/// `{...}` as a JS object; used for Blob options and request literals.
JSObject jsObject(Map<String, Object?> values) =>
    values.jsify() as JSObject;

/// Calls `object[method](...)` and returns the raw JS result.
JSAny? jsCall(JSObject object, String method, [List<JSAny?> args = const []]) =>
    object.callMethodVarArgs<JSAny?>(method.toJS, args);

/// Awaits a `Promise` result returned by [jsCall].
Future<JSAny?> jsAwait(JSAny? value) async {
  if (value == null) return null;
  return (value as JSPromise<JSAny?>).toDart;
}

/// Reads an integer from a JS number (used for quota/usage/counts).
int? jsInt(JSAny? value) {
  if (value.isUndefinedOrNull) return null;
  return (value! as JSNumber).toDartInt;
}

/// Reads a boolean from a JS boolean.
bool jsBool(JSAny? value) {
  if (value.isUndefinedOrNull) return false;
  return (value! as JSBoolean).toDart;
}
