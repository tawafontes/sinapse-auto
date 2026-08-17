import '../models/alert_event.dart';
import '../models/alert_type.dart';
import '../models/telemetry_snapshot.dart';
import 'alert_preferences.dart';
import 'gnss_quality.dart' show GnssQuality;

/// Central alert logic — but, as of Fase 13.1, **only** for the two
/// [AlertType]s that have no [EventDetectionEngine] equivalent:
/// [AlertType.highInclination] (a signal EventDetectionEngine doesn't track
/// at all — see that class's own doc for why tilt is out of scope) and
/// [AlertType.weakGnss] (a continuous "degraded but not lost" condition,
/// distinct from the edge-triggered `gnssLost`/`gnssRecovered` transitions
/// EventDetectionEngine already owns).
///
/// Every other [AlertType] — `highSpeed`, `harshAcceleration`,
/// `harshBraking`, `hardCornering`, `highResultantG`, `gnssLost` — used to be
/// independently re-detected here too, with its own separately-timed
/// hysteresis/cooldown, purely to decide when to show a banner. That was a
/// real architectural duplication (Fase 13.1's own audit, §1/§2): two
/// state machines watching the same physical quantity, with no guarantee
/// they'd ever agree on exactly when an episode started or ended. Those six
/// types are now detected exactly once, by [EventDetectionEngine]; the
/// banner for them is a presentation of that engine's own confirmed
/// [DetectedEvent]s (see `detected_event.dart`'s [alertTypeForDetectedEvent]
/// and `dashboard_screen.dart`'s `_handleDetectedEvent`), not a second
/// independent decision. `AlertType`/`AlertPreferences`/`AlertsScreen`
/// themselves are unchanged and still cover all eight types — thresholds
/// stay one shared, user-configurable vocabulary regardless of which engine
/// actually evaluates them.
///
/// Consumes the same [TelemetrySnapshot] stream every other module reads
/// (`DashboardSensorStreams.snapshot`), never a widget's own independent
/// threshold check. Emits [AlertEvent]s only on an actual fire/clear
/// transition (see [AlertEvent]), not a repeated "still active" event on
/// every tick — a consumer (a dashboard banner, a future notification)
/// tracks the currently-active set itself from these transitions if it
/// needs to.
///
/// Hysteresis + cooldown (see [clearRatioFor]/[_cooldown]) is what prevents
/// the "ALERTA → DESLIGA → ALERTA → DESLIGA" flicker a bare threshold
/// crossing would produce for a signal hovering right at the line: an
/// active alert only clears once the value drops to [clearRatioFor] of its
/// threshold (not the threshold itself), and won't fire again within
/// [_cooldown] of its last firing even if it crosses back immediately.
class AlertEngine {
  AlertEngine(this._snapshotStream, this._preferences);

  final Stream<TelemetrySnapshot> _snapshotStream;
  final AlertPreferences _preferences;

  static const _cooldown = Duration(seconds: 5);

  /// The only [AlertType]s [AlertEngine] itself still detects — see this
  /// class's own doc. Every other type is [EventDetectionEngine]'s sole
  /// responsibility now.
  static const _ownedTypes = {AlertType.highInclination, AlertType.weakGnss};

  late final Stream<AlertEvent> events = _buildStream();

  Stream<AlertEvent> _buildStream() {
    final active = <AlertType, bool>{};
    final lastFiredAt = <AlertType, DateTime>{};

    return _snapshotStream.expand((snapshot) {
      final transitions = <AlertEvent>[];
      for (final type in _ownedTypes) {
        final currentlyActive = active[type] ?? false;

        if (!_preferences.isEnabled(type)) {
          if (currentlyActive) {
            active[type] = false;
            transitions.add(AlertEvent(type: type, active: false, timestamp: snapshot.timestamp));
          }
          continue;
        }

        final shouldBeActive = evaluateAlert(type, snapshot, currentlyActive: currentlyActive, preferences: _preferences);
        if (shouldBeActive == currentlyActive) continue;

        if (shouldBeActive) {
          final last = lastFiredAt[type];
          if (last != null && snapshot.timestamp.difference(last) < _cooldown) continue;
          lastFiredAt[type] = snapshot.timestamp;
        }
        active[type] = shouldBeActive;
        transitions.add(AlertEvent(type: type, active: shouldBeActive, timestamp: snapshot.timestamp));
      }
      return transitions;
    }).asBroadcastStream();
  }
}

/// Pure decision function for a single alert type against a single
/// snapshot — pulled out of [AlertEngine] so the actual trigger/clear logic
/// is independently unit-testable against plain [TelemetrySnapshot]
/// instances, with no stream/timing involved.
double clearRatioFor(AlertType type) => 0.85;

bool evaluateAlert(
  AlertType type,
  TelemetrySnapshot snapshot, {
  required bool currentlyActive,
  required AlertPreferences preferences,
}) {
  switch (type) {
    case AlertType.highSpeed:
      return _evaluateThreshold(snapshot.speedKmh, type, currentlyActive, preferences);
    case AlertType.harshAcceleration:
      final g = snapshot.longitudinalG;
      return _evaluateThreshold(g == null || g <= 0 ? 0.0 : g, type, currentlyActive, preferences);
    case AlertType.harshBraking:
      final g = snapshot.longitudinalG;
      return _evaluateThreshold(g == null || g >= 0 ? 0.0 : -g, type, currentlyActive, preferences);
    case AlertType.highInclination:
      final pitch = snapshot.pitchDegrees?.abs() ?? 0.0;
      final roll = snapshot.rollDegrees?.abs() ?? 0.0;
      return _evaluateThreshold(pitch > roll ? pitch : roll, type, currentlyActive, preferences);
    case AlertType.hardCornering:
      // Unsigned — this live banner just needs "a hard turn happened",
      // not which way (see AlertType's own doc for why, unlike the
      // persisted session event, which does split left/right).
      return _evaluateThreshold(snapshot.lateralG?.abs(), type, currentlyActive, preferences);
    case AlertType.highResultantG:
      // Reuses the already-centralized resultant-G computation — see
      // TelemetryEngine — rather than recomputing one here.
      return _evaluateThreshold(snapshot.gForceMagnitude, type, currentlyActive, preferences);
    case AlertType.weakGnss:
      return snapshot.gnssQuality == GnssQuality.weak || snapshot.gnssQuality == GnssQuality.unavailable;
    case AlertType.gnssLost:
      return snapshot.gnssQuality == GnssQuality.unavailable;
  }
}

bool _evaluateThreshold(double? value, AlertType type, bool currentlyActive, AlertPreferences preferences) {
  if (value == null) return currentlyActive; // no reading at all — don't flip state on missing data.
  final threshold = preferences.thresholdFor(type)!;
  return currentlyActive ? value >= threshold * clearRatioFor(type) : value >= threshold;
}
