import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive/hive.dart';

import '../models/dashcam_clip_record.dart';
import '../models/detected_event.dart';
import '../models/driving_session.dart';
import '../models/driving_session_event.dart';
import '../models/driving_session_sample.dart';
import '../models/telemetry_snapshot.dart';
import 'altitude_trend.dart';
import 'dashcam_telemetry_writer.dart';
import 'gnss_quality.dart';
import 'hive_boxes.dart';
import 'outlier_rejector.dart' show isPlausibleSpeedKmh;

/// Recorder-level state — distinct from [DrivingSessionState], which only
/// exists once a [DrivingSession] object does. IDLE has no session object at
/// all, which is exactly why it lives here instead of as a third value on
/// that enum.
enum DrivingSessionRecorderState { idle, recording }

/// Records a driving session by sampling [DashboardSensorStreams.snapshot]
/// — the same central telemetry stream every other consumer reads, no
/// independent GPS/sensor subscription of its own. Starting/stopping a
/// session only starts/stops *this recorder's own listener* on that
/// already-shared stream; it never touches [SensorService] or the
/// dashboard's live tiles, which keep running (or not) exactly as they
/// otherwise would (see [stopSession]'s own doc).
///
/// Samples are decimated to [_recordingInterval] (independent of
/// [DashboardSensorStreams.snapshot]'s own faster ~5Hz throttle — a
/// dashboard/HUD legitimately wants that; a hour-long session recorded at
/// 5Hz would be 18,000 samples for no real benefit over 1Hz's 3,600) and
/// flushed to Hive every [_flushEverySamples] samples — not just once at
/// [stopSession] — so an unexpected app termination loses at most a few
/// seconds of the *current* session, never the whole thing (the summary
/// [DrivingSession] record itself is written on every sample, since it's
/// only a handful of scalar fields — cheap regardless of flush cadence).
///
/// Two fields ([currentSpeedKmh]/[currentGnssQuality]) update on *every*
/// snapshot regardless of the 1Hz decimation — live-only UI state for
/// `SessionRecordingScreen` (Fase 11 §25: the screen observes this recorder,
/// never the raw telemetry stream directly), not persisted, not part of the
/// decimated sample/statistics pipeline below.
///
/// Event detection itself (Fase 13) does **not** live here anymore — see
/// [recordDetectedEvent]'s own doc for why that moved to a shared,
/// session-independent `EventDetectionEngine`, and what this class's
/// remaining responsibility is.
class DrivingSessionRecorder extends ChangeNotifier {
  DrivingSessionRecorder(this._snapshotStream);

  final Stream<TelemetrySnapshot> _snapshotStream;

  static const _recordingInterval = Duration(seconds: 1);
  static const _flushEverySamples = 10;

  static Box<DrivingSession> get _sessionsBox => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  static LazyBox get _samplesBox => Hive.lazyBox(HiveBoxNames.drivingSessionSamples);

  StreamSubscription<TelemetrySnapshot>? _sub;
  DrivingSession? _activeSession;
  final List<DrivingSessionSample> _pendingSamples = [];
  int _unflushedCount = 0;

  double? _lastAcceptedLatitude;
  double? _lastAcceptedLongitude;
  DateTime? _lastAcceptedFixTimestamp;
  double _validElapsedSeconds = 0;
  double? _lastAltitudeForGainLoss;
  double _gnssQualityIndexSum = 0;
  int _gnssQualityIndexCount = 0;
  DateTime? _lastSampleAt;

  /// Updated on every snapshot, not just decimated ones — live readout only,
  /// see this class's own doc comment.
  double? currentSpeedKmh;

  /// Same live-only contract as [currentSpeedKmh].
  GnssQuality currentGnssQuality = GnssQuality.unavailable;

