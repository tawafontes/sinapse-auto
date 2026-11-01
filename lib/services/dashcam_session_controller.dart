import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/dashcam_clip_descriptor.dart';
import '../models/dashcam_status.dart';
import '../models/dashcam_telemetry_sample.dart';
import '../models/detected_event.dart';
import '../models/driving_session.dart';
import '../models/telemetry_snapshot.dart';
import 'dashcam_clip_files.dart' show DashcamClipFileOps, dashcamClipBasename;
import 'dashcam_clip_index.dart';
import 'dashcam_preferences.dart';
import 'dashcam_service.dart';
import 'dashcam_storage_probe.dart';
import 'dashcam_storage_quota.dart';
import 'dashcam_telemetry_writer.dart';
import 'driving_session_recorder.dart';

/// Binds [DrivingSessionRecorder]'s session lifecycle to [DashcamService]
/// (Fase 15) — the single entry point the UI calls to start/stop a
/// recording+driving session together, and the only new listener this phase
/// adds to the app's already-shared telemetry/event streams (never a second
/// sensor path — see this app's Fase 15 architecture notes).
///
/// **Failure isolation** (the phase's central requirement): every call into
/// [dashcamService] is wrapped in its own `try`/`catch` here and never
/// rethrown — a camera failure only ever moves [status] to
/// [DashcamStatus.error], it never stops [sessionRecorder] from starting or
/// finishing a session. Symmetrically, [sessionRecorder]/`EventDetectionEngine`
/// receive zero modifications anywhere in this phase and have no reference
/// to any dashcam type — this controller only *reads* their streams, it
/// never calls back into `SensorService`/`TelemetryEngine`, so a telemetry
/// failure has no path into the camera's call stack either.
///
/// **Sampling cadence**: [snapshotStream]'s emission rate is highly
/// non-uniform (~5Hz GPS cadence, but an unthrottled near-accelerometer-rate
/// re-emit during any g-force event — see `DashboardSensorStreams`'s own
/// doc). Rather than writing a telemetry sample on every emission, a
/// snapshot subscription only overwrites a live `_latestSnapshot` field
/// (O(1) per emission), and a separate 200ms timer — deliberately equal to
/// `DashboardSensorStreams.snapshotGpsCadenceGap` — periodically samples
/// whatever it currently holds. A [DetectedEvent] additionally writes one
/// precise, out-of-band sample immediately from its own embedded
/// [TelemetrySnapshot], tagged with its [DetectedEventType].
///
/// **No `RouteAware`/`NavigatorObserver`**: recording is a property of
/// [DashcamService]'s internal state, tied only to session start/stop, and
/// is completely independent of whether any preview widget is currently
/// mounted — entering/exiting fullscreen only mounts/unmounts a
/// `CameraPreview` reading frames, never starts/stops capture.
/// Fase 16.2-R4.2B-R5 (independent review P1 — "session controller: initial B
/// + retry/recovery B podem existir como DUAS tentativas semânticas"): the
/// single-flight identity for ONE semantic attempt to acquire/recover the
/// camera for a given session — covering the ENTIRE interval from intent
/// creation through waiting on any prior session's own stale settlement,
/// through `initialize()`/admission, through a presentation timeout if one
/// occurs, through late raw settlement, through START or cleanup, through
/// final status publication, to semantic conclusion. This sits ONE LEVEL
/// ABOVE [DashcamSessionController._observedInitializeSettlement] (raw
/// initialize Future identity, preserved unchanged — see its own doc): an
/// attempt can exist, claimed, BEFORE any raw Future exists at all (e.g.
/// while still waiting on a different session's own stale settlement) —
/// exactly the gap the reviewer's reproduction exploited, since deduplicating
/// purely on the raw Future was insufficient whenever B's own raw Future
/// didn't exist yet. Deliberately NOT an R4.3 lifecycle-generation framework
/// — purely local, single-session-scoped bookkeeping answering "is there
/// already an active camera-acquisition attempt for this session?".
class _CameraAttempt {
  _CameraAttempt({required this.sessionId, required this.isInitial, required this.generation});

  final String sessionId;
  final bool isInitial;

  /// Fase 16.2-R4.3-R1 (§14/§15, D0-approved lifecycle-generation
  /// architecture): the lifecycle epoch this attempt was created in — see
  /// [DashcamSessionController._lifecycleGeneration]'s own doc. Captured
  /// once, at construction, and compared for EXACT equality (never
  /// "newer-or-equal") by [DashcamSessionController._attemptStillValid]: a
  /// background/foreground cycle always changes the current generation, so
  /// even the SAME [sessionId] resuming in a NEW, now-eligible generation
  /// must not let an attempt captured in the OLD one keep acting as if it
  /// were still current (§15's own S/G1→S/G2 example).
  final int generation;

  /// The real, raw `DashcamService.initialize()` operation this attempt is
  /// driving, once one exists (`null` while still waiting on a different
  /// session's own stale settlement — see this class's own doc).
  Future<void>? rawSettlement;
}

/// Fase 16.2-R4.3-R2 (§5/§6, independent-review P1-1 fix — "raw claim
/// precisa incluir generation"): the full identity of whichever raw
/// `DashcamService.initialize()` operation is currently retained/observed —
/// [rawFuture] (compared via [identical] — the physical execution's own
/// identity, unchanged from R4.3-R1) is no longer sufficient ALONE:
/// R4.3-R1's own [DashcamSessionController._claimOrJoinInitialize] compared
/// only [sessionId], which let a LATER generation for the exact SAME
/// [sessionId] wrongly `_claimOrJoinInitialize` (join) a raw operation that
/// physically belongs to an EARLIER, already-superseded generation — the
/// reviewer's reproduced cross-generation raw claim. [generation] is the
/// captured [_CameraAttempt.generation] of whichever attempt FIRST
/// originated (or genuinely re-claimed) this raw operation — see
/// [DashcamSessionController._claimOrJoinInitialize]'s own doc for exactly
/// how both [sessionId] and [generation] must now match for a join to be
/// legitimate. [watcherInstalled] replaces R4.3-R1's own separate
/// `_observedInitializeWatcherInstalled` bool field — naturally scoped to
/// THIS specific raw operation instead of a bare flag that could, in
/// principle, survive being reassigned to a new operation without being
/// reset (it always was reset correctly in R4.3-R1 too, via
/// `_claimOrJoinInitialize`'s own branch — this only makes that invariant
/// structural instead of remembered).
class _ObservedInitialize {
  _ObservedInitialize({required this.rawFuture, required this.sessionId, required this.generation, required this.isInitial});

  final Future<void> rawFuture;
  final String sessionId;
  final int generation;
  final bool isInitial;
  bool watcherInstalled = false;
}

/// Fase 16.2-R4.3-R2.2 (§3-§5, independent-review P1 — "baseline A
/// substituído por B"): the exact, immutable clip-persistence identity of ONE
/// logical session — created exactly once, when that session is born (see
/// [DashcamSessionController._ensureClipsBaselineForSession]'s own doc),
/// never re-derived from whatever "current session" happens to be by the
/// time an async continuation resumes. Replaces R4.3-R2.1's own
/// `_LateStopPersistenceContext` (baseline-only, late-pass-only) — the
/// reviewer's own reproduction (a REAL `startSession()` for B landing
/// between A's STOP and A's own immediate persistence pass) showed that a
/// context captured only for the LATE path is not early enough: the
/// IMMEDIATE pass itself must already be reading from an explicitly-captured
/// context, never a shared "current" field, or B's own [startSession] can
/// silently redirect A's own immediate persistence onto B's baseline.
///
/// [_baseline] is an independent snapshot (never the live field) — the set
/// of clips that already existed before this session's own recording began.
///
/// Deliberately holds no "claimed paths"/obligation bookkeeping of its own —
/// see [DashcamSessionController._claimedPathOwners]'s own doc for the
/// write-dedup record kept there instead, keyed by path rather than by context
/// (which session a clip BELONGS to is decided by its producer token, Fase
/// 16.2-R4.3-R2.5 — not by any claim). This object's own lifetime is simply whatever plain Dart closure
/// captures it ([DashcamSessionController._stopCamera]'s own local
/// `context` variable, and/or [DashcamSessionController._watchLateStopSettlement]'s
/// own parameter) — released the instant nothing references it anymore, no
/// explicit registry/removal needed (mirrors R4.3-R2.1's own
/// `_LateStopPersistenceContext` in this one respect).
class _SessionPersistenceContext {
  _SessionPersistenceContext({required this.sessionId, required Set<DashcamClip> baseline}) : _baseline = Set<DashcamClip>.from(baseline);

  final String sessionId;
  final Set<DashcamClip> _baseline;
}

/// Fase 16.2-R4.4-R2.1 — one index write of a clip of this process
/// ([DashcamSessionController._indexProducedClip]): whether it asked for the
/// clip's protection, and its outcome (`ensureClipIndexed` never throws).
class _ClipIndexWrite {
  _ClipIndexWrite({required this.protectedAsked, required this.outcome});

  final bool protectedAsked;
  final Future<ClipIndexOutcome> outcome;
}

/// Fase 16.2-R4.3-R2.6 (§3-§6, independent-review P1-A — "stopSession(B) é
/// absorvido por A"): the identity of ONE public [DashcamSessionController
/// .stopSession] request — a SEMANTIC session-stop request, distinct from the
/// PHYSICAL teardown ([DashcamSessionController._stopCameraFuture]) it may have
/// to wait behind. [sessionId] is the logical session being stopped, captured
/// synchronously when the request was accepted (`null` = there was no session
/// to stop). This is logical-session-operation identity only — deliberately NOT
/// a lifecycle generation and not a second lifecycle counter.
class _SessionStopRequest {
  _SessionStopRequest({required this.requestId, required this.sessionId});

  final int requestId;
  final String? sessionId;

  /// The Future every caller that joined THIS request receives — set once, right
  /// after the request's own operation is started.
  Future<void>? completion;

  /// Whether a new `stopSession()` call targeting [targetSessionId] is
  /// semantically the same request as this one: the same logical session, or no
  /// session at all (nothing left to stop, so waiting for the in-flight
  /// teardown — this request's own — is exactly what the caller wants).
  bool matches(String? targetSessionId) => targetSessionId == null || sessionId == targetSessionId;
}

class DashcamSessionController extends ChangeNotifier with WidgetsBindingObserver {
  DashcamSessionController({
    required this.dashcamService,
    required this.dashcamPreferences,
    required this.sessionRecorder,
    required this.snapshotStream,
    required this.eventStream,
    this.storageProbe = const MethodChannelDashcamStorageProbe(),
  }) : _lastSeenQuotaMb = dashcamPreferences.storageQuotaMb,
       _storageSnapshot = latestDashcamStorageSnapshot {
    // Fase 16.2-R4.3-R1 (§6, D0-approved lifecycle-generation architecture
    // — "initial lifecycle desconhecido tratado como foreground"): consult
    // Flutter's own real, live binding state rather than assuming "just
    // constructed" means "resumed". Conservative by design: ONLY an
    // explicitly-known `resumed` state starts this controller eligible —
    // `null` (indeterminate, e.g. very early in app startup) and every
    // other state (inactive/paused/hidden/detached) start INELIGIBLE,
    // requiring an actual, later `resumed` callback before any camera
    // attempt may emit native work. `_lifecycleGeneration` itself starts at
    // 0 regardless — there is nothing to invalidate before construction.
    _lifecycleEligible = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _serviceErrorSub = dashcamService.originatedErrors.listen(_onDashcamServiceError);
    // Fase 16.2-R4.4-R1: every published segment is indexed right away — see
    // [_indexProducedClip]. Fase 16.2-R4.4-R2: and then the storage quota runs
    // — see [_onClipPublished].
    _publishedClipsSub = dashcamService.publishedClips.listen(_onClipPublished);
    dashcamService.cameraKnownUnavailableListenable.addListener(_onCameraKnownUnavailableChanged);
    dashcamPreferences.addListener(_onPreferencesChanged);
  }

  final DashcamService dashcamService;
  final DashcamPreferences dashcamPreferences;
  final DrivingSessionRecorder sessionRecorder;
  final Stream<TelemetrySnapshot> snapshotStream;
  final Stream<DetectedEvent> eventStream;

  /// Fase 16.2-R4.4-R2: the volume's facts for the storage quota and the
  /// START's free-space guard. On a platform without the native side
  /// ([DashcamStorageProbe.isSupported] false) neither reads it, and a START
  /// is never held for it.
  final DashcamStorageProbe storageProbe;

  DashcamStatus _liveStatus = DashcamStatus.idle;
  String? errorMessage;
  DateTime? recordingStartedAt;

  /// Fase 16.2-R4.3-R1 (§5-§10, D0-approved lifecycle-generation
  /// architecture — the ONE mutable lifecycle-generation authority for this
  /// whole app: `DashcamService` holds no second counter, and only ever
  /// consults an external predicate this controller supplies — see
  /// [DashcamService.initialize]'s own `semanticStillValid` doc): a
  /// monotonic epoch counter, incremented exactly once per FIRST exit from
  /// an eligible epoch (§7) — `hidden`/`paused`/`detached` while
  /// [_lifecycleEligible] is still `true`. A repeated exit event
  /// (hidden→paused, paused→paused) while already ineligible is a no-op —
  /// see [_updateLifecycleGeneration]'s own doc for the exact rule and why
  /// `inactive` never participates (§9).
  int _lifecycleGeneration = 0;

  /// `true` only while the CURRENT [_lifecycleGeneration] is foreground/
  /// interactive — i.e. genuinely allowed to emit new native camera work
  /// right now. Never implies "this specific [_CameraAttempt] is still
  /// current" on its own — an attempt's own captured [_CameraAttempt.generation]
  /// no longer matching [_lifecycleGeneration] already means a background
  /// cycle happened since it was created, which is a STRONGER, permanent
  /// signal than this transient flag (see [_attemptStillValid]'s own doc).
  bool _lifecycleEligible = false;

  /// Fase 16.2-R4.3-R1 (§22/§23, D0 gate — "initial incompleto através do
  /// background"): `true` once THIS session's own initial telemetry
  /// setup (writer/subscriptions/sample timer) has genuinely been
  /// installed — see [_finishInitialStart]'s own doc. Reset to `false` the
  /// instant a NEW session starts ([startSession]). A later generation's
  /// own continuation for the SAME session (via the hand-off in
  /// [_continueForCurrentGenerationIfWarranted]) consults this to decide
  /// whether it must still run the FULL initial setup exactly once, or may
  /// instead reuse what a prior, now-terminated generation already
  /// installed — never duplicating it, never skipping it.
  bool _initialSetupDone = false;

  /// Fase 16.2-R4.3-R1 (§45): test-only observability, mirroring this
  /// class's own established `...ForTest` pattern (e.g.
  /// [lateInitializeWatcherInstallCountForTest]) — not exposed to the
  /// UI/product surface.
  @visibleForTesting
  int get lifecycleGenerationForTest => _lifecycleGeneration;

  /// Fase 16.2-R4.3-R1 (§45): test-only observability — the exact number of
  /// times [_finishInitialStart] has DURABLY installed this session's own
  /// initial telemetry setup (never merely attempted/torn-down) across this
  /// controller's whole lifetime. Lets a test assert "exactly once, never
  /// duplicated" directly (§22/§23), rather than inferring it indirectly.
  @visibleForTesting
  int initialSetupInstallCountForTest = 0;

  @visibleForTesting
  bool get lifecycleEligibleForTest => _lifecycleEligible;

  /// Fase 16.2-R4.3-R1 (§7-§9, coverage-closure intervention — "L9 real,
  /// writer.open() boundary"), corrected in Fase 16.2-R4.3-R2 (§32/§33,
  /// independent-review P2-G fix — "L9-real gateia ANTES de writer.open()
  /// começar"): an OPTIONAL test seam wrapping [_finishInitialStart]'s own
  /// call to `writer.open()` — `null` (the default) means production calls
  /// `writer.open()` directly, with no behavior change whatsoever. [openCall]
  /// is the REAL `writer.open` tear-off — R4.3-R1's own hook signature took
  /// only [writer] and decided FOR ITSELF when to invoke `writer.open()`,
  /// which let a test's own gate sit BEFORE the real call ever started (the
  /// reviewer's own reproduced gap: this then proved nothing about a
  /// genuinely in-flight `open()`, only about a checkpoint the test itself
  /// delayed reaching). A test now calls [openCall] itself FIRST — starting
  /// the REAL operation immediately, unconditionally — and may gate only
  /// WHEN it chooses to `await` that already-started [Future], e.g.:
  /// `(writer, openCall) async { final realOpen = openCall(); entered
  /// .complete(); await gate.future; await realOpen; }`. Deliberately not a
  /// general writer-injection/mocking framework — the ONLY thing this
  /// changes is WHEN this continuation resumes past the real call, never
  /// whether or what it invokes.
  @visibleForTesting
  Future<void> Function(DashcamTelemetryWriter writer, Future<void> Function() openCall)? openTelemetryWriterHookForTest;

  /// Fase 16.2-R4.3-R2.2 (§16/§48): an OPTIONAL test seam — `null` (the
  /// default) means zero behavior change — awaited by [_stopCamera] right
  /// after this session's own native STOP has genuinely resolved (its own
  /// [DashcamStopOutcome.presentation] already returned) but BEFORE this
  /// session's own immediate persistence pass runs. Lets a test pause in
  /// exactly that window to reproduce/verify the reviewer's own X6 scenario
  /// — a REAL `startSession()` for a DIFFERENT session landing there.
  @visibleForTesting
  Future<void> Function()? beforeImmediatePersistenceHookForTest;

  /// Fase 16.2-R4.3-R2.2 (§17/§49): an OPTIONAL test seam around the actual
  /// Hive write inside [_persistClaimedClips] — `null` (the default) calls
  /// [writeCall] directly, unconditionally, with zero behavior change. A
  /// test may instead gate ITS OWN await of [writeCall]'s already-started
  /// result (mirrors [openTelemetryWriterHookForTest]'s own established
  /// "call first, gate only the await" pattern) to force/observe a real
  /// interleaving with a concurrent claim/persist attempt — [claimedPaths]
  /// are this call's own already-claimed candidate paths (claimed
  /// SYNCHRONOUSLY, before this hook ever runs — see [_tryClaimPath]'s own
  /// doc), purely for the test's own observability.
  ///
  /// Fase 16.2-R4.4-R1: the write now lives in `ensureClipIndexed`, the index's
  /// one writer; this hook is handed to it ([ClipIndexWriteHook], same
  /// signature) for every clip this controller indexes, one clip per call, and
  /// is called only when that clip actually needs a write (one already indexed
  /// is not written again).
  @visibleForTesting
  ClipIndexWriteHook? persistClipIndexHookForTest;

  /// Fase 16.2-R4.3-R1 (§7-§9, D0's exact invalidation rule): called
  /// SYNCHRONOUSLY from [didChangeAppLifecycleState] itself (§10 — BEFORE
  /// any `unawaited` async handler is even launched), so an event's own
  /// invalidation is visible to every already-in-flight continuation's next
  /// checkpoint immediately, never racing behind that continuation's own
  /// `await`.
  ///
  /// - `hidden`/`paused`/`detached`: the FIRST such event while still
  ///   eligible increments the generation and marks it ineligible — a
  ///   REPEATED one (already ineligible) is a no-op (§7's own
  ///   hidden→paused example: exactly one increment, not two).
  /// - `resumed`: marks the CURRENT generation eligible again — never
  ///   increments (§8) — idempotent for a repeated `resumed` (§8's own
  ///   "resumed repetido").
  /// - `inactive`: no-op entirely (§9) — this app's own pre-existing
  ///   semantics already treat it as "may be a transient focus loss, not a
  ///   real background", and this round does not change that.
  void _updateLifecycleGeneration(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_lifecycleEligible) {
          _lifecycleGeneration++;
          _lifecycleEligible = false;
        }
      case AppLifecycleState.resumed:
        _lifecycleEligible = true;
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Fase 16.2 §12 ("resume-during-dispose"), broadened in Fase 16.2-R1:
  /// [dispose] can, in principle, race an already-in-flight
  /// [_attemptRecoveryRestart]/[_stopCamera] triggered by the same event
  /// that's tearing this controller down (e.g. whole-app teardown landing
  /// mid-recovery, or mid-stop). Checked after every `await` in those two
  /// methods — calling `notifyListeners()`, or acting as if this controller
  /// still owns anything, on an already-disposed [ChangeNotifier] is unsafe
  /// — not a general mutex, just re-validated at each point a concurrent
  /// [dispose] could have interleaved through (see each method's own doc).
  bool _disposed = false;

  /// The session this controller is currently recording (or attempting to
  /// record) for — set synchronously at the very top of [startSession]'s
  /// camera-start attempt, *before* any `await`, and cleared only after
  /// [stopSession]'s camera-finalize path has fully resolved. Using the
  /// controller's own field (rather than reading
  /// `sessionRecorder.activeSession?.id` from inside a finalize callback)
  /// avoids a real race: by the time the *last* segment of a session
  /// finalizes, `sessionRecorder.activeSession` may already be null if
  /// `sessionRecorder.stopSession()` happened to resolve first.
  String? _recordingSessionId;

  /// Snapshot (by object identity — [DashcamClip] has no `==` override, so
  /// this is exact) of every clip [dashcamService] already held *before*
  /// this session's recording started. [dashcamService] is a long-lived,
  /// continuously loop-recording instance shared across every session in
  /// this app run, so "this session's clips" = whatever's in
  /// [DashcamService.clips] afterward that *isn't* in this set — robust
  /// regardless of quota eviction reordering the underlying list mid-session.
  Set<DashcamClip> _clipsBeforeThisSession = {};

  /// Fase 16.2-R4.3-R2 (§18-§20, independent-review P1-2 fix — "baseline é
  /// da sessão, não do attempt"): the [_recordingSessionId] value
  /// [_clipsBeforeThisSession] currently belongs to — `null` before any
  /// session has ever captured a baseline.
  /// R4.3-R1 recaptured [_clipsBeforeThisSession] every time
  /// [_finishInitialStart] ran, including for a hand-off-driven G2 resuming
  /// an INITIAL setup G1 never finished for the SAME logical session — the
  /// reviewer's reproduction: G1 already finalized one real clip by the
  /// time it was superseded, but G2's own recapture silently absorbed that
  /// clip into the "before this session" baseline, so
  /// [_persistClipsForSession] never indexed it into this session's own
  /// Hive record (the file itself was never lost — only its INDEXING was
  /// wrong). See [_ensureClipsBaselineForSession]'s own doc for the fix.
  String? _clipsBaselineSessionId;

