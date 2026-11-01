import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/alert_type.dart';
import '../models/detected_event.dart';
import '../models/telemetry_snapshot.dart';
import 'alert_preferences.dart';
import 'altitude_trend.dart';
import 'gnss_quality.dart' show GnssQuality;
import 'ref_counted_broadcast.dart';

/// Fase 13's central "Event Detection Engine" (§6): the single place raw
/// telemetry is turned into confirmed, objective [DetectedEvent]s —
/// consuming only the already-centralized [TelemetrySnapshot] stream
/// (`DashboardSensorStreams.snapshot`), never a sensor directly (§3).
///
/// Evolves, rather than duplicates, the event detection this app already
/// had: before this class existed, `DrivingSessionRecorder` contained its
/// own inline edge+cooldown detector (no hysteresis, no minimum-duration
/// confirmation — a single noisy sample could register as a "hard brake").
/// That logic now lives here instead, extracted into an independently
/// testable, UI-free module, with the missing hysteresis/minimum-duration
/// gating (§18/§20/§58/§59) added on top rather than papered over.
///
/// ### Relationship to [AlertEngine] (revised in Fase 13.1)
/// Fase 13 originally kept this engine and [AlertEngine] as two fully
/// independent detectors for the same six phenomena (acceleration, braking,
/// cornering, resultant G, speed, GNSS loss) — a risk-weighed choice to
/// avoid touching a proven live-alert path. Fase 13.1's own audit (§1/§2)
/// found that tradeoff to be a genuine architectural risk, not a merely
/// stylistic one: two separately-timed hysteresis+cooldown state machines
/// watching the same raw signal have no guarantee of ever agreeing on
/// exactly when an episode starts or ends, and nothing prevented them from
/// silently drifting apart as either was tuned in isolation.
///
/// This engine is now the **sole** detector for those six phenomena
/// (`hardAcceleration`/`hardBraking`/`hardCorneringLeft`/
/// `hardCorneringRight`/`highResultantG`/`speedLimitExceeded`/`gnssLost`/
/// `gnssRecovered`). [AlertEngine]'s own runtime loop no longer evaluates
/// them at all (see that class's doc) — the live banner for these types is
/// now just a presentation of this engine's own confirmed [DetectedEvent]s,
/// wired in `dashboard_screen.dart`'s `_handleDetectedEvent` via
/// `detected_event.dart`'s [alertTypeForDetectedEvent]. [AlertEngine]
/// retains its own independent detection only for `highInclination` and
/// `weakGnss`, neither of which this engine tracks. One confirmed
/// [DetectedEvent] now drives both persistence
/// (`DrivingSessionRecorder.recordDetectedEvent`) and, where applicable, the
/// banner — never two independent decisions about the same real-world
/// moment.
///
/// ### State machine (§22)
/// Every level-based event type (acceleration, braking, cornering,
/// resultant G, speed limit) runs through the same four-state machine —
/// see [_LevelEventTracker]:
///
/// ```
/// IDLE ──(value ≥ enter)──▶ CANDIDATE ──(held ≥ minDuration)──▶ ACTIVE
///   ▲                           │                                 │
///   │                    (drops below enter                (value < exit,
///   │                     before minDuration:                the hysteresis
///   │                     false alarm, discard)              low bound)
///   │                           │                                 ▼
///   └───────────────────────────┘                            COOLDOWN
///   ▲                                                              │
///   └──────────────────(cooldown elapses)─────────────────────────┘
/// ```
///
/// A [DetectedEvent] fires exactly once, on the CANDIDATE→ACTIVE
/// transition — immediately (§19: low latency matters), not after the
/// episode fully ends. No further event can fire for that type until a full
/// ACTIVE→COOLDOWN→IDLE cycle completes, which is what makes "frenagem
/// forte" ×4 during one continuous stomp on the brake impossible (§38/§68).
///
/// GNSS lost/recovered and stopped/resumed are each their own simpler,
/// purpose-built two/four-state machines (see [_GnssTracker]/
/// [_MotionTracker]) — modeling them as a generic "level" wouldn't fit
/// either (GNSS quality already carries its own upstream staleness
/// confirmation from Fase 10's [GnssQuality]; motion needs two independent
/// thresholds — stop vs. resume — for its own hysteresis, not one).
/// Altitude events reuse [TelemetrySnapshot.altitudeTrend] directly — an
/// *already* hysteresis- and confirm-streak-protected signal from Fase 10 —
/// firing only on the transition into `rising`/`falling`, never per-sample
/// while it continues (§17: no second filter invented on top).
///
/// ### Sampling rate (Fase 13.2 root-cause fix)
/// [_snapshotStream] (`DashboardSensorStreams.snapshot`) used to throttle
/// every field — including g-force — to a fixed ~200ms cadence, deliberately
/// sized for GPS-derived signals. That silently discarded ~95% of this
/// device's own ~100Hz accelerometer resolution before it ever reached this
/// engine: a genuine, physically real acceleration/braking/cornering episode
/// lasting 150-215ms (confirmed via direct on-device instrumentation) could
/// present to [LevelEventTracker] as only one or two samples, landing on
/// opposite sides of the episode and never spanning the required
/// [_accelerationMinDuration]/[_brakingMinDuration]/[_corneringMinDuration]
/// continuously. `DashboardSensorStreams.snapshot`'s own doc comment now
/// exempts g-force-triggered emissions from that throttle — this engine
/// needed no change itself (its state machine was always correct; it simply
/// wasn't being shown enough of the real signal to work with).
class EventDetectionEngine {
  EventDetectionEngine(this._snapshotStream, this._preferences);

