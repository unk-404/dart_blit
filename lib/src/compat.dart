/// Zero-copy interop with Dart's typed-data types and other byte libraries.
library;

import 'dart:typed_data';

import 'bytes.dart';
import 'bytes_like.dart';

export 'bytes_like.dart';

/// Converts any [TypedData] to a zero-copy [Bytes] view.
extension TypedDataBytes on TypedData {
  /// Zero-copy view over this typed-data region.
  Bytes asBytes() => Bytes.fromTypedData(this);
}

/// Converts a [BytesLike] implementation to a zero-copy [Bytes] view.
extension BytesLikeBytes on BytesLike {
  /// Zero-copy conversion; returns the same instance when this is already a
  /// [Bytes].
  Bytes toBytes() => Bytes.fromBytesLike(this);
}
