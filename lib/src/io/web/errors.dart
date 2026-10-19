/// Error types raised by the Web (OPFS) backend.
///
/// The web backend cannot throw `dart:io`'s `FileSystemException` (that library
/// is unavailable on the web), so it reports browser `DOMException`s with a
/// small, dependency-free type instead.  The original DOMException *name* is
/// preserved so callers can branch exactly like they would in JavaScript:
///
/// ```dart
/// try {
///   await openOpfsBytesFile('missing.bin', create: false);
/// } on WebFileSystemException catch (e) {
///   if (e.isNotFound) { /* create it */ }
/// }
/// ```
// ignore_for_file: use_super_parameters
library;

/// A failure reported by the browser File System API / OPFS layer.
class WebFileSystemException implements Exception {
  /// Creates an exception from a browser-reported error name and message.
  const WebFileSystemException(this.name, this.message, {this.path});

  /// The `DOMException.name` (for example `NotFoundError`), or `Error` when a
  /// plain JavaScript `Error` was thrown.
  final String name;

  /// Human readable message from the browser.
  final String message;

  /// Logical path the operation was working on, when known.
  final String? path;

  /// The entry does not exist (`create: false` on a missing path).
  bool get isNotFound => name == 'NotFoundError';

  /// The origin's storage quota is exhausted.
  bool get isQuotaExceeded => name == 'QuotaExceededError';

  /// Another handle (another tab/worker) holds the file's exclusive lock.
  bool get isNoModificationAllowed => name == 'NoModificationAllowedError';

  /// The manifest is corrupt beyond recovery.
  bool get isCorruptManifest => name == 'CorruptManifestError';

  /// The requested storage backend is unavailable (e.g. no OPFS).
  bool get isUnsupported => name == 'UnsupportedError';

  @override
  String toString() {
    final suffix = path == null ? '' : ' ($path)';
    return 'WebFileSystemException($name): $message$suffix';
  }
}

/// Thrown when OPFS reports `QuotaExceededError`.
///
/// Quota is tracked per origin and is not a hard limit in any browser (Chrome
/// can report a 10 GiB `estimate().quota` and still accept a 32 GiB sparse
/// file), so the backend never pre-rejects a write based on `estimate()`: it
/// writes and translates the failure into this type.  Callers should treat it
/// as "free space / cleanup needed", not as "file too large".
final class WebQuotaExceededException extends WebFileSystemException {
  /// Creates a quota error with the browser-provided [message].
  const WebQuotaExceededException(String message, {String? path})
    : super('QuotaExceededError', message, path: path);
}
