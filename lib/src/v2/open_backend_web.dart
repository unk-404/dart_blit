import '../io/bytes_file.dart';
import '../io/open_web.dart' as opfs;
import '../io/web/web.dart' as web;
import 'options.dart';

/// Web backend selection: OPFS first, IndexedDB fallback.
Future<BytesFile> openBackend(String path, FileOptions options) async {
  try {
    return await opfs.openBytesFile(
      path,
      create: options.create && !options.readOnly,
      readOnly: options.readOnly,
    );
  } catch (opfsError, stack) {
    try {
      return await web.openIdbBytesFile(
        path,
        create: options.create && !options.readOnly,
        readOnly: options.readOnly,
      );
    } catch (_) {
      Error.throwWithStackTrace(opfsError, stack);
    }
  }
}
