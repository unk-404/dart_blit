/// Cooperative cancellation for AsyncFile operations.
library;

import 'errors.dart';

final class CancelToken {
  bool _cancelled = false;
  Object? _reason;

  bool get isCancelled => _cancelled;
  Object? get reason => _reason;

  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
  }

  void throwIfCancelled({String? path}) {
    if (_cancelled) {
      throw CancelledException(
        'operation cancelled',
        path: path,
        cause: _reason,
      );
    }
  }
}