  /// Fase 14 §8/§18 (persistence audit — "nenhuma corrupção"/"nenhuma
  /// duplicação"): appended to every generated session id, guaranteeing
  /// uniqueness even when [DateTime.now] alone can't. Confirmed by direct
  /// measurement (not assumed) that this matters: on this project's own
  /// Windows dev machine, `DateTime.now().microsecondsSinceEpoch` advances
  /// only about every ~15ms (the platform's underlying timer-tick
  /// resolution) despite its name promising microsecond granularity — 200k
  /// back-to-back calls produced only 9 distinct values. Two sessions
  /// started within that same tick (trivially reproducible in an automated
  /// stress test's tight start/stop loop — see [driving_session_recorder_test.dart]'s
  /// own `deleteDrivingSession` test, which intermittently caught exactly
  /// this collision before this fix) would previously receive the *same*
  /// `id`, so the second session's Hive `put` under that key would silently
  /// overwrite the first's, corrupting/losing one session's data with no
  /// error raised anywhere. A per-process monotonic counter costs nothing
  /// and closes this regardless of the host platform's actual clock
  /// resolution.
  static int _sessionIdSequence = 0;

  static String _newSessionId() => '${DateTime.now().microsecondsSinceEpoch}-${_sessionIdSequence++}';

  DrivingSession? get activeSession => _activeSession;
  bool get isRecording => _activeSession != null;
  DrivingSessionRecorderState get state =>
      _activeSession == null ? DrivingSessionRecorderState.idle : DrivingSessionRecorderState.recording;

  /// Starts a new session. No-op (returns the already-active session) if
  /// one is already recording — callers should check [isRecording] first,
  /// but this stays safe either way rather than silently starting a second,
  /// overlapping session.
  DrivingSession startSession() {
    final existing = _activeSession;
    if (existing != null) return existing;

    final session = DrivingSession(id: _newSessionId(), startTime: DateTime.now());
    _activeSession = session;
    _pendingSamples.clear();
    _unflushedCount = 0;
    _lastAcceptedLatitude = null;
    _lastAcceptedLongitude = null;
    _lastAcceptedFixTimestamp = null;
    _validElapsedSeconds = 0;
    _lastAltitudeForGainLoss = null;
    _gnssQualityIndexSum = 0;
    _gnssQualityIndexCount = 0;
    _lastSampleAt = null;

    unawaited(_sessionsBox.put(session.id, session));
    // Deliberately NOT also seeding an empty list into the samples box here:
    // that write and a later incremental _flush() are both unawaited/async,
    // and if the seed write happened to resolve *after* a flush had already
    // written real samples, it would silently clobber them back to empty —
    // a genuine race, caught by this exact scenario in this class's own
    // test suite. _flush already treats "no entry yet" as an empty list
    // (see its own `raw == null` handling), so no seed is needed: the first
    // flush (incremental, or the forced one in [stopSession]) creates the
    // entry correctly either way.

    _sub = _snapshotStream.listen(_onSnapshot);
    notifyListeners();
    return session;
  }

  /// Ends the active session (no-op if none is active) — only cancels this
  /// recorder's own subscription to the shared snapshot stream; every other
  /// consumer of that stream (dashboard tiles, Diagnostics, a HUD,
  /// `EventDetectionEngine` itself) is completely unaffected, and no sensor
  /// is told to stop.
  Future<void> stopSession() async {
    final session = _activeSession;
    if (session == null) return;

    await _sub?.cancel();
    _sub = null;

    session.endTime = DateTime.now();
    await _flush(session, force: true);
    await session.save();

    _activeSession = null;
    notifyListeners();
  }

