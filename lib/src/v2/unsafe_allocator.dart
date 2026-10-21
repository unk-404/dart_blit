/// Platform allocator used by UnsafeBytes.
library;

export 'unsafe_allocator_native.dart'
    if (dart.library.js_interop) 'unsafe_allocator_web.dart';