  final Stream<TelemetrySnapshot> _snapshotStream;
  final AlertPreferences _preferences;

  /// How far a level must retreat below its own enter threshold before the
  /// episode is considered over — the same 0.85 ratio [AlertEngine] already
  /// uses (`clearRatioFor`), reused rather than a second, differently-tuned
  /// number, so a value hovering right at the line behaves identically
  /// whether it's being watched for a live alert or a session event.
  static const double _exitRatio = 0.85;

  /// How long a level must hold above its enter threshold before it's a
  /// confirmed event, not a single-sample spike — long enough that a
  /// pothole/vibration transient (typically well under 100ms) can't qualify
  /// (§58/§59), short enough that a genuine hard brake/accel pulse (which
  /// easily sustains for several hundred ms once truly underway) is still
  /// reported with low perceived latency (§19).
  static const Duration _accelerationMinDuration = Duration(milliseconds: 150);
  static const Duration _brakingMinDuration = Duration(milliseconds: 150);

  /// Slightly longer than the longitudinal one: a deliberate turn/lane
  /// change sustains lateral G for longer than a brake pulse does
  /// longitudinal G, while a single lateral jolt (a pothole, a rumble
  /// strip) is typically brief — a marginally longer window rejects more of
  /// the latter without meaningfully delaying detection of the former.
  static const Duration _corneringMinDuration = Duration(milliseconds: 200);
  static const Duration _resultantGMinDuration = Duration(milliseconds: 150);

  /// A driver overshooting a limit by a hair for under a second (a brief
  /// downhill roll, GPS jitter) isn't meaningfully "speeding" the way a
  /// sustained excess is.
  static const Duration _speedLimitMinDuration = Duration(seconds: 1);

  /// Every level-based type shares this cooldown — matches the value
  /// already established and validated for session events in earlier
  /// phases (`DrivingSessionRecorder`'s own former `_eventCooldown`, itself
  /// chosen to match [AlertEngine]'s own cooldown) — one number, not a
  /// differently-tuned one per category, since nothing about the signals
  /// involved here justifies a different recovery time.
  static const Duration _levelCooldown = Duration(seconds: 5);

  /// Below this speed, the vehicle is considered stationary — well below
  /// any real "still driving, just slowly" speed, and above the residual
  /// jitter TelemetryEngine's own zero-floor already mostly absorbs (see
  /// `_speedFloorKmh` in `dashboard_sensor_streams.dart`); this just needs
  /// to be a clearly-stopped speed, not the exact floor value.
  static const double _stopThresholdKmh = 3.0;

  /// Must clear this speed (not merely [_stopThresholdKmh] again) before
  /// "resumed" fires — the gap between the two is what stops GPS noise
  /// hovering right at 3 km/h from flapping stopped/resumed repeatedly.
  static const double _resumeThresholdKmh = 8.0;

  /// A stop at a light/sign is unambiguous within a couple of seconds; this
  /// avoids reporting a "stop" for a car merely slowing hard through a
  /// tight, low-speed corner.
  static const Duration _stopMinDuration = Duration(seconds: 3);

  /// Shorter than [_stopMinDuration]: once genuinely moving again, that's
  /// immediately true, and a full 3s wait would make "resumed" feel
  /// sluggish relative to the car actually pulling away — 1s is enough to
  /// reject a single stray fast GPS sample without being perceptibly late.
  static const Duration _resumeMinDuration = Duration(seconds: 1);

