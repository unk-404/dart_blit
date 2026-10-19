/// CRC-32 (IEEE 802.3, polynomial `0xEDB88320`) — pure Dart, web-safe.
///
/// Used for the per-chunk checksums and the manifest trailer.  Two details
/// matter on the web:
///
/// * `dart2js` bitwise operators operate on 32-bit integers and may produce
///   signed values, so every step is normalized with `>>> 0`.  Nothing here
///   relies on 64-bit integer semantics.
/// * table generation uses the same normalization, so the table is identical
///   on the VM, `dart2js` and `dart2wasm`.
library;

import 'dart:typed_data';

/// Table-driven CRC-32 helpers with an incremental API.
final class Crc32 {
  Crc32._();

  static final Uint32List _table = _buildTable();

  /// Initial CRC state for a fresh computation.
  static const int initial = 0xFFFFFFFF;

  /// XOR value applied to the final state (standard CRC-32 finalization).
  static const int xorOut = 0xFFFFFFFF;

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var bit = 0; bit < 8; bit++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) >>> 0 : c >>> 1;
      }
      table[i] = c & 0xFFFFFFFF;
    }
    return table;
  }

  /// Folds [length] bytes of [data] (starting at [start]) into [state].
  ///
  /// [state] is a running (unfinalized) CRC, starting at [initial]; pass the
  /// result back in to continue hashing a stream of buffers.
  static int update(int state, Uint8List data, [int start = 0, int? end]) {
    final e = end ?? data.length;
    var crc = state & 0xFFFFFFFF;
    for (var i = start; i < e; i++) {
      crc = (_table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8)) >>> 0;
    }
    return crc;
  }

  /// Converts a running [state] into the final CRC-32 value.
  static int finish(int state) => (state ^ xorOut) >>> 0;

  /// Convenience: full CRC-32 of `data[start..end)`.
  static int compute(Uint8List data, [int start = 0, int? end]) =>
      finish(update(initial, data, start, end));
}
