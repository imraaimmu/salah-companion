import 'dart:async';

/// A broadcast stream that replays the latest value to each new listener.
class LatestValue<T> {
  final _controller = StreamController<T>.broadcast();
  T? _latest;
  bool _has = false;

  T? get latest => _latest;

  Stream<T> get stream => Stream<T>.multi((sink) {
    if (_has) sink.add(_latest as T);
    final sub = _controller.stream.listen(
      sink.add,
      onError: sink.addError,
      onDone: sink.close,
    );
    sink.onCancel = sub.cancel;
  });

  void add(T value) {
    _latest = value;
    _has = true;
    _controller.add(value);
  }

  Future<void> close() => _controller.close();
}
