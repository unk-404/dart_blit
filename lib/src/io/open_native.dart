import 'bytes_file.dart';
import 'bytes_file_native.dart';

/// Opens a native random-access file.
Future<BytesFile> openBytesFile(String path,
        {bool create = true, bool readOnly = false}) =>
    NativeBytesFile.open(path, create: create, readOnly: readOnly);

/// Opens synchronously; use only on native platforms.
SyncBytesFile openBytesFileSync(String path,
        {bool create = true, bool readOnly = false}) =>
    NativeBytesFile.openSync(path, create: create, readOnly: readOnly);