  /// Fase 14 §2/§18 (stream-leak audit): [stopSession] is the normal path
  /// that cancels [_sub], but a caller that tears this recorder down
  /// directly — [dashboard_screen.dart]'s own `dispose()` does exactly this,
  /// unconditionally, without checking [isRecording] first — would otherwise
  /// leave [_sub] (a listener on the shared, ref-counted
  /// `DashboardSensorStreams.snapshot`) never cancelled if a session
  /// happened to be active at that moment. `super.dispose()` (plain
  /// [ChangeNotifier]) never touches [_sub] on its own, so this override is
  /// what actually closes that gap. Deliberately does NOT call the async
  /// [stopSession] (persisting a final flush, setting `endTime`, etc.) —
  /// [dispose] must stay synchronous, and a recorder being disposed
  /// mid-session already has every sample up to the last flush safely on
  /// disk (see this class's own doc comment on [_flushEverySamples]); the
  /// orphaned, still-`isActive` session record itself is exactly what
  /// [reclaimOrphanedSessions] exists to close out on the next app start.
  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }

  void _onSnapshot(TelemetrySnapshot snapshot) {
    final session = _activeSession;
    if (session == null) return;

    // Live-only fields — updated on every snapshot, ahead of (and
    // independent from) the decimation gate below. Only notify when one of
    // them actually changed value (Fase 14 §10 — rebuild audit): g-force-
    // triggered snapshots fire at near-native accelerometer rate while a
    // session is active, by design (see `DashboardSensorStreams.snapshot`'s
    // own doc, Fase 13.2), but never touch either field here. Without this
    // guard, every such snapshot still called `notifyListeners()`
    // unconditionally, so `SessionRecordingScreen` — a whole-screen
    // `setState` on every notification, and the one screen shown throughout
    // an actual drive — was rebuilding at that same high rate even though
    // neither value it reads from this class had changed.
    final newSpeed = snapshot.speedKmh;
    final newGnssQuality = snapshot.gnssQuality;
    final liveFieldsChanged = newSpeed != currentSpeedKmh || newGnssQuality != currentGnssQuality;
    currentSpeedKmh = newSpeed;
    currentGnssQuality = newGnssQuality;
    if (liveFieldsChanged) notifyListeners();

    final last = _lastSampleAt;
    if (last != null && snapshot.timestamp.difference(last) < _recordingInterval) return;
    _lastSampleAt = snapshot.timestamp;

    if (snapshot.hasGnssFix) {
      session.initialLatitude ??= snapshot.latitude;
      session.initialLongitude ??= snapshot.longitude;
      session.finalLatitude = snapshot.latitude;
      session.finalLongitude = snapshot.longitude;

      final prevLat = _lastAcceptedLatitude;
      final prevLon = _lastAcceptedLongitude;
      final prevTimestamp = _lastAcceptedFixTimestamp;
      if (prevLat != null && prevLon != null && prevTimestamp != null) {
        final segmentMeters = Geolocator.distanceBetween(prevLat, prevLon, snapshot.latitude!, snapshot.longitude!);
        final elapsedSeconds = snapshot.timestamp.difference(prevTimestamp).inMilliseconds / 1000.0;
        // GPS-jump protection (Fase 11 §11): reject this fix for distance
        // purposes if the implied speed between the two points is
        // physically impossible — reusing the exact same plausibility check
        // (and documented 360 km/h ceiling) the Telemetry Engine itself
        // already applies to GNSS speed readings, rather than inventing a
        // second, session-specific threshold. A rejected fix is simply
        // skipped: it becomes neither a new distance segment nor a new
        // reference point, so the *next* fix is still checked against the
        // last genuinely-accepted one.
        final impliedSpeedKmh = elapsedSeconds > 0 ? (segmentMeters / elapsedSeconds) * 3.6 : 0.0;
        if (isPlausibleSpeedKmh(impliedSpeedKmh)) {
          session.distanceMeters += segmentMeters;
          if (elapsedSeconds > 0) _validElapsedSeconds += elapsedSeconds;
          _lastAcceptedLatitude = snapshot.latitude;
          _lastAcceptedLongitude = snapshot.longitude;
          _lastAcceptedFixTimestamp = snapshot.timestamp;
        }
      } else {
        _lastAcceptedLatitude = snapshot.latitude;
        _lastAcceptedLongitude = snapshot.longitude;
        _lastAcceptedFixTimestamp = snapshot.timestamp;
      }

      // Average speed = valid distance / valid elapsed time (Fase 11 §12) —
      // computed from the exact same accepted-fix-pairs distance uses
      // above, not a separate arithmetic mean of instantaneous readings.
      // That older approach was measurably biased: TelemetryEngine emits
      // snapshots faster at higher speed (its own adaptive throttle), so a
      // plain per-sample average systematically over-weighted fast segments
      // relative to how much wall-clock time they actually took. This
      // distance/time methodology has no such bias, and is exactly what
      // "average speed" conventionally means for a trip.
      if (_validElapsedSeconds > 0) {
        session.avgSpeedKmh = (session.distanceMeters / _validElapsedSeconds) * 3.6;
      }
    }

    final speed = snapshot.speedKmh;
    if (speed != null) {
      session.maxSpeedKmh = session.maxSpeedKmh == null ? speed : (speed > session.maxSpeedKmh! ? speed : session.maxSpeedKmh);
    }

    final altitude = snapshot.altitudeMeters;
    if (altitude != null) {
      session.initialAltitudeMeters ??= altitude;
      session.finalAltitudeMeters = altitude;
      session.maxAltitudeMeters = session.maxAltitudeMeters == null || altitude > session.maxAltitudeMeters!
          ? altitude
          : session.maxAltitudeMeters;
      session.minAltitudeMeters = session.minAltitudeMeters == null || altitude < session.minAltitudeMeters!
          ? altitude
          : session.minAltitudeMeters;

      // Gain/loss (Fase 11 §15): only counted while the already
      // hysteresis-protected TelemetryEngine trend classifier itself
      // reports a genuine climb/descent — a flat or noisy signal
      // contributes nothing, with no second dead zone invented here.
      final previousAltitude = _lastAltitudeForGainLoss;
      if (previousAltitude != null) {
        final delta = altitude - previousAltitude;
        if (snapshot.altitudeTrend == AltitudeTrend.rising && delta > 0) {
          session.altitudeGainMeters += delta;
        } else if (snapshot.altitudeTrend == AltitudeTrend.falling && delta < 0) {
          session.altitudeLossMeters += -delta;
        }
      }
      _lastAltitudeForGainLoss = altitude;
    }

    final heading = snapshot.headingDegrees;
    if (heading != null) {
      session.initialHeadingDegrees ??= heading;
      session.finalHeadingDegrees = heading;
    }

    final longitudinalG = snapshot.longitudinalG;
    if (longitudinalG != null) {
      if (longitudinalG > 0) {
        session.maxAccelerationG = session.maxAccelerationG == null || longitudinalG > session.maxAccelerationG!
            ? longitudinalG
            : session.maxAccelerationG;
      } else if (longitudinalG < 0) {
        final magnitude = -longitudinalG;
        session.maxDecelerationG = session.maxDecelerationG == null || magnitude > session.maxDecelerationG!
            ? magnitude
            : session.maxDecelerationG;
      }
    }
    final lateralG = snapshot.lateralG;
    if (lateralG != null) {
      final magnitude = lateralG.abs();
      session.maxLateralG = session.maxLateralG == null || magnitude > session.maxLateralG! ? magnitude : session.maxLateralG;
    }
    final gForceMagnitude = snapshot.gForceMagnitude;
    if (gForceMagnitude != null) {
      session.maxGForceMagnitude = session.maxGForceMagnitude == null || gForceMagnitude > session.maxGForceMagnitude!
          ? gForceMagnitude
          : session.maxGForceMagnitude;
    }

    _gnssQualityIndexSum += snapshot.gnssQuality.index;
    _gnssQualityIndexCount++;
    session.avgGnssQualityIndex = _gnssQualityIndexSum / _gnssQualityIndexCount;

    session.sampleCount++;
    _pendingSamples.add(
      DrivingSessionSample(
        timestamp: snapshot.timestamp,
        latitude: snapshot.latitude,
        longitude: snapshot.longitude,
        speedKmh: snapshot.speedKmh,
        altitudeMeters: snapshot.altitudeMeters,
        longitudinalG: snapshot.longitudinalG,
        lateralG: snapshot.lateralG,
        verticalG: snapshot.verticalG,
        pitchDegrees: snapshot.pitchDegrees,
        rollDegrees: snapshot.rollDegrees,
      ),
    );
    _unflushedCount++;

    unawaited(session.save()); // cheap — scalar fields only, written every sample so a crash loses at most the last partial second.
    if (_unflushedCount >= _flushEverySamples) {
      unawaited(_flush(session));
    }
    notifyListeners();
  }

  /// Appends [event] to the active session, if any (Fase 13 §33: "todo
  /// evento confirmado durante uma sessão ativa deverá ser associado à
  /// sessão") — a plain no-op the rest of the time, not an error condition:
  /// `EventDetectionEngine` runs continuously regardless of whether a
  /// session is being recorded (so events keep alerting/being detectable
  /// even with no trip in progress), and this is simply where that stream
  /// meets session persistence for whoever happens to be listening.
  ///
  /// This — not an inline detector of its own — is the whole of this
  /// class's Fase-13 responsibility: hysteresis, minimum-duration
  /// confirmation, and cooldown all already happened upstream, in
  /// `EventDetectionEngine`, before [event] ever reached here. Earlier
  /// phases had this class doing its own, separate edge+cooldown detection
  /// (no hysteresis, no minimum-duration confirmation) — that duplication
  /// is what moved out; this method's only remaining job is "given an
  /// already-confirmed event, translate and persist it."
  void recordDetectedEvent(DetectedEvent event) {
    final session = _activeSession;
    if (session == null) return;
    final snapshot = event.snapshot;
    session.events.add(
      DrivingSessionEvent(
        type: _toSessionEventType(event.type),
        timestamp: event.timestamp,
        magnitude: event.value,
        id: '${event.timestamp.microsecondsSinceEpoch}-${event.type.name}',
        durationMs: event.duration?.inMilliseconds,
        latitude: snapshot.latitude,
        longitude: snapshot.longitude,
        speedKmh: snapshot.speedKmh,
        altitudeMeters: snapshot.altitudeMeters,
        longitudinalG: snapshot.longitudinalG,
        lateralG: snapshot.lateralG,
        resultantG: snapshot.gForceMagnitude,
        severity: event.severity,
      ),
    );
    unawaited(session.save());
    notifyListeners();
  }

  Future<void> _flush(DrivingSession session, {bool force = false}) async {
    if (_pendingSamples.isEmpty && !force) return;
    // Hive deserializes a stored List back as a plain `List<dynamic>`, not
    // the exact `List<DrivingSessionSample>` it was written as — an
    // unchecked cast to the generic type fails at runtime even though every
    // element genuinely is one; `List<T>.from` performs the (safe, since
    // every element really is a DrivingSessionSample) per-element cast
    // instead.
    final raw = await _samplesBox.get(session.id) as List?;
    final existing = raw == null ? <DrivingSessionSample>[] : List<DrivingSessionSample>.from(raw);
    existing.addAll(_pendingSamples);
    await _samplesBox.put(session.id, existing);
    _pendingSamples.clear();
    _unflushedCount = 0;
  }

  /// Recovers from an app process killed mid-recording (Fase 11 §22-23):
  /// without a foreground service, this app cannot keep recording while
  /// backgrounded/killed (documented limitation — see the Fase 11 delivery
  /// report), but every session is checkpointed incrementally (see this
  /// class's own doc), so the *data* already flushed to Hive up to that
  /// point is never lost. What was missing before this method existed: a
  /// session killed before [stopSession] ever ran stayed `isActive` (no
  /// `endTime`) forever, which made it permanently invisible on the History
  /// screen (`visibleSessionsSortedByRecency` explicitly excludes active
  /// sessions) even though its samples were safely on disk — a real data
  /// *visibility* bug, not a data-loss one. Call once at app startup,
  /// before constructing a [DrivingSessionRecorder] for the new run: any
  /// session already `isActive` at that point cannot belong to the
  /// in-memory instance being constructed (which hasn't started anything
  /// yet), so it's unambiguously an orphan from a previous run.
  static Future<void> reclaimOrphanedSessions() async {
    final orphans = _sessionsBox.values.where((s) => s.isActive).toList();
    for (final session in orphans) {
      final raw = await _samplesBox.get(session.id) as List?;
      final samples = raw == null ? <DrivingSessionSample>[] : List<DrivingSessionSample>.from(raw);
      session.endTime = samples.isEmpty ? session.startTime : samples.last.timestamp;
      session.sampleCount = samples.length;
      await session.save();
    }
  }
}

