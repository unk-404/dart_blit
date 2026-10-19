// C counterpart of the Dart file/mmap benchmarks.
//
// It emits benchmark_test JSONL with the same names so bench-svg can put the
// Dart and C runs in one two-series card. Only shared single-thread operations
// are measured: 8 MiB sequential read/write, 4 KiB random read/write, and
// mmap 4 KiB random read/write. Pool/IOCP/io_uring are intentionally out of
// scope because they are Dart-engine-specific comparisons.
//
// Build (Windows, from a Developer PowerShell):
//   cl /nologo /O2 /std:c11 benchmark\c\blit_bench.c /Fe:bench-c.exe
// Build (POSIX):
//   cc -O2 -std=c11 -D_FILE_OFFSET_BITS=64 benchmark/c/blit_bench.c -o bench-c
//
// Run:
//   bench-c bench-c.bin > bench-c.jsonl

#define _CRT_SECURE_NO_WARNINGS
#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#endif

#define FILE_SIZE ((uint64_t)1 << 30)
#define SEQ_BLOCK ((uint64_t)8 << 20)
#define BLOCK ((uint64_t)4 << 10)
#define SEQ_OPS 128
#define RANDOM_OPS 50000
#define MMAP_OPS 200000

#ifdef _WIN32
typedef HANDLE file_handle;
#else
typedef int file_handle;
#endif

static double now_sec(void) {
#ifdef _WIN32
  static LARGE_INTEGER frequency;
  static int initialized = 0;
  LARGE_INTEGER counter;
  if (!initialized) {
    QueryPerformanceFrequency(&frequency);
    initialized = 1;
  }
  QueryPerformanceCounter(&counter);
  return (double)counter.QuadPart / (double)frequency.QuadPart;
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
#endif
}

static int fail(const char *what) {
#ifdef _WIN32
  fprintf(stderr, "%s failed (win32 error %lu)\n", what,
          (unsigned long)GetLastError());
#else
  fprintf(stderr, "%s failed: %s\n", what, strerror(errno));
#endif
  return 1;
}

static file_handle open_rw(const char *path) {
#ifdef _WIN32
  return CreateFileA(path, GENERIC_READ | GENERIC_WRITE,
                     FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
                     FILE_ATTRIBUTE_NORMAL, NULL);
#else
  return open(path, O_RDWR | O_CREAT, 0644);
#endif
}

static int close_file(file_handle file) {
#ifdef _WIN32
  return CloseHandle(file) ? 0 : -1;
#else
  return close(file);
#endif
}

static int truncate_file(file_handle file, uint64_t size) {
#ifdef _WIN32
  LARGE_INTEGER position;
  position.QuadPart = (LONGLONG)size;
  if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN)) return -1;
  return SetEndOfFile(file) ? 0 : -1;
#else
  return ftruncate(file, (off_t)size);
#endif
}

static int read_at(file_handle file, void *buffer, size_t length,
                   uint64_t offset) {
#ifdef _WIN32
  LARGE_INTEGER position;
  DWORD read = 0;
  position.QuadPart = (LONGLONG)offset;
  if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN)) return -1;
  if (!ReadFile(file, buffer, (DWORD)length, &read, NULL)) return -1;
  return (int)read;
#else
  ssize_t n = pread(file, buffer, length, (off_t)offset);
  return n < 0 ? -1 : (int)n;
#endif
}

static int write_at(file_handle file, const void *buffer, size_t length,
                    uint64_t offset) {
#ifdef _WIN32
  LARGE_INTEGER position;
  DWORD written = 0;
  position.QuadPart = (LONGLONG)offset;
  if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN)) return -1;
  if (!WriteFile(file, buffer, (DWORD)length, &written, NULL)) return -1;
  return (int)written;
#else
  ssize_t n = pwrite(file, buffer, length, (off_t)offset);
  return n < 0 ? -1 : (int)n;
#endif
}

static int flush_file(file_handle file) {
#ifdef _WIN32
  return FlushFileBuffers(file) ? 0 : -1;
#else
  return fsync(file);
#endif
}

static uint64_t random_offset(uint64_t *state) {
  uint64_t x = *state;
  x ^= x << 13;
  x ^= x >> 7;
  x ^= x << 17;
  *state = x;
  return (x % ((FILE_SIZE - BLOCK) / BLOCK)) * BLOCK;
}

static void emit(const char *name, int operations, double seconds) {
  double throughput = (double)operations / seconds;
  double latency = seconds * 1e6 / (double)operations;
  printf("{\"formatVersion\":1,\"name\":\"%s\",\"compiler\":\"c\","
         "\"throughput\":{\"value\":%.6f,\"unit\":\"ops/sec\"},"
         "\"statistics\":{\"relativeMarginOfError\":0.0,\"samples\":%d},"
         "\"latency\":{\"mean\":%.3f,\"unit\":\"microseconds\"}}\n",
         name, throughput, operations, latency);
}

