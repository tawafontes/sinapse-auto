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
import 'dashcam_clip_files.dart' show canonicalClipArtifactsIn, dashcamClipsDirectory;
import 'dashcam_telemetry_writer.dart';
import 'gnss_quality.dart';
import 'hive_boxes.dart';
import 'outlier_rejector.dart' show isPlausibleSpeedKmh;

/// Recorder-level state — distinct from [DrivingSessionState], which only
/// exists once a [DrivingSession] object does. IDLE has no session object at
/// all, which is exactly why it lives here instead of as a third value on
/// that enum.
///
/// Fase 16.2-R4.3-R2.6.4: derived, never stored (see
/// [DrivingSessionRecorder.state]). A session whose `endTime` is set is being
/// finalized — it stays the recorder's active session until its samples and its
/// own record are durably written, and it is never handed out again as if it
/// were still recording:
///  * [finalizing] — a [DrivingSessionRecorder.stopSession] attempt is in
///    flight;
///  * [finalizationFailed] — the last attempt failed (e.g. a Hive box was
///    unavailable); the session's data is kept in memory, nothing is
///    discarded, and calling [DrivingSessionRecorder.stopSession] again retries
///    only what is still missing.
enum DrivingSessionRecorderState { idle, recording, finalizing, finalizationFailed }

/// Fase 16.2-R4.3-R2.6.4: a start request refused because the current session
/// cannot be handed out — it is being finalized, or its finalization failed
/// and must be retried first. Thrown before anything is touched. A distinct
/// type so a UI can treat this EXPECTED refusal (e.g. a start control rendered
/// a moment before the refusal became true) without also silencing
/// [StateError]s that reveal real bugs.
class SessionAdmissionRejected extends StateError {
  SessionAdmissionRejected(super.message);
}

/// Fase 16.2-R4.3-R2.6.6 (D1): a deletion refused because a recorder still
/// controls the session — it is recording, being finalized, or its
/// finalization failed and awaits a retry (see
/// [DrivingSessionRecorder.controllingState]). Thrown by [deleteDrivingSession]
/// before anything is removed. A distinct type, like [SessionAdmissionRejected],
/// so a UI can handle this EXPECTED refusal without silencing real errors.
class SessionDeletionRejected extends StateError {
  SessionDeletionRejected(super.message);
}