/// Pure mapping between the detection-layer [DetectedEventType] and the
/// persistence-layer [DrivingSessionEventType] — pulled out as a top-level
/// function so it's independently unit-testable without a whole recorder
/// instance behind it.
@visibleForTesting
DrivingSessionEventType detectedEventTypeToSessionEventType(DetectedEventType type) => _toSessionEventType(type);

DrivingSessionEventType _toSessionEventType(DetectedEventType type) {
  switch (type) {
    case DetectedEventType.hardAcceleration:
      return DrivingSessionEventType.hardAcceleration;
    case DetectedEventType.hardBraking:
      return DrivingSessionEventType.hardBraking;
    case DetectedEventType.hardCorneringLeft:
      return DrivingSessionEventType.hardCorneringLeft;
    case DetectedEventType.hardCorneringRight:
      return DrivingSessionEventType.hardCorneringRight;
    case DetectedEventType.highResultantG:
      return DrivingSessionEventType.highResultantG;
    case DetectedEventType.speedLimitExceeded:
      return DrivingSessionEventType.speedLimitExceeded;
    case DetectedEventType.stopped:
      return DrivingSessionEventType.stopped;
    case DetectedEventType.resumed:
      return DrivingSessionEventType.resumed;
    case DetectedEventType.gnssLost:
      return DrivingSessionEventType.gnssLost;
    case DetectedEventType.gnssRecovered:
      return DrivingSessionEventType.gnssRecovered;
    case DetectedEventType.altitudeRisingSignificant:
      return DrivingSessionEventType.altitudeRisingSignificant;
    case DetectedEventType.altitudeFallingSignificant:
      return DrivingSessionEventType.altitudeFallingSignificant;
  }
}