  /// Defense in depth on top of [TelemetrySnapshot.altitudeTrend]'s own
  /// upstream confirm-streak (Fase 10): a real climb/descent is a slow
  /// phenomenon (many seconds to minutes), so this mainly guards against
  /// the rare case of a trend oscillating near its own boundary from
  /// producing a rapid burst of rising/falling/rising events.
  static const Duration _altitudeCooldown = Duration(seconds: 10);

  /// Subscribed to the snapshot stream only while listened to — see
  /// [RefCountedBroadcast] (Fase 16.2-R4.3-R2.6.8: this used to be a bare
  /// `asBroadcastStream()`, which never released it).
  late final RefCountedBroadcast<DetectedEvent> _events = RefCountedBroadcast<DetectedEvent>(_detectEvents);

  late final Stream<DetectedEvent> events = _events.stream;

  /// Ends [events] and releases the snapshot stream. Terminal.
  void dispose() => _events.dispose();

  /// One listening period's detector — fresh tracker state.
  Stream<DetectedEvent> _detectEvents() {
    final acceleration = LevelEventTracker(exitRatio: _exitRatio, minDuration: _accelerationMinDuration, cooldown: _levelCooldown);
    final braking = LevelEventTracker(exitRatio: _exitRatio, minDuration: _brakingMinDuration, cooldown: _levelCooldown);
    final corneringRight = LevelEventTracker(exitRatio: _exitRatio, minDuration: _corneringMinDuration, cooldown: _levelCooldown);
    final corneringLeft = LevelEventTracker(exitRatio: _exitRatio, minDuration: _corneringMinDuration, cooldown: _levelCooldown);
    final resultantG = LevelEventTracker(exitRatio: _exitRatio, minDuration: _resultantGMinDuration, cooldown: _levelCooldown);
    final speedLimit = LevelEventTracker(exitRatio: _exitRatio, minDuration: _speedLimitMinDuration, cooldown: _levelCooldown);
    final motion = MotionTracker(
      stopThresholdKmh: _stopThresholdKmh,
      resumeThresholdKmh: _resumeThresholdKmh,
      stopMinDuration: _stopMinDuration,
      resumeMinDuration: _resumeMinDuration,
    );
    final gnss = GnssTracker();
    final altitude = AltitudeTrendTracker(cooldown: _altitudeCooldown);

    return _snapshotStream.expand((snapshot) {
      final results = <DetectedEvent>[];

      void tryLevel(
        LevelEventTracker tracker,
        double? magnitude,
        AlertType thresholdType,
        DetectedEventType eventType, {
        double? displayValue,
      }) {
        if (magnitude == null || !magnitude.isFinite) return; // §40: no reading / NaN / infinite never produces an event.
        final threshold = _preferences.thresholdFor(thresholdType);
        if (threshold == null || !_preferences.isEnabled(thresholdType)) return;
        final confirmedAt = tracker.update(magnitude, threshold, snapshot.timestamp);
        if (confirmedAt == null) return;
        results.add(
          DetectedEvent(
            type: eventType,
            timestamp: confirmedAt,
            severity: severityForLevel(magnitude, threshold),
            snapshot: snapshot,
            // The tracker itself only ever sees the unsigned magnitude (it
            // has to, to compare against a threshold) — but the event's own
            // recorded value should be the natural, signed reading a user
            // would expect to see (e.g. "-0.78 G" for a hard brake, matching
            // Fase 13 §25's own example), not the internal comparison value.
            value: displayValue ?? magnitude,
            duration: tracker.minDuration,
          ),
        );
      }

      final longitudinalG = snapshot.longitudinalG;
      tryLevel(
        acceleration,
        longitudinalG == null ? null : (longitudinalG > 0 ? longitudinalG : 0.0),
        AlertType.harshAcceleration,
        DetectedEventType.hardAcceleration,
        displayValue: longitudinalG,
      );
      tryLevel(
        braking,
        longitudinalG == null ? null : (longitudinalG < 0 ? -longitudinalG : 0.0),
        AlertType.harshBraking,
        DetectedEventType.hardBraking,
        displayValue: longitudinalG,
      );

      final lateralG = snapshot.lateralG;
      tryLevel(
        corneringRight,
        lateralG == null ? null : (lateralG > 0 ? lateralG : 0.0),
        AlertType.hardCornering,
        DetectedEventType.hardCorneringRight,
        displayValue: lateralG,
      );
      tryLevel(
        corneringLeft,
        lateralG == null ? null : (lateralG < 0 ? -lateralG : 0.0),
        AlertType.hardCornering,
        DetectedEventType.hardCorneringLeft,
        displayValue: lateralG,
      );

      tryLevel(resultantG, snapshot.gForceMagnitude, AlertType.highResultantG, DetectedEventType.highResultantG);
      tryLevel(speedLimit, snapshot.speedKmh, AlertType.highSpeed, DetectedEventType.speedLimitExceeded);

      final motionEvent = motion.update(snapshot.speedKmh, snapshot.timestamp);
      if (motionEvent != null) {
        results.add(DetectedEvent(type: motionEvent, timestamp: snapshot.timestamp, severity: EventSeverity.info, snapshot: snapshot, value: snapshot.speedKmh));
      }

      final gnssEvent = gnss.update(snapshot.gnssQuality);
      if (gnssEvent != null) {
        results.add(DetectedEvent(type: gnssEvent, timestamp: snapshot.timestamp, severity: EventSeverity.info, snapshot: snapshot));
      }

      final altitudeEvent = altitude.update(snapshot.altitudeTrend, snapshot.timestamp);
      if (altitudeEvent != null) {
        results.add(DetectedEvent(type: altitudeEvent, timestamp: snapshot.timestamp, severity: EventSeverity.info, snapshot: snapshot, value: snapshot.altitudeMeters));
      }

      return results;
    });
  }
}