/// Fase 16.2-R4.3-R2.6.6: see [DrivingSessionRecorder.sessionControlChanges].
class _SessionControlNotifier extends ChangeNotifier {
  void changed() => notifyListeners();
}

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
  DrivingSessionRecorder(this._snapshotStream) {
    _authorities.add(this);
  }

  final Stream<TelemetrySnapshot> _snapshotStream;

  /// Fase 16.2-R4.3-R2.6.6 (D1 — a session deleted from the history while its
  /// finalization was pending: its retry became impossible, or it recreated
  /// the deleted session, or left an ended record without samples): the
  /// recorders of this process that may still write a session. Membership is
  /// only "may still write"; WHICH session and in WHAT state is always read
  /// live from the recorder ([controllingState]) — this is not a second
  /// finalization state. Static because the deletion layer
  /// ([deleteDrivingSession]) is reached without any recorder instance (the
  /// History screen does not hold the app's `DrivingSessionHost`) and must hold
  /// for every caller, not only for a UI that happens to know the recorder. A
  /// recorder leaves it when it is disposed, or — if a finalization attempt was
  /// in flight then — when that
  /// attempt settles: until then that attempt still writes the session.
  static final Set<DrivingSessionRecorder> _authorities = {};

  /// Fase 16.2-R4.3-R2.6.12 (independent review of R2.6.11, P2): the ids of the
  /// sessions a recorder of this process created and has NOT durably finalized
  /// — from [startSession] until a finalization attempt has written everything
  /// (the samples, then the record with its end time; see [stopSession]).
  ///
  /// While an id is here, the instance the sessions box holds for it — the
  /// recorder's own — may carry what exists only in memory: the end time of a
  /// finalization that failed or is still in flight, counts whose own writes
  /// failed. Writing that instance publishes all of it, so nobody but its
  /// recorder may (see [persistSessionTelemetryOutcome]).
  ///
  /// Unlike [_authorities], DISPOSING THE RECORDER DOES NOT REMOVE THE ID.
  /// [_authorities] answers "may a recorder still write this session?" — no,
  /// once it is disposed, which is what frees the session for a deletion. This
  /// answers "is what the box holds for it durable?" — and a disposed recorder
  /// leaves that instance exactly as unconfirmed as it was. Reproduced with
  /// only [_authorities] to ask: a recorder whose finalization had failed was
  /// disposed (the app's root torn down), the session's telemetry file closed
  /// afterwards, and its outcome, finding no recorder in control, wrote the
  /// record — end time of the failed finalization included: finalized on disk
  /// with 3 samples declared and none stored, which the next start's reclaim
  /// (active records only) no longer repaired.
  ///
  /// Not a second finalization state: nothing is decided from it except that
  /// one refusal, and the recorder's state is still derived ([state]). An id
  /// leaves on the one event that makes the record durable; one whose recorder
  /// was disposed first stays for the rest of the process (one id per session
  /// abandoned that way). A new process starts empty — its records are exactly
  /// what their files hold, and its startup recovery reconciles the ones a
  /// previous run left unfinalized.
  ///
  /// Fase 16.2-R4.3-R2.6.13: that end time is now unconfirmed
  /// ([DrivingSession.endTime]) — no write stores it, with or without this
  /// refusal. The refusal stays: the counts are still only in memory, and the
  /// result of a telemetry file is not attached to a session nobody finalized.
  static final Set<String> _unfinalizedSessionIds = {};

  static final _SessionControlNotifier _controlChanges = _SessionControlNotifier();

  /// Fase 16.2-R4.3-R2.6.6: notified (after the current slice) whenever a
  /// recorder starts or stops controlling a session, or the state of one it
  /// controls changes — including transitions that write nothing to the
  /// sessions box (a STOP's start, a failed samples checkpoint, a dispose), so
  /// a history list watching only that box would show a stale deletability.
  static Listenable get sessionControlChanges => _controlChanges;

  /// Fase 16.2-R4.3-R2.6.6: the state in which a recorder of this process
  /// still controls session [sessionId] — [DrivingSessionRecorderState.recording],
  /// [DrivingSessionRecorderState.finalizing] or
  /// [DrivingSessionRecorderState.finalizationFailed] — or `null` when none
  /// does and the session can be deleted.
  ///
  /// A session id enters a recorder's control exactly once, when
  /// [startSession] creates it under a fresh id, and leaves it exactly once:
  /// when its finalization has written everything (every sample flush and
  /// per-sample record save was queued before the finalization's own writes,
  /// which it awaits), or when its recorder is disposed with no attempt in
  /// flight (it can then write nothing more). Once `null`, it is `null` for
  /// that id for the rest of the process — which is why a deletion authorized
  /// by this check cannot be overtaken by a stop or a retry of that session
  /// (Fase 16.2-R4.3-R2.6.7: including a stop on the disposed recorder, which
  /// is refused — see [stopSession]).
  ///
  /// In-process only: after the app process dies nothing records that a
  /// session's finalization was still pending (see [deleteDrivingSession]).
  static DrivingSessionRecorderState? controllingState(String sessionId) => _controlling(sessionId)?.state;

  /// The recorder of this process that still controls [sessionId], if any —
  /// see [controllingState].
  static DrivingSessionRecorder? _controlling(String sessionId) {
    for (final recorder in _authorities) {
      if (recorder._activeSession?.id == sessionId) return recorder;
    }
    return null;
  }

  /// Publishes a change in what this recorder controls (see
  /// [sessionControlChanges]); a disposed recorder with no attempt in flight
  /// can write nothing more and stops being an authority here.
  void _controlChanged() {
    if (_disposed && _finalization == null) _authorities.remove(this);
    scheduleMicrotask(_controlChanges.changed);
  }

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

  /// Fase 16.2-R4.3-R2.6.4: the in-flight finalization attempt of
  /// [_activeSession], if any — joined by a concurrent [stopSession] instead
  /// of running a second one.
  Future<void>? _finalization;

  /// Fase 16.2-R4.3-R2.6.4: why the last finalization attempt failed — kept
  /// only for observability (see [lastFinalizationError]); the state itself is
  /// derived ([state]).
  Object? _lastFinalizationError;

  DrivingSession? get activeSession => _activeSession;

  /// Whether a session object is held — recording, or still being finalized
  /// (see [state]); unchanged meaning, so existing callers keep treating a
  /// session that is not yet durably closed as present.
  bool get isRecording => _activeSession != null;

  DrivingSessionRecorderState get state {
    final session = _activeSession;
    if (session == null) return DrivingSessionRecorderState.idle;
    if (session.endTime == null) return DrivingSessionRecorderState.recording;
    return _finalization != null ? DrivingSessionRecorderState.finalizing : DrivingSessionRecorderState.finalizationFailed;
  }

  /// Fase 16.2-R4.3-R2.6.4: the active session has ended but is not durably
  /// closed yet ([DrivingSessionRecorderState.finalizing] or
  /// [DrivingSessionRecorderState.finalizationFailed]). While true, no new
  /// session can start and the current one is never handed out as an alias.
  bool get hasPendingFinalization => _activeSession?.endTime != null;

  /// Fase 16.2-R4.3-R2.6.4: the error of the last finalization attempt, while
  /// the state is [DrivingSessionRecorderState.finalizationFailed]; `null`
  /// otherwise.
  Object? get lastFinalizationError => state == DrivingSessionRecorderState.finalizationFailed ? _lastFinalizationError : null;

  /// Fase 16.2-R4.3-R2.6.5: accepted samples not yet known to be stored (see
  /// [_flush]).
  @visibleForTesting
  int get pendingSampleCountForTest => _pendingSamples.length;

  /// Starts a new session. No-op (returns the already-active session) if
  /// one is already recording — callers should check [isRecording] first,
  /// but this stays safe either way rather than silently starting a second,
  /// overlapping session.
  ///
  /// Fase 16.2-R4.3-R2.6.1 (§3, independent pre-audit P2-2 — "STOP reentrante
  /// durante a publicação"): [onCreated], when given, runs synchronously and
  /// exactly once — only when a NEW session was created, never for the
  /// already-active alias above — after the session is fully initialized and
  /// already visible as [activeSession] but BEFORE any listener is notified.
  /// [notifyListeners] hands control to arbitrary synchronous listeners, one of
  /// which may legitimately call back into whoever owns this recorder (e.g.
  /// `DashcamSessionController.stopSession()`); a caller that keeps its own
  /// per-session bookkeeping registers it here so that, by the time any
  /// observer can react, the new session is already identifiable — and
  /// therefore cancellable — on the caller's side too. It is a registration
  /// point, not a second notification channel: it must not call back into this
  /// recorder.
  ///
  /// Fase 16.2-R4.3-R2.6.4: a session whose finalization is pending
  /// ([hasPendingFinalization]) is NOT handed back as that alias — it has
  /// ended; resurrecting it would record video for a session whose telemetry
  /// subscription is gone. That call throws [SessionAdmissionRejected] instead,
  /// before touching anything. And the sessions box is resolved BEFORE any
  /// state changes: if it is unavailable the call fails with nothing created —
  /// no active session left behind, no subscription, no announcement.
  DrivingSession startSession({void Function(DrivingSession session)? onCreated}) {
    final existing = _activeSession;
    if (existing != null) {
      if (existing.endTime != null) {
        throw SessionAdmissionRejected(
          'startSession() rejected: session ${existing.id} has ended and is still being finalized '
          '(${state.name}); finalize it (stopSession()) before starting a new one.',
        );
      }
      return existing;
    }

    // Fase 16.2-R4.3-R2.6.4 (independent review, START Hive failure): resolved
    // first — `Hive.box()` throws synchronously when the box is not open, and
    // doing that after `_activeSession` was set left an orphan session that no
    // caller knew about and a later start silently reused.
    final sessionsBox = _sessionsBox;

    final session = DrivingSession(id: _newSessionId(), startTime: DateTime.now());
    _activeSession = session;
    _unfinalizedSessionIds.add(session.id);
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

    unawaited(sessionsBox.put(session.id, session));
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
    try {
      onCreated?.call(session);
    } finally {
      // Even a failing registration callback must not leave the session
      // created-but-unannounced.
      notifyListeners();
      _controlChanged();
    }
    return session;
  }

  /// Ends the active session (no-op if none is active) — only cancels this
  /// recorder's own subscription to the shared snapshot stream; every other
  /// consumer of that stream (dashboard tiles, Diagnostics, a HUD,
  /// `EventDetectionEngine` itself) is completely unaffected, and no sensor
  /// is told to stop.
  ///
  /// Fase 16.2-R4.3-R2.6.4 (independent review, STOP Hive failure): this is a
  /// FINALIZATION with checkpoints, not a one-shot. From its synchronous prefix
  /// the session has ended (`endTime`, set once and preserved by retries) and
  /// the state is [DrivingSessionRecorderState.finalizing] — published to
  /// listeners right away. The session stays [activeSession] until BOTH its
  /// samples and its own record are durably written; only then is it
  /// cleared. If a write fails, the error reaches the caller, nothing is
  /// discarded, and the state becomes
  /// [DrivingSessionRecorderState.finalizationFailed]: the session is no longer
  /// admissible as a live one (see [startSession]) and calling this again
  /// retries only what is still missing —
  ///  * samples: reconciled by logical position against what is stored, then
  ///    only the ones still missing are written (see [_flush], Fase
  ///    16.2-R4.3-R2.6.5) — a retry never appends a sample twice, even when an
  ///    earlier `put` wrote them and still threw;
  ///  * the session record: persisted by its stable id (see
  ///    [_persistSessionRecord]), including when this instance is still bound
  ///    to a box that was closed and reopened.
  /// A call while an attempt is in flight joins it. Nothing here retries on its
  /// own, and nothing re-subscribes to the snapshot stream.
  ///
  /// Fase 16.2-R4.3-R2.6.13 (independent review of R2.6.12, P2): the end time
  /// set here is UNCONFIRMED ([DrivingSession.endUnconfirmed]) — the session has
  /// ended for everyone who reads it, and no write of its record stores that
  /// until the terminal checkpoint ([_finalize]). The record writes requested
  /// before the STOP (the start's put, a save per sample and per event) are
  /// awaited by nobody and may still be waiting in the box's queue; hive
  /// serializes the instance when each of them RUNS, and one that ran after
  /// this point used to store the end time — a record finished on disk before
  /// its samples were stored and, when their write then failed or the process
  /// died, for good: the startup recovery reclaims active records. Now
  /// whichever of them runs, and whenever, stores a session that is still
  /// active.
  Future<void> stopSession() {
    final session = _activeSession;
    if (session == null) return Future<void>.value();
    final inFlight = _finalization;
    if (inFlight != null) return inFlight;
    // Fase 16.2-R4.3-R2.6.7 (DL5 of the R2.6.6 pre-audit): a disposed recorder
    // starts no new attempt. It stopped controlling its session when it was
    // disposed (or when the attempt in flight then settled) and was removed from
    // [_authorities]; R2.6.6 put it back here, so a stop on a recorder disposed
    // in finalizationFailed rewrote a session the history had deleted meanwhile
    // (record and samples back, reproduced). The attempt already in flight at
    // dispose is joined above and keeps its semantics; there is no retry after
    // dispose.
    if (_disposed) {
      return Future<void>.error(
        StateError(
          'stopSession() rejected: this recorder was disposed and no longer controls session ${session.id} '
          '(${state.name}); nothing was written.',
        ),
      );
    }

    // Kept by a retry: a session that already ended is not ended again.
    session.endUnconfirmed(DateTime.now());
    _lastFinalizationError = null;
    final attempt = Completer<void>();
    _finalization = attempt.future;
    // Published after this slice, not synchronously: a listener that itself
    // called stopSession() (directly, or through a controller) must not be
    // re-entered mid-call. [state] already reads `finalizing` for anyone who
    // asks synchronously.
    scheduleMicrotask(_notifyIfAlive);
    // Fase 16.2-R4.3-R2.6.6: an attempt writes the session, so its recorder is an
    // authority while it runs. A live recorder is always one (see [_authorities]);
    // a disposed one cannot get here (R2.6.7, above).
    _controlChanged();
    // The attempt is settled BEFORE listeners are notified, so a listener (or a
    // notification on an already-disposed recorder) can never leave the
    // caller's Future pending.
    unawaited(
      _finalize(session).then(
        (_) {
          _finalization = null;
          // Its samples and its record, end time included, are written: from
          // here on the instance the box holds is what the disk holds.
          _unfinalizedSessionIds.remove(session.id);
          if (identical(_activeSession, session)) _activeSession = null;
          _controlChanged();
          attempt.complete();
          _notifyIfAlive();
        },
        onError: (Object error, StackTrace stackTrace) {
          _finalization = null;
          _lastFinalizationError = error;
          _controlChanged();
          attempt.completeError(error, stackTrace);
          _notifyIfAlive();
        },
      ),
    );
    return attempt.future;
  }

  /// The checkpoints of one finalization attempt — see [stopSession]. In this
  /// order, each one only after the previous completed:
  ///  1. no further sample: the subscription is cancelled;
  ///  2. every accepted sample is stored: [_flush] reconciles the stored list
  ///     against all of them and writes what is missing;
  ///  3. the terminal checkpoint: the end time is confirmed and the record is
  ///     written.
  ///
  /// Fase 16.2-R4.3-R2.6.13: step 3 is the ONLY point where the end time enters
  /// what a write of the record stores, and it is reached only when step 2
  /// returned without error in this very attempt — so a record that reads as
  /// finished on disk declares the samples stored for it. No queue was added:
  /// every write of the record goes through the box's own, in the order it was
  /// requested, and each stores the one instance as it is when it runs. The
  /// writes requested before this one are therefore ahead of it and store
  /// either a session still active (they ran before the confirmation) or this
  /// same final state (after it) — never an older state on top of a newer one.
  Future<void> _finalize(DrivingSession session) async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    // Queued after any incremental flush still in flight, and reconciled
    // against what is stored (see [_flush]): writes only what is missing.
    await _flush(session, force: true);
    // In the slice that requests the write below: nothing runs in between.
    session.confirmEndTime();
    await _persistSessionRecord(session);
  }

  /// Fase 16.2-R4.3-R2.6.4: writes [session]'s own record under its stable id
  /// into the CURRENTLY open sessions box (throws, like any unavailable box,
  /// when it is not open — the attempt then fails and stays retryable):
  ///  * bound to that box → `save()`;
  ///  * never stored (the start's own `put` never landed) → `put` it now;
  ///  * still bound to a box instance that was closed (hive 2.2.3 keeps the
  ///    binding across a close; that instance can neither `save()` nor be
  ///    `put` into the reopened box) → `put` an unbound
  ///    [DrivingSession.detachedCopy] under the same id. The in-memory
  ///    instance is dropped right after (the session is cleared on success),
  ///    so the durable record is the only surviving copy.
  Future<void> _persistSessionRecord(DrivingSession session) {
    final box = _sessionsBox;
    final bound = session.box;
    if (identical(bound, box)) return session.save();
    if (bound == null) return box.put(session.id, session);
    return box.put(session.id, session.detachedCopy());
  }

  /// Fase 14 §2/§18 (stream-leak audit): [stopSession] is the normal path
  /// that cancels [_sub], but a caller that tears this recorder down
  /// directly — `DrivingSessionHost.dispose()` (the app's own teardown; before
  /// Fase 16.2-R4.3-R2.6.8, every `DashboardScreen.dispose()`) does exactly
  /// this, unconditionally, without checking [isRecording] first — would
  /// otherwise leave [_sub] (a listener on the shared, ref-counted
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
  ///
  /// Fase 16.2-R4.3-R2.6.6: a disposed recorder stops controlling its session
  /// ([controllingState]) — it can neither collect nor retry anything — except
  /// while a finalization attempt is still in flight: that attempt still writes
  /// the session, so it stays protected from deletion until the attempt settles.
  /// Fase 16.2-R4.3-R2.6.7: and it never starts another one ([stopSession]
  /// refuses on a disposed recorder).
  /// Fase 16.2-R4.3-R2.6.12: a session it did not durably finalize stays
  /// unfinalized ([_unfinalizedSessionIds]) — disposing writes nothing and
  /// confirms nothing, so the end time of a failed finalization this recorder
  /// leaves in memory is still not something anyone else may write.
  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    _controlChanged();
    super.dispose();
  }

  /// Fase 16.2-R4.3-R2.6.4: a finalization can settle after this recorder was
  /// disposed (whole-screen teardown mid-stop); notifying then would throw.
  bool _disposed = false;

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  void _onSnapshot(TelemetrySnapshot snapshot) {
    final session = _activeSession;
    // Fase 16.2-R4.3-R2.6.4: a session being finalized is never extended.
    if (session == null || session.endTime != null) return;

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
    // Fase 16.2-R4.3-R2.6.5: counted since the last flush was REQUESTED, not
    // completed — a slow or failed flush used to leave the count above the
    // threshold, so every following sample started one more concurrent flush.
    if (_unflushedCount >= _flushEverySamples) {
      _unflushedCount = 0;
      unawaited(_flush(session).catchError(_reportIncrementalFlushFailure));
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
    // Fase 16.2-R4.3-R2.6.4: an ended session (being finalized, or awaiting a
    // finalization retry) does not collect events that happened after its end.
    if (session == null || session.endTime != null) return;
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

  /// Fase 16.2-R4.3-R2.6.5: the tail of the flush queue — see [_flush].
  Future<void> _flushQueue = Future<void>.value();

  /// Checkpoints [session]'s pending samples. Runs strictly after every flush
  /// requested before it (incremental or final), whatever their outcome.
  ///
  /// Fase 16.2-R4.3-R2.6.5 (independent review, P2 — ambiguous Hive write):
  /// every flush used to read the stored list, append the pending samples,
  /// `put` it and then clear ALL pending samples. Reproduced on hive 2.2.3:
  ///  * `LazyBox.put` writes the frame and updates the keystore BEFORE it
  ///    runs compaction; a compaction failure (e.g. `PathAccessException`
  ///    opening the `.hivec` file) makes `put` throw with the new list already
  ///    visible. The pending samples were kept, the retry appended them again:
  ///    40,41,42 → 40,41,42,40,41,42 (sampleCount still 3);
  ///  * samples accepted WHILE a flush was inside its `put` (compaction
  ///    rewrites the whole file) were dropped by that `clear()`, and concurrent
  ///    flushes computed from the same stored prefix and overwrote each other
  ///    (up to 10 of 20 accepted samples lost).
  /// Now:
  ///  * one flush at a time ([_flushQueue]), so no two compute from the same
  ///    stored prefix;
  ///  * the identity of a sample is its LOGICAL POSITION in the session:
  ///    [_pendingSamples] always holds the last `_pendingSamples.length` of the
  ///    `sampleCount` samples accepted so far, in order, so the first
  ///    `sampleCount - _pendingSamples.length` are the ones known to be
  ///    stored. Before writing, the stored list is read back and every pending
  ///    sample already stored at its position (a write that took effect
  ///    although its `put` threw) is dropped from the pending ones —
  ///    reconciled by position, never by value: identical readings (a parked
  ///    car) are distinct samples;
  ///  * after a `put` completes, only the samples of THAT candidate leave the
  ///    pending ones; any accepted meanwhile stay for the next flush;
  ///  * a stored list that cannot be this session's prefix (shorter than what
  ///    is known to be stored, or longer than everything accepted) is not
  ///    "repaired": the flush fails with a diagnostic and nothing is cleared or
  ///    written — the finalization then stays pending (see [stopSession]).
  ///
  /// Durability: a sample leaves the pending ones once a `put` containing it
  /// completed, or once it is read back from the box. For a LazyBox both mean
  /// the frame was handed to the file (`writeFrames` completed — the keystore
  /// is only updated after it); hive 2.2.3 never flushes/fsyncs the file on
  /// `put`, so either survives the app process being killed, and neither is
  /// guaranteed against the OS crashing or power loss.
  Future<void> _flush(DrivingSession session, {bool force = false}) {
    final run = _flushQueue.then((_) => _flushOnce(session, force: force));
    _flushQueue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _flushOnce(DrivingSession session, {required bool force}) async {
    // Defensive: pending samples always belong to the active session, whose
    // finalization awaits every flush queued for it before a next session can
    // start.
    if (!identical(_activeSession, session)) return;
    if (_pendingSamples.isEmpty && !force) return;
    final box = _samplesBox;
    // Hive deserializes a stored List back as a plain `List<dynamic>`, not
    // the exact `List<DrivingSessionSample>` it was written as — an
    // unchecked cast to the generic type fails at runtime even though every
    // element genuinely is one; `List<T>.from` performs the (safe, since
    // every element really is a DrivingSessionSample) per-element cast
    // instead.
    final raw = await box.get(session.id) as List?;
    final stored = raw == null ? <DrivingSessionSample>[] : List<DrivingSessionSample>.from(raw);

    final knownStored = session.sampleCount - _pendingSamples.length;
    final alreadyStored = stored.length - knownStored;
    if (alreadyStored < 0 || alreadyStored > _pendingSamples.length) {
      throw StateError(
        'Samples of session ${session.id} cannot be reconciled: ${stored.length} stored, '
        '$knownStored known to be stored, ${session.sampleCount} accepted. '
        'Nothing was cleared or written.',
      );
    }
    _pendingSamples.removeRange(0, alreadyStored);
    // Everything is stored and the entry exists: nothing to write.
    if (_pendingSamples.isEmpty && raw != null) return;

    final candidate = List<DrivingSessionSample>.of(_pendingSamples);
    await box.put(session.id, stored..addAll(candidate));
    _pendingSamples.removeRange(0, candidate.length);
  }

  /// An incremental flush that failed changes nothing that matters: its
  /// samples stay pending and the next flush (at the latest the finalization's,
  /// which reports its own failure) reconciles and retries them. Still
  /// reported, as before (it used to surface as an uncaught async error).
  static void _reportIncrementalFlushFailure(Object error, StackTrace stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'driving session recorder',
        context: ErrorDescription('while checkpointing samples (they stay pending; the next flush reconciles them)'),
      ),
    );
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
  ///
  /// Fase 16.2-R4.3-R2.6.7: a record marked for deletion is not reclaimed — it
  /// is being deleted ([completePendingSessionDeletions]), and closing it here
  /// could race that deletion's removal of the record.
  ///
  /// Fase 16.2-R4.3-R2.6.8 (R4.3-D2): it runs only from
  /// [recoverDrivingSessionsAtStartup]. `DashboardScreen.initState` used to run
  /// it on every mount — and a recreated dashboard is mounted while the one it
  /// replaces is still on screen (the Navigator keeps removed routes until the
  /// new one finishes pushing), so it closed the session the live recorder was
  /// still recording, which then read as finalizationFailed with its pending
  /// samples stranded (reproduced 3/3 through Tema → Concluir and "+" → Continuar).
  static Future<void> reclaimOrphanedSessions() async {
    final orphans = _sessionsBox.values.where((s) => s.isActive && !s.deletionPending).toList();
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
///
/// Fase 16.2-R4.3-R2.6.6 (D1): refuses, with [SessionDeletionRejected] and
/// before anything is removed, a session a recorder still controls — recording,
/// finalizing, or awaiting a finalization retry
/// ([DrivingSessionRecorder.controllingState]). Reproduced before this check,
/// through the real history screen (whose list shows a pending session: the
/// sessions box caches the recorder's own instance, whose endTime is already
/// set): deleting a session whose samples were partly checkpointed made every
/// retry fail ("cannot be reconciled") and kept START refused until the app
/// restarted; deleting one with nothing stored let the retry recreate it; and
/// deleting one while its final sample put ran left an ended record without
/// samples that survived a restart. This check — not the history UI — is the
/// authority, so it holds for any caller. It runs synchronously, in the same
/// slice that queues the first removal, and a session released by its
/// recorder can never be controlled again (see
/// [DrivingSessionRecorder.controllingState]), so no stop or retry can write it
/// after a deletion was authorized.
///
/// Limitation, not covered here: the check is in-process. After the app
/// process dies, nothing on disk says a session's FINALIZATION was pending —
/// it looks like any finished session and is deletable; recovering it after a
/// restart is outside this check.
///
/// Fase 16.2-R4.3-R2.6.7 — a DURABLE deletion (reproduced before this round,
/// scratchpad/fase16_2_r4_3_r2_6_7/01_prefix_repro): the dashcam kept indexing a
/// clip of a session deleted while its STOP was still settling (the recorder
/// releases a session before the controller's immediate index pass, and a
/// retained native STOP publishes later still) — an index entry and a clip
/// file nobody could reach; a clip published while this function was deleting
/// files was left without ANY index; and a deletion interrupted after the
/// record was gone (process killed, a box failing) left index, clips and
/// telemetry out of the UI's reach forever. Now, after the check above:
///  1. every box it needs is resolved — one unavailable fails the deletion
///     with nothing done;
///  2. the durable intent: the record is marked
///     ([DrivingSession.deletionPending]) and written, BEFORE anything is
///     removed. A record that does not exist gets a marked stand-in, so the
///     intent is durable in every case;
///  3. in the same slice that write returns, the deletion is committed in
///     memory ([sessionDeletionCommitted]): the clip-index writer checks it in
///     the slice of its own write and neither indexes nor keeps a clip of the
///     session any more;
///  4. samples; 5. clip files, then their index (a clip file some index
///     references for ANOTHER session is left alone) — Fase 16.2-R4.4-R1:
///     the files are the indexed paths AND every canonical clip and partial
///     copy in `dashcam_clips/` whose name says it is this session's
///     ([canonicalClipArtifactsIn]: by the decoded session id, never by
///     substring, time or a legacy name), listed after step 3: a canonical
///     file is a durable obligation to index it (`reconcileCanonicalClipsAtStartup`
///     in `dashcam_clip_index.dart`), so leaving it behind would let the
///     session's video outlive the deletion. A clips directory that cannot be
///     resolved has no known files (as for telemetry); one that exists and
///     cannot be listed fails the deletion and keeps the marker; 6. telemetry;
///  7. the record — the marker — last.
/// Every step is idempotent (a missing entry or file is already done), so a
/// deletion that failed or was killed after step 2 is simply run again: from
/// the History (the marked record stays listed as pending) or, at the next
/// start, by [completePendingSessionDeletions]. A step never swallows its
/// failure any more: a file that still exists fails the deletion and keeps
/// the marker (the one exception is a telemetry location that cannot be
/// resolved at all — no telemetry file is known then, as before).
///
/// A write that fails is never presumed rolled back (hive 2.2.3 can write a
/// frame and still throw, R2.6.5): if the marker's write throws, the deletion
/// stops there — nothing removed, nothing committed — and the in-memory
/// record keeps reading as marked, which is what may be on disk; a later
/// deletion (or the next start) writes it again before removing anything.
///
/// Removing the record last is safe because no clip is ever indexed for a
/// deleted session. Fase 16.2-R4.4-R1 replaced the premise this rested on — "in
/// a new process no clip of a session of an earlier process exists to be
/// indexed" no longer holds: a clip now carries its session in its file name,
/// and the next start indexes it (`reconcileCanonicalClipsAtStartup`). The
/// invariant that holds instead: a clip is indexed for session S only by
/// `ensureClipIndexed`, with a name whose session is S, and only if either
/// (at runtime, a clip this process produced) S's deletion is not committed in
/// this process ([sessionDeletionCommitted]), or (at startup, a name found on
/// disk) S's record EXISTS and is NOT marked. This deletion commits before it
/// reads the index and before it selects S's files (indexed paths ∪ the
/// canonical clips and partials whose name says S); everything indexed before
/// the commit goes with the index; nothing is indexed after it in this
/// process; in a later process a record removed last means S is ABSENT, and
/// its canonical files are preserved as orphans, never indexed; a record still
/// marked is completed by [completePendingSessionDeletions] before the startup
/// reconciliation runs, and that reconciliation refuses it anyway.
///
/// A second call for the same session while one runs joins it.
Future<void> deleteDrivingSession(String id) async {
  final controlled = DrivingSessionRecorder.controllingState(id);
  if (controlled != null) {
    throw SessionDeletionRejected(
      'deleteDrivingSession($id) rejected: the session is still controlled by its recorder '
      '(${controlled.name}); nothing was removed. Finalize it (stopSession()) first.',
    );
  }
  final inFlight = _sessionDeletionsInFlight[id];
  if (inFlight != null) return inFlight;
  final run = _runSessionDeletion(id);
  _sessionDeletionsInFlight[id] = run;
  try {
    await run;
  } finally {
    if (identical(_sessionDeletionsInFlight[id], run)) _sessionDeletionsInFlight.remove(id);
  }
}

/// Fase 16.2-R4.3-R2.6.7: see [deleteDrivingSession] (step 3). Only ever grows
/// — by one id per deletion the user makes in a process — because a retained
/// native STOP of a deleted session can settle at any later time.
final Set<String> _committedSessionDeletions = {};

final Map<String, Future<void>> _sessionDeletionsInFlight = {};

/// Fase 16.2-R4.3-R2.6.7: whether the deletion of session [sessionId] was
/// durably decided in this process (its marker was written; see
/// [deleteDrivingSession]). The dashcam's clip-index writer — the only one,
/// `ensureClipIndexed` since Fase 16.2-R4.4-R1 — checks it synchronously in the
/// same slice as its index write: `true` means the session's clips must not be
/// indexed (nor re-attributed to any other session) and the files it produced
/// are discarded ([discardClipFilesOfDeletedSession]). A record that is merely
/// absent is not a deletion: a START whose `put` failed leaves a live session
/// without one. That is the RUNTIME guard, for clips this process produced; a
/// marker whose write failed decides nothing here (frozen X113). For a clip
/// found on disk at startup the guard is the record itself, read from disk:
/// it must exist and not be marked.
bool sessionDeletionCommitted(String sessionId) => _committedSessionDeletions.contains(sessionId);

/// The start time of the marked stand-in [deleteDrivingSession] writes for a
/// session without a record.
final DateTime _markerOnlyTime = DateTime.fromMillisecondsSinceEpoch(0);

Future<void> _runSessionDeletion(String id) async {
  final sessionsBox = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  final samplesBox = Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
  final videosBox = Hive.box(HiveBoxNames.dashcamSessionVideos);

  final record = sessionsBox.get(id);
  if (record == null) {
    await sessionsBox.put(id, DrivingSession(id: id, startTime: _markerOnlyTime, endTime: _markerOnlyTime, deletionPending: true));
  } else {
    record.deletionPending = true;
    // Fase 16.2-R4.3-R2.6.13: the marker is written on the record AS IT READS.
    // A session whose recorder was disposed before finalizing it carries an end
    // time no write stores ([DrivingSession.endTime]); this write is the
    // deletion's own — the session is being removed, nothing reconciles a
    // marked record, and an ended one is what the History goes on listing as a
    // pending deletion after a restart, should this one not finish.
    record.confirmEndTime();
    await sessionsBox.put(id, record);
  }
  _committedSessionDeletions.add(id);

  await samplesBox.delete(id);

  // Read once, after step 3: no entry can be added to it any more.
  final raw = videosBox.get(id) as List?;
  // Fase 16.2-R4.4-R1: listed after step 3 too — a canonical file published
  // from now on is refused by the index and discarded by its publisher.
  final paths = <String>{
    if (raw != null) for (final clip in List<DashcamClipRecord>.from(raw)) clip.filePath,
    ...await _canonicalClipArtifactsOf(id),
  };
  if (paths.isNotEmpty) await _deleteClipFiles(videosBox, paths.toList(), owner: id);
  await videosBox.delete(id);

  File? telemetryFile;
  try {
    telemetryFile = await DashcamTelemetryWriter.fileForSession(id);
  } catch (_) {
    // No documents directory to resolve: no telemetry file is known.
  }
  if (telemetryFile != null) await _deleteFileIfPresent(telemetryFile);

  await sessionsBox.delete(id);
}

/// Fase 16.2-R4.4-R1: the canonical clips and partials of session [id] in
/// `dashcam_clips/` (see [deleteDrivingSession], step 5). No resolvable
/// documents directory: none is known. A directory that exists and cannot be
/// listed throws — the deletion fails and keeps its marker.
Future<List<String>> _canonicalClipArtifactsOf(String id) async {
  final Directory directory;
  try {
    directory = await dashcamClipsDirectory();
  } catch (_) {
    return const [];
  }
  return canonicalClipArtifactsIn(directory, id);
}

/// Deletes [paths] (clip files of session [owner]), except a path an index
/// entry of ANOTHER session references — two indexes can name the same file
/// (a clip name is `clip_<milliseconds>` and the copy overwrites: see the
/// R2.6.6 pre-audit, G), and deleting it would take that session's video. The
/// reference is read synchronously right before each deletion starts. Tries
/// every path, then fails with the first error if any file is still there.
Future<void> _deleteClipFiles(Box videosBox, List<String> paths, {required String owner}) async {
  Object? failure;
  StackTrace? failureStack;
  for (final path in paths) {
    if (_clipPathReferencedByAnotherSession(videosBox, path, owner)) continue;
    try {
      await _deleteFileIfPresent(File(path));
    } catch (error, stackTrace) {
      failure ??= error;
      failureStack ??= stackTrace;
    }
  }
  if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
}

bool _clipPathReferencedByAnotherSession(Box videosBox, String path, String owner) {
  for (final key in videosBox.keys) {
    if (key == owner) continue;
    final raw = videosBox.get(key);
    if (raw is List && raw.any((clip) => clip is DashcamClipRecord && clip.filePath == path)) return true;
  }
  return false;
}

/// A file that is not there is already deleted — including one that
/// disappeared between the check and the delete (storage-quota enforcement).
/// One that is still there after a failed delete fails the caller.
Future<void> _deleteFileIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    if (await file.exists()) rethrow;
  }
}

/// Fase 16.2-R4.3-R2.6.7: discards clip files session [sessionId] produced
/// (the caller selected them by producer token) and whose indexing was refused
/// because the session's deletion is committed ([sessionDeletionCommitted]) —
/// the files nobody else knows about: they were never in any index. A path an
/// index references for another session is left alone (see
/// [_deleteClipFiles]). Never throws; returns the paths that could not be
/// deleted, for the caller to report.
Future<List<String>> discardClipFilesOfDeletedSession(String sessionId, List<String> paths) async {
  assert(sessionDeletionCommitted(sessionId), 'only the files of a session whose deletion is committed are discarded');
  final notDeleted = <String>[];
  final Box videosBox;
  try {
    videosBox = Hive.box(HiveBoxNames.dashcamSessionVideos);
  } catch (_) {
    // No index to consult: nothing is deleted on a guess.
    return List<String>.of(paths);
  }
  for (final path in paths) {
    try {
      await _deleteClipFiles(videosBox, [path], owner: sessionId);
    } catch (_) {
      notDeleted.add(path);
    }
  }
  return notDeleted;
}

/// Fase 16.2-R4.3-R2.6.8: the app's one startup recovery of driving sessions,
/// awaited once per process by the app bootstrap (main.dart), after the boxes
/// are open and BEFORE the app's single [DrivingSessionRecorder] exists (it is
/// created with the app's `DrivingSessionHost`, after `runApp`). In order:
///  1. [completePendingSessionDeletions] — interrupted deletions first, so the
///     reclaim never touches a record being deleted;
///  2. [DrivingSessionRecorder.reclaimOrphanedSessions] — sessions a killed
///     process left active. Safe only here: no recorder of this process has
///     started anything yet, so every active record is an orphan.
/// Never throws: a failure is reported and startup continues (the orphan is
/// reclaimed at the next start).
Future<void> recoverDrivingSessionsAtStartup() async {
  await completePendingSessionDeletions();
  try {
    await DrivingSessionRecorder.reclaimOrphanedSessions();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'driving session recorder',
        context: ErrorDescription('while reclaiming sessions a previous run left active (retried at the next start)'),
      ),
    );
  }
}

