/// 32 GiB sparse-file test: a 4 KiB write at the 30 GiB offset must not
/// zero-fill the 30 GiB gap.
///
/// This test is skipped by default because it creates a 32 GiB logical file.
/// On NTFS/APFS/ext4/xfs it is sparse and uses only a few MiB of real disk;
/// run it explicitly with:
///
///     $env:BYTES_RUN_32G = '1'
///     dart test test/native/sparse_32g_test.dart
///
/// The time thresholds are deliberately loose (10 s) so a slow CI machine does
/// not fail while a zero-filling filesystem (which needs minutes) still does.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/src/io/native/native.dart';
import 'package:test/test.dart';

const int _gib = 1024 * 1024 * 1024;
const int _fileSize = 32 * _gib;
const int _writeOffset = 30 * _gib;
const int _gapOffset = 20 * _gib;
const int _blockSize = 4096;
const Duration _maxFarIo = Duration(seconds: 10);

void main() {
  final enabled = Platform.environment['BYTES_RUN_32G'] == '1';
  final supported = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final Object skip;
  if (!enabled) {
    skip = 'set BYTES_RUN_32G=1 to run the 32 GiB sparse-file test';
  } else if (!supported) {
    skip = '32 GiB sparse test is only enabled on Windows, Linux and macOS';
  } else {
    skip = false;
  }

  test(
    '32 GiB sparse file: far 4K write/read does not zero-fill',
    () {
      final dir = Directory.systemTemp.createTempSync('bytes_sparse_32g_');
      final path = '${dir.path}${Platform.pathSeparator}sparse32g.bin';
      final watch = Stopwatch();
      try {
        final file = openMmapFileSync(path);
        try {
          // ---- extend sparsely ----------------------------------------------
          watch
            ..reset()
            ..start();
          file.truncate(_fileSize, sparse: true);
          watch.stop();
          final truncateMs = watch.elapsedMilliseconds;
          expect(file.length, _fileSize);
          expect(
            truncateMs,
            lessThan(_maxFarIo.inMilliseconds),
            reason: 'sparse truncate to 32 GiB took ${truncateMs}ms',
          );

          // ---- write 4 KiB at 30 GiB --------------------------------------
          final payload = Uint8List(_blockSize);
          for (var i = 0; i < payload.length; i++) {
            payload[i] = (i * 37 + 11) & 0xFF;
          }
          watch
            ..reset()
            ..start();
          expect(file.writeAt(_writeOffset, payload), _blockSize);
          watch.stop();
          final writeMs = watch.elapsedMilliseconds;
          expect(
            writeMs,
            lessThan(_maxFarIo.inMilliseconds),
            reason:
                '4 KiB write at 30 GiB took ${writeMs}ms; this suggests '
                'the gap was zero-filled instead of staying sparse',
          );
          expect(file.length, _fileSize);

          // ---- read it back ------------------------------------------------
          final readBack = Uint8List(_blockSize);
          watch
            ..reset()
            ..start();
          expect(file.readAt(_writeOffset, readBack), _blockSize);
          watch.stop();
          final readMs = watch.elapsedMilliseconds;
          expect(readBack, payload);
          expect(
            readMs,
            lessThan(_maxFarIo.inMilliseconds),
            reason: '4 KiB read at 30 GiB took ${readMs}ms',
          );

          // ---- the untouched gap is sparse zeros and cheap to read ---------
          final gap = Uint8List(_blockSize);
          watch
            ..reset()
            ..start();
          expect(file.readAt(_gapOffset, gap), _blockSize);
          watch.stop();
          final gapMs = watch.elapsedMilliseconds;
          expect(gap.every((b) => b == 0), isTrue);
          expect(
            gapMs,
            lessThan(_maxFarIo.inMilliseconds),
            reason: 'reading the sparse gap at 20 GiB took ${gapMs}ms',
          );

          // ---- a mapped window at 30 GiB sees the write --------------------
          final region = file.map(offset: _writeOffset, length: _blockSize);
          expect(region.length, _blockSize);
          expect(region.bytes, payload);
          region.close();
          file.flush();
        } finally {
          file.close();
        }

        expect(
          File(path).lengthSync(),
          _fileSize,
          reason: 'logical length must remain 32 GiB',
        );
      } finally {
        if (File(path).existsSync()) {
          File(path).deleteSync();
        }
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

