/// Mimalloc-inspired allocator for blit.
///
/// Follows mimalloc's source where it matters for blit:
/// * the 73-bin 12.5% table from `init.c` / `page-queue.c`;
/// * 64 KiB small pages, 512 KiB medium pages, 4 MiB large pages;
/// * page-local free lists and lazy 8 KiB capacity extension from `page.c`;
/// * on-demand page allocation; no arena is reserved up front.
///
/// It intentionally omits mimalloc's thread-safe heaps, arenas, guard pages,
/// encoded free lists and OS commit machinery. The unsafe path is assumed to be
/// single-isolate, and invalid operations are undefined.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'allocator_api.dart';

const int _smallPageSize = 64 * 1024;
const int _mediumPageSize = 512 * 1024;
const int _largePageSize = 4 * 1024 * 1024;
const int _maxExtendBytes = 8 * 1024;
const int _sliceShift = 16;
const int _sliceSize = 1 << _sliceShift;
const int _hugeBin = 73;

// mimalloc `init.c`: MI_PAGE_QUEUES_EMPTY, words converted to bytes.
// index 0 is unused; bins 1..72 are the real classes.
const List<int> _binSizes = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  384,
  448,
  512,
  640,
  768,
  896,
  1024,
  1280,
  1536,
  1792,
  2048,
  2560,
  3072,
  3584,
  4096,
  5120,
  6144,
  7168,
  8192,
  10240,
  12288,
  14336,
  16384,
  20480,
  24576,
  28672,
  32768,
  40960,
  49152,
  57344,
  65536,
  81920,
  98304,
  114688,
  131072,
  163840,
  196608,
  229376,
  262144,
  327680,
  393216,
  458752,
  524288,
  655360,
  786432,
  917504,
  1048576,
  1310720,
  1572864,
  1835008,
  2097152,
  2621440,
  3145728,
  3670016,
  4194304,
];

final class _Page {
  _Page({
    required this.bin,
    required this.blockSize,
    required this.base,
    required this.raw,
    required this.pageSize,
    required this.data,
    required this.reserved,
  });

  final int bin;
  final int blockSize;
  final int base;
  final int raw;
  final int pageSize;
  final ByteData data;
  final int reserved;
  int capacity = 0;
  int freeHead = 0;
}

final class BlitAllocator implements UnsafeAllocator {
  BlitAllocator();

  final List<_Page?> _current = List<_Page?>.filled(_hugeBin, null);
  final Map<int, _Page> _pageBySlice = {};
  final List<_Page> _pages = [];
  final Set<int> _huge = {};
  int _cachedAddress = 0;
  int _cachedCapacity = 0;
  int _activeAddress = 0;
  int _activeCapacity = 0;

  int get pageCount => _pages.length;

  int get residentBytes => _pages.fold(0, (sum, page) => sum + page.pageSize);

  // mimalloc keeps a page-local free list; this single-slot cache is the same
  // idea for the common immediate alloc/free pattern. It avoids the page map
  // entirely until a second live allocation or a non-LIFO free appears.
  @override
  @pragma('vm:prefer-inline')
  int alloc(int size) {
    if (size <= _cachedCapacity) {
      final cached = _cachedAddress;
      if (cached != 0) {
        _cachedAddress = 0;
        _activeAddress = cached;
        _activeCapacity = _cachedCapacity;
        return cached;
      }
    }
    return _allocSlow(size);
  }

  int _allocSlow(int requested) {
    var size = requested;
    if (size <= 0) size = 1;
    final bin = _binFor(size);
    if (bin == _hugeBin) {
      final address = malloc.allocate<Uint8>(size).address;
      _huge.add(address);
      return address;
    }
    var page = _current[bin];
    if (page == null) {
      page = _newPage(bin);
      _current[bin] = page;
    }
    var address = page.freeHead;
    if (address == 0) {
      if (_extend(page)) {
        address = page.freeHead;
      } else {
        page = _newPage(bin);
        _current[bin] = page;
        address = page.freeHead;
      }
    }
    if (address == 0) throw StateError('allocator failed');
    page.freeHead = _readAddress(page, address);
    _activeAddress = address;
    _activeCapacity = _binSizes[bin];
    if (page.freeHead == 0 && page.capacity >= page.reserved) {
      _current[bin] = null;
    }
    return address;
  }

