import 'dart:async';

/// Fase 16.2-R4.4-R1-T-Rm — a deadline of `DashcamService` that elapses when
/// the TEST says so, not when the host's scheduler happens to get there.
///
/// Every presentation/STOP deadline of `DashcamService` is a `Future.timeout`
/// whose [Timer] is created through `Zone.current.createTimer`. Inside [run],
/// a timer whose duration lies in ([min], [max]] is HELD while [holding] is
/// true: it is not armed; [expire] fires the held ones — through a real
/// zero-delay timer, as the timer itself would fire — and the service takes
/// its real timeout path. A held timer that `Future.timeout` cancels (its
/// future completed first) simply never fires. Every other timer (the test's
/// own polling, zero-delay yields, segment timers) passes through untouched,
/// and nothing in `lib/` is replaced or bypassed.
///
/// Two uses (R-m: the test-configured deadline used to race real preparation
/// work that R4.4-R1 made heavier — a clip's promotion is real file I/O):
///  * **a deadline the scenario needs to elapse at a precise point** — e.g. a
///    recovery's presentation must time out while its native initialize is
///    retained: configure a long, distinctive deadline (see [forDeadline]),
///    prove the precondition (the native call entered its gate), then [expire].
///    `DashcamService.initialize` ORs its view's own expiry into its
///    pre-emission check, so the stopwatch reading never has to get there;
///  * **a deadline the scenario needs NOT to elapse** — a preparation step that
///    must settle normally (a stop whose clip the rest of the test builds on):
///    hold it for that step only; [pending] must be 0 afterwards (the step
///    completed before anything had to fire).
class HeldDeadlines {
  HeldDeadlines({required this.min, required this.max, this.holding = true});

  /// Holds the timers a `Future.timeout` of [deadline] (or of whatever is left
  /// of it, at most [slack] later) arms.
  factory HeldDeadlines.forDeadline(Duration deadline, {Duration slack = const Duration(milliseconds: 1500)}) =>
      HeldDeadlines(min: deadline - slack, max: deadline);

  /// Holds every deadline timer of at most [max] — INCLUDING a zero-duration
  /// one. For a deadline the scenario needs NOT to elapse: a STOP arms its
  /// finalization's timeout against the same deadline instant as its native
  /// stop's, and once that instant has passed (the host busy for longer than
  /// the deadline in between) `_remainingUntil` clamps it to [Duration.zero].
  /// That timer is still this deadline; held from 1 µs up it escaped, fired
  /// for real and the clip went late (reproduced with a synchronous busy-wait
  /// between the two timeouts, T-Rm 09_round2/stopgap_before).
  factory HeldDeadlines.upTo(Duration max, {bool holding = true}) =>
      HeldDeadlines(min: const Duration(microseconds: -1), max: max, holding: holding);

  final Duration min;
  final Duration max;

  /// Timers created while false are armed normally.
  bool holding;

  final List<_HeldTimer> _held = [];

  /// Held timers not yet fired or cancelled.
  int get pending => _held.where((t) => t.isActive).length;

  bool _holds(Duration duration) => holding && duration > min && duration <= max;

  /// Runs [body] in the zone where matching timers are held. Everything [body]
  /// starts — including continuations queued by the service — stays in it.
  R run<R>(R Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (!_holds(duration)) return parent.createTimer(zone, duration, callback);
        final timer = _HeldTimer(parent, zone, callback);
        _held.add(timer);
        return timer;
      },
    ),
  );

  /// The deadline elapses now for every held timer. Returns how many fired.
  int expire() {
    var fired = 0;
    for (final timer in _held) {
      if (timer._fire()) fired++;
    }
    _held.removeWhere((t) => !t.isActive);
    return fired;
  }
}

class _HeldTimer implements Timer {
  _HeldTimer(this._parent, this._zone, this._callback);

  final ZoneDelegate _parent;
  final Zone _zone;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  bool _fire() {
    if (!_active) return false;
    _active = false;
    _tick = 1;
    _parent.createTimer(_zone, Duration.zero, _callback);
    return true;
  }
}
