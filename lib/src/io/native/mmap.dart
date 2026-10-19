import 'dart:io';

import 'mmap_base.dart';
import 'mmap_posix.dart';
import 'mmap_windows.dart';

export 'mmap_base.dart';

/// Opens a native mmap file.  Synchronous; run in a worker isolate for UI code.
///
/// [direct] uses `FILE_FLAG_NO_BUFFERING` on Windows, `O_DIRECT` on
/// Linux/Android and `F_NOCACHE` on macOS/iOS.  It requires 4 KiB aligned
/// offsets/lengths and is for streaming files larger than RAM; random 4 KiB
/// access is much slower than the buffered/mmap path.
Future<MmapFile> openMmapFile(String path,
    {bool create = true, bool readOnly = false, bool direct = false}) async {
  if (Platform.isWindows) {
    return WindowsMmapFile.open(
        path, create: create, readOnly: readOnly, direct: direct);
  }
  return PosixMmapFile.open(
      path, create: create, readOnly: readOnly, direct: direct);
}

/// Synchronous open.
MmapFile openMmapFileSync(String path,
    {bool create = true, bool readOnly = false, bool direct = false}) {
  if (Platform.isWindows) {
    return WindowsMmapFile.openSync(
        path, create: create, readOnly: readOnly, direct: direct);
  }
  return PosixMmapFile.openSync(
      path, create: create, readOnly: readOnly, direct: direct);
}
