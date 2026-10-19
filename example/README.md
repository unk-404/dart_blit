# Examples

- `bytes_example.dart` — zero-copy `Bytes`, `BytesMut`, `Uint64`, and native
  random-access file I/O.
- `bytes_web_example.dart` — Web-safe core (no `dart:io`/`dart:ffi`), suitable
  for `dart compile js` / `dart compile wasm`.

From the repository root:

```sh
dart run example/bytes_example.dart
dart compile js example/bytes_web_example.dart -o build/web/example.js
```
