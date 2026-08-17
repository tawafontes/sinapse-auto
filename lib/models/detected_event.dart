import 'package:hive/hive.dart';

import 'alert_type.dart';
import 'telemetry_snapshot.dart';

part 'detected_event.g.dart';

/// Every phenomenon [EventDetectionEngine] can recognize from telemetry — the
/// single, sole detector for all of these (Fase 13.1 §1/§2: one source of
/// truth per phenomenon). Both the session-persistence path
/// ([DrivingSessionRecorder.recordDetectedEvent]) and, for the subset with a
/// live-banner equivalent, the alert path (see [alertTypeForDetectedEvent])
/// key off this same confirmed [DetectedEvent] — [AlertEngine] no longer
/// independently re-detects any of these. See `event_detection_engine.dart`'s
/// own doc for the full architecture.
enum DetectedEventType {
  hardAcceleration,
  hardBraking,

  /// Split left/right (Fase 13 §10) — the pre-Fase-13
  /// `DrivingSessionEventType.hardCornering` is now legacy-only: still
  /// deserializable from old sessions, never emitted by new detection.
  hardCorneringLeft,
  hardCorneringRight,

  /// Combined longitudinal+lateral+vertical magnitude exceeding its own,
  /// higher threshold — reuses `TelemetrySnapshot.gForceMagnitude` (the
  /// app's one already-centralized "G resultante" computation, see
  /// `TelemetryEngine`) rather than recomputing a 2-axis magnitude, per
  /// Fase 13 §11's explicit "não duplicar cálculo se já existir uma
  /// implementação centralizada".
  highResultantG,

  /// Speed sustained above the user-configured limit (Fase 13 §12) —
  /// shares its threshold with the existing `AlertType.highSpeed`
  /// preference (one configured number, not a second one to keep in sync).
  speedLimitExceeded,

  stopped,
  resumed,
  gnssLost,
  gnssRecovered,
  altitudeRisingSignificant,
  altitudeFallingSignificant,
}

/// Objective, measurable severity (Fase 13 §26/§27) — never a judgement of
/// the driver, only a banding of how far past its own threshold the
/// triggering value was. `info` is also the fixed severity for
/// state-transition events with no natural "how extreme" axis (stopped,
/// resumed, GNSS lost/recovered, altitude trend change).
///
/// Hive-annotated directly (typeId 14, next free slot per the registry in
/// `sensor_widget_config.dart`) since, unlike [DetectedEvent] itself
/// (purely an in-memory detection-layer type, never persisted), this
/// specific enum also doubles as `DrivingSessionEvent.severity`'s stored
/// type — matching the project's established "annotate the enum directly"
/// convention rather than a parallel persisted copy.
@HiveType(typeId: 14)
enum EventSeverity {
  @HiveField(0)
  info,
  @HiveField(1)
  warning,
  @HiveField(2)
  high,
  @HiveField(3)
  critical,
}

/// One confirmed detection from [EventDetectionEngine] — already past its
/// type's hysteresis + minimum-duration + cooldown gate (see that class's
/// own doc), never a raw, unconfirmed threshold crossing. [snapshot] is the
/// full [TelemetrySnapshot] at the instant of confirmation (Fase 13 §24:
/// "capturar um snapshot da telemetria naquele instante"), letting any
/// consumer read whatever fields it needs (position, speed, altitude, every
/// G axis) without this type having to duplicate them as its own fields.
class DetectedEvent {
  const DetectedEvent({
    required this.type,
    required this.timestamp,
    required this.severity,
    required this.snapshot,
    this.value,
    this.duration,
  });

  final DetectedEventType type;

  /// The instant the event was confirmed (state machine entered `active`),
  /// not when the candidate first started being tracked.
  final DateTime timestamp;

  final EventSeverity severity;

  /// The full telemetry at confirmation — see this class's own doc.
  final TelemetrySnapshot snapshot;

  /// The measured value that triggered the event, in its natural canonical
  /// unit (g for G-based events, km/h for speed) — null for events with no
  /// single triggering magnitude (stopped/resumed/GNSS transitions).
  final double? value;

  /// How long the underlying condition held before the cooldown transition
  /// (Fase 13 §25) — only populated for level-based events (the detector
  /// naturally knows start→end); null for edge/instant events, where a
  /// "duration" isn't a meaningful single-instant concept the same way.
  final Duration? duration;
}

/// The live-banner [AlertType] a confirmed [DetectedEvent] should surface as
/// (Fase 13.1 §1/§2), or null when [type] has no live-banner equivalent —
/// [stopped]/[resumed]/[gnssRecovered]/altitude-trend events have never had
/// one (no matching [AlertType] exists for them) and remain session-history
/// only, exactly as before this fix.
///
/// This is the seam that lets [EventDetectionEngine] be the *only* runtime
/// state machine watching each of these six phenomena: before Fase 13.1,
/// [AlertEngine] independently re-evaluated the same threshold+hysteresis
/// logic for `highSpeed`/`harshAcceleration`/`harshBraking`/`hardCornering`/
/// `highResultantG`/`gnssLost` purely to decide when to show a banner — two
/// separately-timed cooldowns for one physical event, with no guarantee they
/// ever agreed. Now the banner is just a presentation of the same confirmed
/// event the session already recorded: this function decides *whether* one
/// is shown, `AlertPreferences.isEnabled` (checked by the caller) decides
/// whether the user still wants it.
AlertType? alertTypeForDetectedEvent(DetectedEventType type) {
  switch (type) {
    case DetectedEventType.hardAcceleration:
      return AlertType.harshAcceleration;
    case DetectedEventType.hardBraking:
      return AlertType.harshBraking;
    case DetectedEventType.hardCorneringLeft:
    case DetectedEventType.hardCorneringRight:
      return AlertType.hardCornering;
    case DetectedEventType.highResultantG:
      return AlertType.highResultantG;
    case DetectedEventType.speedLimitExceeded:
      return AlertType.highSpeed;
    case DetectedEventType.gnssLost:
      return AlertType.gnssLost;
    case DetectedEventType.gnssRecovered:
    case DetectedEventType.stopped:
    case DetectedEventType.resumed:
    case DetectedEventType.altitudeRisingSignificant:
    case DetectedEventType.altitudeFallingSignificant:
      return null;
  }
}