  /// Fase 16.2-R4.3-R2.5 (§21, independent-review P1-1 — "clip provenance é
  /// first-observer-wins"): this map is now WRITE-DEDUP bookkeeping only — "which
  /// session already attempted to index this path" — NOT the definition of a
  /// clip's producer. The producer is decided where the clip is born
  /// ([DashcamClip.producerToken], stamped by [DashcamService] before the clip
  /// is publicly visible), and [_persistClaimedClips] only ever offers a
  /// session clips carrying its own token, so no observation order can make a
  /// session claim a clip another session produced. The R2.2-R2.4 text below
  /// describes the earlier design (claim == provenance) and is kept for its
  /// history; where it calls this map "the TRUE cross-session clip-ownership
  /// authority" or "PROVENANCE", read the sentence above instead.
  ///
  /// Fase 16.2-R4.3-R2.2 (§11-§14/§23, independent-review P1 — "atomic clip
  /// claim" / "claim não pode ser registry infinito"): the cross-session
  /// clip-ownership authority (until R2.5 — see above) — path -> owning sessionId — replacing Fase
  /// 16.2-R4.3-R2.1's own controller-lifetime, never-pruned
  /// `_persistedClipPaths` registry. Keyed by PATH (not by context/session),
  /// so ownership outlives any individual [_SessionPersistenceContext]'s own
  /// in-memory lifetime — necessary because a context can legitimately have
  /// no live async work referencing it anymore (its session's own immediate
  /// pass long done, no late continuation pending) while the CLIP it once
  /// claimed still physically exists and must remain correctly, permanently
  /// attributed against any LATER session's own stale baseline (a session
  /// whose baseline was captured before that clip existed cannot otherwise
  /// tell "not in my baseline" apart from "genuinely new").
  ///
  /// Bounded (§12/§13/§14 — "não manter histórico eterno... bounded pela
  /// quantidade de clips ainda relevantes"): pruned in [_pruneClaimedPathOwners]
  /// to contain only paths [DashcamService.clips] currently still lists — a
  /// clip deleted by [DashcamService]'s own storage-quota enforcement can
  /// never again appear as a persistence candidate for any session, so its
  /// claim entry serves no further purpose. This keeps the map's size tied
  /// to however many clips currently exist on disk (itself already bounded
  /// by `DashcamConfig.storageQuotaMb`), never to the app's total lifetime
  /// clip count.
  ///
  /// Fase 16.2-R4.3-R2.4 (§17-§22, independent-review P1-B #2 — "failed
  /// write transfere provenance", reproduced 20/20): this map's own
  /// semantics are PROVENANCE — "which session's own Recording produced this
  /// physical clip" — not "has this clip's own Hive write succeeded".
  /// [_persistClaimedClips]'s own claim (via [_tryClaimPath]) is entered
  /// here BEFORE that clip's own Hive write is even attempted, and — since
  /// this round — is deliberately never rolled back if that write later
  /// fails: an R2.2/R2.3-era version DID roll it back on failure, which
  /// freed the path entirely, and a LATER, unrelated session's own
  /// persistence pass (whose own baseline, captured before this clip
  /// existed, also fails to recognize it as "not new") could then
  /// legitimately claim — and index under ITS OWN sessionId — a clip that
  /// physically belongs to the FIRST session. A clip may end up with no Hive
  /// index entry at all after an explicit, reported storage failure (this
  /// class's own no-auto-retry contract — [_persistClaimedClips]'s own doc
  /// — is unaffected by this), but it is NEVER re-attributed to a different
  /// session's own Hive record because of it. Entries are dropped only by
  /// [_pruneClaimedPathOwners], once the clip they concern is no longer even
  /// physically tracked in [DashcamService.clips] — never by a write outcome.
  ///
  /// Fase 16.2-R4.4-R1: no longer excludes anything from a pass either. Whether
  /// a clip is indexed is now the index's to say (`ensureClipIndexed` finds it
  /// by its canonical name and writes nothing), and a pass that meets a clip
  /// not yet confirmed retries it — a claim taken before a failed write must
  /// not stop that retry. What stays is the record of which session each path
  /// was indexed for (diagnostics: [ownerOfPathForTest]), and the refusal to
  /// let a different session's pass take a path already noted for another
  /// (defense in depth: a clip's session is the one its own name carries).
  final Map<String, String> _claimedPathOwners = {};

  @visibleForTesting
  int get claimedPathOwnersCountForTest => _claimedPathOwners.length;

  /// Fase 16.2-R4.3-R2.4 (§26, X19): the sessionId currently owning [path]'s
  /// own provenance claim, or `null` if nothing has claimed it. Read-only
  /// test seam over [_claimedPathOwners] — makes the sticky-provenance
  /// property (that field's own doc) directly assertable per-path, not only
  /// via the aggregate count [claimedPathOwnersCountForTest] already exposes.
  @visibleForTesting
  String? ownerOfPathForTest(String path) => _claimedPathOwners[path];

  /// Fase 16.2-R4.4-R2.1.1 (RES-1): the STOP's passes over its session's clips
  /// ([_persistClaimedClips]) still running — started by [_stopCamera], owned
  /// here, awaited by no STOP. Each one's outcome is the index's to report
  /// (`ensureClipIndexed`, once per clip, `recordingResult` — which never moves
  /// this controller's status); an unexpected error is reported the same way,
  /// never left unhandled. Each removes itself when it settles. Keyed by the
  /// pass, valued by its session.
  final Map<Future<void>, String> _clipIndexFollowUps = {};

  /// Fase 16.2-R4.4-R2.1.1: test-only — every STOP pass over its clips started
  /// so far ([_clipIndexFollowUps]) — of [sessionId] only, when given — has
  /// settled: what `stopSession()` used to wait for before returning.
  @visibleForTesting
  Future<void> clipIndexFollowUpsSettledForTest({String? sessionId}) => Future.wait([
    for (final MapEntry(key: pass, value: owner) in _clipIndexFollowUps.entries)
      if (sessionId == null || owner == sessionId) pass,
  ]);

  /// Starts and owns [context]'s immediate STOP pass over its clips — see
  /// [_clipIndexFollowUps].
  Future<void> _followUpClipIndex(_SessionPersistenceContext context) => _ownClipIndexFollowUp(context.sessionId, _persistClaimedClips(context));

  /// Owns [work], an index pass of [sessionId]'s STOP: registered in
  /// [_clipIndexFollowUps] until it settles; an unexpected error is reported
  /// (`recordingResult`), never left unhandled.
  Future<void> _ownClipIndexFollowUp(String sessionId, Future<void> work) {
    late final Future<void> owned;
    owned = work
        .catchError(
          (Object error) => dashcamService.reportExternalError('Falha ao indexar clipe(s) da sessão $sessionId: $error', scope: DashcamServiceErrorScope.recordingResult),
        )
        .whenComplete(() => _clipIndexFollowUps.remove(owned));
    _clipIndexFollowUps[owned] = sessionId;
    return owned;
  }

  /// Fase 16.2-R4.4-R2.1 (R2-P3-HW-STOP): the LATEST index write
  /// [_indexProducedClip] started for each clip of this process, by path. The
  /// STOP's passes ([_persistClaimedClips]) await that write instead of queueing
  /// a new turn of the index FIFO: a publication's quota pass is queued in that
  /// FIFO right after the publication's own write settles, so a new turn queued
  /// by the STOP waited for the whole pass, and the camera release with it (the
  /// SM-A326B released a camera 7.1 s after its STOP, behind a 5.5 s pass).
  /// Pruned with [_claimedPathOwners].
  final Map<String, _ClipIndexWrite> _clipIndexWrites = {};

  /// Drops every [_claimedPathOwners] and [_clipIndexWrites] entry whose path
  /// [DashcamService.clips] no longer lists — see [_claimedPathOwners]' own
  /// doc for why this is safe.
  void _pruneClaimedPathOwners() {
    final currentPaths = dashcamService.clips.map((clip) => clip.file.path).toSet();
    _claimedPathOwners.removeWhere((path, _) => !currentPaths.contains(path));
    _clipIndexWrites.removeWhere((path, _) => !currentPaths.contains(path));
  }

  /// Fase 16.2-R4.3-R2.2 (§11-§13, independent-review P1 — "atomic clip
  /// claim"): synchronous — no `await` anywhere in this function's own body,
  /// so nothing else in this single-threaded isolate can run between
  /// checking whether [path] is already owned and recording [context]'s own
  /// claim on it. This is what makes claiming atomic with respect to the
  /// Hive `await` a claiming call site performs immediately afterward:
  /// unlike Fase 16.2-R4.3-R2.1's own "claim after a successful write"
  /// design, a SECOND concurrent persistence attempt (a later session's own
  /// immediate pass, or another late continuation) that checks THIS SAME
  /// path while the first attempt's own Hive write is still in flight always
  /// observes the claim already taken — it can never also select the same
  /// physical clip as "new". Idempotent for the SAME context re-claiming its
  /// own already-owned path (returns `true`, a no-op write) — only a
  /// DIFFERENT session's own context is ever rejected.
  ///
  /// Fase 16.2-R4.3-R2.5 (§21, independent-review P1-1): this is WRITE-DEDUP
  /// only — it records which session already ATTEMPTED to index [path] so the
  /// same clip is never written (or its failure re-reported) twice — and is no
  /// longer the definition of a clip's producer. R2.2-R2.4 used the first
  /// successful claim as provenance, which made ownership depend on observation
  /// order (a different session's pass could win the claim during the
  /// `await _enforceStorageQuota()` window of [DashcamService
  /// ._finalizeSegmentResult], before the producing session ever looked).
  /// Producer provenance now lives on the clip ([DashcamClip.producerToken]);
  /// [_persistClaimedClips] only offers a session clips it produced, so the
  /// cross-session rejection here is defense in depth, not the authority.
  ///
  /// Fase 16.2-R4.4-R1: [sessionId] is the session the clip's canonical name
  /// carries ([_indexProducedClip]).
  bool _tryClaimPath(String sessionId, String path) {
    final owner = _claimedPathOwners[path];
    if (owner != null && owner != sessionId) return false;
    _claimedPathOwners[path] = sessionId;
    return true;
  }

  /// Fase 16.2-R4.3-R2.5 (§22/§31): the opaque producer token for [sessionId]'s
  /// Recordings — [DashcamService.startLoopRecording]'s `clipOwnerToken`. The
  /// logical session's own id: unique per session, identical across every
  /// lifecycle generation, segment rotation, recovery and camera switch of that
  /// session (a lifecycle generation is NOT a provenance — one logical session
  /// spans G1/G2/G3), and different for every new logical session.
  /// [DashcamService] treats it as opaque.
  Object _producerTokenFor(String sessionId) => sessionId;

  _SessionPersistenceContext? _currentPersistenceContext;

  /// Fase 16.2-R4.3-R2 (§18-§21, independent-review P1-2 fix): captures
  /// [_clipsBeforeThisSession] EXACTLY ONCE per logical session — a no-op if
  /// [sessionId] already owns the current baseline ([_clipsBaselineSessionId]
  /// already matches), which is what makes this safe to call from
  /// [startSession] alone, never again from [_finishInitialStart] (§19:
  /// "não capturar novamente"), regardless of how many lifecycle
  /// generations that one logical session's own camera setup ends up
  /// spanning. Called synchronously, before any Recording for [sessionId]
  /// can possibly exist (§19: "ANTES que qualquer Recording dessa sessão
  /// possa produzir clip").
  ///
  /// Fase 16.2-R4.3-R2.2 (§3-§5, independent-review P1 — "baseline A
  /// substituído por B"): ALSO creates [sessionId]'s own
  /// [_SessionPersistenceContext] here, in this SAME one-shot-guarded call —
  /// the single moment this logical session is born — so every later
  /// persistence operation (immediate or late) can capture an explicit
  /// reference to it instead of ever re-reading [_currentPersistenceContext]
  /// after an `await`. The PREVIOUS context (if any) is simply overwritten
  /// here — it needs no explicit release: which session a clip belongs to is
  /// decided by the clip's own producer token ([DashcamClip.producerToken],
  /// Fase 16.2-R4.3-R2.5), not by this field or any claim, so a still-in-flight
  /// persistence operation for the previous session stays completely correct
  /// via whatever local `context` reference its own async continuation already
  /// captured, regardless of what [_currentPersistenceContext] itself now
  /// points to.
  void _ensureClipsBaselineForSession(String sessionId) {
    if (_clipsBaselineSessionId == sessionId) return;
    _clipsBeforeThisSession = dashcamService.clips.toSet();
    _clipsBaselineSessionId = sessionId;
    _currentPersistenceContext = _SessionPersistenceContext(sessionId: sessionId, baseline: _clipsBeforeThisSession);
  }

  StreamSubscription<DashcamServiceError>? _serviceErrorSub;
  StreamSubscription<DashcamClip>? _publishedClipsSub;
  StreamSubscription<TelemetrySnapshot>? _snapshotSub;
  StreamSubscription<DetectedEvent>? _eventSub;
  Timer? _sampleTimer;
  TelemetrySnapshot? _latestSnapshot;
  DashcamTelemetryWriter? _telemetryWriter;

  /// Fase 16.2-R4.3-R2.6.11: the writer of the session being recorded whose
  /// file could NOT be opened, while no later attempt of that session has
  /// installed one ([_finishInitialStart]). It was never installed as
  /// [_telemetryWriter], so no close owns it; kept only so the session's STOP
  /// can record, on that session, that its telemetry was never written
  /// ([_finalizeStoppedTelemetry]). A retry that opens the file replaces it
  /// with a recording writer and clears this.
  DashcamTelemetryWriter? _unopenedTelemetryWriter;

  /// Set by [stopSession] for as long as [_stopCamera] is still finishing
  /// the just-ended session's camera-side teardown (finalizing the
  /// in-flight segment, persisting its `DashcamClipRecord`s). [_startCamera]
  /// awaits this first — see its own doc for the real, physically-found bug
  /// this closes.
  Future<void>? _stopCameraFuture;

  static const _sampleInterval = Duration(milliseconds: 200);

  /// [DashcamStatus.disabled] whenever the feature is switched off in
  /// Settings, regardless of any other internal state — otherwise whatever
  /// [_liveStatus] currently reflects (idle/initializing/recording/error, and
  /// since Fase 16.2-R4.3-R2.6.10 finalizing — see [_finalizeStoppedTelemetry]),
  /// with one truthfulness correction (Fase 16.2-R1, independent review
  /// P1-5):
  ///
  /// [_liveStatus] only ever transitions to [DashcamStatus.recording] inside
  /// [_startCamera]/[_attemptRecoveryRestart], both of which set it
  /// synchronously right after `dashcamService.startLoopRecording()`
  /// succeeds — there is no *other* moment [_liveStatus] gets updated for a
  /// background camera loss (`notifyAppBackgrounded()`/timeout detection
  /// live entirely in [DashcamService], deliberately not mirrored into a
  /// second copy of the same fact here — see `DashcamService.cameraKnownUnavailable`'s
  /// own doc). That means [_liveStatus] can legitimately keep reading
  /// `recording` for a window after the camera actually became unavailable
  /// (backgrounded, or a native call timed out) and *before* a recovery
  /// attempt has had a chance to run or even start. An independent review
  /// demonstrated this is a real, externally-observable gap — this getter
  /// closes it by computing the truth at read time instead of trying to
  /// keep a second, redundant flag in sync with [DashcamService]'s own:
  /// whenever [_liveStatus] says `recording` but the service says the
  /// camera is known-unavailable, the *displayed* status downgrades to
  /// [DashcamStatus.cameraUnavailable] — video is not actually being
  /// captured, so it must not be reported as if it were, however briefly.
  ///
  /// Fase 16.2-R4.3-R2.6.21: computing it at read time is only half of
  /// "truthfully": a consumer reads it when it is told to (or when its own
  /// ticker fires — and the REC indicator's and the preview's tick only while
  /// this says `recording`). So a change of that service fact is now
  /// published too ([_onCameraKnownUnavailableChanged]).
  DashcamStatus get status {
    if (!dashcamPreferences.enabled) return DashcamStatus.disabled;
    if (_liveStatus == DashcamStatus.recording && (dashcamService.cameraKnownUnavailable || _cameraUnavailableDuringStop)) {
      return DashcamStatus.cameraUnavailable;
    }
    return _liveStatus;
  }

  /// Fase 16.2-R4.3-R2.6.21: set when this controller's camera session is
  /// being stopped — [_stopCamera] has cleared [_recordingSessionId], and
  /// [_liveStatus] still reads `recording` until that stop settles it — and
  /// the service's camera is, or becomes, known unavailable meanwhile. Read
  /// by [status]: from then on, until the stop settles [_liveStatus], the
  /// status says `cameraUnavailable` even once the service's fact clears.
  /// That happens when a rotation's restart START, overdue when the stop was
  /// requested, succeeds late: the service clears its overdue mark, does NOT
  /// adopt the Recording (the stop made it stale — it is stopped right
  /// after), and [status] would otherwise say `recording` again, and now
  /// publish it, during the stop. Cleared where a recording is next
  /// established.
  bool _cameraUnavailableDuringStop = false;

  /// Fase 16.2-R4.4-R2: the bytes the storage quota manages — read from the
  /// disk by the latest pass (every process's clips), not this service's
  /// in-memory sum, which is only the fallback until a first snapshot exists.
  int get totalClipBytes => _storageSnapshot?.managedBytes ?? dashcamService.totalClipBytes;

  /// Fase 16.2-R4.4-R2: the EFFECTIVE quota of the latest pass — the configured
  /// one, raised to two segments when it is below that — or the configured one
  /// until a pass has run.
  int get quotaBytes => _storageSnapshot?.effectiveQuotaBytes ?? dashcamService.quotaBytes;

  /// Fase 16.2-R4.4-R2: the latest storage snapshot this controller saw (its
  /// own passes, or the startup's).
  DashcamStorageSnapshot? get storageSnapshot => _storageSnapshot;
  DashcamStorageSnapshot? _storageSnapshot;

  /// Fase 16.2-R4.4-R2: the quota setting last seen — a change of it runs a
  /// pass ([_onPreferencesChanged]); no other preference does.
  int _lastSeenQuotaMb;

  void _onPreferencesChanged() {
    final quotaMb = dashcamPreferences.storageQuotaMb;
    if (quotaMb != _lastSeenQuotaMb) {
      _lastSeenQuotaMb = quotaMb;
      // The pass reads the service's quota when its turn runs — after the
      // host has passed the new configuration on (it listens too).
      unawaited(_runStoragePass(DashcamQuotaTrigger.settingChanged));
    }
    notifyListeners();
  }

  /// Fase 16.2-R4.3-R2.6.21: [DashcamService.cameraKnownUnavailable] changed —
  /// told synchronously, by the write that changed it. [status] reads that fact
  /// only while [_liveStatus] is `recording`, so only then does what the UI
  /// shows change, and only then is it published: at a rotation's START or
  /// stop deadline (`recording` → `cameraUnavailable`), when that call
  /// succeeds late (back to `recording`), when the app is backgrounded.
  void _onCameraKnownUnavailableChanged() {
    if (_disposed || _liveStatus != DashcamStatus.recording) return;
    if (_recordingSessionId == null && dashcamService.cameraKnownUnavailable) _cameraUnavailableDuringStop = true;
    notifyListeners();
  }

  /// Fase 16.2-R4.3-R1 (§40-42), replaced in Fase 16.2-R4.3-R2 (§42-44,
  /// independent-review P2-C fix — "modelo de erros não distingue
  /// adequadamente"): dispatches on [error.scope] — see
  /// [DashcamServiceErrorScope]'s own doc for each case.
  ///
  ///  * [DashcamServiceErrorScope.lifecycleCamera]: may only affect this
  ///    session's own status if BOTH [error.generation] matches the CURRENT
  ///    [_lifecycleGeneration] AND [error.origin] is
  ///    [DashcamService.previewController] (the CURRENT controller) — §42's
  ///    own explicit requirement: controller identity ALONE is not
  ///    sufficient (a controller could, in principle, remain the same
  ///    across epochs), so generation is checked FIRST, independently.
  ///  * [DashcamServiceErrorScope.recordingResult]: NEVER affects this
  ///    session's own status (§43) — it remains fully diagnosable via
  ///    [DashcamService.errors]/[DashcamService.originatedErrors] (both
  ///    already delivered this message before this handler even runs), it
  ///    just never poisons a healthy CURRENT camera on its own.
  ///  * [DashcamServiceErrorScope.backendGlobal]: always visible/blocking,
  ///    independent of any generation (§44) — unchanged from R4.3-R1's own
  ///    `origin == null` behavior.
  void _onDashcamServiceError(DashcamServiceError error) {
    switch (error.scope) {
      case DashcamServiceErrorScope.lifecycleCamera:
        if (error.generation != _lifecycleGeneration) return;
        if (!identical(error.origin, dashcamService.previewController)) return;
      case DashcamServiceErrorScope.recordingResult:
        return;
      case DashcamServiceErrorScope.backendGlobal:
        break;
    }
    _liveStatus = DashcamStatus.error;
    errorMessage = error.message;
    notifyListeners();
  }

  /// Fase 16.2-R4.3-R1 (§12, coverage-closure intervention — "prova direta
  /// do consumidor stale"): a thin, test-only forwarder to
  /// [_onDashcamServiceError] itself — NOT a reimplementation of its
  /// filtering logic. Exists because the natural delivery path
  /// ([dashcamService.originatedErrors]) is, for the one call site capable
  /// of a mismatched origin, constrained by DashcamService's own single,
  /// FIFO-serialized native queue to always deliver before a later
  /// controller can have already become current (see the report's own
  /// "error-source classification" section) — this lets a test construct
  /// an arbitrary [DashcamServiceError] (including one whose origin is
  /// deliberately a DIFFERENT, no-longer-current controller) and feed it
  /// through the EXACT SAME production handler, proving the filtering
  /// branch itself, independent of whether today's architecture can
  /// naturally race it into that exact shape.
  @visibleForTesting
  void deliverServiceErrorForTest(DashcamServiceError error) => _onDashcamServiceError(error);

