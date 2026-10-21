/// Native-buffer extensions for [AsyncFile].
library;

import 'async_file.dart';
import 'native_buffer.dart';

extension AsyncFileNative on AsyncFile {
  /// Reads into a caller-owned native buffer without allocating a Dart buffer.
  Future<int> readIntoNative(int offset, NativeBuffer buffer) =>
      readAt(offset, buffer.readBuf());

  /// Writes from a caller-owned native buffer.
  Future<int> writeFromNative(int offset, NativeBuffer buffer) =>
      writeAt(offset, buffer.writeSlice());

  /// Reads the whole file into a pooled native buffer.
  ///
  /// The caller owns the result and must dispose/release it.
  Future<NativeBuffer> readAllNative({NativeBufferPool? pool}) async {
    final length = await this.length;
    final buffer = pool?.acquire(length) ?? NativeBuffer.allocate(length);
    try {
      final n = await readIntoNative(0, buffer);
      if (n != length) throw StateError('short native read: $n of $length');
      return buffer;
    } catch (_) {
      pool?.release(buffer);
      rethrow;
    }
  }
}
