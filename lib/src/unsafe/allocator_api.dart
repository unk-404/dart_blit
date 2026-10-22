/// Address allocator contract used by opt-in UnsafeBytes allocations.
library;

abstract interface class UnsafeAllocator {
  int alloc(int size);
  void free(int address);
}