  /// Starts a driving session and (if Dashcam is enabled) recording,
  /// together. [sessionRecorder.startSession] is synchronous and always
  /// succeeds (pure object construction + a Hive put — see its own doc), so
  /// a session is always startable regardless of camera health (the one
  /// exception is admission — see below): the camera
  /// side is fired-and-forgotten, isolated by its own `try`/`catch`.
  ///
  /// Fase 16.2-R4.3-R2.6.1 (§2-§3, independent pre-audit P2-1/P2-2) — two
  /// admission/publication rules:
  ///
  /// **A session that is ENDING is never reusable as a new one (P2-1).**
  /// [DrivingSessionRecorder.startSession] deliberately returns the
  /// already-active session when there is one, and the recorder only clears its
  /// active session after its own asynchronous flush/save — so a `startSession()`
  /// issued while the recorder is still ending A (the camera side of A may
  /// already be idle, which is exactly when the dashcam tile offers "Iniciar
  /// sessão") used to receive A back, re-arm the camera for A, and let the next
  /// `stopSession()` be absorbed by A's own request: a live Recording with no
  /// session to own it, and the following session's clips attributed to A.
  /// Now such a call is REJECTED: it throws a [StateError] before touching
  /// anything (no recorder call, no camera, no bookkeeping) — the caller must
  /// consult [canStartSession] (the UI does, and is told when it flips back) and
  /// retry once A has ended. Deliberately not deferred/queued: the recorder is a
  /// single-slot object with shared per-session state, so a new session cannot
  /// exist until A's flush is done, and a silently queued intent would start a
  /// session at a time the caller can no longer see. Starting while the current
  /// session is ACTIVE (not ending) keeps its long-standing, valid contract:
  /// it returns that same session and (re-)arms the camera for it.
  ///
  /// **A new session is registered here before anyone can observe it (P2-2).**
  /// [DrivingSessionRecorder.startSession] notifies its listeners synchronously;
  /// a listener may call [stopSession] right there. The new session's own
  /// per-session state ([_recordingSessionId], its persistence baseline) is
  /// therefore registered through the recorder's `onCreated` hook — before that
  /// notification — so a re-entrant stop finds a fully identifiable session and
  /// its ordinary stop path invalidates it; the camera is armed afterwards ONLY
  /// if the session is still the one this controller records for.
  DrivingSession startSession() {
    if (!canStartSession) {
      throw SessionAdmissionRejected(
        'startSession() rejected: session ${sessionRecorder.activeSession?.id} is still being ended '
        '(${sessionRecorder.state.name}). Check canStartSession and retry once it has ended.',
      );
    }
    final cameraEnabled = dashcamPreferences.enabled;
    var registeredBeforePublication = false;
    final session = sessionRecorder.startSession(
      onCreated: cameraEnabled
          ? (created) {
              registeredBeforePublication = true;
              _registerSessionForCamera(created.id);
            }
          : null,
    );
    if (cameraEnabled) {
      // The already-active alias (session alive, not ending), or a recorder that
      // did not invoke the hook: same registration as before, just later.
      if (!registeredBeforePublication) _registerSessionForCamera(session.id);
      // A re-entrant stopSession() during the recorder's own notification
      // already invalidated this session ([_stopCamera] clears
      // [_recordingSessionId] synchronously) — arming the camera now would
      // resurrect a session that was stopped at birth.
      if (_recordingSessionId == session.id) unawaited(_startCamera(session.id));
    }
    return session;
  }

  /// The camera-side per-session state a new (or re-armed) session needs before
  /// anything can act on it — see [startSession].
  void _registerSessionForCamera(String sessionId) {
    // Fase 16.2-R4.3-R2.6.3: whether this registration continues a camera-side
    // lifetime that is still live for this SAME session — the already-active
    // alias of a session whose camera side was never stopped.
    // [_recordingSessionId] is the identity to use: it is set here and cleared
    // synchronously by [_stopCamera], in the same slice that tears the
    // session's telemetry setup down.
    final continuesLiveCameraSide = _recordingSessionId == sessionId;
    // Fase 16.2-R4.3-R2 (§19, independent-review P1-2 fix): the session's
    // own clip baseline is born HERE, synchronously, before any Recording
    // for it can possibly exist — never recaptured later by
    // [_finishInitialStart], regardless of how many lifecycle generations
    // this one logical session's own camera setup ends up spanning. See
    // [_ensureClipsBaselineForSession]'s own doc.
    //
    // Fase 16.2-R4.3-R2.6.4: done FIRST — it is the only step here that can
    // throw (it reads [DashcamService.clips]). Registering the identity before
    // it left a half-registered session (identity without its persistence
    // context) whenever it threw from the recorder's `onCreated`, and that
    // session's stop then failed on the missing context (reproduced: P4).
    // Now either everything below is registered or nothing is.
    _ensureClipsBaselineForSession(sessionId);
    _recordingSessionId = sessionId;
    // Fase 16.2-R4.3-R1 (§22/§23): a brand new session's own initial
    // telemetry setup has not been installed yet — see
    // [_initialSetupDone]'s own doc.
    //
    // Fase 16.2-R4.3-R2.6.3: reset ONLY when this starts a new camera-side
    // lifetime — a new session, a live session whose camera side was never
    // registered (dashcam enabled mid-session), or one whose camera side was
    // already stopped (and its telemetry torn down with it). Resetting on the
    // alias of a session that is still recording made [_initialSetupDone]
    // false while that session's writer/subscriptions/sample timer were
    // installed and running; the next `resumed` then treated the session as
    // never set up, ran [_finishInitialStart] again and left the first
    // sample timer ticking forever — into the NEXT sessions' telemetry too
    // (reproduced: 5 ticks/s with no session at all).
    if (!continuesLiveCameraSide) _initialSetupDone = false;
  }

  /// Fase 16.2-R4.3-R2.6.1 (§2): the session whose recorder-side stop this
  /// controller issued ([_stopRecorderSession]) and has not yet seen finish.
  /// Identity, not a flag or a counter: an older stop finishing late must never
  /// clear a newer session's own marker.
  String? _recorderStopSessionId;

  /// Whether [startSession] would currently be accepted — `false` exactly while
  /// the recorder's active session is one this controller is still ending (see
  /// [startSession]). The controller notifies its listeners when this flips back
  /// to `true`, so a UI that disabled its start control can re-enable it.
  ///
  /// Fase 16.2-R4.3-R2.6.4: the recorder is the authority on whether its
  /// session is durably closed — a session whose finalization is in flight OR
  /// FAILED ([DrivingSessionRecorder.hasPendingFinalization]) keeps this
  /// `false`. This controller's own marker only ever knew that the recorder's
  /// stop call had returned, not that it had succeeded: after a failed
  /// persistence it re-admitted the session and a start re-armed the camera for
  /// a session that no longer collects telemetry. While false because of a
  /// failure, [stopSession] is the retry.
  bool get canStartSession {
    if (sessionRecorder.hasPendingFinalization) return false;
    final ending = _recorderStopSessionId;
    return ending == null || sessionRecorder.activeSession?.id != ending;
  }

  /// Fase 16.2-R4.3-R2.6.4: the recorder's last finalization attempt failed —
  /// its session is kept, nothing can start, and [stopSession] retries only the
  /// persistence that is still missing. For a UI to say so.
  bool get sessionFinalizationFailed => sessionRecorder.state == DrivingSessionRecorderState.finalizationFailed;

  /// Fase 16.2-R4.4-R1.2 (X66-screen, independent review of R4.4-R1-T-Rm, P2):
  /// whether a [stopSession] call now would RETRY the failed finalization —
  /// [sessionFinalizationFailed], and no STOP request of that session still in
  /// flight for it to join. The recorder publishes its failure as soon as its own
  /// attempt fails, while the same STOP request may still be waiting for its
  /// camera stop and its telemetry close ([_doStopSession]); a [stopSession]
  /// call in that window joins that request — the same logical STOP — and gets
  /// its outcome, the failure already shown: it starts no attempt. A retry
  /// offered then was lost (a UI that offered it on the recorder's state alone).
  /// This controller notifies its listeners when the request clears and this
  /// becomes `true`. Decided by the same rule [stopSession] uses to join.
  bool get canRetrySessionFinalization => sessionFinalizationFailed && _joinableStopRequest(_stopTargetSessionId) == null;

  /// Fase 16.2-R4.2B-R3 (§28-§31/§36) introduced session-scoped dedup for a
  /// background initialize-settlement watcher. Fase 16.2-R4.2B-R4 (§15-§32,
  /// independent review P1-C — "transição de sessão A→B insegura")
  /// replaced the plain session-id string with THIS raw-Future-identity
  /// tracking: the reviewer demonstrated that a session-id string ALONE
  /// cannot distinguish "this IS my own operation" from "the raw Future
  /// underneath still belongs to whichever caller originated it first" —
  /// `DashcamService.initialize()`'s own reentrancy dedup means a session B
  /// calling it while session A's own raw operation is still retained
  /// silently ATTACHES to A's Future, not a fresh one; if B then treated
  /// that Future's eventual resolution as ITS OWN success, it could start
  /// recording/telemetry for a controller/operation that was never really
  /// B's, while A's own (correctly superseded) cleanup concurrently tore
  /// the same controller back down.
  ///
  /// The raw Future itself ([_observedInitializeSettlement], compared via
  /// [identical]) is the identity; [_observedInitializeSessionId]/
  /// [_observedInitializeIsInitial] record WHO legitimately originated it
  /// and WHY — fixed the instant a raw operation is first observed (see
  /// [_claimOrJoinInitialize]'s own doc), not only once a presentation
  /// timeout fires, and never overwritten by a later caller that merely
  /// finds the SAME Future already claimed by a different session (see
  /// [_claimOrJoinInitialize]'s own doc for exactly how that's enforced).
  /// This is explicitly NOT a lifecycle-generation/R4.3 framework (§50 of
  /// that round's own report) — it is local, private state answering one
  /// narrow question: "who semantically owns the settlement of this one
  /// raw Future?"
  /// Fase 16.2-R4.3-R2 (§5/§6): a single [_ObservedInitialize] replaces
  /// R4.3-R1's own three loose fields (`_observedInitializeSettlement`/
  /// `_observedInitializeSessionId`/`_observedInitializeIsInitial`) plus the
  /// separate `_observedInitializeWatcherInstalled` bool — see
  /// [_ObservedInitialize]'s own doc for why generation must now be part of
  /// this identity.
  _ObservedInitialize? _observedInitialize;

  /// Fase 16.2-R4.2B-R4 (§22): test-only observability — the exact number
  /// of background watchers ever installed via [_watchLateInitialize],
  /// across this controller's whole lifetime. A native call count alone
  /// cannot prove "at most one logical consumer" (both a correct single
  /// watcher AND an incorrect duplicate pair observe the same eventual
  /// native call count) — this lets a test assert the DEDUP itself, not
  /// merely one of its downstream effects.
  @visibleForTesting
  int lateInitializeWatcherInstallCountForTest = 0;

  /// Fase 16.2-R4.2B-R4 (§18-§20), extended in Fase 16.2-R4.3-R2 (§5-§8,
  /// independent-review P1-1 fix — "raw claim precisa incluir generation"):
  /// claims [rawSettlement] for [sessionId]/[generation]/[isInitial] if it
  /// is a genuinely NEW raw operation (never seen before, or the
  /// previously-claimed one has since been cleared — see
  /// [_clearInitializeClaimIfSettled]), or confirms [sessionId] AND
  /// [generation] as the operation's own, already-recorded originator if
  /// [rawSettlement] is the SAME Future already claimed. Returns `true` in
  /// both of those cases (safe for [sessionId]/[generation] to eventually
  /// treat this operation's settlement as its own), `false` when
  /// [rawSettlement] is a raw operation ALREADY, legitimately claimed by a
  /// DIFFERENT session OR a DIFFERENT generation of the SAME session (§8:
  /// "same session / different generation" — CRITICAL: the reviewer's own
  /// reproduced bug was exactly a same-[sessionId] join across generations,
  /// which R4.3-R1's session-only check let through) — the identity of the
  /// FIRST real originator always wins; a later caller, even for the exact
  /// same [sessionId] in a NEWER generation, can never convert it (see
  /// [_doAttemptRecoveryRestart]'s own barrier-wait doc for how a newer
  /// generation is instead made to wait for it, never join it).
  /// [rawSettlement] of `null` (no real operation currently retained at
  /// all) is always `true` — nothing to claim or conflict with.
  ///
  /// Fase 16.2-R4.3-R2.2 (§30, independent-review audit — "raw join
  /// purpose"): also requires [observed.isInitial] to match [isInitial] —
  /// the reviewer found [_ObservedInitialize] already stores [isInitial] but
  /// this join never compared it. Genuinely reachable: DashcamService's own
  /// `_initializeFuture` reuse means an INITIAL attempt's raw native
  /// operation can still be the exact same retained `Future` a later
  /// RECOVERY attempt for the SAME session/generation observes (e.g. the
  /// initial attempt's own caller-side presentation timeout fired and
  /// installed a watcher, while the underlying raw call is still genuinely
  /// pending, and the user's own `retryCamera()` arrives before it settles).
  /// Without this check, recovery could "join" a raw operation whose own
  /// installed watcher (see [_installLateInitializeWatcherIfNeeded]) is
  /// unconditionally driven by the FIRST claimant's own [isInitial] — here,
  /// `true` — running [_finishInitialStart] once it resolves, while
  /// recovery's own direct continuation (gated on the very same `claimed`
  /// result) could ALSO run its own, different post-success path
  /// concurrently for the identical resolved raw: two independent
  /// continuations for one operation, never a possible outcome for any
  /// other already-established join. A purpose mismatch is now treated
  /// exactly like a foreign generation (this class's own doc, §1 bullet 3,
  /// and [_ObservedInitialize]'s own doc) — a barrier to wait behind, never
  /// something to adopt.
  bool _claimOrJoinInitialize(Future<void>? rawSettlement, String sessionId, int generation, {required bool isInitial}) {
    if (rawSettlement == null) return true;
    final observed = _observedInitialize;
    if (observed != null && identical(observed.rawFuture, rawSettlement)) {
      return observed.sessionId == sessionId && observed.generation == generation && observed.isInitial == isInitial;
    }
    _observedInitialize = _ObservedInitialize(rawFuture: rawSettlement, sessionId: sessionId, generation: generation, isInitial: isInitial);
    return true;
  }

  /// Fase 16.2-R4.2B-R4 (§32): [settledFuture] is KNOWN to have genuinely,
  /// fully settled (successfully or not) and needs no background watcher —
  /// clears this controller's own claim on it, but ONLY if it still refers
  /// to THIS exact operation (mirrors [_stopCameraFuture]'s own established
  /// self-clearing pattern) — never clobbers a NEWER claim a different
  /// session/generation may have already installed in the meantime.
  void _clearInitializeClaimIfSettled(Future<void> settledFuture) {
    if (identical(_observedInitialize?.rawFuture, settledFuture)) {
      _observedInitialize = null;
    }
  }

  /// Fase 16.2-R4.2B-R4 (§20-§22): installs the SINGLE background watcher
  /// for [pending] — a no-op if [pending] is no longer the currently
  /// claimed operation (stale call) or a watcher was already installed for
  /// it (by an earlier discoverer — e.g. an initial start's own timeout
  /// racing a retry/recovery's own timeout for the exact same Future).
  /// Always uses the CLAIMANT's own recorded session/generation/purpose
  /// (§18) — never the caller's own — so whichever of [_startCamera]/
  /// [_doAttemptRecoveryRestart] happens to be the one that actually
  /// notices the timeout first still installs a watcher for the RIGHT
  /// owner, not itself.
  ///
  /// Fase 16.2-R4.3-R2 (§9/§10, independent-review P1-1 fix — "watcher
  /// original deve ser instalado antes do hand-off"): every caller of this
  /// method (both catch blocks in [_startCamera]/[_doAttemptRecoveryRestart])
  /// now invokes it BEFORE deciding whether to hand off to a newer
  /// generation, never after — see each catch block's own doc for the exact
  /// ordering bug this closes.
  void _installLateInitializeWatcherIfNeeded(Future<void> pending) {
    final observed = _observedInitialize;
    if (observed == null || !identical(observed.rawFuture, pending)) return;
    if (observed.watcherInstalled) return;
    observed.watcherInstalled = true;
    lateInitializeWatcherInstallCountForTest++;
    // Fase 16.2-R4.2B-R5: the CLAIMANT's own attempt — read fresh here,
    // never the calling method's own local `attempt` variable — so a
    // (structurally rare, but not assumed impossible) caller/claimant
    // mismatch still resolves to the right owner's attempt, matching this
    // method's own pre-existing "claimant, never caller" doc above.
    final attempt = _activeCameraAttempt;
    unawaited(
      _watchLateInitialize(
        pending,
        observed.sessionId,
        isInitialStart: observed.isInitial,
        attempt: (attempt != null && attempt.sessionId == observed.sessionId) ? attempt : null,
      ),
    );
  }

  /// Fase 16.2-R4.2B-R5 (§4-§11, independent review P1 — "session
  /// controller: initial B + retry/recovery B podem existir como DUAS
  /// tentativas semânticas"): the ONE active camera-acquisition attempt for
  /// [_recordingSessionId], if any — see [_CameraAttempt]'s own doc for why
  /// this sits above [_observedInitializeSettlement] rather than replacing
  /// it. Claimed synchronously, the INSTANT [_startCamera]/
  /// [_attemptRecoveryRestart] begin — before any `await`, including the
  /// stale-settlement barrier-wait — so a `retryCamera()`/lifecycle-resumed
  /// call arriving WHILE this session's own initial attempt is still only
  /// waiting on a DIFFERENT session's stale settlement (i.e. before this
  /// attempt has its own raw Future yet) still observes an attempt already
  /// active and declines to start a second, concurrent one. Cleared only at
  /// this attempt's own true semantic terminal: successfully reached
  /// [DashcamStatus.recording], terminally failed with nothing left
  /// retained, or superseded ([stopSession]/[dispose] — see their own doc).
  _CameraAttempt? _activeCameraAttempt;

  /// Fase 16.2-R4.2B-R5 (§38): test-only observability, mirroring
  /// [lateInitializeWatcherInstallCountForTest]'s own established pattern —
  /// not exposed to the UI/product surface.
  @visibleForTesting
  String? get activeCameraAttemptSessionIdForTest => _activeCameraAttempt?.sessionId;

  @visibleForTesting
  bool? get activeCameraAttemptIsInitialForTest => _activeCameraAttempt?.isInitial;

  @visibleForTesting
  int cameraAttemptCreationCountForTest = 0;

  /// `true` only while [attempt] is BOTH the currently-active attempt
  /// (checked via [identical] — Fase 16.2-R4.2B-R5 §21: an old attempt must
  /// never be confused with a newer one for the same [sessionId], e.g. a
  /// terminated initial attempt vs. a later, legitimate recovery attempt)
  /// AND [sessionId] is still genuinely wanted (not disposed, not
  /// superseded by a newer/different session) AND (Fase 16.2-R4.3-R1
  /// §14/§15) [attempt]'s own captured [_CameraAttempt.generation] still
  /// EXACTLY matches [_lifecycleGeneration] — a background/foreground cycle
  /// always changes the current generation, so this alone is sufficient to
  /// detect "a lifecycle transition happened since this attempt was
  /// created", with no need to separately compare [_lifecycleEligible] at
  /// most checkpoints (see [requireEligible]'s own doc for the one class of
  /// checkpoint that still needs it).
  ///
  /// [requireEligible] additionally requires [_lifecycleEligible] to be
  /// `true` RIGHT NOW — Fase 16.2-R4.3-R1 (§12/§20/§29): needed ONLY at the
  /// checkpoints that are about to EMIT new native intent or PUBLISH
  /// [initializing]/[recording] (never at a pure barrier/cleanup-decision
  /// checkpoint) — because an attempt created WHILE ALREADY ineligible
  /// (e.g. [_startCamera] called while backgrounded) keeps the SAME
  /// generation for as long as that epoch lasts, so generation-matching
  /// alone cannot distinguish "still in the same, still-ineligible epoch"
  /// from "back in an eligible one". Once eligibility has been confirmed at
  /// such a checkpoint, no LATER checkpoint in the same attempt can
  /// observe eligibility having silently gone false without ALSO seeing
  /// the generation change (background always increments it — see
  /// [_updateLifecycleGeneration]'s own doc) — which the generation check
  /// already catches — so `requireEligible` is never needed twice in one
  /// attempt's own flow.
  bool _attemptStillValid(_CameraAttempt attempt, String sessionId, {bool requireEligible = false}) {
    if (_disposed || _recordingSessionId != sessionId || !identical(_activeCameraAttempt, attempt)) {
      return false;
    }
    if (attempt.generation != _lifecycleGeneration) return false;
    if (requireEligible && !_lifecycleEligible) return false;
    return true;
  }

  /// Releases [attempt]'s claim on [_activeCameraAttempt] — but ONLY if it
  /// is still the CURRENT one (Fase 16.2-R4.2B-R5 §21: "uma tentativa antiga
  /// nunca limpa a nova"). A no-op if a newer attempt (for this session or
  /// any other) has already replaced it.
  void _clearAttemptIfCurrent(_CameraAttempt attempt) {
    if (identical(_activeCameraAttempt, attempt)) {
      _activeCameraAttempt = null;
    }
  }

  /// Fase 16.2-R4.3-R1 (§17, D0's own critical "progresso após stale op"
  /// gate): deterministically continues a still-wanted session's own
  /// camera work for the CURRENT lifecycle generation, right when a PRIOR
  /// generation's own continuation discovers it is stale and stops short —
  /// never a timer/retry poll (explicitly prohibited by D0), always
  /// triggered exactly once, synchronously, from the exact point that
  /// discovery happens. Simply re-enters [_attemptRecoveryRestart] — itself
  /// already fully idempotent/self-guarding (in-flight dedup, active-
  /// attempt check, session/disposed check, eligibility check — see its own
  /// doc) — so this call is always SAFE to make unconditionally, from every
  /// "stale, give up" branch in [_startCamera]/[_doAttemptRecoveryRestart]/
  /// [_watchLateInitialize]/[_finishInitialStart]/[_finishStartingRecording],
  /// with no need to first determine WHY the prior attempt became invalid:
  /// if the session already ended, is disposed, or another attempt already
  /// claimed the slot, [_attemptRecoveryRestart] itself correctly no-ops;
  /// if the ONLY reason was a lifecycle-generation change and the CURRENT
  /// generation is genuinely eligible right now, it correctly starts a
  /// fresh attempt — using [_initialSetupDone] to decide whether that fresh
  /// attempt must still complete the session's own initial setup exactly
  /// once (§22/§23) or may reuse what is already installed.
  ///
  /// Fase 16.2-R4.3-R1 (reentrant self-block fix — found via L5's own
  /// causal test, not masked): [_finishStartingRecording]/[_finishInitialStart]'s
  /// own superseded branch can call this from INSIDE
  /// [_doAttemptRecoveryRestart]'s own, still-unwinding call stack (the
  /// synchronous continuation right after `await _finishStartingRecording(...)`
  /// has not yet returned to [_attemptRecoveryRestart]'s own
  /// `.whenComplete()`) — at that exact instant, [_recoveryFuture] still
  /// references THAT SAME, now-functionally-concluded OUTER call, which
  /// would otherwise make [_attemptRecoveryRestart]'s own in-flight dedup
  /// wrongly re-join it (a permanent no-op — nothing new is ever created,
  /// reproducing the exact "resumed G2 finds Future/attempt G1, joins,
  /// nothing left to trigger recovery" hazard §17 exists to close, just
  /// self-inflicted instead of externally triggered). [_recoveryFuture] is
  /// set ONLY inside [_attemptRecoveryRestart], always in lockstep with
  /// [_activeCameraAttempt] — every caller of this method has ALREADY
  /// cleared [_activeCameraAttempt] before reaching here, so if it reads
  /// `null` right now, any lingering [_recoveryFuture] can only be this
  /// same, now-stale outer call's own reference — safe to clear early
  /// (its own `.whenComplete()` would have done the same, moments later;
  /// this only removes the race against that timing).
  void _continueForCurrentGenerationIfWarranted() {
    if (_activeCameraAttempt == null) {
      _recoveryFuture = null;
    }
    unawaited(_attemptRecoveryRestart());
  }

