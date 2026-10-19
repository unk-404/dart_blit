/// Zero-copy bytes and high-performance random-access file I/O.
///
/// Core types are web-safe (no `dart:io` / `dart:ffi`).  Use
/// `package:blit/bytes_ffi.dart` for the native mmap engine.
library;

export 'src/bytes.dart';
export 'src/bytes_mut.dart';
export 'src/bytes_reader.dart';
export 'src/bytes_writer.dart';
export 'src/io/bytes_file.dart';
export 'src/io/open.dart';
export 'src/u64/uint64.dart';
