/// Platform external-memory primitives.
library;

export 'allocator_native.dart'
    if (dart.library.js_interop) 'allocator_web.dart';
