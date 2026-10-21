/// Minimal structural view of a contiguous byte source.
///
/// This is intentionally not a replacement for [Bytes]: it is the boundary
/// type for APIs that accept "some bytes" without pinning their public API to
/// `blit.Bytes`.  Implementations must return a contiguous, zero-copy view
/// from [asUint8List]; segmented buffers need to copy explicitly.
library;

import 'dart:typed_data';

abstract interface class BytesLike {
  /// Number of bytes in the view.
  int get length;

  /// Zero-copy contiguous view.
  ///
  /// The returned view must remain valid as long as the implementation says
  /// so.  Callers convert it to [Bytes] or [Uint8List] once and keep that
  /// concrete type in hot loops.
  Uint8List asUint8List();
}