  /// Fase 16.2-R4.3-R2.6.3: whether [sessionId]'s telemetry producers — the
  /// writer, the snapshot/event subscriptions and the sample timer that
  /// [_finishInitialStart] installs together — are live right now. Derived from
  /// those fields themselves, not from a flag: the writer carries the owning
  /// session's id, and every teardown path ([_stopCamera],
  /// [_teardownStartedRecording], [dispose]) cancels the sample timer along
  /// with the rest. See [_finishInitialStart]'s second defense.
  bool _telemetryInstalledFor(String sessionId) => (_sampleTimer?.isActive ?? false) && _telemetryWriter?.sessionId == sessionId;

  /// Fase 16.2-R4.2B-R5 (§24/§26): tears down whatever partial recording
  /// setup [_finishInitialStart] already performed before discovering (via
  /// the real `previewController.value.isRecordingVideo` signal, checked
  /// immediately before publishing [DashcamStatus.recording] — see that
  /// method's own doc) that this attempt must not publish it after all — no
  /// resource is left dangling, and nothing is duplicated on any later,
  /// legitimate attempt.
  ///
  /// Fase 16.2-R4.3-R2 (§31, independent-review P2/audit fix — "teardown
  /// hoje usa writer/subscriptions/timer compartilhados"): [snapshotSub]/
  /// [eventSub]/[sampleTimer]/[writer] are the caller's OWN, locally
  /// captured references to exactly what IT just installed — never re-read
  /// from the shared `_snapshotSub`/`_eventSub`/`_sampleTimer`/
  /// `_telemetryWriter` fields, which is what makes this safe BY
  /// CONSTRUCTION rather than by an implicit "caller always runs this
  /// synchronously, before any hand-off" ordering argument: even if a
  /// caller's own hand-off happened to race ahead and install a NEWER
  /// generation's own resources into those shared fields first, this method
  /// would still only ever cancel/close what it was explicitly handed. Each
  /// shared field is nulled only if it still, at this exact moment, holds
  /// THIS SAME reference ([identical] — mirrors [_clearAttemptIfCurrent]'s
  /// own established idiom) — never a newer generation's own installation.
  ///
  /// Fase 16.2-R4.3-R2.6.18: [startAttempt] is the identity of the START this
  /// continuation itself issued — see [_stopWhatThisStartDid]. Until then the
  /// stop was targeted with the service's camera and Recording id READ HERE, at
  /// cleanup time, on the argument that nothing could have run in between.
  void _teardownStartedRecording({
    required StreamSubscription<TelemetrySnapshot>? snapshotSub,
    required StreamSubscription<DetectedEvent>? eventSub,
    required Timer? sampleTimer,
    required DashcamTelemetryWriter? writer,
    required DashcamStartAttempt? startAttempt,
  }) {
    snapshotSub?.cancel();
    if (identical(_snapshotSub, snapshotSub)) _snapshotSub = null;
    eventSub?.cancel();
    if (identical(_eventSub, eventSub)) _eventSub = null;
    sampleTimer?.cancel();
    if (identical(_sampleTimer, sampleTimer)) _sampleTimer = null;
    if (writer != null) _finalizeUnownedTelemetryWriter(writer, 'while releasing the telemetry file of a recording torn down before it was published');
    if (identical(_telemetryWriter, writer)) _telemetryWriter = null;
    _stopWhatThisStartDid(startAttempt);
  }

  /// Fase 16.2-R4.3-R2.6.18 (substitute independent review of R2.6.17, R1 —
  /// "camera-only cleanup"): the cleanup of ONE camera START this controller
  /// issued and no longer wants — the attempt went stale while the START was in
  /// flight, or the START returned without the camera really recording.
  ///
  /// [startAttempt] is that START's own identity, handed out by
  /// [DashcamService.beginStartLoopRecording] at the instant the START was
  /// accepted, and passed back unchanged: the service stops what THAT START
  /// recorded (whatever a segment rotation has turned it into since) and takes
  /// the recording intent down only while that START is still the latest one.
  ///
  /// Before, this stop named `previewController` and `activeRecordingId` as
  /// read after the START returned. That is the camera plus whatever Recording
  /// the service happened to hold: when the START had produced none — it
  /// outlived its deadline, or nothing had ever been recorded on this service —
  /// the id was `null` or an older Recording's, and the request amounted to
  /// "whatever this camera is doing", which the service took for the START
  /// standing at that instant, a later one included.
  ///
  /// `null` means the service did not accept that call as a START of its own (a
  /// recording was already wanted and absorbed it): this attempt started
  /// nothing, so there is nothing of its own to stop.
  void _stopWhatThisStartDid(DashcamStartAttempt? startAttempt) {
    if (startAttempt == null) return;
    unawaited(dashcamService.stopLoopRecording(startAttempt: startAttempt));
  }

  /// Fase 16.2-R4.3-R2.6.2 — the ONE admission barrier every camera acquisition
  /// attempt passes before it may emit native work: [_startCamera] (a session's
  /// first start) AND [_doAttemptRecoveryRestart] (user retry, `resumed`,
  /// generation hand-off). Those are the only two places a [_CameraAttempt] is
  /// ever created.
  ///
  /// The barrier is the existing [_stopCameraFuture] — an earlier session's
  /// still-finishing teardown, which already chains every earlier one through
  /// [_stopCamera]'s `physicalBarrier` (Fase 16.2-R4.3-R2.6). Until R2.6.2 only
  /// [_startCamera] waited for it. The recovery path did not, which was
  /// unreachable while a new session had no id yet during the recorder's own
  /// notification — until R2.6.1 registered that id there (`onCreated`, so a
  /// re-entrant stop can cancel it). A synchronous recorder listener calling
  /// [retryCamera] at that point then created the new session's attempt through
  /// recovery, which initialized the camera while the previous session's
  /// teardown was still pending; that teardown's late cleanup then published
  /// `idle` over the new, physically recording session (pre-audit C-3b,
  /// reproduced). Waiting here restores the premise [_stopCamera] relies on:
  /// no newer session can be recording by the time an older teardown's own
  /// cleanup runs.
  ///
  /// Returns `null` when there is nothing to wait for, so the caller adds NO
  /// `await` in the common case (its synchronous prefix — e.g. [_startCamera]'s
  /// `initializing` notification — stays exactly as it was). The caller must
  /// re-validate its attempt after awaiting a non-null result. Never a
  /// self-wait: a teardown never awaits an attempt or a recovery, and a stop of
  /// the attempt's own session would already have invalidated the attempt
  /// synchronously. [_stopCamera] never propagates an error; `catchError` only
  /// keeps an unexpected one from turning into an attempt failure.
  Future<void>? _priorPhysicalTeardown() => _stopCameraFuture?.catchError((_) {});

