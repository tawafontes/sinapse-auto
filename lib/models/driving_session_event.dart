import 'package:hive/hive.dart';

import 'detected_event.dart' show EventSeverity;

part 'driving_session_event.g.dart';

/// A relevant event flagged during a driving session — recorded by
/// `DrivingSessionRecorder.recordDetectedEvent` from whatever
/// `EventDetectionEngine` (Fase 13) confirms while a session is active;
/// still recording-only, no live alert UI of its own (that's the separate,
/// already-shipped dashboard alert banner — see `AlertEngine`).
///
/// [hardCornering] (index 2) is **legacy-only** as of Fase 13: sessions
/// recorded before this phase may still have one, and it must keep
/// deserializing correctly (Fase 11's own compatibility guarantee), but new
/// detection always emits [hardCorneringLeft]/[hardCorneringRight] instead
/// — matching this codebase's established "retire, never renumber/remove"
/// pattern for a persisted enum (see e.g. `SensorType`'s retired
/// `lightLevel`/`battery`/`time`/`compass` entries).
///
/// typeId: 12
@HiveType(typeId: 12)
enum DrivingSessionEventType {
  @HiveField(0)
  hardAcceleration,
  @HiveField(1)
  hardBraking,
  @HiveField(2)
  hardCornering,
  @HiveField(3)
  gnssLost,
  @HiveField(4)
  gnssRecovered,
  @HiveField(5)
  hardCorneringLeft,
  @HiveField(6)
  hardCorneringRight,
  @HiveField(7)
  highResultantG,
  @HiveField(8)
  speedLimitExceeded,
  @HiveField(9)
  stopped,
  @HiveField(10)
  resumed,
  @HiveField(11)
  altitudeRisingSignificant,
  @HiveField(12)
  altitudeFallingSignificant,
}

/// typeId: 13
///
/// Fields 3-12 were added in Fase 13, after this type had already shipped
/// and accumulated real persisted data — every one of them is either
/// nullable or carries an explicit `defaultValue:`, for exactly the reason
/// `DrivingSession`'s own Fase-11-vintage fields document: without it,
/// hive_generator emits an unchecked cast that throws reading any event
/// recorded before these fields existed. [id]/[durationMs] stay nullable
/// (a legacy event genuinely has neither); [severity] gets a `defaultValue`
/// instead, since "unknown severity" is more honestly represented as the
/// least-alarming band ([EventSeverity.info]) than as null.
@HiveType(typeId: 13)
class DrivingSessionEvent {
  DrivingSessionEvent({
    required this.type,
    required this.timestamp,
    this.magnitude,
    this.id,
    this.durationMs,
    this.latitude,
    this.longitude,
    this.speedKmh,
    this.altitudeMeters,
    this.longitudinalG,
    this.lateralG,
    this.resultantG,
    this.severity = EventSeverity.info,
  });

  @HiveField(0)
  final DrivingSessionEventType type;

  @HiveField(1)
  final DateTime timestamp;

  /// The value that triggered the event, in its natural unit (g for
  /// G-based events, km/h for speed/motion ones) — null for the events with
  /// no single triggering magnitude (GNSS transitions).
  @HiveField(2)
  final double? magnitude;

  /// Stable identifier (Fase 13 §62) — never the list index, which shifts
  /// under insertion/deletion. Null only for events persisted before this
  /// field existed.
  @HiveField(3)
  final String? id;

  /// How long the underlying condition had already held at the moment this
  /// event fired (Fase 13 §25) — see `EventDetectionEngine`'s own doc for
  /// why this is the *qualifying* duration, not the full episode's, and why
  /// it's null for edge/instant event types. Stored as milliseconds (a
  /// native Hive type) rather than a raw [Duration], which Hive has no
  /// built-in adapter for.
  @HiveField(4)
  final int? durationMs;

  Duration? get duration => durationMs == null ? null : Duration(milliseconds: durationMs!);

  /// The rest of the fields below are a snapshot of the telemetry at the
  /// moment of confirmation (Fase 13 §24/§23) — letting the session detail
  /// screen show "what was happening" without needing to correlate back to
  /// a nearby [DrivingSessionSample] by timestamp.
  @HiveField(5)
  final double? latitude;
  @HiveField(6)
  final double? longitude;
  @HiveField(7)
  final double? speedKmh;
  @HiveField(8)
  final double? altitudeMeters;
  @HiveField(9)
  final double? longitudinalG;
  @HiveField(10)
  final double? lateralG;
  @HiveField(11)
  final double? resultantG;

  @HiveField(12, defaultValue: EventSeverity.info)
  final EventSeverity severity;
}

String driveSessionEventTypeLabel(DrivingSessionEventType type) {
  switch (type) {
    case DrivingSessionEventType.hardAcceleration:
      return 'Aceleração forte';
    case DrivingSessionEventType.hardBraking:
      return 'Frenagem forte';
    case DrivingSessionEventType.hardCornering:
      return 'Curva forte';
    case DrivingSessionEventType.gnssLost:
      return 'Perda de GNSS';
    case DrivingSessionEventType.gnssRecovered:
      return 'Recuperação de GNSS';
    case DrivingSessionEventType.hardCorneringLeft:
      return 'Curva forte à esquerda';
    case DrivingSessionEventType.hardCorneringRight:
      return 'Curva forte à direita';
    case DrivingSessionEventType.highResultantG:
      return 'G resultante elevado';
    case DrivingSessionEventType.speedLimitExceeded:
      return 'Excesso de velocidade';
    case DrivingSessionEventType.stopped:
      return 'Parada';
    case DrivingSessionEventType.resumed:
      return 'Retomada de movimento';
    case DrivingSessionEventType.altitudeRisingSignificant:
      return 'Subida significativa';
    case DrivingSessionEventType.altitudeFallingSignificant:
      return 'Descida significativa';
  }
}

String eventSeverityLabel(EventSeverity severity) {
  switch (severity) {
    case EventSeverity.info:
      return 'Informativo';
    case EventSeverity.warning:
      return 'Atenção';
    case EventSeverity.high:
      return 'Alto';
    case EventSeverity.critical:
      return 'Crítico';
  }
}