/// Objective severity banding (§26/§27) for a level-based event — purely a
/// function of how far [magnitude] sits past its own [threshold], the same
/// number the event was actually detected against (never a second,
/// independently-chosen scale). Ratios (not raw deltas) so the same bands
/// apply sensibly whether [threshold] is 0.4g or 80 km/h.
@visibleForTesting
EventSeverity severityForLevel(double magnitude, double threshold) {
  if (threshold <= 0) return EventSeverity.warning;
  final ratio = magnitude / threshold;
  if (ratio >= 2.0) return EventSeverity.critical;
  if (ratio >= 1.5) return EventSeverity.high;
  return EventSeverity.warning;
}

enum _LevelState { idle, candidate, active, cooldown }

/// The generic four-state detector diagrammed in this file's own top-level
/// doc — shared by every level-based event type (acceleration, braking,
/// cornering, resultant G, speed limit). [enterThreshold] is passed into
/// [update] per call (not fixed at construction) so a live change to the
/// user's configured threshold (`AlertPreferences`) takes effect on the
/// very next snapshot, matching how [AlertEngine] already re-reads its own
/// thresholds every sample rather than caching them.
@visibleForTesting
class LevelEventTracker {
  LevelEventTracker({required this.exitRatio, required this.minDuration, required this.cooldown});

  final double exitRatio;
  final Duration minDuration;
  final Duration cooldown;

  _LevelState _state = _LevelState.idle;
  DateTime? _candidateSince;
  DateTime? _cooldownUntil;

  /// Returns the confirmation timestamp ([now]) the instant this call
  /// transitions candidate→active, else null. [value] must already be the
  /// signed-appropriate, non-negative magnitude for whichever direction
  /// this tracker watches (e.g. 0 when longitudinal G is negative, for a
  /// tracker watching acceleration) — callers pass 0 rather than skipping
  /// the call entirely so a genuinely-opposite reading still correctly
  /// counts as "below threshold" for hysteresis/cooldown purposes.
  DateTime? update(double value, double enterThreshold, DateTime now) {
    // Falls through to the idle branch below on the very same sample, once
    // the cooldown has elapsed — a value that's already back above
    // threshold the instant cooldown ends should start counting
    // immediately, not sit idle for one extra sample waiting for the next
    // tick to notice.
    if (_state == _LevelState.cooldown && !now.isBefore(_cooldownUntil!)) {
      _state = _LevelState.idle;
    }
    switch (_state) {
      case _LevelState.idle:
        if (value >= enterThreshold) {
          _state = _LevelState.candidate;
          _candidateSince = now;
        }
        return null;
      case _LevelState.candidate:
        if (value < enterThreshold) {
          _state = _LevelState.idle;
          _candidateSince = null;
          return null;
        }
        if (now.difference(_candidateSince!) >= minDuration) {
          _state = _LevelState.active;
          return now;
        }
        return null;
      case _LevelState.active:
        if (value < enterThreshold * exitRatio) {
          _state = _LevelState.cooldown;
          _cooldownUntil = now.add(cooldown);
        }
        return null;
      case _LevelState.cooldown:
        return null;
    }
  }
}

enum _MotionPhase { movingConfirmed, candidateStopped, stoppedConfirmed, candidateMoving }

