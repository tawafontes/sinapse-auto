import 'dart:async';

/// A broadcast stream that is subscribed to its source only while it has at
/// least one listener, and that runs its source exactly once however many
/// listeners it has — what `AlertEngine.events` and
/// `EventDetectionEngine.events` need: both are stateful detectors over the
/// shared `DashboardSensorStreams.snapshot`, observed by several consumers at
/// once (the dashboard's banners, the session's event log, the dashcam).
///
/// Fase 16.2-R4.3-R2.6.8 (R4.3-D2 F27-F29): both engines used to end in a bare
/// `.asBroadcastStream()`. Without an `onCancel` handler, that keeps its source
/// subscription after its last listener leaves (dart:async
/// `_AsBroadcastStream._onCancel` only cancels once its controller is closed,
/// which never happens here). Each dashboard that was ever disposed therefore
/// left its whole snapshot pipeline subscribed — with the 1 Hz GNSS stale-check
/// timer `TelemetryEngine.gnssQuality` starts in its `onListen` — for the rest
/// of the process (reproduced: one live timer per disposed dashboard).
/// `asBroadcastStream(onCancel: (s) => s.cancel())` is not a fix either: that
/// wrapper's `cancel` marks the stream permanently done, so a later listener
/// would never get another event.
///
/// Every listening period ("epoch") calls [open] again for a FRESH source, so
/// a detector's state never spans a period during which nobody was listening
/// and no snapshot was evaluated — exactly what a newly constructed engine
/// did before. Delivery is synchronous, like `asBroadcastStream`'s own
/// controller, so a listener sees an event at the same moment as before.
class RefCountedBroadcast<T> {
  RefCountedBroadcast(this.open);

  /// Builds the source for a new listening period; called on the first
  /// listener after none.
  final Stream<T> Function() open;

  late final StreamController<T> _controller = StreamController<T>.broadcast(
    sync: true,
    onListen: _subscribe,
    onCancel: _unsubscribe,
  );

  StreamSubscription<T>? _source;

  Stream<T> get stream => _controller.stream;

  void _subscribe() {
    _source = open().listen(_controller.add, onError: _controller.addError, onDone: _controller.close);
  }

  Future<void> _unsubscribe() {
    final source = _source;
    _source = null;
    return source?.cancel() ?? Future<void>.value();
  }

  /// Releases the source and ends the stream for every listener still
  /// attached. Terminal.
  void dispose() {
    unawaited(_unsubscribe());
    unawaited(_controller.close());
  }
}