/// Fase 16.2-R4.3-R2.6.7: completes every deletion that was durably marked
/// ([DrivingSession.deletionPending]) and did not finish — the process died
/// between its steps, or one failed. Called once at startup (from
/// [recoverDrivingSessionsAtStartup]), after the boxes are open and before
/// anything can list or record a session; safe
/// to call again at any time (it joins a deletion in flight). Each deletion
/// runs the whole idempotent sequence of [deleteDrivingSession] again,
/// writing the marker first. Never throws: a deletion that fails again is
/// reported and stays marked for the next start (and for the History).
Future<void> completePendingSessionDeletions() async {
  try {
    final pending = [
      for (final session in Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).values)
        if (session.deletionPending) session.id,
    ];
    for (final id in pending) {
      try {
        await deleteDrivingSession(id);
      } catch (error, stackTrace) {
        _reportPendingDeletionFailure(error, stackTrace, 'while completing the interrupted deletion of session $id (it stays marked; the next start retries it)');
      }
    }
  } catch (error, stackTrace) {
    _reportPendingDeletionFailure(error, stackTrace, 'while looking for interrupted session deletions');
  }
}

void _reportPendingDeletionFailure(Object error, StackTrace stackTrace, String context) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'driving session recorder',
      context: ErrorDescription(context),
    ),
  );
}

