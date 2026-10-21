import '../bytes_file.dart';
import '../bytes_file_native.dart';
import '../read_fast.dart';
import '../native/native_mmap_file.dart';
import '../options.dart';

Future<BytesFile> openBackend(String path, FileOptions options) async {
  if (options.direct) {
    return NativeMmapFile.open(
      path,
      create: options.create,
      readOnly: options.readOnly,
      direct: true,
    );
  }
  if (options.readOnly) {
    return ReadFast.open(
      path,
      create: options.create && !options.readOnly,
      readOnly: true,
      workers:
          options.profile == PerformanceProfile.latency ||
              options.profile == PerformanceProfile.memory
          ? 1
          : null,
    );
  }
  return NativeBytesFile.open(
    path,
    create: options.create,
    readOnly: options.readOnly,
  );
}