  Future<void> _startCamera(String sessionId) async {
    // Fase 16.2-R4.2B-R5 (§7/§20, independent review P1 — "initial B +
    // retry/recovery B podem existir como DUAS tentativas semânticas"): the
    // single-flight claim happens HERE, synchronously, before ANY `await` —
    // including the stale-settlement barrier-wait below. This is the exact
    // point the reviewer's reproduction exploited: the OLD code only ever
    // recorded "this session owns an attempt" once a real raw Future
    // existed (via [_claimOrJoinInitialize]), which is too late — a
    // `retryCamera()` arriving while this session's own initial attempt was
    // still merely waiting on a DIFFERENT session's stale settlement found
    // nothing recorded yet for this session and started a second, fully
    // concurrent recovery attempt.
    if (_activeCameraAttempt != null && _activeCameraAttempt!.sessionId == sessionId) {
      // An attempt (initial or recovery — first purpose wins, §8) is
      // already active for this session; nothing new to do.
      return;
    }
    final attempt = _CameraAttempt(sessionId: sessionId, isInitial: true, generation: _lifecycleGeneration);
    _activeCameraAttempt = attempt;
    cameraAttemptCreationCountForTest++;

    // Wait out any still-finishing previous session's camera teardown
    // first. Physically found on real hardware (Fase 15 validation): back-
    // to-back sessions started faster than the previous one's _stopCamera
    // could finish let this method's guard below see a stale _liveStatus
    // and return early, WITHOUT ever refreshing _clipsBeforeThisSession for
    // the new session. That stale baseline (still the *previous* session's,
    // from before its own clip existed) then made the previous session's
    // already-correctly-persisted clip look "new" again to THIS session's
    // later _persistClipsForSession call, silently duplicating the same
    // clip into both sessions' DashcamClipRecord lists — the previous
    // session's own clip finalizes/persists exactly once regardless,
    // untouched by this wait, since it doesn't depend on anything this
    // method does.
    final priorTeardown = _priorPhysicalTeardown();
    if (priorTeardown != null) await priorTeardown;
    if (!_attemptStillValid(attempt, sessionId)) {
      _clearAttemptIfCurrent(attempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }

    if (_liveStatus == DashcamStatus.initializing || _liveStatus == DashcamStatus.recording) {
      _clearAttemptIfCurrent(attempt);
      return;
    }
    // Fase 16.2-R4.2B-R4 (§23-§27, independent review P1-C — "transição de
    // sessão A→B insegura"): if a DIFFERENT session's own raw initialize()
    // operation is still retained, wait for it to genuinely settle FIRST —
    // never call dashcamService.initialize() while it's still pending,
    // which would silently ATTACH this session's own intent to that
    // unrelated operation (DashcamService's own reentrancy dedup is a pure
    // efficiency optimization keyed on "one native call in flight," not a
    // promise about WHICH caller's semantic intent it satisfies — see
    // [_claimOrJoinInitialize]'s own doc). Awaiting [staleSettlement] here
    // is only ever a BARRIER ("I must not start yet"), never a claim on its
    // outcome (§25) — this session's own attempt begins fresh, below, only
    // once it is confirmed clear. Fase 16.2-R4.2B-R5 (§11): [attempt] was
    // already claimed above, BEFORE this wait — a retry/resume arriving
    // during this exact window now correctly observes it as active.
    // Fase 16.2-R4.3-R2 (§5-§8, independent-review P1-1 fix): reads the
    // full [_ObservedInitialize] identity now, not merely a bare Future —
    // this call's own barrier-wait stays unconditional (any real raw
    // operation observed at all, regardless of whose it is) because
    // [_startCamera] only ever runs ONCE per brand-new [sessionId] (see
    // [startSession]'s own doc) — it can never legitimately observe a raw
    // operation that is ALREADY its own.
    final observedBarrier = _observedInitialize;
    if (observedBarrier != null) {
      await observedBarrier.rawFuture.catchError((_) {});
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      // Fase 16.2-R4.2B-R4 (§26): do not rely on Future-listener
      // registration ordering between DashcamService's own internal
      // `whenComplete` (which clears `pendingInitializeSettlement`) and the
      // await above — confirm explicitly instead of assuming it already
      // ran first.
      for (var i = 0; i < 50 && dashcamService.pendingInitializeSettlement != null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
    }

    // Fase 16.2-R4.3-R1 (§20/§24, D0-approved lifecycle-generation
    // architecture): the pre-native checkpoint — requires eligibility NOW,
    // not merely generation match (this attempt could have been created
    // while already ineligible — see [_attemptStillValid]'s own doc).
    //
    // Fase 16.2-R4.3-R2 (§16/§17, independent-review fix — "status não é
    // control plane"): R4.3-R1 used to set `DashcamStatus.error` here purely
    // to make foreground-absence re-trigger recovery on the NEXT `resumed`
    // — the reviewer correctly rejected reusing a user-visible status as an
    // internal signalling channel for "not foreground yet, not a camera
    // failure". [_cameraAcquisitionNeeded] (consulted directly by
    // [_handleLifecycleChange]'s own `resumed` branch — see its own doc) now
    // derives that need from real internal state instead — no status
    // mutation, no [notifyListeners] here at all; abandoning purely because
    // this attempt was created while ineligible is a silent, no-op-visible
    // wait, exactly like any other stale-barrier abandonment in this class.
    if (!_attemptStillValid(attempt, sessionId, requireEligible: true)) {
      _clearAttemptIfCurrent(attempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }
    // Fase 16.2-R4.4-R2: the free-space guard, before any camera intent — see
    // [_admitByStorage].
    final storageCheck = _storageCheckBeforeStart();
    if (storageCheck != null && !await _admitByStorage(storageCheck, attempt, sessionId)) return;

    _liveStatus = DashcamStatus.initializing;
    errorMessage = null;
    notifyListeners();
    Future<void>? rawSettlement;
    // Fase 16.2-R4.2B-R4 (§18-§20): declared OUTSIDE the try (unlike a
    // plain `final` inside it, which Dart scopes only to the try block and
    // would be unreachable from `catch`) — `true` by default so a failure
    // BEFORE the claim call itself (there is none today, but this is the
    // safe default regardless) never accidentally skips this session's own
    // cleanup below.
    var claimed = true;
    try {
      // Fase 16.2-R4.3-R1 (§11-§13/§24): passes THIS attempt's own
      // semantic validity down into DashcamService's existing pre-emission
      // checkpoints — see [DashcamService.initialize]'s own doc. Fase
      // 16.2-R4.3-R2 (§41): also passes this attempt's own generation, so a
      // controller-scoped error DashcamService later reports for whatever
      // controller this call creates can be tagged with it.
      final callFuture = dashcamService.initialize(
        semanticStillValid: () => _attemptStillValid(attempt, sessionId),
        lifecycleGeneration: attempt.generation,
      );
      rawSettlement = dashcamService.pendingInitializeSettlement;
      attempt.rawSettlement = rawSettlement;
      claimed = _claimOrJoinInitialize(rawSettlement, sessionId, attempt.generation, isInitial: true);
      await callFuture;
      if (claimed && rawSettlement != null) _clearInitializeClaimIfSettled(rawSettlement);
      if (!claimed) {
        // Fase 16.2-R4.2B-R4 (§25): despite the wait above, this call still
        // ended up attached to a DIFFERENT session's own operation — never
        // treat its outcome as this session's own, and never touch its
        // claim/watcher bookkeeping (that legitimately belongs to the OTHER
        // session's own path, success or failure alike).
        if (!_attemptStillValid(attempt, sessionId)) {
          _clearAttemptIfCurrent(attempt);
          _continueForCurrentGenerationIfWarranted();
          return;
        }
        _clearAttemptIfCurrent(attempt);
        _liveStatus = DashcamStatus.error;
        errorMessage = 'Camera initialize is currently owned by another session';
        notifyListeners();
        return;
      }
      // Fase 16.2-R4.3-R2 (§28/§29): captured atomically, right after
      // `initialize()` genuinely succeeded — see [_finishInitialStart]'s
      // own identical doc for why this must happen before any further
      // `await`/staleness branch, not be re-read later.
      final initializedController = dashcamService.previewController;
      if (!_attemptStillValid(attempt, sessionId)) {
        // Fase 16.2-R4.2B-R3 (§28/§29B): superseded (stopped/disposed/a
        // newer session already replaced this one) while initialize() was
        // in flight — mirrors [_doAttemptRecoveryRestart]'s own identical,
        // already-established handling of this exact race. Fase
        // 16.2-R4.3-R2 (§28): targeted at [initializedController] — never a
        // newer generation's own, possibly-already-current one.
        //
        // Fase 16.2-R4.3-R2.6.19 (N6): ...and asked for only when there IS a
        // camera to name. `null` here means this attempt's `initialize()` was
        // abandoned before its native call (DashcamService completes it
        // normally, without a camera): the attempt has nothing of its own to
        // release, and passing that `null` on would ask for the service's
        // UNTARGETED release — see [_watchLateInitialize]'s own doc.
        _clearAttemptIfCurrent(attempt);
        if (initializedController != null) {
          unawaited(dashcamService.releaseIdleCamera(expectedController: initializedController));
        }
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      await _finishInitialStart(sessionId, attempt);
    } catch (error) {
      // Fase 16.2-R4.3-R2 (§9/§10, independent-review P1-1 fix — "watcher
      // original deve ser instalado antes do hand-off"): resolve THIS
      // attempt's own claim/watcher obligation on the raw operation FIRST,
      // unconditionally — regardless of whether this attempt itself is
      // still current. R4.3-R1 checked staleness FIRST and returned
      // immediately when stale, which could leave a genuinely-still-pending
      // raw operation "observed" but never watched — the exact P1-1
      // reproduction (nobody left to conclude it, so a later, same-sessionId
      // generation's own claim check could find it unclaimed and wrongly
      // treat it as available to adopt). Never: hand-off, THEN install
      // ownership of the old raw (§10's own explicit prohibition).
      var attemptStillPending = false;
      if (claimed) {
        final pending = dashcamService.pendingInitializeSettlement;
        if (pending != null) {
          _installLateInitializeWatcherIfNeeded(pending);
          attemptStillPending = true;
        } else if (rawSettlement != null) {
          _clearInitializeClaimIfSettled(rawSettlement);
        }
      }
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      if (!attemptStillPending) {
        _clearAttemptIfCurrent(attempt);
      }
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    }
    if (_disposed) return;
    notifyListeners();
  }

  /// The full "initialize succeeded, now actually start recording for the
  /// FIRST time this session" continuation — Fase 16.2-R4.2B-R3 (§30):
  /// deliberately NOT the same as [_finishStartingRecording] (recovery's own
  /// tail) — recovery reuses this session's ALREADY-open telemetry writer/
  /// subscriptions/sample timer (a mere camera loss never tears those down),
  /// but the very first start must create them for the first time. Exactly
  /// one call per session, whether reached synchronously (the common case,
  /// from [_startCamera]) or via [_watchLateInitialize] after a presentation
  /// timeout — same superseded-checks after each `await` as
  /// [_finishStartingRecording]/[_doAttemptRecoveryRestart] already
  /// establish, so a session that moved on while this was still running
  /// never gets a resurrected recording, telemetry writer, or timer.
  Future<void> _finishInitialStart(String sessionId, _CameraAttempt attempt) async {
    // Fase 16.2-R4.3-R2.6.3 (second defense): camera acquisition and telemetry
    // setup are separate eligibilities. This continuation always (re)arms the
    // camera, but it may install telemetry producers only if THIS session has
    // none live. Reachable with them live: [_startCamera] always ends here,
    // including for the alias of a session whose camera merely errored while
    // its telemetry kept running. Overwriting would leave the earlier sample
    // timer and subscriptions running unowned. In that case this defers to
    // [_finishStartingRecording] — the same camera-only continuation recovery
    // uses when it reuses what is already open — and keeps [_initialSetupDone]
    // true, since this session's setup IS installed.
    if (_telemetryInstalledFor(sessionId)) {
      _initialSetupDone = true;
      await _finishStartingRecording(sessionId, attempt);
      return;
    }
    // Fase 16.2-R4.3-R2 (§19, independent-review P1-2 fix): the baseline is
    // captured ONCE, in [startSession] itself, the instant this logical
    // session is born — NEVER recaptured here. See
    // [_ensureClipsBaselineForSession]'s own doc for why recapturing here
    // (R4.3-R1's own behavior) silently absorbed a real, already-finalized
    // clip from an earlier, superseded generation's own setup into THIS
    // generation's baseline, making it invisible to [_persistClipsForSession].
    // Fase 16.2-R4.3-R1 (§20/§29): pre-native checkpoint for THIS native
    // emission — requires eligibility now (see [_attemptStillValid]'s own
    // doc), and is ALSO consulted again, once, right before the real
    // `startVideoRecording()` call inside DashcamService itself (see
    // [DashcamService.startLoopRecording]'s own doc) in case the FIFO
    // delays this request further.
    //
    // Fase 16.2-R4.3-R2.6.18: [DashcamService.beginStartLoopRecording] — the
    // same START, which also hands back its own identity at the instant it is
    // accepted. Every cleanup below passes THAT identity back
    // ([_stopWhatThisStartDid]); none of them reads the service's camera or
    // Recording any more to decide what "this attempt's" was. (Fase
    // 16.2-R4.3-R2 §28/§29 captured `previewController`/`activeRecordingId`
    // right after the START returned for that purpose: the camera plus
    // whatever Recording the service held, which is not the START — see
    // [_stopWhatThisStartDid].)
    final start = dashcamService.beginStartLoopRecording(
      semanticStillValid: () => _attemptStillValid(attempt, sessionId, requireEligible: true),
      // Fase 16.2-R4.3-R2.5 (§22/§31): the logical session's own id is the
      // producer token every clip of this Recording will carry — see
      // [_producerTokenFor].
      clipOwnerToken: _producerTokenFor(sessionId),
    );
    final startAttempt = start.attempt;
    await start.presentation;
    if (!_attemptStillValid(attempt, sessionId)) {
      _clearAttemptIfCurrent(attempt);
      _stopWhatThisStartDid(startAttempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }

    final writer = DashcamTelemetryWriter(sessionId: sessionId, onFailure: _onTelemetryWriterFailed);
    // Fase 16.2-R4.3-R1 (§7-§9, coverage-closure intervention): the
    // production call is always `writer.open()` directly (the hook below
    // is `null` by default and this method's own behavior is byte-for-byte
    // unchanged when it is) — this exists ONLY so a test can deterministically
    // hold this exact async boundary open (gate a REAL `open()` call, not
    // replace it) to prove the writer/subscriptions/timer setup this
    // continuation is about to perform is genuinely still pending when a
    // lifecycle transition invalidates it. See
    // [openTelemetryWriterHookForTest]'s own doc.
    final hook = openTelemetryWriterHookForTest;
    if (hook != null) {
      await hook(writer, writer.open);
    } else {
      await writer.open();
    }
    if (!_attemptStillValid(attempt, sessionId)) {
      // Superseded while the telemetry file itself was still opening — the
      // recording above is already real and unowned by anyone; stop it too,
      // not just the writer, so nothing keeps running for a session nobody
      // wants anymore. Fase 16.2-R4.3-R1 (§38): only THIS local `writer` is
      // ever touched here — never a re-read of `_telemetryWriter`, which by
      // now may already belong to a newer generation's own setup. Fase
      // 16.2-R4.3-R2.6.18: the STOP names this attempt's own START
      // ([startAttempt], taken above, before this `await`) — for the same
      // reason.
      _clearAttemptIfCurrent(attempt);
      _finalizeUnownedTelemetryWriter(writer, 'while releasing the telemetry file of a superseded camera attempt');
      _stopWhatThisStartDid(startAttempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }
    // Fase 16.2-R4.3-R2.6.10 (pre-audit P2-B): open() now completes only once
    // the file is really open, and reports a failure instead of throwing
    // (see DashcamTelemetryWriter.open). A session whose telemetry file could
    // not be opened must never be published as `recording`: before, dart:io
    // opened lazily, so this line was passed, the UI said "Gravando" and every
    // sample of the session was accepted and lost. The failure takes the same
    // path an open() that threw always took (a telemetry directory that could
    // not be created): [_startCamera]'s own catch publishes `error` with it.
    // The recording started above keeps running, as it always did on that
    // path; STOP ends it and indexes its clip.
    if (writer.state != DashcamTelemetryWriterState.open) {
      // Fase 16.2-R4.3-R2.6.11: this is how the session's telemetry stands
      // until an attempt opens the file — see [_unopenedTelemetryWriter].
      _unopenedTelemetryWriter = writer;
      throw writer.failure ?? StateError('dashcam telemetry file not opened (${writer.state.name})');
    }
    _telemetryWriter = writer;
    _unopenedTelemetryWriter = null;

    _latestSnapshot = null;
    final snapshotSub = snapshotStream.listen((snapshot) => _latestSnapshot = snapshot);
    _snapshotSub = snapshotSub;
    final eventSub = eventStream.listen(_onDetectedEvent);
    _eventSub = eventSub;
    final sampleTimer = Timer.periodic(_sampleInterval, (_) => _onSampleTick());
    _sampleTimer = sampleTimer;

    // Fase 16.2-R4.2B-R5 (§24/§25/§29, independent review P1 — "defesa
    // contra falso REC"), extended in Fase 16.2-R4.3-R1 (§43) with
    // `requireEligible`: the definitive guard, immediately before
    // publishing — re-validates [attempt] (generation + eligibility) AND
    // confirms native recording is REALLY still true. A START that was
    // valid when requested can have been superseded by a legitimate
    // teardown before this point (e.g. this exact attempt's own
    // single-flight claim already prevents a concurrent recovery from
    // causing this — see [_CameraAttempt]'s own doc — but this stays as an
    // explicit, independent proof, not an assumption resting solely on the
    // single-flight guarantee above it).
    if (!_attemptStillValid(attempt, sessionId, requireEligible: true)) {
      // Superseded — whatever superseded this attempt already owns
      // `_liveStatus`; just tear down what THIS continuation itself just
      // installed (see [_teardownStartedRecording]'s own doc — Fase
      // 16.2-R4.3-R2 §31 — for why these are passed explicitly, as local
      // references, rather than re-read from the shared fields).
      _clearAttemptIfCurrent(attempt);
      _teardownStartedRecording(snapshotSub: snapshotSub, eventSub: eventSub, sampleTimer: sampleTimer, writer: writer, startAttempt: startAttempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }
    if (dashcamService.previewController?.value.isRecordingVideo != true) {
      // Still current, but the real native signal disagrees with a bare
      // "startLoopRecording() returned" — never publish `recording` on
      // that alone (§25: no new status invented for R5 — converges to the
      // same `error` this class already uses elsewhere).
      _clearAttemptIfCurrent(attempt);
      _teardownStartedRecording(snapshotSub: snapshotSub, eventSub: eventSub, sampleTimer: sampleTimer, writer: writer, startAttempt: startAttempt);
      _liveStatus = DashcamStatus.error;
      errorMessage = 'Camera stopped recording before it could be confirmed';
      return;
    }

    recordingStartedAt = DateTime.now();
    _cameraUnavailableDuringStop = false;
    _liveStatus = DashcamStatus.recording;
    // Fase 16.2-R4.3-R1 (§22/§23): the session's own initial setup is now
    // DURABLY installed — a later generation's own hand-off (see
    // [_initialSetupDone]'s own doc) may safely reuse it instead of
    // repeating it.
    _initialSetupDone = true;
    initialSetupInstallCountForTest++;
    _clearAttemptIfCurrent(attempt);
  }

  /// Fase 16.2-R4.3-R2.6.2: test-only, behavior-neutral count of every
  /// [_onSampleTick] ever run by this controller — lets a test prove that no
  /// sample timer (orphaned or otherwise) keeps ticking once no session is
  /// recording, and that a session runs exactly one.
  @visibleForTesting
  int sampleTickCountForTest = 0;

  void _onSampleTick() {
    sampleTickCountForTest++;
    final snapshot = _latestSnapshot;
    if (snapshot != null) {
      _telemetryWriter?.add(_sampleFromSnapshot(snapshot));
    }
  }

  void _onDetectedEvent(DetectedEvent event) {
    _telemetryWriter?.add(_sampleFromSnapshot(event.snapshot, eventType: event.type));
    if (event.severity == EventSeverity.high || event.severity == EventSeverity.critical) {
      unawaited(protectCurrentClip());
    }
  }

  DashcamTelemetrySample _sampleFromSnapshot(TelemetrySnapshot snapshot, {DetectedEventType? eventType}) {
    return DashcamTelemetrySample(
      timestamp: snapshot.timestamp,
      latitude: snapshot.latitude,
      longitude: snapshot.longitude,
      speedKmh: snapshot.speedKmh,
      altitudeMeters: snapshot.altitudeMeters,
      headingDegrees: snapshot.headingDegrees,
      pitchDegrees: snapshot.pitchDegrees,
      rollDegrees: snapshot.rollDegrees,
      longitudinalG: snapshot.longitudinalG,
      lateralG: snapshot.lateralG,
      verticalG: snapshot.verticalG,
      resultantG: snapshot.gForceMagnitude,
      eventType: eventType,
    );
  }

  /// Marks the clip currently being recorded as protected against quota
  /// eviction — the replacement for `DashcamService`'s previously-undone
  /// G-force-watcher hook, now driven by [EventDetectionEngine]'s own
  /// already-confirmed, already-debounced events instead of a second
  /// detector. Also reused directly as the fullscreen "Proteger este
  /// clipe" menu action. Best-effort: a failure here must never surface as
  /// an app error, it only means the clip isn't guaranteed protected.
  ///
  /// Fase 16.2-R4.4-R1: the retroactive half — [DashcamService.clips]' last
  /// clip, marked protected in memory by `markClipAsProtected` — is now also
  /// recorded in the index ([_indexProducedClip]), where it used to stay in
  /// memory only. Its name keeps the protection it was published with
  /// (renaming would leave an indexed path stale); the index entry only ever
  /// goes from unprotected to protected, never back. If this write fails, the
  /// clip's next index trigger retries it protected (Fase 16.2-R4.4-R1.1). A
  /// process that dies before any of them succeeds loses only the upgrade
  /// (P3, declared).
  Future<void> protectCurrentClip() async {
    // The clip markClipAsProtected marks — read in the same synchronous slice
    // (it marks the last clip before its first await), not after the await,
    // when a segment published meanwhile would be the last one.
    final clips = dashcamService.clips;
    final marked = clips.isEmpty ? null : clips.last;
    try {
      await dashcamService.markClipAsProtected();
    } catch (_) {
      // Best-effort, see doc above.
    }
    if (marked != null && marked.isProtected) await _indexProducedClip(marked);
  }

  /// Fase 16.2-R4.3-R2.6.10: every telemetry writer whose close this controller
  /// started and has not seen finish — a stopped session's
  /// ([_finalizeStoppedTelemetry]), a disposed recording's or a torn-down
  /// attempt's ([_finalizeUnownedTelemetryWriter]) — mapped to the Future that
  /// owns its outcome (it never completes with an error). Non-empty = some
  /// telemetry file is still being finalized, so the status is not `idle`.
  final Map<DashcamTelemetryWriter, Future<void>> _telemetryFinalizations = {};

  /// Test-only: completes once every telemetry finalization in flight right
  /// now has finished (never with an error: each outcome is already handled).
  @visibleForTesting
  Future<void> telemetryFinalizationsForTest() => Future.wait<void>(_telemetryFinalizations.values.toList());

  @visibleForTesting
  int get pendingTelemetryFinalizationsForTest => _telemetryFinalizations.length;

  /// Fase 16.2-R4.3-R2.6.10 (pre-audit P2-A): the current recording's telemetry
  /// file failed — its writer refuses every sample from then on — while the
  /// camera keeps recording video. A degraded recording, deliberately NOT
  /// [DashcamStatus.error]: `error` would hide the live preview and offer
  /// "Tentar novamente", whose recovery re-initializes the camera
  /// (`DashcamService.initialize` cancels the recording in progress) and could
  /// not repair the file anyway (a failed writer never writes again). [status]
  /// stays `recording`; this says what is being lost. From the session's STOP
  /// on it is the status itself ([_finalizeStoppedTelemetry]). `null` while
  /// the telemetry is healthy.
  String? get telemetryFailureMessage {
    final writer = _telemetryWriter;
    if (writer == null || writer.failure == null) return null;
    return _telemetryFailureMessage(writer);
  }

  static String _telemetryFailureMessage(DashcamTelemetryWriter writer) {
    final refused = writer.refusedSampleCount;
    return 'Telemetria da dashcam incompleta: ${writer.persistedSampleCount} de ${writer.acceptedSampleCount} amostras gravadas'
        '${refused > 0 ? ', $refused recusadas após a falha' : ''} (${writer.failure})';
  }

  /// [DashcamTelemetryWriter.onFailure] of every writer this controller
  /// creates. Only the current recording's own writer changes what this
  /// controller shows ([telemetryFailureMessage]); a writer already handed to
  /// a finalization reports through it.
  void _onTelemetryWriterFailed(DashcamTelemetryWriter writer) {
    if (_disposed || !identical(writer, _telemetryWriter)) return;
    // Not synchronously: the writer calls this from inside its own operation,
    // and a listener must not re-enter the controller there (the same reason
    // [stopSession] defers its own notification).
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  /// Fase 16.2-R4.3-R2.6.10 (pre-audit P2-A/P2-C): takes [sessionId]'s writer —
  /// synchronously, in [_doStopSession]'s slice, and keyed by the writer's own
  /// session id, so another session's writer is never taken — and starts its
  /// close, independently of the camera teardown. The returned Future is part
  /// of the STOP request and never fails: its outcome is handled here.
  ///
  /// - A failure already known while recording, or found while finishing the
  ///   file, is published as [DashcamStatus.error] with what was lost: the STOP
  ///   no longer ends as a silent success (pre-audit: 53 accepted, 25 written,
  ///   STOP "ok", `idle`).
  /// - Once a NEWER session has registered for the camera
  ///   ([_recordingSessionId]), the status is that session's: a failure of this
  ///   older file is reported through [FlutterError.reportError] instead of
  ///   being published over it. Likewise after [dispose].
  /// - No timeout: a close that never completes keeps this STOP request, and
  ///   [DashcamStatus.finalizing], pending — the file is never declared
  ///   finalized on a timer — while the camera, already released, stays free.
  ///
  /// Fase 16.2-R4.3-R2.6.11 (independent review, P2): whichever of the cases
  /// above applies, the terminal result of the file is ALSO recorded durably on
  /// the session the writer belongs to ([_recordTelemetryOutcome]) — success
  /// included. Before, a failure of an older session's file after a newer one
  /// had started existed only as that [FlutterError] report, and a failure
  /// published as the status was gone at the next START: the session's own
  /// record never said its telemetry was lost. The status rules above are
  /// unchanged; the newer session's status, camera and writer are not touched.
  Future<void>? _finalizeStoppedTelemetry(String sessionId) {
    final writer = _telemetryWriter;
    if (writer == null || writer.sessionId != sessionId) return _recordUnopenedTelemetry(sessionId);
    _telemetryWriter = null;
    final knownAtStop = writer.failure;
    // It failed while recording (then shown by [telemetryFailureMessage]): from
    // this STOP on, the dashcam status itself says so. [stopSession]'s own
    // deferred notification publishes it.
    if (knownAtStop != null) _publishTelemetryFailure(writer);
    return _trackTelemetryFinalization(writer, recordsSessionOutcome: true, (error, stack) {
      if (error != null) {
        if (!_disposed && _recordingSessionId == null) {
          _publishTelemetryFailure(writer);
        } else if (!identical(error, knownAtStop)) {
          _reportTelemetryFailure(error, stack!, 'while finalizing the telemetry file of the stopped session ${writer.sessionId}');
        }
      }
      _settleFinalizingStatus();
      if (!_disposed) notifyListeners();
    });
  }

  /// Fase 16.2-R4.3-R2.6.11: the STOP of a session whose telemetry file never
  /// opened ([_unopenedTelemetryWriter]) — there is no file to finalize, but
  /// that session's telemetry did end: unwritten. Recorded on it, as part of
  /// the same STOP request. The status is not touched (the open failure has
  /// been the status since the START). `null` when [sessionId] has no such
  /// writer: it never had any telemetry obligation.
  Future<void>? _recordUnopenedTelemetry(String sessionId) {
    final writer = _unopenedTelemetryWriter;
    if (writer == null || writer.sessionId != sessionId) return null;
    _unopenedTelemetryWriter = null;
    return _recordTelemetryOutcome(writer);
  }

  /// Fase 16.2-R4.3-R2.6.11: records [writer]'s terminal result on the session
  /// that owns it — [DashcamTelemetryWriter.sessionId], fixed when the writer
  /// was created for that session and the ONLY identity used here. Static on
  /// purpose: it cannot read which session this controller records now
  /// ([_recordingSessionId], the recorder's active session, [_telemetryWriter]),
  /// so the result of A can never land on B, nor be skipped because A is no
  /// longer current. Runs once per writer, after its close has settled (or, for
  /// a writer that never opened, at its session's STOP), when its counters are
  /// final.
  ///
  /// Success only when the writer has no failure AND every accepted sample was
  /// written. Never throws: a result that could not be recorded — or that the
  /// session's record refuses because it already carries a different one — is
  /// reported; one that finds its session deleted, or marked for deletion, is
  /// dropped (see [persistSessionTelemetryOutcome]). So is one whose session
  /// was never durably finalized by a recorder that is gone (Fase
  /// 16.2-R4.3-R2.6.12): the record is the recorder's, and this result is not
  /// allowed to finalize it in the recorder's place.
  static Future<void> _recordTelemetryOutcome(DashcamTelemetryWriter writer) async {
    final sessionId = writer.sessionId;
    final outcome = writer.failure == null && writer.unpersistedSampleCount == 0 ? DashcamTelemetryOutcome.success : DashcamTelemetryOutcome.failed;
    try {
      final written = await persistSessionTelemetryOutcome(
        sessionId,
        outcome: outcome,
        accepted: writer.acceptedSampleCount,
        persisted: writer.persistedSampleCount,
        refused: writer.refusedSampleCount,
      );
      if (written == SessionTelemetryOutcomeWrite.conflict) {
        throw StateError('session $sessionId already carries a different telemetry outcome; it was kept');
      }
    } catch (error, stack) {
      _reportTelemetryFailure(
        error,
        stack,
        'while recording the telemetry outcome of session $sessionId (${outcome.name}: ${writer.persistedSampleCount} of '
        '${writer.acceptedSampleCount} samples written, ${writer.refusedSampleCount} refused) — it may not survive a restart',
      );
    }
  }

  /// Fase 16.2-R4.3-R2.6.10: closes a writer no STOP owns — a recording torn
  /// down by [dispose], or a camera attempt superseded or torn down before it
  /// published anything. The close is started and OWNED (tracked in
  /// [_telemetryFinalizations], its outcome handled) instead of a bare
  /// `unawaited` Future nobody owns; a failure not already surfaced before
  /// (while recording, or by the open) is reported through
  /// [FlutterError.reportError].
  void _finalizeUnownedTelemetryWriter(DashcamTelemetryWriter writer, String context) {
    final known = writer.failure;
    unawaited(
      _trackTelemetryFinalization(writer, (error, stack) {
        if (error != null && !identical(error, known)) _reportTelemetryFailure(error, stack!, context);
        if (_settleFinalizingStatus() && !_disposed) notifyListeners();
      }),
    );
  }

  /// [recordsSessionOutcome] (Fase 16.2-R4.3-R2.6.11): the writer is the one
  /// its session recorded with and this close is that session's STOP, so its
  /// terminal result is the session's and is recorded on it
  /// ([_recordTelemetryOutcome]) as the last part of the returned Future — the
  /// STOP request therefore lasts until it is. It comes AFTER the file's own
  /// finalization is over and published: recording it may have to wait for the
  /// recorder to finish the session's record, which says nothing about the
  /// telemetry file and must not keep the status at `finalizing`. Not for a
  /// writer that never recorded (an attempt superseded or torn down before it
  /// was published — the session's writer of record comes later, or never), nor
  /// for a recording torn down by [dispose]: that session was not stopped, and
  /// what a process being torn down may still get to write is not a result to
  /// rely on — its telemetry outcome stays unknown.
  Future<void> _trackTelemetryFinalization(
    DashcamTelemetryWriter writer,
    void Function(Object? error, StackTrace? stack) onOutcome, {
    bool recordsSessionOutcome = false,
  }) {
    final finalization = () async {
      Object? error;
      StackTrace? stack;
      try {
        await writer.close();
      } catch (e, s) {
        error = e;
        stack = s;
      }
      _telemetryFinalizations.remove(writer);
      onOutcome(error, stack);
      if (recordsSessionOutcome) await _recordTelemetryOutcome(writer);
    }();
    _telemetryFinalizations[writer] = finalization;
    return finalization;
  }

  /// `finalizing` → `idle` once no telemetry file is still being finalized.
  /// Only from `finalizing`: any other status belongs to someone else (a newer
  /// session's camera, an error). Returns whether it changed.
  bool _settleFinalizingStatus() {
    if (_liveStatus != DashcamStatus.finalizing || _telemetryFinalizations.isNotEmpty) return false;
    _liveStatus = DashcamStatus.idle;
    return true;
  }

  void _publishTelemetryFailure(DashcamTelemetryWriter writer) {
    final message = _telemetryFailureMessage(writer);
    final current = errorMessage;
    if (_liveStatus == DashcamStatus.error && current != null) {
      // A camera error of the same STOP is kept; the telemetry loss is added
      // (once — this runs at STOP and again with the close's outcome).
      if (!current.contains(message)) errorMessage = '$current\n$message';
    } else {
      errorMessage = message;
    }
    _liveStatus = DashcamStatus.error;
  }

  static void _reportTelemetryFailure(Object error, StackTrace stack, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'dashcam session controller',
        context: ErrorDescription(context),
      ),
    );
  }

  /// In-flight [stopSession] request, if any — see that method's own doc
  /// (Fase 16.2-R1, P1-6; identity added in Fase 16.2-R4.3-R2.6).
  _SessionStopRequest? _stopSessionRequest;
  int _nextStopRequestId = 0;

  /// Test-only: the identity of the [stopSession] request currently in flight
  /// (`null` when none) — see [_SessionStopRequest].
  @visibleForTesting
  int? get inFlightStopRequestIdForTest => _stopSessionRequest?.requestId;

  /// Test-only: the logical session the in-flight [stopSession] request
  /// targets (`null` when none is in flight, or when it targets "no session").
  @visibleForTesting
  String? get inFlightStopRequestSessionIdForTest => _stopSessionRequest?.sessionId;

  /// Fase 16.2-R4.3-R2.6.1 (§3-§4): test-only, behavior-neutral view of the
  /// logical session this controller is currently recording (or acquiring the
  /// camera) for — [_recordingSessionId] — so a test can prove WHICH session a
  /// camera acquisition/recording belongs to (or that none does).
  @visibleForTesting
  String? get recordingSessionIdForTest => _recordingSessionId;

  /// Stops recording and finishes the driving session together.
  ///
  /// Re-entrant-safe (Fase 16.2-R1, independent review P1-6): a second call
  /// for the SAME logical session while one is already in flight joins the
  /// same in-flight [Future] instead of running [_stopCamera] a second time —
  /// mirroring `DashcamService.initialize()`'s own, already-established dedup
  /// pattern. Without this, two concurrent `stopSession()` calls (e.g. a
  /// user double-tap, or a UI stop racing an automatic one) would each
  /// independently call `dashcamService.stopLoopRecording()`,
  /// `_persistClipsForSession()`, and `dashcamService.releaseIdleCamera()`
  /// — demonstrated by the review to risk persisting the same clip twice
  /// and running cleanup twice.
  ///
  /// Fase 16.2-R4.3-R2.6 (§1-§12, independent-review P1-A — "stopSession(B) é
  /// absorvido por A", reproduced 20/20): the R1-era dedup was keyed on "a stop
  /// is in flight", not on WHICH logical session is being stopped. With
  /// session A's teardown still finishing and session B already started, a
  /// public `stopSession()` meant to stop B found A's in-flight [Future] and
  /// returned it: when A finished, "the stop" was satisfied, B's own request
  /// never became an operation, B's pending camera acquisition was never
  /// invalidated, and B went on to reach `recording` after it had been
  /// stopped. A Future in flight cannot mean "any future request to stop any
  /// session is already satisfied" — this method now separates the PHYSICAL
  /// teardown barrier (A's native obligations, which B and later sessions must
  /// still wait for — see [_stopCameraFuture]/[_stopCamera]'s `physicalBarrier`)
  /// from the SEMANTIC session stop request (this one, which belongs to B).
  ///
  /// The target logical session is captured SYNCHRONOUSLY, first, before any
  /// dedup decision — the recorder's active session, which is what
  /// `startSession()` returns and what the caller means by "the session I am
  /// stopping" (falling back to [_recordingSessionId] only if the recorder has
  /// none). An in-flight request is joined only when it is semantically the
  /// same request ([_SessionStopRequest.matches]); a request for a different
  /// session gets its OWN [_SessionStopRequest], whose synchronous prefix
  /// ([_stopCamera]) invalidates that session's pending/future camera
  /// acquisition immediately — not when the earlier session finally finishes.
  ///
  /// Fase 16.2-R4.4-R1.2 (X66-screen): a call for the same session while the
  /// recorder's attempt has already failed but the request is still in flight
  /// (its camera stop, its telemetry close) joins that request too and gets its
  /// outcome — the failure: it is NOT a retry of the persistence. Once the
  /// request has cleared, a call is a new request whose own recorder attempt
  /// retries what is still missing. [canRetrySessionFinalization] says which of
  /// the two a call would be now.
  Future<void> stopSession() {
    final targetSessionId = _stopTargetSessionId;
    final inFlight = _joinableStopRequest(targetSessionId);
    if (inFlight != null) return inFlight.completion!;
    final request = _SessionStopRequest(requestId: _nextStopRequestId++, sessionId: targetSessionId);
    _stopSessionRequest = request;
    final completion = _doStopSession(request).whenComplete(() {
      // Only clear the slot if a newer request has not already replaced it — an
      // earlier request finishing must never erase a later session's own.
      if (!identical(_stopSessionRequest, request)) return;
      _stopSessionRequest = null;
      // Fase 16.2-R4.4-R1.2 (X66-screen): with the recorder's attempt already
      // failed, this is when a retry becomes possible
      // ([canRetrySessionFinalization]) — and nothing else notifies at this
      // point (the recorder and the telemetry close did, earlier, while this
      // request was still in flight). Only then: no other listener-visible state
      // changes here.
      if (!_disposed && sessionFinalizationFailed) notifyListeners();
    });
    request.completion = completion;
    // Fase 16.2-R4.3-R2.6.4: the recorder entered its finalization synchronously
    // inside [_doStopSession], so [canStartSession] is already false — publish
    // it right after this slice rather than only when some later step happens
    // to notify: a start control rendered before this stop (e.g. the dashcam
    // tile) must not stay enabled for the whole finalization. Not synchronously:
    // a listener that itself called stopSession() must not be re-entered
    // mid-call.
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
    return completion;
  }

  /// The logical session a [stopSession] call made now would target — captured
  /// synchronously, first (see [stopSession]).
  String? get _stopTargetSessionId => sessionRecorder.activeSession?.id ?? _recordingSessionId;

  /// The in-flight [stopSession] request a call for [targetSessionId] joins —
  /// the same logical STOP ([_SessionStopRequest.matches]) — or `null` when that
  /// call would start its own. The one rule shared by [stopSession] and
  /// [canRetrySessionFinalization].
  _SessionStopRequest? _joinableStopRequest(String? targetSessionId) {
    final inFlight = _stopSessionRequest;
    return inFlight != null && inFlight.matches(targetSessionId) ? inFlight : null;
  }

  /// [sessionRecorder.stopSession] and the camera-finalize path run
  /// concurrently, not strictly sequentially: `DrivingSessionRecorder.stopSession()`
  /// already persists the session as part of its own call, and blocking it
  /// on a slow/hung camera finalize would itself violate this phase's
  /// failure-isolation requirement. The two paths are independent, each its
  /// own `try`/`catch`, joined only by the session id they both key off.
  ///
  /// Fase 16.2-R4.3-R2.6.10 (pre-audit P2-C): the session's telemetry file is a
  /// THIRD independent obligation ([_finalizeStoppedTelemetry]), no longer part
  /// of [_stopCamera]. [_stopCamera] used to await the writer's close in its
  /// `finally`, before releasing the camera — so a close that never completed
  /// (a hung disk) kept the camera held, and since [_stopCameraFuture] is the
  /// barrier every later camera acquisition waits for, every later session got
  /// no camera while the UI said "Pronto". Now the physical teardown (and so
  /// the barrier) never depends on the file; this STOP request still completes
  /// only once the file is finalized too, and until then the status is
  /// [DashcamStatus.finalizing], not `idle`.
  Future<void> _doStopSession(_SessionStopRequest request) async {
    final sessionId = _recordingSessionId;
    Future<void>? cameraStop;
    Future<void>? telemetryStop;
    if (sessionId != null) {
      // Fase 16.2-R4.3-R2.6 (§12): an EARLIER session's teardown still in
      // flight is a physical barrier for this session's own camera-side work —
      // captured before [_stopCameraFuture] is replaced below, so the chain
      // A → B → C stays intact (C waits on B's future, which waits on A's).
      final future = _stopCamera(sessionId, physicalBarrier: _stopCameraFuture);
      cameraStop = future;
      // Same synchronous slice: [_stopCamera]'s synchronous prefix has just
      // cancelled the sample timer and the subscriptions, so nothing adds to
      // the writer any more.
      telemetryStop = _finalizeStoppedTelemetry(sessionId);
      // Self-clearing (same pattern as DashcamService._initializeFuture):
      // only null it back out if a newer stop hasn't already replaced it.
      _stopCameraFuture = future;
      unawaited(
        future.whenComplete(() {
          if (identical(_stopCameraFuture, future)) _stopCameraFuture = null;
        }),
      );
    }
    await Future.wait<void>([
      _stopRecorderSession(),
      ?cameraStop,
      ?telemetryStop,
    ]);
  }

  /// [sessionRecorder.stopSession] plus the bookkeeping [canStartSession] needs
  /// (Fase 16.2-R4.3-R2.6.1 §2): from this synchronous slice until the recorder
  /// has really cleared its active session, that session is ENDING — the marker
  /// is set BEFORE the recorder is called, and cleared (identity-checked) only
  /// when the recorder's own stop has finished, successfully or not. The
  /// recorder's Future is returned untouched, so a failure still reaches
  /// [stopSession]'s callers exactly as before. Assumes every stop of this
  /// recorder goes through the controller (the app's only stop entry point when
  /// a dashcam controller exists — see `SessionRecordingScreen`).
  Future<void> _stopRecorderSession() {
    final endingSessionId = sessionRecorder.activeSession?.id;
    if (endingSessionId == null) return sessionRecorder.stopSession();
    _recorderStopSessionId = endingSessionId;
    final stop = sessionRecorder.stopSession();
    unawaited(
      stop.then<void>((_) {}, onError: (_) {}).whenComplete(() {
        if (_recorderStopSessionId != endingSessionId) return;
        _recorderStopSessionId = null;
        // The ending window just closed. [canStartSession] itself flipped when
        // the recorder cleared its active session (a moment earlier, with no
        // controller notification of its own), so this — not a before/after
        // comparison — is what tells a UI that disabled its start control that
        // it may re-enable it.
        if (!_disposed) notifyListeners();
      }),
    );
    return stop;
  }

  Future<void> _stopCamera(String sessionId, {Future<void>? physicalBarrier}) async {
    _snapshotSub?.cancel();
    _snapshotSub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _latestSnapshot = null;
    // Fase 16.2-R1 (independent review, P1-2): cleared here, synchronously,
    // before any `await` — not only at the end in the `finally` block below
    // (kept there too, harmlessly redundant, as a fallback for whatever
    // legitimately-different sessionId case it originally guarded). A real
    // regression test caught the previous, end-only clearing racing a
    // concurrent recovery attempt's own staleness check
    // (`_recordingSessionId != sessionId`): both were unblocked by the same
    // underlying queued native operation settling, and depending on
    // microtask-scheduling luck the recovery's check could still see the
    // *old* sessionId and incorrectly treat itself as still current. Clearing
    // it immediately, in the same synchronous slice this method is entered
    // in, removes that race entirely rather than narrowing it.
    if (_recordingSessionId == sessionId) {
      _recordingSessionId = null;
      // Fase 16.2-R4.3-R2.6.21: a stop that begins with the camera already
      // unavailable — see [_cameraUnavailableDuringStop].
      if (_liveStatus == DashcamStatus.recording && dashcamService.cameraKnownUnavailable) _cameraUnavailableDuringStop = true;
    }
    // Fase 16.2-R4.2B-R5 (§22, independent review P1): stopSession
    // semantically invalidates this session's own active camera attempt,
    // synchronously, in this same slice — same reasoning as
    // [_recordingSessionId] immediately above: a late continuation must not
    // START, publish recording, recreate the writer, or restore
    // subscriptions after this point. The underlying raw native Future (if
    // any) still follows DashcamService's own established retention
    // contract — nothing here fakes cancelling it.
    if (_activeCameraAttempt != null && _activeCameraAttempt!.sessionId == sessionId) {
      _activeCameraAttempt = null;
    }
    // Fase 16.2-R4.3-R2.2 (§4-§6/§41): this session's own persistence context
    // — the ONE and ONLY read of [_currentPersistenceContext] in this method —
    // captured synchronously, before any `await` (in particular before the
    // [physicalBarrier] wait below: a later session may already be current
    // once that wait ends).
    final context = _currentPersistenceContext;
    assert(
      context != null && context.sessionId == sessionId,
      'startSession() must have already created this session\'s own persistence context via _ensureClipsBaselineForSession',
    );
    // Fase 16.2-R4.3-R2.6 (§7/§12, independent-review P1-A): [physicalBarrier]
    // is an EARLIER session's still-finishing teardown ([_stopCameraFuture] as
    // it was when this stop request was accepted) — a PHYSICAL barrier this
    // session's own camera-side work must respect, never something that
    // satisfies this session's own SEMANTIC stop request. By this point
    // everything semantic is already done and synchronous: this session's
    // [_recordingSessionId] and [_activeCameraAttempt] were just invalidated
    // above, so whatever this session's own pending acquisition was waiting on,
    // it can never acquire the camera afterward. Waiting here only preserves
    // the ordering the earlier session's native obligations require (later
    // sessions wait on THIS method's [_stopCameraFuture], which now transitively
    // includes them); the raw native operations themselves are never cancelled.
    // Never throws ([_stopCamera] itself never propagates an error).
    // Null (the common case) adds no `await` at all — the synchronous
    // capture-before-first-await ordering below is byte-for-byte what it was.
    if (physicalBarrier != null) {
      await physicalBarrier.catchError((_) {});
    }

    // Fase 16.2-R4.3-R2.1 (§9/§10): captured BEFORE issuing the STOP,
    // synchronously — the controller this session's own stop targets, used
    // below to scope the final release to ONLY this session's own controller.
    //
    // Fase 16.2-R4.3-R2.5 (§15-§18, independent-review P1-2 — "handle
    // legítimo rejeitado por RecordingId snapshot antigo"): the Recording id
    // is deliberately NO LONGER captured here. R2.1-R2.4 compared the
    // eventual handle's `recordingId` against `activeRecordingId` read at this
    // instant — but when a queued START is still in flight, the Recording this
    // stop legitimately concludes DOES NOT EXIST YET, so that snapshot names
    // the PREVIOUS Recording and the (correct) late handle was discarded,
    // leaving the clip un-indexed. A snapshot taken before an obligation's own
    // target materializes is not authority over that obligation; the
    // service-side stop INTENT is — see [DashcamStopOutcome.intentId].
    final controllerBeingStopped = dashcamService.previewController;
    // Fase 16.2-R4.3-R2.2 (§25-§27) captured the telemetry writer here too, so
    // the `finally` block below could close only this session's own writer.
    // Fase 16.2-R4.3-R2.6.10: the writer is no longer this method's business
    // at all — [_doStopSession] hands it to [_finalizeStoppedTelemetry] in the
    // same synchronous slice this method was entered in, so the physical
    // teardown below never waits on the file.
    // Fase 16.2-R4.3-R2.2 (§4-§6/§41, independent-review P1 — "STOP
    // obligation deve ser capturada antes do await"): (1) the STOP is
    // emitted and (2) its own [DashcamStopOutcome.handle] is captured as a
    // VALUE here, synchronously, before this method's own first `await` —
    // never by reading [DashcamService.pendingStopHandle] again later (see
    // [DashcamStopOutcome]'s own doc for the fast-settle race that closes).
    // (3) this session's own persistence context is captured here too, from
    // [_currentPersistenceContext] — the ONE and ONLY read of that field in
    // this whole method; every persistence operation below uses [context]
    // explicitly from this point on, never re-consulting "whatever the
    // current session is" after an `await` (the reviewer's own reproduced
    // P1: a REAL `startSession()` for B landing between A's STOP and A's own
    // immediate persistence pass must never redirect A's own clips onto B's
    // baseline).
    final stopOutcome = dashcamService.beginStopLoopRecording();
    final stopHandleFuture = stopOutcome.handle;
    // Fase 16.2-R4.3-R2.3 (§24-§27) shared a set of this stop's failed paths
    // between the immediate pass and the late one, so a write failure was not
    // reported twice. Fase 16.2-R4.4-R1: the index reports each clip's failure
    // once per process itself (`ensureClipIndexed`), and both passes RETRY
    // whatever is not confirmed yet — the set is gone.
    try {
      // (4) only now — after (1)-(3) above — does this await the bounded
      // presentation.
      await stopOutcome.presentation;
      if (context != null) {
        // Fase 16.2-R4.3-R2.2 (§16/§48, Checkpoint A test-only seam): lets a
        // test pause EXACTLY here — the native STOP has already genuinely
        // resolved (this line is only reached once [stopOutcome.presentation]
        // itself has), but this session's own immediate persistence pass has
        // not yet run — the precise window the reviewer's own X6 reproduction
        // needs. `null` (the default) means zero behavior change.
        final gate = beforeImmediatePersistenceHookForTest;
        if (gate != null) await gate();
        // (5) immediate persistence — explicitly against [context], never
        // against `sessionId`/`_clipsBeforeThisSession` read independently.
        // Fase 16.2-R4.4-R1: no longer the first durable fact of the session's
        // clips — each was indexed when its segment was published.
        // Fase 16.2-R4.4-R2.1.1 (RES-1, owner decision): started here and
        // OWNED ([_followUpClipIndex]), no longer awaited — neither by the
        // camera release below, nor by the physical barrier the next START
        // waits for, nor by stopSession(). The canonical file is the
        // durability frontier (R4.4-R1); the index write it still gets is
        // queued in the index FIFO, where an earlier publication's quota pass
        // may hold it for as long as that pass runs.
        unawaited(_followUpClipIndex(context));
        // (6) Fase 16.2-R4.3-R2.4 (§9, independent-review P1-A #2 —
        // "announcement discovery expires"): [stopHandleFuture] is observed
        // via a durable, NON-blocking continuation here — NOT a direct
        // `await` — and this is a deliberate behavior change from R2.2/R2.3.
        // The comment this replaced claimed the underlying announcement
        // "has always already resolved too" by the time [stopOutcome
        // .presentation] resolves — true under the OLD [_adoptAnnouncedStop],
        // where a presentation-timeout resolved BOTH [presentation] AND
        // [handle] together. Since R2.4, a presentation timeout resolves
        // [presentation] ALONE — [handle] keeps running independently,
        // bounded only by the real, physical obligation's own resolution
        // (DashcamService._adoptAnnouncedStop's own doc) — which, for an
        // ADOPTED, foreign announcement (e.g. a concurrent, unrelated
        // releaseIdleCamera() call still genuinely queued behind another
        // long-retained native operation), can take arbitrarily long. A
        // direct `await` here would silently turn THIS method's own
        // established bounded-by-presentation contract into an unbounded
        // one — a real, reproduced deadlock (a caller awaiting THIS method's
        // own return can never reach the very code that would eventually
        // unblock the adopted announcement). [handle] never completes with
        // an error (every producer — DashcamService's own case A/B/C
        // handle-resolution paths — only ever calls `.complete()`, never
        // `.completeError()`), so detaching this from the surrounding
        // `try`/`catch` loses no error observability.
        //
        // Fase 16.2-R4.3-R2.5 (§15/§16): the handle is trusted by INTENT
        // identity — `handle.intentId == stopOutcome.intentId` — not by
        // reconstructing the correlation from a pre-issuance RecordingId/
        // controller snapshot (which rejected a legitimate late handle whose
        // Recording was still being started when this stop was issued). Foreign
        // stops are still rejected: [DashcamService] resolves an intent's handle
        // ONLY to a stop that intent itself produced or legitimately adopted
        // ([DashcamService._intentHandle]), and this stop is untargeted
        // ("whichever Recording I stop"), so there is no frozen target to
        // re-check here.
        unawaited(
          stopHandleFuture.then((handle) {
            if (handle != null && handle.intentId != null && handle.intentId == stopOutcome.intentId) {
              // Fase 16.2-R4.4-R2.1.1: owned like the immediate pass. It may now
              // run alongside it: both decide per clip from its latest index
              // write ([_indexWriteSettled]), in the index FIFO, so neither
              // duplicates the other's write.
              unawaited(_ownClipIndexFollowUp(context.sessionId, _watchLateStopSettlement(context, handle.settlement)));
            }
          }),
        );
      }
      // Fase 16.2-R4.3-R2.2 (§25-§27, independent-review finding — audited
      // and left UNCONDITIONAL, unlike the writer/controller cleanup below):
      // a version of this method once guarded this assignment on
      // `_recordingSessionId == null`, mirroring the `finally` block's own
      // targeted release — but that guard is actively HARMFUL here: a newer
      // session B's own [_startCamera] structurally cannot reach genuine
      // recording (or install anything of its own) until THIS session's own
      // [_stopCameraFuture] resolves (see [_startCamera]'s own
      // `pendingStop` wait, unchanged/frozen this round) — meaning B can
      // never actually be "already recording" by the time this line runs.
      // B's own [_startCamera], once unblocked by this method's own return,
      // RELIES on [_liveStatus] having already been reset away from
      // `recording`/`initializing` (its own pre-existing Fase 15 guard) to
      // know it is safe to proceed — conditionally skipping this assignment
      // (as an earlier version of this round's own fix did) starves that
      // check forever once B has already claimed [_recordingSessionId],
      // deadlocking B's own camera acquisition permanently. Unconditional
      // is therefore correct: by construction, only THIS session's own
      // outcome can be being reported at this exact point.
      //
      // Fase 16.2-R4.3-R2.6.2: "by construction" requires that EVERY path
      // able to acquire the camera for B waits for this method first — not
      // only [_startCamera]. The recovery path ([_doAttemptRecoveryRestart])
      // did not, and a `retryCamera()` issued while B was being published
      // (R2.6.1's `onCreated` registration) reached genuine recording here
      // while this line then published `idle` over it. Both paths now share
      // [_priorPhysicalTeardown]; this assignment itself stays unconditional.
      //
      // Fase 16.2-R4.3-R2.6.10: `idle` ("Pronto") only if no telemetry file is
      // still being finalized; otherwise `finalizing` — the camera side is
      // done, the session is not ([_settleFinalizingStatus] moves it on once
      // the file is).
      if (_liveStatus != DashcamStatus.error) {
        _liveStatus = _telemetryFinalizations.isEmpty ? DashcamStatus.idle : DashcamStatus.finalizing;
      }
    } catch (error) {
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    } finally {
      // Fase 16.2-R4.3-R2.6.10: the telemetry writer used to be closed (and
      // awaited) here, before the release below — see [_doStopSession].
      //
      // Fase 15 hardware-testing fix: this session is over and no new one
      // is starting — release the camera hardware now rather than leaving
      // it held open for the rest of the app process's lifetime (see
      // DashcamService.releaseIdleCamera's own doc for the physically-
      // confirmed real cost of not doing this). Best-effort, matching every
      // other cleanup step in this block: a failure here must not block
      // finishing the session, and a future session's own initialize()
      // would release/replace whatever's left held regardless.
      //
      // Fase 16.2-R4.3-R2.2 (§25-§27, independent-review finding —
      // [controllerBeingStopped]'s own [identical] check ALONE is not
      // sufficient here, unlike every other targeted-cleanup call site in
      // this class: `DashcamService` deliberately REUSES an already-held,
      // still-idle controller for a brand new session's own
      // `startLoopRecording()` call instead of always re-initializing (a
      // real, intentional optimization — see [DashcamService.initialize]'s
      // own doc) — so a NEWER session B that starts WHILE this stale
      // continuation is still paused (e.g. genuinely awaiting Hive I/O
      // above) can end up holding THE EXACT SAME controller object A itself
      // was using, without B ever calling `initialize()` at all. In that
      // case `identical(dashcamService.previewController,
      // controllerBeingStopped)` is `true` even though the controller now
      // belongs to B — [controllerBeingStopped] cannot distinguish "my own,
      // now-idle controller" from "a newer session's own, now-ACTIVE
      // controller that happens to be the same object". [_recordingSessionId]
      // is what actually can: it is set synchronously, before any `await`,
      // the instant ANY session starts wanting the camera (`startSession`),
      // so `null` here means genuinely nobody wants it right now — the only
      // condition under which releasing is this stale continuation's own
      // duty to perform at all. If a newer session already claims it,
      // release is left entirely to THAT session's own eventual
      // `_stopCamera` — never performed here.
      //
      // Fase 16.2-R4.3-R2.6.19 (N6): ...and only when this session HAD a
      // camera when it was stopped. [controllerBeingStopped] is `null` when
      // the session ended before it had one — its `initialize()` still in
      // flight, abandoned, or failed. Passing that `null` on asked the
      // service for its UNTARGETED release (see [_watchLateInitialize]'s own
      // doc for what `null` means there): not "this session's camera", which
      // does not exist, but whatever camera is current when the request's
      // turn in the service's queue comes. Here the queue's order kept that
      // harmless — the request is issued before a later session can ask for
      // anything.
      //
      // It was not always an empty request (pre-review microaudit of this
      // round: the same sequences traced with and without this condition).
      // Queued behind this session's own `initialize()` still in flight, it
      // is what disposed the camera that initialize produced whenever it
      // settled inside the stop deadline, and this method returned only
      // then; when the initialize took longer, this method gave up at the
      // deadline and returned with it still in flight. Now it never waits:
      // nothing is asked for, and this method's Future — which is
      // [_stopCameraFuture], and one of the three things `stopSession()`
      // waits for — completes while that initialize may still produce a
      // camera.
      //
      // What holds a later camera attempt back from that initialize is not
      // this Future, and beyond the deadline it never was: it is
      // [_observedInitialize]. The claim is taken when the initialize is
      // asked for and cleared only when it settles (nothing in this method
      // touches it), and [_startCamera]/[_doAttemptRecoveryRestart] wait for
      // it before they may ask for an initialize of their own. The process
      // owner stays held for as long as the initialize is in flight. The
      // camera it produces late is released by name by the attempt that asked
      // for it ([_startCamera], [_doAttemptRecoveryRestart]) or by its
      // watcher ([_watchLateInitialize]) — or by the service's own teardown,
      // if the controller is disposed first. That request reaches the
      // service's queue ahead of the next attempt's `initialize()`; or, when
      // it is the watcher's and the next attempt was already waiting, behind
      // it, in which case that `initialize()` has itself disposed the late
      // camera before opening its own, and the named release finds a
      // different camera current and does nothing. Either way one camera is
      // open at a time, and none is left open.
      if (_recordingSessionId == null && controllerBeingStopped != null) {
        try {
          await dashcamService.releaseIdleCamera(expectedController: controllerBeingStopped);
        } catch (_) {
          // Best-effort — see above.
        }
      }
      if (_recordingSessionId == sessionId) {
        _recordingSessionId = null;
      }
      recordingStartedAt = null;
    }
    // Fase 16.2-R1: deliberately outside the try/finally above (a `return`
    // inside `finally` risks silently swallowing control flow — flagged by
    // the analyzer itself) rather than as its own last statement inside it.
    // _stopCamera is reached after several awaits, so dispose() (synchronous,
    // always-immediate — see its own doc) can in principle have already torn
    // this ChangeNotifier down by the time execution gets here (whole-app
    // teardown mid-stop). Same reasoning/guard as _attemptRecoveryRestart's own.
    if (_disposed) return;
    notifyListeners();
  }

  /// Fase 16.2-R4.3-R2.2 (§4/§6/§9/§11-§13/§20/§35-§40): the shared claim +
  /// Hive-write body behind both the immediate pass ([_stopCamera]) and the
  /// late pass ([_watchLateStopSettlement]) — [context] is ALWAYS an
  /// explicit reference the caller captured before any relevant `await`,
  /// never re-derived from "whatever session is current now". New clips are
  /// selected by producer provenance (Fase 16.2-R4.3-R2.5: only clips carrying
  /// this session's own [DashcamClip.producerToken]) and [context]'s own
  /// [_SessionPersistenceContext._baseline], then each candidate path is
  /// CLAIMED synchronously via [_tryClaimPath] — entirely BEFORE this method's
  /// own first `await` — so two concurrent passes of the SAME session (its
  /// immediate pass racing its own late one) can never both write the same
  /// clip (§11-§13: "atomic clip claim" as WRITE-DEDUP; Fase 16.2-R4.3-R2.1's
  /// own registry-based defense only marked a path persisted AFTER its own Hive
  /// write completed, which was not atomic across that write). Which session a
  /// clip belongs to is decided by its producer, not by this claim.
  ///
  /// A Hive write failure does NOT roll back the claims this call took (Fase
  /// 16.2-R4.3-R2.4 reversed the R2.2/R2.3 "claim rollback" — see
  /// [_claimedPathOwners]'s own doc): a failed write is not proof this
  /// session stopped being the clip's owner. The failure is
  /// reported exactly once (§37), scoped `recordingResult` (§36 — a failure
  /// to index a specific Recording's own clip, never a reason to poison a
  /// healthy current camera), via [DashcamService.reportExternalError] — the
  /// same [DashcamService.errors]/[DashcamService.originatedErrors] streams
  /// every other `recordingResult` failure already uses, rather than a
  /// second, parallel error channel. This method never throws — a failure
  /// here must never surface as an unhandled async error from
  /// [_watchLateStopSettlement]'s own `unawaited` call (§35), and must never
  /// abort [_stopCamera]'s own immediate-pass caller either.
  ///
  /// Fase 16.2-R4.4-R1: this is no longer where the session's clips first
  /// become durable — each one was indexed when its segment was published
  /// ([_indexProducedClip]) — and it no longer writes the index itself: every
  /// candidate goes through `ensureClipIndexed`, the index's one writer. A
  /// clip already indexed costs a lookup and writes nothing; one whose earlier
  /// write failed is RETRIED here (the design's retry policy: the next
  /// in-process trigger, then the next start — no timer, no loop), its failure
  /// still reported once. The old `get` + `addAll` + `put` is gone.
  Future<void> _persistClaimedClips(_SessionPersistenceContext context) async {
    // Fase 16.2-R4.3-R2.2 (§12-§14): keeps [_claimedPathOwners] bounded —
    // see that field's own doc. Cheap: proportional to however many clips
    // currently exist, not to this app run's total lifetime clip count.
    _pruneClaimedPathOwners();
    // Fase 16.2-R4.4-R1: a clip already claimed or already failed is no longer
    // excluded here (it was, until now, by [_claimedPathOwners] and by the
    // stop's own set of failed paths): whether it still needs a write is the
    // index's answer, and a failed one is retried.
    //
    // Fase 16.2-R4.3-R2.5 (§20-§30, independent-review P1-1 — "clip provenance
    // é first-observer-wins"): WHOSE clip this is is decided by its PRODUCER,
    // never by which session's persistence pass happens to see it first. Only
    // clips whose [DashcamClip.producerToken] is this session's own token
    // ([_producerTokenFor]) are candidates — the token was stamped when the
    // clip was born, before it was ever visible in [DashcamService.clips], so
    // no observation order (this session's own pass, another session's pass
    // running outside DashcamService's FIFO, a late continuation) can change
    // it. Unknown provenance (`null` — a Recording started without a token) is
    // NEVER adopted by any session: adopting it would be first-observer
    // semantics again. [context]'s baseline additionally excludes anything that
    // predates the session itself (legacy domain); it can only ever REMOVE a
    // candidate, never make a foreign-token clip eligible.
    final token = _producerTokenFor(context.sessionId);
    final candidates = dashcamService.clips.where((clip) => clip.producerToken == token && !context._baseline.contains(clip)).toList();
    for (final clip in candidates) {
      // Fase 16.2-R4.4-R2.1 (R2-P3-HW-STOP): a clip whose index write already
      // settled (or is settling) costs that write's Future, not a new FIFO turn
      // queued behind its publication's quota pass — see [_indexWriteSettled].
      if (await _indexWriteSettled(clip)) continue;
      await _indexProducedClip(clip);
    }
  }

  /// Fase 16.2-R4.4-R1 — [clip], produced by this process's [dashcamService],
  /// into the index of the session its canonical NAME carries, through
  /// `ensureClipIndexed` (`ClipIndexOrigin.producedInThisProcess`) — the one
  /// path every trigger takes: each published segment ([DashcamService
  /// .publishedClips]), the STOP's immediate and late passes
  /// ([_persistClaimedClips]) and a protection ([protectCurrentClip]). A clip
  /// without a canonical name (unknown provenance) is never indexed.
  ///
  /// The session comes from the name, never from "the current session": a
  /// clip of A that finalizes after B started is A's, and so is its entry.
  /// What R2.6.7 put in this controller's own write is in `ensureClipIndexed`
  /// now, unchanged: the deletion check in the same synchronous slice as the
  /// read and the write — only a COMMITTED deletion refuses (frozen X98,
  /// X113) — and the discard of a refused clip's file. Its failures are
  /// reported through [dashcamService], once per clip. Never throws.
  ///
  /// Fase 16.2-R4.4-R1.1 (IR-P2-01): every trigger asks for the protection the
  /// clip carries in memory ([DashcamClip.isProtected]). Until a write carrying
  /// it takes effect, that flag is the protection's only representation: the
  /// name keeps the protection the clip was published with. It used to be
  /// passed only by [protectCurrentClip], as the argument of its one write: when
  /// that write failed (Hive rolled it back), the STOP's passes retried the clip
  /// unprotected, found it "already indexed", and the entry stayed unprotected
  /// for good. The flag only ever goes from false to true and nothing clears it,
  /// so no failure can discard it; once the entry is protected, every later
  /// trigger finds it so and writes nothing.
  ///
  /// Fase 16.2-R4.4-R2.1: the write is recorded in [_clipIndexWrites] (the
  /// clip's latest), so a STOP can wait for it without queueing behind it.
  Future<void> _indexProducedClip(DashcamClip clip) async {
    final descriptor = DashcamClipDescriptor.parse(dashcamClipBasename(clip.file.path));
    if (descriptor == null) return;
    if (!_tryClaimPath(descriptor.sessionId, clip.file.path)) return;
    final write = _ClipIndexWrite(
      protectedAsked: clip.isProtected,
      outcome: ensureClipIndexed(
        clip.file.path,
        origin: ClipIndexOrigin.producedInThisProcess,
        protectedNow: clip.isProtected,
        writeHookForTest: persistClipIndexHookForTest,
        report: (message) => dashcamService.reportExternalError(message, scope: DashcamServiceErrorScope.recordingResult),
      ),
    );
    _clipIndexWrites[clip.file.path] = write;
    await write.outcome;
  }

  /// Fase 16.2-R4.4-R2.1 — whether [clip] needs no new index write from a STOP:
  /// its latest write ([_clipIndexWrites]) has settled with anything but
  /// [ClipIndexOutcome.indexPending] (a write failure, the one outcome a retry
  /// can change), having asked for the protection the clip carries now (R4.4-R1.1:
  /// a protection raised in memory since must still reach the entry). Awaits
  /// that write — never a new turn of the index FIFO, so never the quota pass
  /// queued behind it. A write started while this one was awaited decides
  /// instead. `false` → the caller retries through [_indexProducedClip].
  Future<bool> _indexWriteSettled(DashcamClip clip) async {
    final path = clip.file.path;
    for (;;) {
      final write = _clipIndexWrites[path];
      if (write == null) return false;
      final outcome = await write.outcome;
      if (!identical(_clipIndexWrites[path], write)) continue;
      return outcome != ClipIndexOutcome.indexPending && (write.protectedAsked || !clip.isProtected);
    }
  }

  /// Fase 16.2-R4.4-R2 — a segment was published: it is indexed first
  /// ([_indexProducedClip]), then the storage quota's pass runs — queued in the
  /// index FIFO once that write has settled, so the clip that triggered it is
  /// already indexed (and immune). Never in the camera FIFO: a slow or failing
  /// deletion no longer delays the next segment, nor stops the recording.
  ///
  /// Fase 16.2-R4.4-R2.1: nothing awaits the pass — a STOP waits for the clip's
  /// index write ([_indexWriteSettled]), never for the pass queued after it. The
  /// pass never throws (`runDashcamQuotaPass` reports, counts and absorbs its
  /// own failures). Its trigger is the clip's path read here, at publication —
  /// not "this process's last clip" when the pass finally runs, which a later
  /// segment may have replaced by then.
  void _onClipPublished(DashcamClip clip) {
    final triggerClipPath = clip.file.path;
    unawaited(_indexProducedClip(clip).then((_) => _runStoragePass(DashcamQuotaTrigger.publication, triggerClipPath: triggerClipPath)));
  }

  /// Fase 16.2-R4.4-R2: test-only — replaces the file operations of the
  /// storage quota's evictions to fail exactly at one of them.
  @visibleForTesting
  DashcamClipFileOps? storageFileOpsForTest;

  /// Fase 16.2-R4.4-R2: one storage-quota pass (`runDashcamQuotaPass`). The
  /// quota and the resolution are the service's configuration, read when the
  /// pass's turn runs. Never throws.
  Future<void> _runStoragePass(DashcamQuotaTrigger trigger, {String? triggerClipPath}) async {
    _absorbStoragePass(
      await runDashcamQuotaPass(
        trigger: trigger,
        quotaBytes: () => dashcamService.quotaBytes,
        resolution: () => dashcamService.configuredResolution,
        probe: storageProbe,
        triggerClipPath: triggerClipPath,
        protectedInMemory: _clipsProtectedInMemory,
        immunePaths: _newestClipOfThisProcess,
        fileOps: storageFileOpsForTest ?? const DashcamClipFileOps(),
      ),
    );
  }

  /// A pass's evictions leave this process's memory in the same slice: the
  /// service forgets the clips (and their provenance), and their write-dedup
  /// claims go with them — what remains stays bounded by the clips that exist.
  void _absorbStoragePass(DashcamQuotaPassResult result) {
    final snapshot = result.snapshot;
    if (snapshot != null) _storageSnapshot = snapshot;
    if (result.evictedPaths.isEmpty) return;
    dashcamService.forgetClips(result.evictedPaths.toSet());
    _pruneClaimedPathOwners();
  }

  /// The clips of this process protected in memory ([DashcamClip.isProtected])
  /// — possibly not yet in their index entry (R4.4-R1.1): the quota never
  /// evicts them either.
  Set<String> _clipsProtectedInMemory() => {
    for (final clip in dashcamService.clips)
      if (clip.isProtected) clip.file.path,
  };

  /// The clip [protectCurrentClip] would mark retroactively (the last one this
  /// process published): immune, so a protection can never arrive for a clip
  /// the quota is already deleting.
  Set<String> _newestClipOfThisProcess() {
    final clips = dashcamService.clips;
    return clips.isEmpty ? const {} : {clips.last.file.path};
  }

  /// Fase 16.2-R4.4-R2 — the free-space guard of a START (D0 §10,
  /// `evaluateDashcamStartStorage`), or `null` when this platform has no
  /// storage probe — then there is nothing to wait for, and no `await` is
  /// added to the START.
  Future<DashcamStartStorageDecision>? _storageCheckBeforeStart() {
    if (!storageProbe.isSupported) return null;
    return evaluateDashcamStartStorage(
      quotaBytes: () => dashcamService.quotaBytes,
      resolution: () => dashcamService.configuredResolution,
      probe: storageProbe,
      protectedInMemory: _clipsProtectedInMemory,
      immunePaths: _newestClipOfThisProcess,
      fileOps: storageFileOpsForTest ?? const DashcamClipFileOps(),
    );
  }

  /// Awaits [check] for [attempt]: `true` lets the START go on. `false`
  /// concludes the attempt here — superseded meanwhile (the usual checkpoint),
  /// or refused: the camera is never acquired, the status is `error` with the
  /// storage reason (never "camera unavailable"), and the session itself goes
  /// on — the recorder is not touched. A later START (a retry, the next
  /// `resumed`) checks again.
  Future<bool> _admitByStorage(Future<DashcamStartStorageDecision> check, _CameraAttempt attempt, String sessionId) async {
    final decision = await check;
    final pass = decision.pass;
    if (pass != null) _absorbStoragePass(pass);
    if (!_attemptStillValid(attempt, sessionId, requireEligible: true)) {
      _clearAttemptIfCurrent(attempt);
      _continueForCurrentGenerationIfWarranted();
      return false;
    }
    if (decision.allowed) return true;
    _clearAttemptIfCurrent(attempt);
    _liveStatus = DashcamStatus.error;
    errorMessage = decision.refusal;
    if (!_disposed) notifyListeners();
    return false;
  }

  /// Fase 16.2-R4.3-R2.1 (§2/§8/§10), redesigned in Fase 16.2-R4.3-R2.2
  /// (§4-§9): installed by [_stopCamera] exactly once per stop, from a
  /// [DashcamStopOutcome.handle] captured at STOP-issuance time (never a
  /// later re-read of [DashcamService.pendingStopHandle] — see that class's
  /// own doc) — awaits the REAL, unbounded [settlement] (never a poll, never
  /// a retry timer) and persists whatever clip it produced using [context]'s
  /// own captured, immutable baseline — never the shared
  /// `_clipsBeforeThisSession`/`_currentPersistenceContext` fields
  /// themselves, which may already belong to a different, later session by
  /// the time this resolves.
  ///
  /// [context] itself needs no explicit lifetime management here — it is
  /// simply this method's own parameter, kept alive for as long as this
  /// `Future`'s own continuation is (see [_SessionPersistenceContext]'s own
  /// doc); which clips belong to [context]'s session is decided by their
  /// producer token ([DashcamClip.producerToken], Fase 16.2-R4.3-R2.5), and
  /// same-session write-dedup by [_claimedPathOwners] (keyed by path) — never
  /// by whether [context] itself is still "live" in any registry.
  ///
  /// A settlement FAILURE (native STOP ultimately failed, or its own clip
  /// processing did) is a quiet no-op here — zero phantom path — the
  /// failure itself is already reported exactly once via
  /// [DashcamService.errors]/[DashcamService.originatedErrors]
  /// (recordingResult-scoped). Never touches [notifyListeners]/any
  /// [_disposed]-guarded state: structurally safe to still run to completion
  /// after this controller itself has been disposed (this session's own
  /// clip is genuinely its history, not live UI state).
  Future<void> _watchLateStopSettlement(_SessionPersistenceContext context, Future<void> settlement) async {
    try {
      await settlement;
    } catch (_) {
      return;
    }
    await _persistClaimedClips(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Fase 16.2-R4.3-R1 (§10, D0-approved lifecycle-generation architecture
    // — CRITICAL ordering requirement): generation/eligibility update
    // happens SYNCHRONOUSLY, HERE, before the async handler is even
    // launched — so a NEW event immediately invalidates any already-in-
    // flight continuation's NEXT checkpoint, even while that continuation
    // is still suspended inside an earlier `await`. Launching the async
    // handler first (updating generation only once it eventually runs)
    // would leave a window where a stale continuation's own checkpoint
    // could still observe the OLD generation as current.
    _updateLifecycleGeneration(state);
    unawaited(_handleLifecycleChange(state));
  }

  /// Fase 16.2-R4.3-R2 (§16/§17, independent-review fix — "status não é
  /// control plane"): whether [_handleLifecycleChange]'s own `resumed`
  /// branch should attempt recovery — derived directly from real internal
  /// state, never from [_liveStatus] (a USER-VISIBLE fact, not an internal
  /// signalling channel — the reviewer rejected R4.3-R1's own use of
  /// `DashcamStatus.error` to mean "not foreground yet"). `true` whenever
  /// there is an active session, dashcam is enabled, no attempt is already
  /// in flight (an active [_CameraAttempt] already owns making progress —
  /// see its own doc), and this session is not ALREADY durably,
  /// successfully recording (initial setup installed, [_liveStatus] genuinely
  /// `recording`, camera not known-unavailable) — covering, uniformly,
  /// every case that needs a resumed-triggered recovery: a genuine error, a
  /// background camera loss ([DashcamService.cameraKnownUnavailable]), an
  /// INITIAL attempt never even tried because the app was backgrounded the
  /// whole time (I0-A), and a raw initialize left pending while ineligible
  /// (X2) whose own hand-off already found nothing to do (see
  /// [_attemptRecoveryRestart]'s own eligibility gate).
  bool get _cameraAcquisitionNeeded {
    final sessionId = _recordingSessionId;
    if (sessionId == null || _disposed || !dashcamPreferences.enabled) return false;
    if (_activeCameraAttempt != null) return false;
    if (!_initialSetupDone) return true;
    if (_liveStatus != DashcamStatus.recording) return true;
    return dashcamService.cameraKnownUnavailable;
  }

  Future<void> _handleLifecycleChange(AppLifecycleState state) async {
    final controller = dashcamService.previewController;
    try {
      if (state == AppLifecycleState.paused) {
        // Fase 16.2: mark the camera unavailable BEFORE the preview-pause
        // attempt below — see DashcamService.notifyAppBackgrounded's own
        // doc. Unconditional and safe: a no-op unless a recording is
        // actually in progress. Fase 16.2-R4.3-R1 (§19): background's own
        // pre-existing contract is UNCHANGED — still no automatic STOP/
        // releaseIdleCamera/dispose here, only the generation invalidation
        // that already happened synchronously above.
        dashcamService.notifyAppBackgrounded();
        await controller?.pausePreview();
      } else if (state == AppLifecycleState.resumed) {
        // Fase 16.2-R4.3-R1 (§18, D0 gate): capture the generation the
        // INSTANT this handler starts running — before the real,
        // potentially slow `resumePreview()` native call.
        final capturedGeneration = _lifecycleGeneration;
        try {
          await controller?.resumePreview();
        } catch (_) {
          // Fase 16.2 — physically confirmed on a Samsung SM-A326B: resuming
          // the preview on the OLD controller (still the one referenced
          // above; recovery below hasn't replaced it yet) throws once
          // Android has actually revoked its camera, not a silent no-op.
          // Without this inner catch, that exception fell straight through
          // to the outer best-effort catch, skipping the recovery check
          // below on EVERY resume after a real camera loss — DashcamStatus
          // stayed stuck reporting a stale "recording" that had never
          // actually been re-established: no fresh camera, no timer, and
          // (confirmed on-device) no clip ever saved on the next stop.
        }
        // Fase 16.2-R4.3-R1 (§18): revalidate AFTER the native
        // `resumePreview()` awaited above — a LATER lifecycle transition
        // (another full background→foreground cycle) could have happened
        // while it was still in flight. A stale resumed handler must not
        // decide recovery, publish state, release the CURRENT controller,
        // or touch a newer generation's own attempt — it simply stops here.
        if (_disposed || _lifecycleGeneration != capturedGeneration || !_lifecycleEligible) {
          return;
        }
        // Fase 16.2-R4.3-R2 (§16/§17, independent-review fix): decided via
        // [_cameraAcquisitionNeeded] — real internal state, not
        // [_liveStatus] — see its own doc for why this now uniformly covers
        // a genuine error, a background camera loss
        // ([DashcamService.cameraKnownUnavailable] — Fase 16.2's own
        // pre-existing signal, since a background camera loss never flips
        // `_liveStatus` on its own), an INITIAL attempt never even tried
        // (I0-A), and a raw initialize left pending while ineligible (X2).
        // [_attemptRecoveryRestart] is reused unchanged: it already does a
        // fresh initialize()+startLoopRecording() (or the full initial
        // setup, per [_initialSetupDone] — see [_attemptRecoveryRestart]'s
        // own doc), which clears `cameraKnownUnavailable` on success.
        if (_cameraAcquisitionNeeded) {
          await _attemptRecoveryRestart();
        }
      }
    } catch (_) {
      // Best-effort final safety net — a pausePreview() failure, or any
      // other unexpected exception in this method, must not crash the app.
      // (resumePreview()'s own, expected-on-real-hardware failure has its
      // own inner catch above precisely so it does NOT land here — see its
      // doc.) Recording itself (not the preview) is what matters here, not
      // whether the recording survives backgrounding. Fase 16.1 physically
      // found that Android can silently revoke the camera itself (not just
      // pause the recording request) from a backgrounded app, with no
      // Dart-visible signal — notifyAppBackgrounded/cameraKnownUnavailable
      // above exist to detect and recover from that on the next resume
      // (Fase 16.2), instead of relying on this catch block. Separately,
      // DashcamService now requests a non-persistent recording (Fase
      // 16.2-R4.1A, see _startVideoRecordingWithTimeout's own doc): in the
      // background scenarios physically reproduced in Fase 16.2 R3-C, that
      // was observed to auto-finalize natively (ERROR_SOURCE_INACTIVE)
      // once the camera source went inactive — an experimental
      // observation, not a guaranteed SLA. Either way, the actual recovery
      // mechanism is the next-resume path above, not this catch block.
    }
  }

  /// Manually retries starting the camera after an error — the explicit
  /// "Tentar novamente" action in the preview UI. A no-op if there's no
  /// active recording session to retry for (e.g. the session already ended).
  Future<void> retryCamera() => _attemptRecoveryRestart();

  /// In-flight [_attemptRecoveryRestart] call, if any — Fase 16.2-R4.2B-R2
  /// (§28/§29, independent review — "retries não acumulam"): a second call
  /// (another `resumed` lifecycle dispatch, or a user-initiated
  /// [retryCamera]) while one is already running joins the same in-flight
  /// [Future] instead of requesting a second [DashcamService.initialize] —
  /// mirrors [stopSession]'s own, already-established dedup pattern
  /// ([_stopSessionFuture]'s own doc).
  Future<void>? _recoveryFuture;

  /// Fase 16.2-R1 (independent review, P1-2 "recovery não é serializada nem
  /// cancelável"): re-validates ownership — [sessionId] still the current
  /// [_recordingSessionId], and not [_disposed] — after *every* `await` in
  /// this method, not only at the end. A `stopSession()`, a `dispose()`, a
  /// new backgrounding, or another recovery attempt can all happen while
  /// this one is mid-flight (the queue inside `DashcamService` serializes
  /// *its own* native operations, but has no idea this specific call is the
  /// one that requested them, or whether it's still wanted by the time they
  /// finish); once superseded, this attempt must not go on to start a
  /// recording for a session that's already stopped, hand a fresh camera to
  /// whatever *did* supersede it, or touch a disposed [ChangeNotifier].
  ///
  /// Fase 16.2-R4.2B-R2 (§28): deduped via [_recoveryFuture]. Fase
  /// 16.2-R4.2B-R5 (§7/§8/§19, independent review P1 — "initial B +
  /// retry/recovery B podem existir como DUAS tentativas semânticas"):
  /// ALSO declines whenever [_activeCameraAttempt] already, legitimately
  /// belongs to the current [_recordingSessionId] — regardless of whether
  /// that attempt was established by THIS method earlier (another
  /// recovery), or by [_startCamera] for the session's very first,
  /// still-in-progress attempt, and regardless of whether that attempt has
  /// its own raw initialize Future YET (it may still only be waiting on a
  /// different session's own stale settlement — see [_CameraAttempt]'s own
  /// doc). [_recoveryFuture] alone was proven insufficient by the
  /// reviewer's own reproduction: it only ever serializes recoveries
  /// against EACH OTHER, never against a concurrent INITIAL attempt for the
  /// same session.
  Future<void> _attemptRecoveryRestart() {
    final inFlight = _recoveryFuture;
    if (inFlight != null) return inFlight;
    final sessionId = _recordingSessionId;
    if (sessionId == null || _disposed) return Future<void>.value();
    // Fase 16.2-R4.3-R1 (§21, D0-approved lifecycle-generation
    // architecture): recovery REQUIRES eligibility to even begin — unlike
    // [_startCamera] (a user-initiated new session, allowed to claim an
    // attempt and wait), recovery only ever makes sense once the CURRENT
    // generation is genuinely foreground/interactive. While ineligible,
    // this is a safe, cheap no-op — the next `resumed` transition (or this
    // very call being re-triggered by [_continueForCurrentGenerationIfWarranted]
    // once eligible) is what actually starts the work.
    if (!_lifecycleEligible) return Future<void>.value();
    if (_activeCameraAttempt != null && _activeCameraAttempt!.sessionId == sessionId) {
      // First purpose wins (§8): an attempt (initial or recovery) is
      // already active for this session — join/no-op, never convert it or
      // start a second, concurrent one.
      return Future<void>.value();
    }
    // Fase 16.2-R4.3-R1 (§21/§22): purpose is NOT hardcoded to recovery
    // anymore — if this session's own initial setup was never completed
    // (e.g. background interrupted it before it could finish — see
    // [_initialSetupDone]'s own doc), THIS attempt must still run the FULL
    // initial setup exactly once, never merely "resume" a setup that was
    // never really installed.
    final attempt = _CameraAttempt(sessionId: sessionId, isInitial: !_initialSetupDone, generation: _lifecycleGeneration);
    _activeCameraAttempt = attempt;
    cameraAttemptCreationCountForTest++;
    final future = _doAttemptRecoveryRestart(attempt);
    _recoveryFuture = future;
    return future.whenComplete(() {
      if (identical(_recoveryFuture, future)) _recoveryFuture = null;
    });
  }

  Future<void> _doAttemptRecoveryRestart(_CameraAttempt attempt) async {
    final sessionId = attempt.sessionId;

    // Fase 16.2-R4.3-R2.6.2: the same physical-teardown admission barrier
    // [_startCamera] waits for — see [_priorPhysicalTeardown]. Checked FIRST,
    // before the raw-initialize barrier below, in the same order [_startCamera]
    // uses. The attempt stays registered while it waits (single-flight: a
    // concurrent start/retry for this session joins it instead of bypassing
    // the wait), and is re-validated afterwards — a stop, a dispose or a newer
    // lifecycle generation that happened meanwhile means it never touches the
    // camera.
    final priorTeardown = _priorPhysicalTeardown();
    if (priorTeardown != null) {
      await priorTeardown;
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
    }

    // Fase 16.2-R4.2B-R4 (§23-§27, independent review P1-C): see
    // [_startCamera]'s own identical doc for why this barrier-wait (never a
    // claim on the outcome) must run BEFORE ever calling
    // `dashcamService.initialize()` whenever a DIFFERENT session's own raw
    // operation is still retained. Fase 16.2-R4.2B-R5 (§11): [attempt] was
    // already claimed by [_attemptRecoveryRestart] BEFORE this wait.
    //
    // Fase 16.2-R4.3-R2 (§8, independent-review P1-1 fix — "same session /
    // different generation, CRÍTICO"): R4.3-R1 only ever compared
    // [sessionId] here — the exact gap the reviewer reproduced: the EXACT
    // SAME [sessionId] resuming in a NEW generation found this condition
    // `false` (its own sessionId matched) and skipped the barrier-wait
    // entirely, then went on to `_claimOrJoinInitialize` a raw operation
    // that physically belonged to the OLD generation. Now ALSO waits
    // whenever [observedBarrier.generation] differs from THIS attempt's own
    // — an earlier generation's raw operation is always a FOREIGN barrier
    // to a newer one, never something it may join, even for the identical
    // logical session (see [_ObservedInitialize]'s own doc).
    //
    // Fase 16.2-R4.3-R2.2 (§30, independent-review audit — "raw join
    // purpose"): ALSO waits whenever [observedBarrier.isInitial] differs
    // from THIS attempt's own — see [_claimOrJoinInitialize]'s own doc for
    // why a purpose mismatch, even for the identical session AND generation,
    // must never be silently joined. Barrier-waiting (not erroring
    // immediately, unlike a genuinely foreign session) is the right response
    // here: this is still this session's own earlier attempt, just under a
    // different purpose label — once its raw settles, this attempt's own
    // fresh `initialize()` call below proceeds normally.
    final observedBarrier = _observedInitialize;
    if (observedBarrier != null &&
        (observedBarrier.sessionId != sessionId || observedBarrier.generation != attempt.generation || observedBarrier.isInitial != attempt.isInitial)) {
      await observedBarrier.rawFuture.catchError((_) {});
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      for (var i = 0; i < 50 && dashcamService.pendingInitializeSettlement != null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
    }

    // Fase 16.2-R4.3-R1 (§21/§24): pre-native checkpoint — requires
    // eligibility now (see [_attemptStillValid]'s own doc).
    if (!_attemptStillValid(attempt, sessionId, requireEligible: true)) {
      _clearAttemptIfCurrent(attempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }
    // Fase 16.2-R4.4-R2: the same free-space guard as [_startCamera]'s — a
    // recovery or a retry starts a new Recording too.
    final storageCheck = _storageCheckBeforeStart();
    if (storageCheck != null && !await _admitByStorage(storageCheck, attempt, sessionId)) return;

    _liveStatus = DashcamStatus.initializing;
    errorMessage = null;
    notifyListeners();
    Future<void>? rawSettlement;
    var claimed = true;
    try {
      final callFuture = dashcamService.initialize(
        semanticStillValid: () => _attemptStillValid(attempt, sessionId),
        lifecycleGeneration: attempt.generation,
      );
      rawSettlement = dashcamService.pendingInitializeSettlement;
      attempt.rawSettlement = rawSettlement;
      claimed = _claimOrJoinInitialize(rawSettlement, sessionId, attempt.generation, isInitial: attempt.isInitial);
      await callFuture;
      if (claimed && rawSettlement != null) _clearInitializeClaimIfSettled(rawSettlement);
      if (!claimed) {
        if (!_attemptStillValid(attempt, sessionId)) {
          _clearAttemptIfCurrent(attempt);
          _continueForCurrentGenerationIfWarranted();
          return;
        }
        _clearAttemptIfCurrent(attempt);
        _liveStatus = DashcamStatus.error;
        errorMessage = 'Camera initialize is currently owned by another session';
        notifyListeners();
        return;
      }
      // Fase 16.2-R4.3-R2 (§28/§29): captured atomically, right after
      // `initialize()` genuinely succeeded — see [_finishInitialStart]'s
      // own identical doc.
      final initializedController = dashcamService.previewController;
      if (!_attemptStillValid(attempt, sessionId)) {
        // Fase 16.2-R1 (P1-2): superseded while initialize() was in flight
        // (it cannot be cancelled — see DashcamService's own doc on why).
        // Whatever superseded this attempt (stopSession, dispose, a fresh
        // recovery) already ran its own cleanup for its OWN concerns, but
        // has no idea this camera exists — release it directly rather than
        // leave it open and untracked. Fase 16.2-R4.3-R2 (§28): targeted.
        //
        // Fase 16.2-R4.3-R2.6.19 (N6): ...and asked for only when there IS a
        // camera to name — see [_startCamera]'s own identical doc and
        // [_watchLateInitialize]'s.
        _clearAttemptIfCurrent(attempt);
        if (initializedController != null) {
          unawaited(dashcamService.releaseIdleCamera(expectedController: initializedController));
        }
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      // Fase 16.2-R4.3-R1 (§21/§22): dispatches on THIS attempt's own
      // purpose, not on which method created it — a hand-off-created
      // attempt for a session whose initial setup was never completed
      // still runs the FULL initial continuation here.
      if (attempt.isInitial) {
        await _finishInitialStart(sessionId, attempt);
      } else {
        await _finishStartingRecording(sessionId, attempt);
      }
    } catch (error) {
      // Fase 16.2-R4.3-R2 (§9/§10, independent-review P1-1 fix): see
      // [_startCamera]'s own identical doc — claim/watcher resolution
      // always happens BEFORE the staleness/hand-off decision.
      var attemptStillPending = false;
      if (claimed) {
        // Fase 16.2-R4.2B-R2 (§30, independent review — "resolução tardia do
        // initialize"): only reachable this way for a genuine presentation
        // TIMEOUT on THIS call's own initialize() — a real, already-settled
        // failure (e.g. "No cameras available") always clears
        // DashcamService's own retained Future before rethrowing, so
        // pendingInitializeSettlement is already null for that case, and this
        // branch is skipped. `_liveStatus`/`errorMessage` below are set the
        // same way for both cases (§27: no new status/UI semantics) — this
        // only adds a background watcher for the retained case.
        final pending = dashcamService.pendingInitializeSettlement;
        if (pending != null) {
          _installLateInitializeWatcherIfNeeded(pending);
          // Fase 16.2-R4.2B-R5 (§9): stays active — the watcher owns
          // concluding it later.
          attemptStillPending = true;
        } else if (rawSettlement != null) {
          _clearInitializeClaimIfSettled(rawSettlement);
        }
      }
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      if (!attemptStillPending) {
        _clearAttemptIfCurrent(attempt);
      }
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    }
    if (_disposed) return;
    notifyListeners();
  }

  /// The shared "initialize succeeded, now actually start recording" tail
  /// for RECOVERY specifically — Fase 16.2-R4.2B-R2 (§30): factored out of
  /// [_doAttemptRecoveryRestart] so [_watchLateInitialize] can run the exact
  /// same logic once a LATE initialize success arrives, instead of
  /// duplicating it. See [_finishInitialStart]'s own doc for why the very
  /// first start needs a DIFFERENT (fuller) continuation instead of reusing
  /// this one.
  Future<void> _finishStartingRecording(String sessionId, _CameraAttempt attempt) async {
    // Fase 16.2-R4.3-R2.6.18: the START hands back its own identity — see
    // [_finishInitialStart]'s own identical doc and [_stopWhatThisStartDid].
    final start = dashcamService.beginStartLoopRecording(
      semanticStillValid: () => _attemptStillValid(attempt, sessionId, requireEligible: true),
      // Fase 16.2-R4.3-R2.5 (§33): recovery of the SAME logical session —
      // same producer token as the Recording it replaces.
      clipOwnerToken: _producerTokenFor(sessionId),
    );
    final startAttempt = start.attempt;
    await start.presentation;
    if (!_attemptStillValid(attempt, sessionId)) {
      // Superseded while startLoopRecording() was in flight — a recording
      // may genuinely have just started for a session/attempt nobody is
      // tracking anymore. Stop it rather than leave it running unowned;
      // whatever superseded this attempt already owns `_liveStatus`. Fase
      // 16.2-R4.3-R2.6.18: by the identity of this attempt's own START.
      _clearAttemptIfCurrent(attempt);
      _stopWhatThisStartDid(startAttempt);
      _continueForCurrentGenerationIfWarranted();
      return;
    }
    if (dashcamService.previewController?.value.isRecordingVideo != true) {
      // Fase 16.2-R4.2B-R5 (§24/§25/§29, independent review P1 — "defesa
      // contra falso REC"): this attempt is still current, but the real
      // native signal disagrees with a bare "startLoopRecording() returned"
      // — never publish `recording` on that alone. No new status invented
      // for R5 — converges to the same `error` this class already uses
      // elsewhere for a camera that failed to (stay) record(ing).
      _clearAttemptIfCurrent(attempt);
      _stopWhatThisStartDid(startAttempt);
      _liveStatus = DashcamStatus.error;
      errorMessage = 'Camera stopped recording before it could be confirmed';
      return;
    }
    _cameraUnavailableDuringStop = false;
    _liveStatus = DashcamStatus.recording;
    _clearAttemptIfCurrent(attempt);
  }

  /// Fase 16.2-R4.2B-R2 (§17/§18/§30/§31, independent review — "resolução
  /// tardia do initialize"), extended in Fase 16.2-R4.2B-R3 (§28-§31) to
  /// also cover the very first [_startCamera] attempt, not only
  /// [_doAttemptRecoveryRestart]: whichever of the two already gave up on
  /// [pending] once its own presentation deadline elapsed (reporting
  /// [DashcamStatus.error] to this controller's own listeners) — but
  /// `DashcamService` itself never abandoned the real native call (see
  /// [DashcamService.pendingInitializeSettlement]'s own doc). This watches
  /// that SAME retained operation in the background and reacts once it
  /// genuinely settles, however long that takes (including never, for a
  /// genuinely stuck call — see [DashcamService._doInitializeController]'s
  /// own doc): a late SUCCESS resumes recording for [sessionId] if it is
  /// still the one this controller wants — via [_finishInitialStart] when
  /// [isInitialStart] (the very first setup this session ever needed) or
  /// [_finishStartingRecording] otherwise (recovery reusing what's already
  /// open) — or releases the now-unwanted camera if not; a late FAILURE, or
  /// a session that has moved on, is a quiet no-op — no second
  /// `initialize()` is ever requested from here (§17: converge
  /// deterministically, no automatic retry).
  Future<void> _watchLateInitialize(
    Future<void> pending,
    String sessionId, {
    required bool isInitialStart,
    required _CameraAttempt? attempt,
  }) async {
    Object? lateError;
    try {
      await pending;
    } catch (error) {
      lateError = error;
    }
    // Fase 16.2-R4.2B-R3 (§31), re-based onto raw-Future identity in Fase
    // 16.2-R4.2B-R4 (§30): self-clearing, mirroring [_stopCameraFuture]'s
    // own established pattern — only clear this if [pending] still IS the
    // currently-claimed operation; a newer session's own, still-active
    // claim (a different raw Future entirely) must never be clobbered by
    // an older one settling late.
    _clearInitializeClaimIfSettled(pending);
    // Fase 16.2-R4.2B-R5 (§4-§11): validate via the ATTEMPT (identity +
    // session), not merely the session id — see [_CameraAttempt]'s own doc
    // for why a bare session-id match is insufficient to distinguish this
    // attempt from a newer, later, legitimate one for the SAME session
    // (§13/§14: recovery after this attempt's own true terminal remains
    // possible). [attempt] may be `null` here only in the structurally rare
    // case documented at [_installLateInitializeWatcherIfNeeded]'s own call
    // site — treated the same as "no longer valid".
    final stillValid = attempt != null && _attemptStillValid(attempt, sessionId);
    if (!stillValid) {
      // Fase 16.2-R4.2B-R2 (§18/§31): superseded (session stopped/disposed/
      // moved on to a different session, or this attempt itself concluded)
      // while the real native initialize was still retained — do not
      // resurrect anything nobody wants anymore. A late SUCCESS still left
      // a live, now-unwanted controller open — release it (mirrors
      // [_doAttemptRecoveryRestart]'s own identical superseded-cleanup for
      // an in-time success).
      if (attempt != null) _clearAttemptIfCurrent(attempt);
      if (lateError == null) {
        // Fase 16.2-R4.3-R2 (§28/§29): targeted — [dashcamService
        // .previewController], read fresh here (this branch is reached
        // synchronously, immediately after `pending` itself just resolved
        // successfully, with no further `await` before this read), is the
        // exact controller THIS late success just adopted, never a newer
        // generation's own, possibly-already-current one.
        //
        // Fase 16.2-R4.3-R2.6.19 (independent review of R2.6.18, N6 —
        // "null-target idle camera release"): ...when it adopted one. An
        // initialize that settles NORMALLY this late is not always a late
        // success: once its attempt is stale, or its own deadline has
        // elapsed, DashcamService abandons it before its native call and
        // completes it WITHOUT a camera. The value read here is then `null`,
        // and `releaseIdleCamera(expectedController: null)` does not mean
        // "release nothing" — it is the service's UNTARGETED release, which
        // disposes whatever camera is current when its turn in the service's
        // queue comes. "The camera I would release does not exist" became
        // "release any camera".
        //
        // It did damage in one order of events. This watcher is registered on
        // the retained operation only when that initialize's presentation
        // deadline elapses. A NEWER session's attempt that was already
        // waiting for the same operation ([_startCamera]'s barrier) was
        // registered before it, so when the operation settles that attempt
        // runs first and asks for its own `initialize()`. The untargeted
        // release then entered the queue BEHIND that initialize and disposed
        // the camera it had just opened: the new session ended in `error`
        // with no video. Reproduced with the product's own deadlines — an
        // initialize held past its 10 s at device discovery, and one waiting
        // behind a native stop that took 15 s to return.
        //
        // So: no camera of this attempt's own, nothing to release, and no
        // release is asked for. Nothing leaks by that — an initialize that
        // DID produce a camera is released here, by name, exactly as before.
        final lateCamera = dashcamService.previewController;
        if (lateCamera != null) {
          unawaited(dashcamService.releaseIdleCamera(expectedController: lateCamera));
        }
      }
      // Fase 16.2-R4.3-R1 (§17, D0's own critical gate — "progresso após
      // stale op"): THIS is the classic case the D0 architecture exists to
      // close — a presentation-timeout'd operation whose raw settlement
      // finally arrives after a lifecycle transition made it stale. Without
      // this call, a still-wanted session could be left stuck forever with
      // nothing left to trigger its own, current-generation attempt.
      _continueForCurrentGenerationIfWarranted();
      return;
    }
    if (lateError != null) {
      // Still no camera, and nothing left retained to wait on for this
      // attempt — stay in error; no second initialize() is requested from
      // here. Terminal for this attempt.
      _clearAttemptIfCurrent(attempt);
      return;
    }
    try {
      if (isInitialStart) {
        await _finishInitialStart(sessionId, attempt);
      } else {
        await _finishStartingRecording(sessionId, attempt);
      }
    } catch (error) {
      if (!_attemptStillValid(attempt, sessionId)) {
        _clearAttemptIfCurrent(attempt);
        _continueForCurrentGenerationIfWarranted();
        return;
      }
      _clearAttemptIfCurrent(attempt);
      _liveStatus = DashcamStatus.error;
      errorMessage = error.toString();
    }
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Fase 16.2-R4.2B-R5 (§23, independent review P1): dispose semantically
    // invalidates ANY active camera attempt, unconditionally — mirrors
    // [_stopCamera]'s own identical (session-scoped) invalidation. Not a
    // fictitious cancellation of the underlying raw native Future — that
    // still follows DashcamService's own established retention contract.
    _activeCameraAttempt = null;
    WidgetsBinding.instance.removeObserver(this);
    dashcamPreferences.removeListener(_onPreferencesChanged);
    dashcamService.cameraKnownUnavailableListenable.removeListener(_onCameraKnownUnavailableChanged);
    unawaited(_serviceErrorSub?.cancel());
    // Fase 16.2-R4.4-R1: a clip published after this reaches the late STOP pass
    // ([_watchLateStopSettlement], which outlives dispose) or the next start.
    unawaited(_publishedClipsSub?.cancel());
    _snapshotSub?.cancel();
    _eventSub?.cancel();
    _sampleTimer?.cancel();
    // Fase 16.2-R4.3-R2.6.10 (§13): dispose is synchronous (the app's root
    // State.dispose → DrivingSessionHost.dispose), so it cannot wait for the
    // file: it STARTS the close — the writer refuses samples from this call
    // on, writes what it accepted, releases the handle — and this controller
    // keeps OWNING its outcome ([_telemetryFinalizations]; a failure is
    // reported, never dropped). The camera release below does not wait for
    // it, and nothing reopens the file: a disposed controller installs no
    // writer. A STOP's finalization still in flight keeps running the same
    // way (see [_finalizeStoppedTelemetry]).
    final writer = _telemetryWriter;
    _telemetryWriter = null;
    if (writer != null) _finalizeUnownedTelemetryWriter(writer, 'while finalizing the telemetry file of a recording torn down by dispose()');
    unawaited(dashcamService.dispose());
    super.dispose();
  }
}
