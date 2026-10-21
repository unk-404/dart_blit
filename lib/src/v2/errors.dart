/// Public error hierarchy for blit.
library;

sealed class BlitException implements Exception {
  const BlitException(this.message, {this.path, this.cause});

  final String message;
  final String? path;
  final Object? cause;

  @override
  String toString() {
    final where = path == null ? '' : ' ($path)';
    return '$runtimeType$where: $message';
  }
}

final class BlitIOException extends BlitException {
  const BlitIOException(super.message, {super.path, super.cause});
}

final class EndOfFileException extends BlitException {
  const EndOfFileException(super.message, {super.path});
}

final class CancelledException extends BlitException {
  const CancelledException(super.message, {super.path, super.cause});
}

final class ClosedException extends BlitException {
  const ClosedException(super.message, {super.path});
}

final class PermissionException extends BlitException {
  const PermissionException(super.message, {super.path, super.cause});
}

final class QuotaExceededException extends BlitException {
  const QuotaExceededException(super.message, {super.path, super.cause});
}

final class UnsupportedException extends BlitException {
  const UnsupportedException(super.message, {super.path});
}
