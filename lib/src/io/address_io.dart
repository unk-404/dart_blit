/// Optional zero-copy address target for file engines.
library;

abstract interface class AddressIo {
  int readAtAddress(int offset, int address, int length);
  int writeAtAddress(int offset, int address, int length);
}
