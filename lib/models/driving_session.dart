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

/// Fase 16.2-R4.3-R2.6.11: how a session's dashcam telemetry file ended — the
/// terminal result of the `DashcamTelemetryWriter` that session recorded with.
/// Derived from [DrivingSession.dashcamTelemetryOutcomeCode], never a second
/// stored copy, and deliberately not a Hive type of its own: a new adapter
/// would have to be registered by everything that opens the sessions box.
enum DashcamTelemetryOutcome {
  /// Nothing was ever recorded about it: a session stored before R2.6.11, a
  /// session with no dashcam telemetry at all (dashcam off, no camera), or one
  /// whose process ended before its file was finalized. Neither a failure nor
  /// a success — the file is not inspected to guess one.
  unknown,

  /// The writer was closed with every sample it accepted in the file.
  success,

  /// The writer failed — its file could not be opened, a write failed, or
  /// closing it failed. [DrivingSession.dashcamTelemetryAcceptedCount] and its
  /// two siblings say what was lost.
  failed,
}

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
    DateTime? endTime,
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
    this.deletionPending = false,
    this.dashcamTelemetryOutcomeCode,
    this.dashcamTelemetryAcceptedCount,
    this.dashcamTelemetryPersistedCount,
    this.dashcamTelemetryRefusedCount,
  })  : _storedEndTime = endTime,
        events = events ?? [];

  @HiveField(0)
  final String id;

  @HiveField(1)
  final DateTime startTime;

  /// When the session ended — null while it is still being recorded, see
  /// [isActive].
  ///
  /// Fase 16.2-R4.3-R2.6.13 (independent review of R2.6.12, P2): what this
  /// READS and what a write of this record STORES are two things. hive 2.2.3
  /// keeps a reference to the instance it is given and serializes it when the
  /// queued write RUNS — after every write queued before it on the box, so
  /// arbitrarily later while the file is busy — and that instance is the one
  /// its recorder keeps changing (the box holds that very instance; the History
  /// lists it, a pending finalization included). A STOP ends the session in its
  /// synchronous prefix, before the final samples are stored. Reproduced: a
  /// per-sample save requested BEFORE the STOP ran after it and stored the end
  /// time; the samples write then failed — or the process died right there,
  /// with no I/O error at all — and the file kept a FINISHED session declaring
  /// 4 samples with none stored, which the startup recovery (it reclaims
  /// active records) never repaired.
  ///
  /// So an end time is either
  ///  * unconfirmed ([endUnconfirmed]): read here — and so by [isActive],
  ///    [state], the recorder and the History — and stored by NO write of this
  ///    record, whenever that write runs: on disk the session stays active,
  ///    which is what it is until its samples are stored; or
  ///  * confirmed ([confirmEndTime], the setter, the constructor): what every
  ///    write of this record stores from then on.
  /// Field 2 keeps its index and type, and nothing new is stored.
  DateTime? get endTime => _unconfirmedEndTime ?? _storedEndTime;

  /// Sets a CONFIRMED end time — one the next write of this record stores (the
  /// startup recovery closing an orphan; a record edited by whoever holds it).
  set endTime(DateTime? value) {
    _unconfirmedEndTime = null;
    _storedEndTime = value;
  }

  /// The end time a write of this record stores — see [endTime]. The generated
  /// adapter (a part of this library) reads and sets this, never [endTime].
  @HiveField(2)
  DateTime? _storedEndTime;

  /// See [endTime]. Deliberately not a Hive field.
  DateTime? _unconfirmedEndTime;

  /// Ends this session at [at] IN MEMORY ONLY (see [endTime]): its recorder
  /// calls this when it stops, and [confirmEndTime] once the session's samples
  /// are stored. A session that already has an end time keeps it — a retried
  /// finalization preserves the first one.
  void endUnconfirmed(DateTime at) {
    if (endTime != null) return;
    _unconfirmedEndTime = at;
  }

  /// Makes the end time set by [endUnconfirmed] the one writes of this record
  /// store. No-op when there is none — already confirmed, or never ended.
  void confirmEndTime() {
    final unconfirmed = _unconfirmedEndTime;
    if (unconfirmed == null) return;
    _storedEndTime = unconfirmed;
    _unconfirmedEndTime = null;
  }

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

  /// Fase 16.2-R4.3-R2.6.7: the durable intent to delete this session — set
  /// and written by `deleteDrivingSession` BEFORE it removes anything, and
  /// removed with this record, the last thing that deletion removes. A record
  /// still carrying it is a deletion that did not finish (the process died,
  /// or a step failed): `completePendingSessionDeletions` finishes it at the
  /// next start, and the History shows it as pending. `defaultValue: false`
  /// keeps every record stored before this field existed readable (see
  /// [sampleCount]'s doc).
  @HiveField(25, defaultValue: false)
  bool deletionPending;

  /// Fase 16.2-R4.3-R2.6.11 (independent review, P2 — reproduced: session A's
  /// telemetry file failed after session B had started, 19 of 19 samples lost,
  /// A's STOP completed without error and nothing durable said so): the
  /// terminal result of this session's dashcam telemetry file, written ON THIS
  /// SESSION by `persistSessionTelemetryOutcome` when the writer that recorded
  /// it has been closed. A stable code, not an enum index: `null` = nothing
  /// recorded ([DashcamTelemetryOutcome.unknown]), 1 = success, 2 = failed.
  /// Read it through [dashcamTelemetryOutcome].
  ///
  /// Nullable, like the three counts below, so every record stored before
  /// these fields existed stays readable and reads as unknown (see
  /// [sampleCount]'s doc) — never as a failure, and never as a success nobody
  /// observed. Only the semantic state is stored: no exception text, no
  /// operating-system detail.
  @HiveField(26)
  int? dashcamTelemetryOutcomeCode;

  /// Samples the telemetry writer accepted over the session. `null` while
  /// [dashcamTelemetryOutcome] is unknown.
  @HiveField(27)
  int? dashcamTelemetryAcceptedCount;

  /// Accepted samples the file confirmed. Fewer than
  /// [dashcamTelemetryAcceptedCount] = samples lost.
  @HiveField(28)
  int? dashcamTelemetryPersistedCount;

  /// Samples produced after the writer had failed and refused by it — never
  /// accepted, so not part of the two counts above, and not recorded either.
  @HiveField(29)
  int? dashcamTelemetryRefusedCount;

  static const _telemetrySuccessCode = 1;
  static const _telemetryFailedCode = 2;

  /// See [dashcamTelemetryOutcomeCode]. A code this build does not know reads
  /// as unknown.
  DashcamTelemetryOutcome get dashcamTelemetryOutcome {
    switch (dashcamTelemetryOutcomeCode) {
      case _telemetrySuccessCode:
        return DashcamTelemetryOutcome.success;
      case _telemetryFailedCode:
        return DashcamTelemetryOutcome.failed;
      default:
        return DashcamTelemetryOutcome.unknown;
    }
  }

  /// Whether this record already carries exactly this terminal outcome.
  bool carriesDashcamTelemetryOutcome(DashcamTelemetryOutcome outcome, {required int accepted, required int persisted, required int refused}) =>
      outcome != DashcamTelemetryOutcome.unknown &&
      dashcamTelemetryOutcome == outcome &&
      dashcamTelemetryAcceptedCount == accepted &&
      dashcamTelemetryPersistedCount == persisted &&
      dashcamTelemetryRefusedCount == refused;

  /// Sets the four telemetry-outcome fields — in memory only; whoever calls
  /// this writes the record (`persistSessionTelemetryOutcome`). Absolute
  /// values, so applying the same outcome twice changes nothing.
  void applyDashcamTelemetryOutcome(DashcamTelemetryOutcome outcome, {required int accepted, required int persisted, required int refused}) {
    assert(outcome != DashcamTelemetryOutcome.unknown, 'only a terminal outcome is recorded');
    dashcamTelemetryOutcomeCode = outcome == DashcamTelemetryOutcome.success ? _telemetrySuccessCode : _telemetryFailedCode;
    dashcamTelemetryAcceptedCount = accepted;
    dashcamTelemetryPersistedCount = persisted;
    dashcamTelemetryRefusedCount = refused;
  }

  bool get isActive => endTime == null;

  DrivingSessionState get state => endTime == null ? DrivingSessionState.recording : DrivingSessionState.completed;

  Duration? get duration => endTime?.difference(startTime);

  /// Fase 16.2-R4.3-R2.6.4: a copy of this session carrying every persisted
  /// field, NOT bound to any Hive box — used to re-persist a session under its
  /// own [id] when this instance is still bound to a box instance that has
  /// since been closed. hive 2.2.3's `Box.close()` does not unbind the objects
  /// it held: such an instance can no longer `save()` ("Box has already been
  /// closed"), and `put`ting it into the reopened box is refused ("The same
  /// instance of an HiveObject cannot be stored in two different boxes"). The
  /// copy is a new, unbound instance, so it can be stored. Not a schema change.
  ///
  /// Must list EVERY `@HiveField` above. `driving_session_recorder_test.dart`
  /// guards this by comparing what the generated adapter writes for a fully
  /// populated session and for its copy.
  ///
  /// Fase 16.2-R4.3-R2.6.13: it carries what a write of this instance stores —
  /// an unconfirmed end time (see [endTime]) is not one of those fields.
  DrivingSession detachedCopy() => DrivingSession(
        id: id,
        startTime: startTime,
        endTime: _storedEndTime,
        distanceMeters: distanceMeters,
        maxSpeedKmh: maxSpeedKmh,
        avgSpeedKmh: avgSpeedKmh,
        maxAltitudeMeters: maxAltitudeMeters,
        minAltitudeMeters: minAltitudeMeters,
        maxAccelerationG: maxAccelerationG,
        maxDecelerationG: maxDecelerationG,
        initialAltitudeMeters: initialAltitudeMeters,
        finalAltitudeMeters: finalAltitudeMeters,
        initialHeadingDegrees: initialHeadingDegrees,
        finalHeadingDegrees: finalHeadingDegrees,
        maxLateralG: maxLateralG,
        maxGForceMagnitude: maxGForceMagnitude,
        sampleCount: sampleCount,
        initialLatitude: initialLatitude,
        initialLongitude: initialLongitude,
        finalLatitude: finalLatitude,
        finalLongitude: finalLongitude,
        avgGnssQualityIndex: avgGnssQualityIndex,
        altitudeGainMeters: altitudeGainMeters,
        altitudeLossMeters: altitudeLossMeters,
        events: List<DrivingSessionEvent>.of(events),
        deletionPending: deletionPending,
        dashcamTelemetryOutcomeCode: dashcamTelemetryOutcomeCode,
        dashcamTelemetryAcceptedCount: dashcamTelemetryAcceptedCount,
        dashcamTelemetryPersistedCount: dashcamTelemetryPersistedCount,
        dashcamTelemetryRefusedCount: dashcamTelemetryRefusedCount,
      );
}

