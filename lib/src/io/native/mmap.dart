import 'dart:io';

import 'mmap_base.dart';
import 'mmap_posix.dart';
import 'mmap_windows.dart';

export 'mmap_base.dart';

/// Opens a native mmap file.  Synchronous; run in a worker isolate for UI code.
///
/// [direct] uses `FILE_FLAG_NO_BUFFERING` on Windows and requires 4 KiB aligned
/// offsets/lengths.  It is for streaming files larger than RAM; random 4 KiB
/// access is much slower than the buffered/mmap path.  Other platforms throw
/// [UnsupportedError] for [direct] until their direct-I/O path is implemented.
Future<MmapFile> openMmapFile(String path,
    {bool create = true, bool readOnly = false, bool direct = false}) async {
  if (Platform.isWindows) {
    return WindowsMmapFile.open(
        path, create: create, readOnly: readOnly, direct: direct);
  }
  if (direct) {
    throw UnsupportedError('Direct I/O is not implemented on this platform.');
  }
  return PosixMmapFile.open(path, create: create, readOnly: readOnly);
}

/// Synchronous open.
MmapFile openMmapFileSync(String path,
    {bool create = true, bool readOnly = false, bool direct = false}) {
  if (Platform.isWindows) {
    return WindowsMmapFile.openSync(
        path, create: create, readOnly: readOnly, direct: direct);
  }
  if (direct) {
    throw UnsupportedError('Direct I/O is not implemented on this platform.');
  }
  return PosixMmapFile.openSync(path, create: create, readOnly: readOnly);
}
