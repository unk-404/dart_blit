/// The Dart/GC baseline allocator used only for benchmark comparison.
library;

import 'dart:typed_data';

final class DartAllocator {
  Uint8List alloc(int size) => Uint8List(size);

  void free(Uint8List value) {
    // GC owns it; no-op by design.
  }
}
