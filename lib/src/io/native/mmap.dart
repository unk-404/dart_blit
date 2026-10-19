import 'dart:io';

import 'mmap_base.dart';
import 'mmap_posix.dart';
import 'mmap_windows.dart';

export 'mmap_base.dart';

/// Opens a native mmap file.  Synchronous; run in a worker isolate for UI code.
Future<MmapFile> openMmapFile(String path,
    {bool create = true, bool readOnly = false}) async {
  if (Platform.isWindows) {
    return WindowsMmapFile.open(path, create: create, readOnly: readOnly);
  }
  return PosixMmapFile.open(path, create: create, readOnly: readOnly);
}

/// Synchronous open.
MmapFile openMmapFileSync(String path,
    {bool create = true, bool readOnly = false}) {
  if (Platform.isWindows) {
    return WindowsMmapFile.openSync(path, create: create, readOnly: readOnly);
  }
  return PosixMmapFile.openSync(path, create: create, readOnly: readOnly);
}