/// Removes one session's summary, trajectory, and (Fase 15) dashcam data —
/// see `SessionHistoryScreen`'s deletion UI. A plain top-level function (not
/// a `SessionRepository` class) since this is the only place session data is
/// ever removed and the screens already talk to these same boxes directly
/// (see `SessionHistoryScreen`/`SessionDetailScreen`) — introducing a
/// repository abstraction for one operation would be a parallel structure
/// for its own sake, not a technical necessity.
Future<void> deleteDrivingSession(String id) async {
  final samplesBox = Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
  await samplesBox.delete(id);
  final sessionsBox = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  await sessionsBox.delete(id);
  await _deleteDashcamDataForSession(id);
}

/// Best-effort: a missing/already-gone clip file (e.g. already evicted by
/// storage-quota enforcement) is not an error here — the goal is "nothing
/// dashcam-related survives this session's deletion", not "every file must
/// have existed".
Future<void> _deleteDashcamDataForSession(String id) async {
  final videosBox = Hive.box(HiveBoxNames.dashcamSessionVideos);
  final raw = videosBox.get(id) as List?;
  if (raw != null) {
    final clips = List<DashcamClipRecord>.from(raw);
    for (final clip in clips) {
      try {
        final file = File(clip.filePath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort, see doc above.
      }
    }
  }
  await videosBox.delete(id);

  try {
    final telemetryFile = await DashcamTelemetryWriter.fileForSession(id);
    if (await telemetryFile.exists()) await telemetryFile.delete();
  } catch (_) {
    // Best-effort, see doc above.
  }
}