  @override
  @pragma('vm:prefer-inline')
  void free(int address) {
    if (address == _activeAddress) {
      _cachedAddress = address;
      _cachedCapacity = _activeCapacity;
      _activeAddress = 0;
      return;
    }
    _freeSlow(address);
  }

  void _freeSlow(int address) {
    final page = _pageBySlice[address >> _sliceShift];
    if (page == null) {
      if (_huge.remove(address)) {
        malloc.free(Pointer<Uint8>.fromAddress(address));
      }
      return;
    }
    _writeAddress(page, address, page.freeHead);
    page.freeHead = address;
    _current[page.bin] = page;
  }

  void dispose() {
    for (final address in _huge) {
      malloc.free(Pointer<Uint8>.fromAddress(address));
    }
    _huge.clear();
    _cachedAddress = 0;
    _cachedCapacity = 0;
    _activeAddress = 0;
    _activeCapacity = 0;
    for (final page in _pages) {
      malloc.free(Pointer<Uint8>.fromAddress(page.raw));
    }
    _pages.clear();
    _pageBySlice.clear();
    for (var i = 0; i < _current.length; i++) {
      _current[i] = null;
    }
  }

  _Page _newPage(int bin) {
    final blockSize = _binSizes[bin];
    final pageSize = blockSize <= 8192
        ? _smallPageSize
        : (blockSize <= 65536 ? _mediumPageSize : _largePageSize);
    final total = pageSize + _sliceSize;
    final rawPointer = malloc.allocate<Uint8>(total);
    final raw = rawPointer.address;
    final base = (raw + _sliceSize - 1) & ~(_sliceSize - 1);
    final page = _Page(
      bin: bin,
      blockSize: blockSize,
      base: base,
      raw: raw,
      pageSize: pageSize,
      data: ByteData.sublistView(rawPointer.asTypedList(total)),
      reserved: pageSize ~/ blockSize,
    );
    _pages.add(page);
    for (var offset = 0; offset < pageSize; offset += _sliceSize) {
      _pageBySlice[(base + offset) >> _sliceShift] = page;
    }
    _extend(page);
    return page;
  }

  bool _extend(_Page page) {
    if (page.capacity >= page.reserved) return false;
    final maxExtend = page.blockSize >= _maxExtendBytes
        ? 1
        : (_maxExtendBytes ~/ page.blockSize);
    final count = math.min(maxExtend, page.reserved - page.capacity);
    if (count <= 0) return false;
    final first = page.base + page.capacity * page.blockSize;
    for (var i = 0; i < count; i++) {
      final at = first + i * page.blockSize;
      final next = i + 1 < count ? at + page.blockSize : 0;
      _writeAddress(page, at, next);
    }
    page.capacity += count;
    page.freeHead = first;
    return true;
  }

  int _readAddress(_Page page, int address) {
    final offset = address - page.raw;
    final lo = page.data.getUint32(offset, Endian.little);
    final hi = page.data.getUint32(offset + 4, Endian.little);
    return lo | (hi << 32);
  }

  void _writeAddress(_Page page, int address, int value) {
    final offset = address - page.raw;
    page.data.setUint32(offset, value & 0xFFFFFFFF, Endian.little);
    page.data.setUint32(offset + 4, value >> 32, Endian.little);
  }

  static int _binFor(int size) {
    var wsize = (size + 7) >> 3;
    if (wsize <= 8) return wsize <= 1 ? 1 : wsize;
    // Largest table entry is 4 MiB; larger blocks are singleton huge pages.
    if (wsize > 524288) return _hugeBin;
    wsize--;
    final b = wsize.bitLength - 1;
    final bin = ((b << 2) + ((wsize >> (b - 2)) & 3)) - 3;
    return bin.clamp(1, _hugeBin - 1);
  }
}