/// Stop/resume as one continuous two-sided state machine (§13/§14) rather
/// than two independent level trackers: [stopThresholdKmh] and
/// [resumeThresholdKmh] are deliberately different values, which is itself
/// the hysteresis that keeps GPS jitter right at "basically stopped" from
/// flapping between the two states.
@visibleForTesting
class MotionTracker {
  MotionTracker({
    required this.stopThresholdKmh,
    required this.resumeThresholdKmh,
    required this.stopMinDuration,
    required this.resumeMinDuration,
  });

  final double stopThresholdKmh;
  final double resumeThresholdKmh;
  final Duration stopMinDuration;
  final Duration resumeMinDuration;

  _MotionPhase _phase = _MotionPhase.movingConfirmed;
  DateTime? _candidateSince;

  /// Null [speedKmh] (no reading at all) leaves the state exactly where it
  /// was — never guesses stopped/moving from missing data (§40).
  DetectedEventType? update(double? speedKmh, DateTime now) {
    if (speedKmh == null || !speedKmh.isFinite) return null;
    switch (_phase) {
      case _MotionPhase.movingConfirmed:
        if (speedKmh <= stopThresholdKmh) {
          _phase = _MotionPhase.candidateStopped;
          _candidateSince = now;
        }
        return null;
      case _MotionPhase.candidateStopped:
        if (speedKmh > stopThresholdKmh) {
          _phase = _MotionPhase.movingConfirmed;
          _candidateSince = null;
          return null;
        }
        if (now.difference(_candidateSince!) >= stopMinDuration) {
          _phase = _MotionPhase.stoppedConfirmed;
          return DetectedEventType.stopped;
        }
        return null;
      case _MotionPhase.stoppedConfirmed:
        if (speedKmh >= resumeThresholdKmh) {
          _phase = _MotionPhase.candidateMoving;
          _candidateSince = now;
        }
        return null;
      case _MotionPhase.candidateMoving:
        if (speedKmh < resumeThresholdKmh) {
          _phase = _MotionPhase.stoppedConfirmed;
          _candidateSince = null;
          return null;
        }
        if (now.difference(_candidateSince!) >= resumeMinDuration) {
          _phase = _MotionPhase.movingConfirmed;
          return DetectedEventType.resumed;
        }
        return null;
    }
  }
}

/// Edge-triggered off [GnssQuality.unavailable] — deliberately no extra
/// confirm-duration on top (§15/§16): [GnssQuality] itself already only
/// reports `unavailable` once a fix is missing *or stale beyond its own
/// `maxFixAge`* (Fase 10), which is already the temporal confirmation
/// §15 asks for; layering a second one here would just add redundant
/// latency to a signal already debounced upstream (§54).
///
/// A single boolean baseline (assume "not lost" until proven otherwise)
/// captures both directions correctly with no special-casing: if GNSS
/// genuinely starts already unavailable (e.g. launched deep indoors), the
/// very first sample correctly fires `gnssLost`; the far more common case
/// (GNSS is fine from the start) produces no spurious opening
/// `gnssRecovered`, the exact bug an earlier phase's version of this logic
/// (see `DrivingSessionRecorder`'s prior implementation) had to special-case
/// explicitly.
@visibleForTesting
class GnssTracker {
  bool _lost = false;

  DetectedEventType? update(GnssQuality quality) {
    final isLost = quality == GnssQuality.unavailable;
    if (isLost == _lost) return null;
    _lost = isLost;
    return isLost ? DetectedEventType.gnssLost : DetectedEventType.gnssRecovered;
  }
}

/// Fires only on the transition *into* [AltitudeTrend.rising]/`falling`
/// from anything else — never on every sample while the trend continues
/// (§38), and never on returning to `stable` (not itself a reportable
/// event in the master prompt's own vocabulary). [cooldown] is
/// belt-and-suspenders on top of the upstream trend's own confirm-streak —
/// see this file's class-level doc.
@visibleForTesting
class AltitudeTrendTracker {
  AltitudeTrendTracker({required this.cooldown});

  final Duration cooldown;

  AltitudeTrend _last = AltitudeTrend.stable;
  DateTime? _lastFiredAt;

  DetectedEventType? update(AltitudeTrend trend, DateTime now) {
    final previous = _last;
    _last = trend;
    if (trend == previous) return null;
    if (trend == AltitudeTrend.stable) return null;
    final lastFired = _lastFiredAt;
    if (lastFired != null && now.difference(lastFired) < cooldown) return null;
    _lastFiredAt = now;
    return trend == AltitudeTrend.rising ? DetectedEventType.altitudeRisingSignificant : DetectedEventType.altitudeFallingSignificant;
  }
}
