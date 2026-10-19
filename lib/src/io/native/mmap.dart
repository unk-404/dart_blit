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
    {bool create = true,
    bool readOnly = false,
    bool direct = false,
    bool largePages = false}) async {
  if (Platform.isWindows) {
    return WindowsMmapFile.open(path,
        create: create,
        readOnly: readOnly,
        direct: direct,
        largePages: largePages);
  }
  if (largePages) {
    throw UnsupportedError('large pages are only implemented on Windows');
  }
  return PosixMmapFile.open(
      path, create: create, readOnly: readOnly, direct: direct);
}

/// Synchronous open.
MmapFile openMmapFileSync(String path,
    {bool create = true,
    bool readOnly = false,
    bool direct = false,
    bool largePages = false}) {
  if (Platform.isWindows) {
    return WindowsMmapFile.openSync(path,
        create: create,
        readOnly: readOnly,
        direct: direct,
        largePages: largePages);
  }
  if (largePages) {
    throw UnsupportedError('large pages are only implemented on Windows');
  }
  return PosixMmapFile.openSync(
      path, create: create, readOnly: readOnly, direct: direct);
}

/// Clones [source] to [dest].
///
/// macOS/iOS use `clonefile(2)` (APFS copy-on-write).  Other platforms fall
/// back to `File.copySync`; use [MmapFile.cloneRangeFrom] on Windows when
/// block cloning is available.
void cloneFileSync(String source, String dest, {bool overwrite = false}) {
  if (Platform.isMacOS || Platform.isIOS) {
    posixCloneFileSync(source, dest, overwrite: overwrite);
    return;
  }
  if (overwrite) {
    final old = File(dest);
    if (old.existsSync()) old.deleteSync();
  }
  File(source).copySync(dest);
}
