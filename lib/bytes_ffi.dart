/// Native-only mmap engine (pure `dart:ffi`, no C).
///
/// Import this library only on native targets; it uses `dart:io` and
/// `dart:ffi`.  Web builds should use `package:blit/bytes.dart` instead.
library;

export 'src/io/native/iocp_windows.dart' show IocpException, IocpFile;
export 'src/io/native/mmap_windows.dart' show WindowsException;
export 'src/io/native/isolate_pool.dart';
export 'src/io/native/mmap.dart';
export 'src/io/native/uring_file.dart';
export 'src/io/read_fast.dart';