/// Fase 16.2-R4.3-R2.6.11: what [persistSessionTelemetryOutcome] did.
enum SessionTelemetryOutcomeWrite {
  /// Written on the session's record.
  recorded,

  /// A recorder of this process still controls the session — it records it, or
  /// its finalization failed and awaits a retry: the outcome was set on that
  /// recorder's own instance, nothing was written, and the recorder's next
  /// write of the record stores it.
  handedToRecorder,

  /// Fase 16.2-R4.3-R2.6.12: the recorder that created the session never
  /// durably finalized it and no longer controls it (it was disposed): nothing
  /// was set and nothing was written. The record the box holds may carry what
  /// that recorder left only in memory, and its file is still the unfinalized
  /// one the next start's recovery reconciles — the outcome stays unknown.
  sessionNotFinalized,

  /// The record already carries this same outcome: nothing was written.
  alreadyRecorded,

  /// The record carries a DIFFERENT terminal outcome: it is kept and nothing
  /// was written. A session records with one writer, closed once, so this is
  /// not expected — the caller reports it.
  conflict,

  /// No record exists under this id — the session was deleted, or was never
  /// stored. It is not recreated.
  sessionAbsent,

  /// The record is marked for deletion: left exactly as it is.
  sessionDeletionPending,
}

/// Fase 16.2-R4.3-R2.6.11 — records, ON session [sessionId] and durably, how
/// its dashcam telemetry file ended. Independent review (P2, reproduced: A
/// stopped, B started, A's file failed afterwards — 19 of 19 samples lost, A's
/// STOP without error, and only a log line said so): the result of a telemetry
/// file belongs to the session that owned the writer, whatever is recording by
/// the time it is known. [sessionId] is that owner — the id the writer was
/// created with — and nothing here asks which session is active now.
///
/// The record is the one the open box holds under [sessionId] WHEN THIS RUNS,
/// read by id and not carried in by the caller: by then the session may have
/// ended, been finalized, re-persisted under a new instance, marked for
/// deletion or removed. Only its four telemetry fields are set, on that very
/// instance, and it is written in the same synchronous slice as the checks —
/// so every other field (end time, sample count, events, the deletion marker
/// and anything added later) is written as it stands, never replaced by an
/// older copy, and the instance the box holds stays the same one.
///
/// A recorder that still controls the session
/// ([DrivingSessionRecorder.controllingState]) is the only writer of its
/// record, as it is for a deletion. Writing the record serializes the WHOLE
/// instance, so a write issued here while the recorder finalizes it would
/// store an end time the recorder has not checkpointed yet — a record that
/// reads as finalized before its samples are (seen: this very write made the
/// frozen X59 find the record finalized on disk after a FAILED finalization).
/// Therefore an attempt in flight is awaited first, and then:
///  * the recorder released the session (the usual case — and always the case
///    when the outcome arrives late, with a newer session already recording):
///    the write below, after the recorder's own last one;
///  * its finalization failed and it keeps the session for a retry: the
///    outcome is set on the recorder's own instance and nothing is written
///    here — the retry stores it together with the record it finalizes
///    ([SessionTelemetryOutcomeWrite.handedToRecorder]).
///
/// Fase 16.2-R4.3-R2.6.12 (independent review of R2.6.11, P2 — reproduced
/// through the app's real root teardown): "no recorder controls it" is not
/// "its record is durable". A recorder also stops controlling its session when
/// it is DISPOSED, and the instance the box holds then still carries whatever
/// that recorder had only in memory — after a failed finalization, an end time
/// no write ever stored. The write below took the absence of a recorder for a
/// finished session and published it: a record finalized on disk with 3
/// samples declared and none stored, which the startup recovery — it reclaims
/// ACTIVE records — then left alone. A telemetry outcome may change its own
/// four fields and nothing else: the end time, the sample count and the
/// finalization of a session are the recorder's to make durable, never this
/// function's. So what is asked here is the positive question — did the
/// recorder that created this session durably finalize it? — whose answer does
/// not depend on that recorder still existing:
///  * not finalized and its recorder gone: nothing is set and nothing is
///    written ([SessionTelemetryOutcomeWrite.sessionNotFinalized]). The file
///    keeps the unfinalized record, the next start's recovery reconciles it
///    from the samples that are stored, and the telemetry outcome is lost with
///    the finalization it could not be attached to — it stays unknown, never a
///    result that was not recorded;
///  * a session no recorder of this process created (any session of an earlier
///    run): the box holds it exactly as its file does.
///
/// A deletion takes precedence ([deleteDrivingSession]): a record that is
/// marked, or gone, is not touched — never recreated, its marker never
/// cleared, nothing written for the startup recovery to trip over. The
/// deletion marks its record in the slice it starts and removes it last, and
/// the box serializes its writes, so an outcome written just before a deletion
/// goes with the record, and one arriving after the deletion started finds the
/// mark.
///
/// The values are absolute and a terminal outcome is recorded once: the same
/// outcome again is a no-op ([SessionTelemetryOutcomeWrite.alreadyRecorded]),
/// a different one is refused ([SessionTelemetryOutcomeWrite.conflict]).
///
/// A write that fails is not presumed rolled back (hive 2.2.3 can write the
/// frame and still throw — a compaction after it, R2.6.5 — and after a write
/// that did fail the cached instance still carries the fields): what the box
/// file holds cannot be read back from a non-lazy box. So the CURRENT record
/// is read again and, unless a deletion took it meanwhile, the same absolute
/// state is written once more — whether or not the first write took effect,
/// the record then carries the outcome exactly once. If that write fails too,
/// the first error is thrown: the outcome may not be on disk (the in-memory
/// record carries it, and any later write of that record stores it).
///
/// Throws when the sessions box is unavailable. Not covered: a process that
/// dies before this is called — or before a recorder it was handed to writes
/// the record — leaves the outcome unknown: nothing durable describes a
/// telemetry file that was still being written. Likewise a recorder disposed
/// before it finalized the session, whether the outcome was handed to it
/// before that or arrives after: that recorder stores nothing more, and
/// nothing else may finalize its record in this process.
Future<SessionTelemetryOutcomeWrite> persistSessionTelemetryOutcome(
  String sessionId, {
  required DashcamTelemetryOutcome outcome,
  required int accepted,
  required int persisted,
  required int refused,
}) async {
  assert(outcome != DashcamTelemetryOutcome.unknown, 'only a terminal outcome is recorded');
  while (true) {
    final attempt = DrivingSessionRecorder._controlling(sessionId)?._finalization;
    if (attempt == null) break;
    try {
      await attempt;
    } catch (_) {
      // Its own caller gets the failure; the recorder keeps the session.
    }
  }
  final held = DrivingSessionRecorder._controlling(sessionId)?._activeSession;
  if (held != null) {
    if (held.dashcamTelemetryOutcome != DashcamTelemetryOutcome.unknown) {
      return held.carriesDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused)
          ? SessionTelemetryOutcomeWrite.alreadyRecorded
          : SessionTelemetryOutcomeWrite.conflict;
    }
    held.applyDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused);
    return SessionTelemetryOutcomeWrite.handedToRecorder;
  }
  // No recorder controls it. Finalized by its recorder, or never recorded by
  // this process: the box holds what the file holds. Otherwise its recorder
  // was disposed before finalizing it, and what the box holds is not durable.
  if (DrivingSessionRecorder._unfinalizedSessionIds.contains(sessionId)) return SessionTelemetryOutcomeWrite.sessionNotFinalized;
  final box = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  final record = box.get(sessionId);
  if (record == null) return SessionTelemetryOutcomeWrite.sessionAbsent;
  if (record.deletionPending) return SessionTelemetryOutcomeWrite.sessionDeletionPending;
  if (record.dashcamTelemetryOutcome != DashcamTelemetryOutcome.unknown) {
    return record.carriesDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused)
        ? SessionTelemetryOutcomeWrite.alreadyRecorded
        : SessionTelemetryOutcomeWrite.conflict;
  }
  record.applyDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused);
  try {
    await box.put(sessionId, record);
    return SessionTelemetryOutcomeWrite.recorded;
  } catch (error, stackTrace) {
    try {
      // The box is resolved again: one that was closed and reopened holds the
      // record as its file has it.
      final currentBox = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
      final current = currentBox.get(sessionId);
      if (current == null) return SessionTelemetryOutcomeWrite.sessionAbsent;
      if (current.deletionPending) return SessionTelemetryOutcomeWrite.sessionDeletionPending;
      if (current.dashcamTelemetryOutcome == DashcamTelemetryOutcome.unknown) {
        current.applyDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused);
      } else if (!current.carriesDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused)) {
        return SessionTelemetryOutcomeWrite.conflict;
      }
      await currentBox.put(sessionId, current);
      return SessionTelemetryOutcomeWrite.recorded;
    } catch (_) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}