int main(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "bench-c.bin";
  file_handle file;
  unsigned char *seq = NULL;
  unsigned char *block = NULL;
  unsigned char *scratch = NULL;
  uint64_t offset = 0;
  uint64_t state = 0x9E3779B97F4A7C15ULL;
  double start;
  int i;

  file = open_rw(path);
#ifdef _WIN32
  if (file == INVALID_HANDLE_VALUE) return fail("CreateFile");
#else
  if (file < 0) return fail("open");
#endif

  seq = (unsigned char *)malloc((size_t)SEQ_BLOCK);
  block = (unsigned char *)malloc((size_t)BLOCK);
  scratch = (unsigned char *)malloc((size_t)SEQ_BLOCK);
  if (seq == NULL || block == NULL || scratch == NULL) {
    fprintf(stderr, "malloc failed\n");
    return 1;
  }
  for (i = 0; i < (int)SEQ_BLOCK; i++) seq[i] = (unsigned char)(i * 31 + 7);
  for (i = 0; i < (int)BLOCK; i++) block[i] = (unsigned char)(i * 17 + 3);

  if (truncate_file(file, FILE_SIZE) != 0) return fail("truncate");
  for (offset = 0; offset < FILE_SIZE; offset += SEQ_BLOCK) {
    if (write_at(file, seq, (size_t)SEQ_BLOCK, offset) != (int)SEQ_BLOCK) {
      return fail("seed write");
    }
  }
  if (flush_file(file) != 0) return fail("seed flush");

  /* Warm the read path once; the measured loop mirrors the Dart bodies. */
  (void)read_at(file, block, (size_t)BLOCK, 0);

  start = now_sec();
  offset = 0;
  for (i = 0; i < SEQ_OPS; i++) {
    if (read_at(file, scratch, (size_t)SEQ_BLOCK, offset) !=
        (int)SEQ_BLOCK) {
      return fail("sequential read");
    }
    /* Dart readAt copies native scratch into Uint8List; mirror that copy. */
    memcpy(seq, scratch, (size_t)SEQ_BLOCK);
    offset = (offset + SEQ_BLOCK) % FILE_SIZE;
  }
  emit("file.read.8MiB", SEQ_OPS, now_sec() - start);

  start = now_sec();
  offset = 0;
  for (i = 0; i < SEQ_OPS; i++) {
    /* Dart writeAt copies Uint8List into native scratch before WriteFile. */
    memcpy(scratch, seq, (size_t)SEQ_BLOCK);
    if (write_at(file, scratch, (size_t)SEQ_BLOCK, offset) !=
        (int)SEQ_BLOCK) {
      return fail("sequential write");
    }
    offset = (offset + SEQ_BLOCK) % FILE_SIZE;
  }
  emit("file.write.8MiB", SEQ_OPS, now_sec() - start);

  start = now_sec();
  for (i = 0; i < RANDOM_OPS; i++) {
    if (read_at(file, scratch, (size_t)BLOCK, random_offset(&state)) !=
        (int)BLOCK) {
      return fail("random read");
    }
    memcpy(block, scratch, (size_t)BLOCK);
  }
  emit("file.read.random4K", RANDOM_OPS, now_sec() - start);

  start = now_sec();
  for (i = 0; i < RANDOM_OPS; i++) {
    memcpy(scratch, block, (size_t)BLOCK);
    if (write_at(file, scratch, (size_t)BLOCK, random_offset(&state)) !=
        (int)BLOCK) {
      return fail("random write");
    }
  }
  emit("file.write.random4K", RANDOM_OPS, now_sec() - start);

#ifdef _WIN32
  {
    HANDLE mapping = CreateFileMappingA(file, NULL, PAGE_READWRITE, 0, 0, NULL);
    unsigned char *view;
    if (mapping == NULL) return fail("CreateFileMapping");
    view = (unsigned char *)MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (view == NULL) return fail("MapViewOfFile");

    for (i = 0; i < 1000; i++) memcpy(block, view + random_offset(&state), BLOCK);
    start = now_sec();
    for (i = 0; i < MMAP_OPS; i++) {
      memcpy(block, view + random_offset(&state), BLOCK);
    }
    emit("mmap.read.random4K", MMAP_OPS, now_sec() - start);

    start = now_sec();
    for (i = 0; i < MMAP_OPS; i++) {
      memcpy(view + random_offset(&state), block, BLOCK);
    }
    emit("mmap.write.random4K", MMAP_OPS, now_sec() - start);
    UnmapViewOfFile(view);
    CloseHandle(mapping);
  }
#else
  {
    unsigned char *view = (unsigned char *)mmap(
        NULL, (size_t)FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
    if (view == MAP_FAILED) return fail("mmap");

    for (i = 0; i < 1000; i++) memcpy(block, view + random_offset(&state), BLOCK);
    start = now_sec();
    for (i = 0; i < MMAP_OPS; i++) {
      memcpy(block, view + random_offset(&state), BLOCK);
    }
    emit("mmap.read.random4K", MMAP_OPS, now_sec() - start);

    start = now_sec();
    for (i = 0; i < MMAP_OPS; i++) {
      memcpy(view + random_offset(&state), block, BLOCK);
    }
    emit("mmap.write.random4K", MMAP_OPS, now_sec() - start);
    munmap(view, (size_t)FILE_SIZE);
  }
#endif

  free(seq);
  free(block);
  free(scratch);
  close_file(file);
  return 0;
}