/// Fase 16.2-R4.3-R2.6.11: what the History says about [session]'s dashcam
/// telemetry, after the words "Telemetria da dashcam" — `null` when there is
/// nothing to say ([DashcamTelemetryOutcome.unknown]). Built from the stored
/// outcome and counts only.
String? dashcamTelemetryOutcomeSummary(DrivingSession session) {
  final accepted = session.dashcamTelemetryAcceptedCount ?? 0;
  final persisted = session.dashcamTelemetryPersistedCount ?? 0;
  final refused = session.dashcamTelemetryRefusedCount ?? 0;
  switch (session.dashcamTelemetryOutcome) {
    case DashcamTelemetryOutcome.unknown:
      return null;
    case DashcamTelemetryOutcome.success:
      return 'completa: $persisted amostras gravadas';
    case DashcamTelemetryOutcome.failed:
      // The file never opened and nothing was offered to it.
      if (accepted == 0 && refused == 0) return 'não gravada';
      final counts = '$persisted de $accepted amostras gravadas';
      if (persisted < accepted || refused > 0) {
        return 'incompleta: $counts${refused > 0 ? ', $refused recusadas após a falha' : ''}';
      }
      // Every accepted sample is in the file; only closing it failed.
      return 'com erro ao finalizar o arquivo: $counts';
  }
}
