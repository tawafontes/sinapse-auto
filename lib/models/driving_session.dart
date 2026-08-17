import 'package:hive/hive.dart';

import 'driving_session_event.dart';

part 'driving_session.g.dart';

/// Strongly-typed lifecycle state of a single [DrivingSession] — derived
/// from [DrivingSession.endTime], never stored redundantly (there's exactly
/// one source of truth). The recorder-level "no session at all" (IDLE) state
/// isn't part of this enum on purpose: a [DrivingSession] instance never
/// exists during IDLE, so it can't be one of this type's own values — see
/// `DrivingSessionRecorder.isRecording` for that.
enum DrivingSessionState { recording, completed }

/// A single driving session's summary — the record `HistoryScreen` lists
/// and `DrivingSessionRecorder` maintains live while recording. Kept
/// deliberately lightweight (no embedded trajectory/telemetry samples —
/// those live separately, see `driving_session_sample.dart`) so listing
/// every past session (for the History screen) never requires deserializing
/// a single sample, only these few scalar fields per session.
///
/// typeId: 10
@HiveType(typeId: 10)
class DrivingSession extends HiveObject {
  DrivingSession({
    required this.id,
    required this.startTime,
    this.endTime,
    this.distanceMeters = 0,
    this.maxSpeedKmh,
    this.avgSpeedKmh,
    this.maxAltitudeMeters,
    this.minAltitudeMeters,
    this.maxAccelerationG,
    this.maxDecelerationG,
    this.initialAltitudeMeters,
    this.finalAltitudeMeters,
    this.initialHeadingDegrees,
    this.finalHeadingDegrees,
    this.maxLateralG,
    this.maxGForceMagnitude,
    this.sampleCount = 0,
    this.initialLatitude,
    this.initialLongitude,
    this.finalLatitude,
    this.finalLongitude,
    this.avgGnssQualityIndex,
    this.altitudeGainMeters = 0,
    this.altitudeLossMeters = 0,
    List<DrivingSessionEvent>? events,
  }) : events = events ?? [];

  @HiveField(0)
  final String id;

  @HiveField(1)
  final DateTime startTime;

  /// Null while the session is still being recorded — see [isActive].
  @HiveField(2)
  DateTime? endTime;

  @HiveField(3)
  double distanceMeters;

  @HiveField(4)
  double? maxSpeedKmh;

  @HiveField(5)
  double? avgSpeedKmh;

  @HiveField(6)
  double? maxAltitudeMeters;

  @HiveField(7)
  double? minAltitudeMeters;

  /// Highest positive longitudinal G observed (accelerating).
  @HiveField(8)
  double? maxAccelerationG;

  /// Most negative longitudinal G observed (braking) — stored as a
  /// magnitude (always >= 0) for straightforward display ("frenagem
  /// máxima: 0.6g"), not as a signed value a caller would need to negate.
  @HiveField(9)
  double? maxDecelerationG;

  @HiveField(10)
  double? initialAltitudeMeters;

  @HiveField(11)
  double? finalAltitudeMeters;

  /// GNSS-derived heading, degrees — null whenever the first/last accepted
  /// sample happened to be below the heading system's own low-speed cutoff
  /// (see `TelemetryEngine.headingDegrees`), same "no reliable reading"
  /// semantics as everywhere else in the telemetry model.
  @HiveField(12)
  double? initialHeadingDegrees;

  @HiveField(13)
  double? finalHeadingDegrees;

  /// Highest magnitude of lateral G observed (either direction — a hard
  /// left and a hard right both count).
  @HiveField(14)
  double? maxLateralG;

  /// Highest resultant (vector-magnitude) G observed — orientation-
  /// independent, the same figure the G-force widget's own "MÁX" badge
  /// tracks.
  @HiveField(15)
  double? maxGForceMagnitude;

  /// Count of decimated samples actually recorded for this session (i.e.
  /// the length of its `DrivingSessionSample` list) — kept as its own field
  /// so the History list can show/reason about it without loading the
  /// (lazy, possibly large) samples box.
  ///
  /// `defaultValue: 0` (here and on every other non-nullable field added in
  /// this same round) isn't cosmetic: without it, hive_generator emits an
  /// unchecked `fields[16] as int` with no null-coalescing, which throws
  /// "type 'Null' is not a subtype of type 'int'" the instant it reads a
  /// session persisted by an earlier phase, before this field existed —
  /// confirmed by an actual crash on the physical device's real, pre-existing
  /// session history during this round's validation, not just a theoretical
  /// concern. Every field added before this round is nullable specifically
  /// to sidestep this; these four couldn't be (an int/double/List "sample
  /// count"/"gain"/"events list" has no meaningful null), so the
  /// `defaultValue:` is what makes them equally safe to add after the fact.
  @HiveField(16, defaultValue: 0)
  int sampleCount;

  @HiveField(17)
  double? initialLatitude;

  @HiveField(18)
  double? initialLongitude;

  @HiveField(19)
  double? finalLatitude;

  @HiveField(20)
  double? finalLongitude;

  /// Running average of every accepted sample's `GnssQuality.index`
  /// (0=unavailable .. 4=excellent) — a plain double so the average itself
  /// isn't lossy; see `gnssQualityFromAverageIndex` to map it back to a
  /// [GnssQuality] label for display. Null only if the session never
  /// received a single snapshot.
  @HiveField(21)
  double? avgGnssQualityIndex;

  /// Cumulative climb, in meters — only counted while
  /// `TelemetrySnapshot.altitudeTrend` reports [AltitudeTrend.rising] (see
  /// `DrivingSessionRecorder`), i.e. already protected by that system's own
  /// dead zone/hysteresis. A flat or noisy signal contributes 0, by
  /// construction, not through a second filter invented for this field.
  @HiveField(22, defaultValue: 0)
  double altitudeGainMeters;

  /// Same as [altitudeGainMeters], for [AltitudeTrend.falling].
  @HiveField(23, defaultValue: 0)
  double altitudeLossMeters;

  /// Relevant events flagged during the session (hard acceleration/braking/
  /// cornering, GNSS lost/recovered) — see `driving_session_event.dart`.
  /// Recording only, no live alert UI in this phase (see
  /// `DrivingSessionRecorder`'s own doc).
  @HiveField(24, defaultValue: <DrivingSessionEvent>[])
  List<DrivingSessionEvent> events;

  bool get isActive => endTime == null;

  DrivingSessionState get state => endTime == null ? DrivingSessionState.recording : DrivingSessionState.completed;

  Duration? get duration => endTime?.difference(startTime);
}
