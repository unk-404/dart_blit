// Core Bytes/BytesMut/reader/writer benchmarks.
//
// Run:
//   dart run benchmark_test --output jsonl benchmark/bytes_benchmarks_test.dart
//
// Bodies with an `xN` suffix execute N operations; divide ops/sec by N for
// per-operation throughput. Units are applied by bytes-bench-svg.toml.

@Timeout(Duration(minutes: 5))
library;

import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit.dart';
import 'package:test/test.dart' show Timeout, group, setUpAll;

int _sink = 0;
var _index = 0;

const _benchTimeout = Timeout(Duration(minutes: 2));

void bench(String name, dynamic Function() body) =>
    benchmark(name, body, timeout: _benchTimeout);

Uint8List _pattern(int length) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = (i * 31 + 7) & 0xFF;
  }
  return data;
}

void main() {
  final data = Bytes.fromList(_pattern(1 << 20));
  final mut = BytesMut(1 << 20);

  setUpAll(() {
    // Warm the JIT and the fixed-size destinations once.
    for (var i = 0; i < 1000; i++) {
      _sink ^= data.getUint8(i);
    }
  });

  group('Bytes', () {
    bench('bytes.slice x1024', () {
      for (var i = 0; i < 1024; i++) {
        final start = (_index++ * 7) & 0xFFFF;
        _sink ^= data.slice(start, start + 333)[0];
      }
    });

    bench('bytes.getUint8.checked x4096', () {
      for (var i = 0; i < 4096; i++) {
        _sink ^= data.getUint8((_index++ * 13) & 0xFFFFF);
      }
    });

    bench('bytes.getUint8.unchecked x4096', () {
      for (var i = 0; i < 4096; i++) {
        _sink ^= data.getUint8Unchecked((_index++ * 13) & 0xFFFFF);
      }
    });

    bench('bytes.getUint32 x4096', () {
      for (var i = 0; i < 4096; i++) {
        _sink ^= data.getUint32((_index++ * 4) & 0xFFFFF);
      }
    });

    bench('bytes.copyTo.4KiB x64', () {
      final dst = Uint8List(4096);
      for (var i = 0; i < 64; i++) {
        data.slice(0, 4096).copyTo(dst);
        _sink ^= dst[4095];
      }
    });

    bench('bytes.fromTypedData x4096', () {
      for (var i = 0; i < 4096; i++) {
        _sink ^= Bytes.fromTypedData(data.asUint8List()).getUint8(0);
      }
    });
  });

  group('BytesMut', () {
    bench('mut.putUint8.checked x4096', () {
      mut.clear();
      for (var i = 0; i < 4096; i++) {
        mut.putUint8(i);
      }
      _sink ^= mut.asUint8List()[4095];
    });

    bench('mut.putUint8.unchecked x4096', () {
      mut.clear();
      for (var i = 0; i < 4096; i++) {
        mut.putUint8Unchecked(i);
      }
      _sink ^= mut.asUint8List()[4095];
    });

    bench('mut.spareView.4KiB x1', () {
      mut.clear();
      final spare = mut.spareView(4096);
      for (var i = 0; i < 4096; i++) {
        spare[i] = i;
      }
      mut.advance(4096);
      _sink ^= spare[4095];
    });

    bench('mut.putUint32 x1024', () {
      mut.clear();
      for (var i = 0; i < 1024; i++) {
        mut.putUint32(i);
      }
      _sink ^= mut.asUint8List()[4095];
    });
  });

  group('Raw', () {
    final raw = Uint8List(4096);
    bench('raw.uint8.write x4096', () {
      for (var i = 0; i < 4096; i++) {
        raw[i] = i;
      }
      _sink ^= raw[4095];
    });

    bench('raw.uint8.read x4096', () {
      for (var i = 0; i < 4096; i++) {
        _sink ^= raw[i];
      }
    });
  });

  {
    final scratch = BytesMut(1 << 16);
    final copy = Uint8List(4096);

    bench('mem.getUint32', () {
      for (var i = 0; i < 4096; i++) {
        _sink ^= data.getUint32((_index++ * 4) & 0xFFFFC);
      }
    });

    bench('mem.read4K', () {
      for (var n = 0; n < 64; n++) {
        for (var i = 0; i < 4096; i++) {
          _sink ^= data[i];
        }
      }
    });

    bench('mem.write4K', () {
      for (var n = 0; n < 64; n++) {
        scratch.clear();
        final view = scratch.spareView(4096);
        view.fillRange(0, 4096, n & 0xFF);
        scratch.advance(4096);
        _sink ^= copy[n & 4095];
      }
    });

    bench('mem.setUint32', () {
      scratch.clear();
      for (var i = 0; i < 4096; i++) {
        scratch.putUint32Unchecked(i);
      }
      _sink ^= scratch.length;
    });

    bench('mem.alloc4K', () {
      for (var i = 0; i < 64; i++) {
        final value = Bytes.fromUint8List(Uint8List(4096));
        _sink ^= value.length;
      }
    });
  }
  group('Reader/Writer', () {
    bench('reader.readUint8.checked x4096', () {
      final reader = BytesReader(data);
      for (var i = 0; i < 4096; i++) {
        _sink ^= reader.readUint8();
      }
    });

    bench('reader.readUint8.unchecked x4096', () {
      final reader = BytesReader(data);
      for (var i = 0; i < 4096; i++) {
        _sink ^= reader.readUint8Unchecked();
      }
    });

    bench('writer.putUint8 x4096', () {
      final writer = BytesWriter(Uint8List(4096));
      for (var i = 0; i < 4096; i++) {
        writer.putUint8(i);
      }
      _sink ^= writer.position;
    });
  });

  if (_sink == 0x7fffffff) print('unreachable sink=$_sink');
}
