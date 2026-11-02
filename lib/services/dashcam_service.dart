import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, max;

import 'package:camera/camera.dart';
import 'package:camera_android_camerax/camera_android_camerax.dart' show RecordingEvidence, currentRecordingEvidenceSource;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier, visibleForTesting;

import '../models/dashcam_clip_descriptor.dart';
import '../models/dashcam_config.dart';
import '../models/dashcam_status.dart';
import 'dashcam_clip_files.dart';

/// A single recorded loop-recording segment on disk.
class DashcamClip {
  DashcamClip({
    required this.file,
    required this.recordedAt,
    required this.sizeBytes,
    this.durationSeconds = 0,
    this.isProtected = false,
    this.producerToken,
    this.recordingId,
  });

  /// Fase 16.2-R4.4-R1: the clip's file in `dashcam_clips/`, moved there by
  /// `rename(2)` under its canonical name ([DashcamClipDescriptor]) — the
  /// name, not this object, is what survives the process: it carries the
  /// session, the clip's identity and everything its index entry holds. A clip
  /// of unknown provenance has a legacy `clip_<ms>.mp4` name instead.
  final File file;

  /// Fase 16.2-R4.3-R2.5 (§20-§28, independent-review P1-1 — "clip provenance
  /// é first-observer-wins"): the opaque, immutable token of whoever STARTED
  /// the Recording that produced this clip ([DashcamService
  /// .startLoopRecording]'s `clipOwnerToken`) — the clip's PRODUCER, decided
  /// where the clip is born, never by whichever consumer happens to observe it
  /// first. [DashcamService] attaches no meaning to it (it does not know what a
  /// "session" is); `DashcamSessionController` supplies its session id.
  /// Assigned in the constructor — i.e. it exists before the clip can be added
  /// to [DashcamService.clips] at all, so there is no instant at which a clip
  /// is publicly visible without its provenance (see
  /// [DashcamService._finalizeSegmentResult]). `null` means UNKNOWN provenance:
  /// the Recording was started without a token (legacy/direct callers) —
  /// consumers must treat that conservatively, never adopt it. Runtime-only:
  /// not persisted anywhere; its lifetime is exactly this object's, so it is
  /// bounded by [DashcamService.clips] (a clip evicted by the storage quota
  /// takes its provenance with it: [DashcamService.forgetClips]).
  final Object? producerToken;

  /// The [DashcamService.activeRecordingId] value of the Recording that
  /// produced this clip, or `null` if unknown. Runtime-only diagnostics (not
  /// persisted); complements [producerToken].
  final int? recordingId;

  /// The wall-clock instant `CameraController.startVideoRecording()` was
  /// called for this segment — not when it was finalized. Using the start
  /// instant (rather than the finalize instant, up to [DashcamService.segmentDuration]
  /// later) is what makes a video position lineable up against telemetry at
  /// all (Fase 15).
  final DateTime recordedAt;
  final int sizeBytes;
  final int durationSeconds;

  /// Protected clips are never deleted by quota enforcement. Set via
  /// [DashcamService.markClipAsProtected]. Fase 16.2-R4.4-R2: the storage
  /// quota reads this flag besides the clip's name and index entry — until a
  /// write carrying it lands, it is the protection's only representation
  /// (R4.4-R1.1).
  bool isProtected;
}

/// Fase 16.2-R4.3-R2 (§40/§41, independent-review P2-C fix — "modelo de
/// erros não distingue adequadamente"): explicit three-way scope, replacing
/// R4.3-R1's original `origin == null` ⇒ "global" shortcut, which the
/// reviewer found conflated two genuinely different things under one `null`
/// — an old Recording's own finalize/processing failure (never a reason to
/// poison a healthy CURRENT camera) and a truly global backend fact. See
/// [DashcamServiceError.scope]'s own doc for each case.
enum DashcamServiceErrorScope {
  /// Concerns a SPECIFIC [CameraController]'s own acquisition/health —
  /// camera-lost, a late native START failure, a START failure during
  /// rotation restart. Only THIS scope carries [DashcamServiceError.origin]/
  /// [DashcamServiceError.generation] — see [DashcamSessionController
  /// ._onDashcamServiceError]'s own doc for exactly how both are used
  /// together to decide whether it may still affect the CURRENT camera.
  lifecycleCamera,

  /// Concerns a specific (possibly already-superseded) Recording's own
  /// finalize/STOP/clip-processing/storage outcome — diagnosable via
  /// [DashcamService.errors]/[DashcamService.originatedErrors] like any
  /// other, but never a reason, on its own, to move a healthy CURRENT
  /// camera to [DashcamStatus.error] (`DashcamStatus` lives in
  /// `dashcam_session_controller.dart`'s own import graph, not referenced
  /// directly here).
  recordingResult,

  /// A fact about the backend/process as a whole, independent of any single
  /// controller or Recording (e.g. a teardown failure that already left
  /// process ownership uncertain — see [DashcamService
  /// ._doReleaseControllerAndOwnership]'s own doc). Always visible/blocking,
  /// never filtered by generation. The default — matches every call site
  /// that does not explicitly pass a narrower [scope].
  backendGlobal,
}

/// Fase 16.2-R4.3-R1 (§40/§41), extended in Fase 16.2-R4.3-R2 (§40/§41,
/// independent-review fix): one emission of [DashcamService.originatedErrors]
/// — see its own doc for the full reasoning. [scope] classifies WHAT this
/// failure is about (see [DashcamServiceErrorScope]'s own doc for each
/// case); [origin]/[generation] are only ever meaningful when
/// `scope == DashcamServiceErrorScope.lifecycleCamera` — [origin] identifies
/// the specific [CameraController] concerned, and [generation] carries
/// whatever lifecycle-generation value [DashcamSessionController] supplied
/// when THAT controller was created (via [DashcamService.initialize]'s own
/// `lifecycleGeneration` parameter) — this class merely carries it opaquely;
/// [DashcamService] itself holds no lifecycle-generation authority of its
/// own (unchanged from R4.3-R1 — see [DashcamService.originatedErrors]'s own
/// doc).
class DashcamServiceError {
  const DashcamServiceError(this.message, {this.scope = DashcamServiceErrorScope.backendGlobal, this.origin, this.generation});

  final String message;
  final DashcamServiceErrorScope scope;
  final CameraController? origin;
  final int? generation;
}

/// Fase 16.2-R4.3-R2.1 (§9, independent-review gap — "late STOP → session
/// persistence ownership"): an IMMUTABLE snapshot of whichever native STOP
/// operation is currently pending, if any — mirrors [DashcamService
/// .pendingInitializeSettlement]'s own established "expose the raw
/// operation's real completion" pattern for STOP, bundled with just enough
/// identity ([recordingId]/[controller]) for a caller to confirm it is
/// still looking at the SAME operation it expects before acting on
/// [settlement] — never [_PendingNativeStop] itself (mutable, and this
/// class's own internal bookkeeping — deliberately not exposed directly).
///
/// Fase 16.2-R4.3-R2.5 (independent-review P1-2): comparing [recordingId]/
/// [controller] against a value the caller captured BEFORE issuing the stop is
/// only sound for a caller that already knows the exact, already-materialized
/// Recording it targets (a targeted cleanup — that comparison is what
/// `expectedRecordingId` already does service-side). For an UNTARGETED stop
/// ("whichever Recording I stop") the Recording may not exist yet when the stop
/// is issued (a START still in flight), so such a snapshot names the PREVIOUS
/// Recording and would reject the legitimate late handle. Such a caller trusts
/// [intentId] instead: [DashcamStopOutcome.intentId] on the outcome that
/// issued the stop must equal it.
class DashcamPendingStopHandle {
  const DashcamPendingStopHandle({
    required this.recordingId,
    required this.controller,
    required this.settlement,
    this.intentId,
    this.producerToken,
    this.physicalStopId,
    this.producerIntentId,
  });

  /// Fase 16.2-R4.3-R2.6 (§31/§32, independent-review P1-B): the PHYSICAL stop's
  /// own identity — one native `stopVideoRecording()` operation. Deliberately a
  /// different identity from [intentId] (which names the LOGICAL request that
  /// observes/owns this handle): when an intent adopts a stop that an EARLIER
  /// intent physically produced (transitive discovery, see
  /// [DashcamService._claimStopIntent]), [intentId] stays the adopter's own,
  /// [producerIntentId] names the intent that actually issued the stop, and
  /// [physicalStopId] is the same for every adopter — so "logical intent 4
  /// adopted the physical stop intent 2 produced" is expressible without
  /// pretending the two requests are the same request.
  final int? physicalStopId;

  /// The logical intent whose finalize physically issued this stop
  /// ([_PendingNativeStop.originIntentId]); equal to [intentId] when the
  /// handle's owner produced the stop itself, different when it adopted it.
  final int? producerIntentId;

  /// Fase 16.2-R4.3-R2.5 (§6/§15/§16, independent-review P1-2 — "handle
  /// legítimo rejeitado por RecordingId snapshot antigo"): the identity of the
  /// stop INTENT ([DashcamStopOutcome.intentId]) that produced/adopted this
  /// handle — the service-side guarantee "this handle belongs to that intent",
  /// so a caller can trust the intent→handle correlation instead of
  /// reconstructing it from a [recordingId] snapshot it captured BEFORE the
  /// Recording its own intent eventually stopped even existed (a queued START
  /// still in flight when the intent was issued). `null` only for a handle
  /// built outside [DashcamService.beginStopLoopRecording]'s own intents
  /// (e.g. [DashcamService.pendingStopHandle], observability only).
  final int? intentId;

  /// Fase 16.2-R4.3-R2.5 (§22/§40): the opaque producer token of the
  /// Recording this stop concerns — the SAME value every clip that Recording
  /// produces is stamped with ([DashcamClip.producerToken]), captured when
  /// that Recording was started ([DashcamService.startLoopRecording]'s own
  /// `clipOwnerToken`). `null` when that Recording was started without one.
  final Object? producerToken;

  /// The Recording identity this pending stop concerns. Observability/
  /// diagnostics: since Fase 16.2-R4.3-R2.5 this is NOT what a caller should
  /// compare against a pre-issuance snapshot to decide whether the handle is
  /// legitimate — see [intentId] for why such a snapshot is not authority.
  final int? recordingId;

  /// The controller this pending stop concerns — compare via [identical]
  /// for the same reason as [recordingId].
  final CameraController controller;

  /// The REAL, unbounded settlement of this stop — see
  /// [DashcamService.pendingStopHandle]'s own doc.
  final Future<void> settlement;
}

/// Fase 16.2-R4.3-R2.2 (§6/§7/§9/§41-43, independent-review gap — "STOP
/// obligation deve ser capturada antes do await"): the full, immutable
/// outcome of issuing a stop via [DashcamService.beginStopLoopRecording] —
/// returned BY VALUE, synchronously, so a caller can capture [handle]
/// immediately (before awaiting [presentation] or doing anything else) and
/// never needs to read [DashcamService.pendingStopHandle] again later to
/// discover "what was my own stop" (that getter remains only for
/// observability/tests — see its own doc). Closes a genuine race a fast
/// (within-deadline) native STOP exposes: [DashcamService._pendingNativeStop]
/// can already be cleared by the time [presentation] itself resolves (see
/// [DashcamService._doFinalizeCurrentSegment]'s own doc for exactly why —
/// completion and clearing happen in the same synchronous continuation, with
/// no `await` between them), so a caller that waits for [presentation] and
/// ONLY THEN reads the pending-stop registry can observe `null` even though
/// a real stop, with a real identity/settlement, genuinely existed. [handle]
/// is built directly from the [_PendingNativeStop] object itself (or `null`,
/// if this call turned out not to need a stop at all) the INSTANT it becomes
/// known — never by re-reading a mutable field afterward — so it stays
/// correct regardless of how fast that stop settles.
class DashcamStopOutcome {
  const DashcamStopOutcome({required this.presentation, required this.handle, this.intentId});

  /// Fase 16.2-R4.3-R2.5 (§5-§9, independent-review P1-3 — "announcement
  /// compartilhado entre rotation e explicit stop"): the immutable identity of
  /// the logical stop INTENT this outcome resolves — every
  /// [DashcamStopOutcome] describes exactly one intent, and [handle] can only
  /// ever resolve to a stop that intent itself produced or legitimately
  /// adopted (never one concluded, e.g. as `null`, by an intent with an
  /// incompatible purpose — see [DashcamService._claimStopIntent]). Two
  /// outcomes share an id only if they genuinely joined the SAME intent
  /// (semantically equivalent requests).
  final int? intentId;

  /// The same presentation-bounded future [DashcamService.stopLoopRecording]
  /// has always returned — unchanged semantics.
  final Future<void> presentation;

  /// Resolves to this call's own [DashcamPendingStopHandle] — `null` only if
  /// this call turned out not to create/join a real native stop at all (e.g.
  /// nothing was recording). NOT bounded by [presentation] (Fase
  /// 16.2-R4.3-R2.4): [presentation] only bounds how long the caller waits,
  /// while this resolves once this call's own intent is genuinely decided —
  /// possibly long after [presentation] resolved (an obligation queued behind a
  /// still-running native operation). A caller that must not block on it
  /// observes it with a non-blocking continuation; it always resolves, never
  /// with an error.
  final Future<DashcamPendingStopHandle?> handle;
}

/// Fase 16.2-R4.3-R2.6.18 (substitute independent review of R2.6.17, R1 —
/// "camera-only cleanup"): the identity of ONE accepted
/// [DashcamService.startLoopRecording] call — which START it was (its START
/// epoch, the counter this service already had) and on which controller it was
/// accepted. Opaque: a caller cannot build one, read one or alter one; it gets
/// it from [DashcamService.beginStartLoopRecording] at the instant its START is
/// accepted and hands it back, unchanged, to
/// [DashcamService.beginStopLoopRecording] when what it wants to clean up is
/// "what THAT START did".
///
/// Exists because the camera is not that identity. The same
/// [CameraController] serves every START issued between two `initialize()`
/// calls, so a cleanup that could only say "this camera" was taken to speak for
/// whatever START stood at that instant — a later one included, which then
/// resolved without error and never recorded. And the Recording is not always
/// that identity either: a START whose native call has not returned yet, or
/// never produced one, has no Recording to name.
class DashcamStartAttempt {
  DashcamStartAttempt._(this._startEpoch, this._controller);

  final int _startEpoch;
  final CameraController _controller;

  /// Test-only: the START epoch this attempt was accepted as.
  @visibleForTesting
  int get startEpochForTest => _startEpoch;
}

/// Fase 16.2-R4.3-R2.6.18: what [DashcamService.beginStartLoopRecording]
/// returns — by value, synchronously, like [DashcamStopOutcome].
class DashcamStartOutcome {
  const DashcamStartOutcome({required this.presentation, required this.attempt});

  /// The Future [DashcamService.startLoopRecording] has always returned —
  /// unchanged semantics.
  final Future<void> presentation;

  /// The identity of the START this call was ACCEPTED as. `null` when the call
  /// was not accepted as a START of its own — a recording was already wanted,
  /// so it was absorbed by the intent standing ([presentation] is then already
  /// complete): that caller started nothing, owns nothing, and has nothing of
  /// its own to clean up.
  final DashcamStartAttempt? attempt;
}

/// The lifecycle of a single [_PendingNativeStop] — Fase 16.2-R4.2A. Not a
/// generic state machine: this only ever describes one
/// `controller.stopVideoRecording()` call from issue to real resolution.
enum _NativeStopState {
  /// The raw native `Future` is still within [DashcamService.stopVideoRecordingTimeout].
  active,

  /// The UI-visible deadline elapsed, but the raw native `Future` is still
  /// unresolved — ownership is retained regardless (see
  /// [_PendingNativeStop]'s own doc).
  uiDeadlineExceededPending,

  /// The raw native `Future` resolved with an `XFile`, and it has been
  /// processed into [DashcamService.clips] exactly once.
  completed,

  /// The raw native `Future` resolved with an error, and that error has been
  /// reported via [DashcamService.errors] exactly once.
  failed,
}

/// Distinguishes *why* [DashcamService._doFinalizeCurrentSegment] is being
/// called — Fase 16.2-R4.2A-R4 (§9). Introduced because that method is
/// shared by three structurally different triggers that turned out to need
/// different policies for one specific decision: whether
/// [DashcamService._cameraKnownUnavailable] being `true` is a reason to
/// abandon a segment without even attempting `stopVideoRecording()`.
///
/// Only [rotation] carries a real "restart right after" risk — immediately
/// after finalizing, [DashcamService._doRotateSegment] tries to start a
/// *new* recording on the *same* [CameraController] (see its own doc) — the
/// exact sequence the original Fase 16.1 crash involved. [explicitStop] and
/// [teardown] never do: a user-initiated `stopLoopRecording()` starts
/// nothing afterward, and a [DashcamService._doReleaseController] teardown
/// discards the controller regardless of what finalize decides. Fase
/// 16.2-R4.2A-R7 (§26, doc-accuracy fix): so, architecturally, skipping the
/// native stop for those two only ever loses a clip — it is not the
/// same-generation restart-after-a-hung-stop sequence the original crash
/// needed. This is a verifiable claim about this class's own local
/// serialization/ownership, not a claim that any code path here has been
/// validated safe on real hardware (that validation remains pending — see
/// this class's own doc, final paragraph). See
/// [DashcamService._doFinalizeCurrentSegment]'s own doc for the full
/// reasoning and an independent-review-confirmed regression this
/// distinction fixes.
enum _FinalizeReason {
  /// Triggered by [DashcamService._onRotationTick]/
  /// [DashcamService._doRotateSegment] — the segment-duration timer.
  rotation,

  /// Triggered by a direct, caller-initiated [DashcamService.stopLoopRecording].
  explicitStop,

  /// Triggered by [DashcamService._doReleaseController] — shared by
  /// [DashcamService.releaseIdleCamera], [DashcamService.dispose], and
  /// [DashcamService.initialize]'s own internal release of a prior
  /// controller before building a fresh one.
  teardown,
}

/// Fase 16.2-R4.3-R2.3 (§14-§18, independent-review P1-B — "targeted release
/// libera process owner de G2"): the outcome of one [DashcamService
/// ._doReleaseController] call, as seen by its own caller
/// ([DashcamService._doReleaseControllerAndOwnership]) — the minimal
/// information needed to decide whether releasing
/// [DashcamService._DashcamProcessOwner] is this call's own to do. A
/// mismatch detected only INSIDE the enqueued closure (CHECK 2 — Fase
/// 16.2-R4.3-R2.2 §25-§27) returns normally, not via an exception, so
/// `try`/`catch` alone cannot distinguish "genuinely released" from
/// "silently declined" — this crosses that boundary explicitly instead.
enum _ReleaseDisposition {
  /// This call's own real work released whatever controller it found (or
  /// confirmed none was held at all, or the [expectedController] check
  /// passed and its own scoped release ran) — the service holds nothing,
  /// on this call's own account, that still needs [DashcamService
  /// ._DashcamProcessOwner].
  released,

  /// [expectedController] no longer matched the CURRENT controller by the
  /// time this call's own turn in [DashcamService._queueTail] arrived — a
  /// newer, still-current controller was left completely untouched.
  /// Ownership belongs to whatever still holds THAT controller — never
  /// this stale call's to release.
  targetMismatch,
}

/// Fase 16.2-R4.3-R2.6.14: what [DashcamService._doRotateSegment] concluded
/// about a rotation whose own stop settled only AFTER
/// [DashcamService.stopVideoRecordingTimeout] — see
/// [DashcamService._lateRotationDecision]. Everything but [resume] means "do
/// not start the next segment": the late continuation never overrides
/// whatever happened while it waited.
enum _LateRotationDecision {
  /// Nothing changed while the stop was in flight: the next segment starts,
  /// on the same controller, exactly as after a stop that met the deadline.
  resume,

  /// The late stop ended in an error (the native call, or the processing of
  /// its file). Unchanged policy for a failed rotation stop: no restart on
  /// that controller, [DashcamService._cameraKnownUnavailable] set.
  stopFailed,

  /// A stop, release, re-initialize or dispose was requested meanwhile (each
  /// clears the recording intent synchronously, when requested).
  recordingNoLongerWanted,

  /// A new START was issued meanwhile: that START, queued behind the
  /// rotation, owns starting — the rotation must not start in its place.
  supersededByNewerStart,

  /// The controller the stop was issued on is no longer the current one.
  controllerReplaced,

  /// The camera was marked unavailable meanwhile — the app was backgrounded
  /// ([DashcamService.notifyAppBackgrounded]) or another native call failed.
  cameraUnavailable,
}

/// Fase 16.2-R4.3-R2.6.20: what [DashcamService._doRotateSegment] concluded
/// about a rotation whose restart START settled only AFTER
/// [DashcamService.startVideoRecordingTimeout] — the START-side counterpart of
/// [_LateRotationDecision]; see [DashcamService._lateRestartDecision].
/// Everything but [adopted] means "what that START produced, if anything, is
/// not this run's next segment": the late continuation never overrides
/// whatever happened while it waited.
enum _LateRestartDecision {
  /// Nothing changed while the START was in flight: the Recording it produced
  /// is the run's next segment, exactly as after a START that met the
  /// deadline, and the run's timer counts the next period from this settlement.
  adopted,

  /// The late START ended in an error: nothing was recorded. As after a START
  /// that fails within the deadline, the camera generation is not trusted any
  /// more ([DashcamService._cameraKnownUnavailable]) — and the run ends.
  startFailed,

  /// A stop, release, re-initialize or dispose was requested meanwhile (each
  /// clears the recording intent synchronously, when requested).
  recordingNoLongerWanted,

  /// A new START was accepted meanwhile: the recording intent standing is that
  /// START's, queued behind the rotation — not this run's.
  supersededByNewerStart,

  /// The controller the START was issued on is no longer the current one.
  controllerReplaced,

  /// The camera was marked unavailable meanwhile — the app was backgrounded
  /// ([DashcamService.notifyAppBackgrounded]).
  cameraUnavailable,
}

/// Fase 16.2-R4.3-R2.6.15: the loop-recording run a segment timer belongs to —
/// captured once, when the timer is armed, and carried by every tick that
/// timer ever produces ([DashcamService._onRotationTick]). No new generation
/// is counted here: these are the two identities this class already had, held
/// together —
///  * [startEpoch]: [DashcamService._startIntentEpoch] of the START the timer
///    was armed for (the same value a [_StopIntent] records);
///  * [controller]: the raw camera generation that Recording runs on.
///
/// Why a tick needs it: every guard a rotation used to consult reads the
/// service's CURRENT state, and `_isRecording` answers "does anyone want
/// recording", not "does the recording that created me still exist". After a
/// logical stop followed by a new START it is `true` again — on behalf of
/// someone else. The independent review of R2.6.14 (P2-01) reproduced the
/// consequence through the public API: rotation ticks queued behind a slow
/// stop of run A ran after `stopLoopRecording()` + `startLoopRecording(B)`,
/// found the camera idle and B's intent set, and started Recordings labelled
/// A. B's own START then failed against a camera already recording, which
/// left this service reporting "not recording" over an active Recording that
/// the next `stopLoopRecording()` did not stop.
class _RotationRun {
  const _RotationRun({required this.startEpoch, required this.controller});

  final int startEpoch;
  final CameraController controller;
}

/// Fase 16.2-R4.3-R2.6.15: the ways a rotation tick ends WITHOUT rotating
/// because of that round's own rules — diagnostics only
/// ([DashcamService.rotationTickFatesForTest]); no decision reads it. A tick
/// with none of these fates ran exactly as it did before.
enum _RotationTickFate {
  /// Dropped the instant the timer fired: its run was no longer the current
  /// one. Nothing was claimed, nothing was queued.
  staleAtAdmission,

  /// Dropped the instant the timer fired: a tick of the same run was already
  /// waiting in the queue, and one waiting tick is all a run can ever need.
  coalesced,

  /// Its run was superseded while it waited: when its turn in the queue came
  /// it returned without any effect.
  staleAtExecution,

  /// It waited behind another rotation of the same, still-wanted run, which
  /// meanwhile replaced the segment this tick was for: nothing left to rotate.
  absorbed,

  /// Its run was superseded while its own finalize step was in flight (a stop
  /// that met its deadline, or no stop at all — a stop that missed it is a
  /// [_LateRotationDecision]): the next segment was not started.
  staleAfterStop,
}

/// Fase 16.2-R4.3-R2.6.16: what that round's own rules did to a START that did
/// not end up recording — diagnostics only
/// ([DashcamService.startFatesForTest]); no decision reads it. A START whose
/// intent a stop, a release or a re-initialize had already withdrawn, with a
/// queued operation left to conclude whatever it started, is not counted: that
/// path is older than this round and behaves as it did.
enum _StartFate {
  /// Its turn in the queue came with its own intent still standing, but its
  /// controller — or its caller's context — no longer current: it emitted
  /// nothing (as before) and took its own intent down.
  ownIntentRetracted,

  /// A later START was accepted while this one waited in the queue: when its
  /// turn came it emitted nothing.
  supersededBeforeEmission,

  /// A later START was accepted while this one's native START was in flight:
  /// no timer was armed for the Recording it produced.
  supersededAfterEmission,

  /// Its intent was withdrawn while its native START was in flight and nothing
  /// in the queue was going to stop the Recording it produced: this START
  /// finalized that Recording itself.
  ownRecordingFinalized,
}

/// Fase 16.2-R4.3-R2.5 (§6/§7, independent-review P1-3): WHY a stop intent
/// exists — part of its identity, not a label. Two intents with different
/// purposes are never the "same request", even when they happen to concern the
/// same Recording, so neither's terminal result (in particular a `null`
/// "I decided no stop was needed") may conclude the other. Deliberately finer
/// than [_FinalizeReason] (which only selects one policy inside
/// [DashcamService._doFinalizeCurrentSegment]): this enum distinguishes
/// CALLERS' obligations, e.g. an untargeted session stop from a targeted stale
/// cleanup, which share [_FinalizeReason.explicitStop] but not semantics.
enum _StopPurpose {
  /// [DashcamService._onRotationTick] — the segment-duration timer. Declines to
  /// stop (publishes `null`) whenever [DashcamService._cameraKnownUnavailable]
  /// is set (see [_FinalizeReason.rotation]) — a decision about ROTATION's own
  /// policy, never a statement about anyone else's obligation.
  rotation,

  /// An untargeted [DashcamService.beginStopLoopRecording]/`stopLoopRecording()`
  /// — "stop whatever Recording is current when my own turn arrives", the
  /// session-stop obligation. Its Recording is deliberately NOT frozen at
  /// issuance (see [_StopIntent.expectedRecordingId]).
  explicitStop,

  /// A [DashcamService.beginStopLoopRecording] carrying `expectedController`/
  /// `expectedRecordingId` — a stale caller's cleanup of ONE specific,
  /// already-materialized Recording; a mismatch is a silent no-op.
  targetedCleanup,

  /// [DashcamService.releaseIdleCamera]/[DashcamService.dispose] — teardown of
  /// whatever controller is held (finalizing its Recording first, if any).
  release,

  /// [DashcamService.initialize]'s own internal release of a prior controller
  /// (a new session, or a camera switch) before building a fresh one.
  reinitialize,
}

/// Fase 16.2-R4.3-R2.5 (§5-§13, independent-review P1-2/P1-3): the immutable
/// identity of ONE logical stop request — what R4.3-R2.4 still modeled as a
/// bare, shared `Completer<_PendingNativeStop?>` ("announcement") that any
/// producer could conclude on behalf of any other. Two independent defects
/// followed from that: (P1-3) a rotation intent publishing `null` ("rotation
/// declined") also terminally concluded an explicit session-stop that had
/// reused the same completer, whose own real STOP — issued later — was then
/// silently dropped; and (P1-2) a caller had no way to know which stop was
/// legitimately its own except by comparing against a Recording-id snapshot
/// taken before that Recording existed.
///
/// This is only semantic identity — it does NOT replace
/// [DashcamService._queueTail], which remains the sole authority over physical
/// execution order. It answers "whose obligation is this result" and "may
/// these two callers share one result":
///  * [purpose] is part of the identity ([isCompatibleWith]) — incompatible
///    intents never share a resolution; the later one takes the earlier as a
///    BARRIER instead (see [DashcamService._claimStopIntent]);
///  * [expectedController]/[expectedRecordingId] are set ONLY when the caller
///    genuinely knows the target — an untargeted intent leaves them `null`
///    and resolves to whichever Recording it itself stops;
///  * [resolution] completes exactly once — a real [_PendingNativeStop], or
///    `null` meaning "THIS intent needed no stop" — never with an error.
class _StopIntent {
  _StopIntent({required this.id, required this.purpose, required this.startEpoch, this.expectedController, this.expectedRecordingId, this.attemptEpoch});

  final int id;
  final _StopPurpose purpose;

  /// Fase 16.2-R4.3-R2.6.18: for a cleanup issued on behalf of ONE START
  /// attempt ([DashcamStartAttempt]) — that attempt's START epoch. `null` for
  /// every other intent. It is the temporal identity [expectedController]
  /// cannot give: what such a cleanup may stop, adopt or own is what THAT
  /// attempt recorded, whatever id its current segment has by then. Compare
  /// with [startEpoch], which is when the intent was created: the two are equal
  /// exactly when the cleanup was issued while its attempt was still the latest
  /// START — the only case in which it took the recording intent down, and the
  /// only case in which nothing newer stands ahead of it in the queue.
  final int? attemptEpoch;

  /// [DashcamService._startIntentEpoch] at the instant this intent was created.
  /// Two stop intents concern the SAME Recording only if no START intent was
  /// issued between them — a START issued in between (still queued in the FIFO,
  /// so no Recording identity exists for it yet) would produce the Recording the
  /// later intent targets, not the one the earlier intent stops. See
  /// [isCompatibleWith]/[DashcamService._claimStopIntent]. In today's call graph
  /// an untargeted stop's own synchronous prefix (`_isRecording = false`)
  /// already supersedes any not-yet-running START, so this guard is defense in
  /// depth: it keeps "same Recording" locally evident in the compatibility rule
  /// instead of depending on that distant invariant.
  final int startEpoch;
  final CameraController? expectedController;
  final int? expectedRecordingId;

  final Completer<_PendingNativeStop?> _resolution = Completer<_PendingNativeStop?>();

  Future<_PendingNativeStop?> get resolution => _resolution.future;
  bool get isResolved => _resolution.isCompleted;

  /// The stop this intent resolved to, or `null` (unresolved, or resolved to
  /// "no stop"). Observability only — see [DashcamService.stopIntentsForTest].
  _PendingNativeStop? resolvedStop;

  /// Fase 16.2-R4.3-R2.6 (§19-§27, independent-review P1-B — "perda transitiva
  /// de stop discovery"): the EARLIER intents that were still unresolved (and
  /// concerned the same Recording — [startEpoch]) when this one was created —
  /// the whole chain, not only the immediate predecessor. R2.5 observed just
  /// the slot's intent, which is enough for a pair but not for a chain: in
  /// `explicit(2) → targetedCleanup(3) → explicit(4)`, intent 3 legitimately
  /// resolves `null` (its own target did not match what 2 stops), and intent 4,
  /// watching only 3, never learned about the REAL physical stop 2 produced.
  /// An intermediate `null` means only "THIS intent did not produce/adopt a
  /// stop" — never "no physical obligation exists in the ancestry". This intent
  /// therefore observes every unresolved ancestor directly and adopts the
  /// first real stop it accepts ([acceptsStop]). Cleared the instant this
  /// intent resolves (and each ancestor drops its listeners when IT resolves),
  /// so the lineage lives exactly as long as the FIFO still holds unresolved
  /// intents — see [DashcamService._claimStopIntent].
  final List<_StopIntent> ancestors = [];

  /// Two requests may share ONE intent only if they are semantically the same
  /// request: same purpose, same explicit target, and no START issued between
  /// them ([startEpoch]). Anything else is incompatible — a barrier/
  /// re-evaluation, never a join.
  bool isCompatibleWith(_StopPurpose otherPurpose, CameraController? otherController, int? otherRecordingId, int otherStartEpoch, {int? otherAttemptEpoch}) {
    return purpose == otherPurpose &&
        startEpoch == otherStartEpoch &&
        identical(expectedController, otherController) &&
        expectedRecordingId == otherRecordingId &&
        attemptEpoch == otherAttemptEpoch;
  }

  /// Whether [stop] is something this intent's own caller may legitimately
  /// receive — foreign stops (a different controller/Recording than an explicit
  /// target) are never accepted.
  ///
  /// Fase 16.2-R4.3-R2.6.18: a cleanup issued for a START attempt
  /// ([attemptEpoch]) accepts the stop of a Recording of THAT attempt — its
  /// current segment, whatever its id — and of no other.
  bool acceptsStop(_PendingNativeStop stop) {
    if (expectedController != null && !identical(stop.controller, expectedController)) return false;
    if (expectedRecordingId != null && stop.recordingId != expectedRecordingId) return false;
    if (attemptEpoch != null && stop.recordingStartEpoch != attemptEpoch) return false;
    return true;
  }

  void resolve(_PendingNativeStop? stop) {
    if (_resolution.isCompleted) return;
    resolvedStop = stop;
    _resolution.complete(stop);
  }
}

/// Fase 16.2-R4.3-R2.5 (test-only observability): an immutable summary of one
/// [_StopIntent], so a test can assert intent identity/purpose/outcome without
/// this file exposing the private class itself. See
/// [DashcamService.stopIntentsForTest].
class DashcamStopIntentSnapshot {
  const DashcamStopIntentSnapshot({
    required this.id,
    required this.purpose,
    required this.resolved,
    required this.resolvedRecordingId,
    this.resolvedPhysicalStopId,
    this.producerIntentId,
    this.attemptEpoch,
  });

  final int id;

  /// Fase 16.2-R4.3-R2.6.18: for a cleanup issued for ONE START attempt, that
  /// attempt's START epoch ([_StopIntent.attemptEpoch]); `null` otherwise. How
  /// a test asserts WHICH START a caller named when it cleaned up — a fact
  /// with no other observable trace when something else stops the same
  /// Recording first.
  final int? attemptEpoch;

  /// The physical stop this intent resolved to (adopted or produced), if any —
  /// [_PendingNativeStop.id]. Equal across every intent that adopted the SAME
  /// native operation.
  final int? resolvedPhysicalStopId;

  /// The logical intent that physically issued the stop this intent resolved
  /// to; differs from [id] when this intent ADOPTED it.
  final int? producerIntentId;

  /// [_StopPurpose]'s own `name` (`rotation`/`explicitStop`/`targetedCleanup`/
  /// `release`/`reinitialize`).
  final String purpose;

  final bool resolved;

  /// [_PendingNativeStop.recordingId] of the stop this intent resolved to, or
  /// `null` if it is unresolved or resolved to "no stop".
  final int? resolvedRecordingId;
}

/// A `controller.stopVideoRecording()` call this [DashcamService] has issued
/// and not yet fully resolved — Fase 16.2-R4.2A.
///
/// Exists because [DashcamService.stopVideoRecordingTimeout] bounds how long
/// a *caller* waits, not how long the real native call is given to run:
/// `camera_android_camerax 0.7.4+8` exposes no cancellation for a
/// `stopVideoRecording()` already in flight, and the CameraX plugin holds a
/// single, plugin-wide (not per-controller) `recording`/`pendingRecording`/
/// `videoOutputPath` state — confirmed by auditing
/// `android_camera_camerax.dart` directly. A missed UI deadline therefore
/// must not be treated as "nobody owns this operation anymore": until the
/// real result is known, no other `initialize()`/`startVideoRecording()`/
/// `dispose()` call may safely touch that same native state (see this
/// class's own doc, §1 bullet 3, and [DashcamService._doFinalizeCurrentSegment]'s
/// own doc for how [DashcamService._queueTail] enforces that).
class _PendingNativeStop {
  _PendingNativeStop({
    required this.id,
    required this.controller,
    required this.recordingId,
    required this.startedAt,
    required this.stoppedAt,
    required this.protectClip,
    required this.deadlineInstant,
    this.producerToken,
    this.recordingStartEpoch,
    this.originIntentId,
    this.descriptor,
    Completer<void>? visibleSignal,
  }) : _visibleSignal = visibleSignal ?? Completer<void>() {
    // Fase 16.2-R4.2A-R1 (P1-A fix, §5/§7): every stop — whether triggered
    // by an explicit stopLoopRecording() call or by a rotation tick nobody
    // is directly awaiting — owns exactly one visible signal from the
    // instant it starts, so a LATER caller that discovers this operation
    // already in flight (see [DashcamService.stopLoopRecording]/
    // [DashcamService.releaseIdleCamera]/[DashcamService.dispose]'s own
    // docs) can attach to it directly instead of enqueueing new work that
    // would just wait behind it without its own deadline. Guaranteeing a
    // listener here also means a rotation-triggered stop nobody externally
    // ever attaches to still can't leave this completer's eventual error
    // "unhandled" if [failVisibleSignal] is called.
    unawaited(_visibleSignal.future.catchError((_) {}));
  }

  /// Monotonic, purely for logging/diagnostics and identity comparisons —
  /// object identity ([identical]) is what this class's own code actually
  /// relies on; this exists so a future diagnostic surface has something
  /// stable and human-readable to print.
  final int id;

  /// The controller this stop was issued against — captured once, not
  /// re-read from [DashcamService._controller] later, so a resolution
  /// arriving after a subsequent [DashcamService.initialize] still applies
  /// to the correct (possibly already-replaced) generation, not whatever
  /// [DashcamService._controller] happens to point to by then.
  final CameraController controller;

  /// Fase 16.2-R4.2A-R6 (§4/§5/§8): the identity of the Recording this stop
  /// was issued against — [DashcamService._activeRecordingId]'s value at
  /// the instant this operation was created, captured atomically here for
  /// the exact same reason [startedAt]/[protectClip] are: a LATE failure
  /// resolving after [DashcamService._activeRecordingId] has since moved on
  /// (a fresh Recording legitimately started) must still be attributed to
  /// THIS Recording, not to whatever happens to be "active" by the time it
  /// resolves — see [DashcamService._failedStopRecordingId]'s own doc for
  /// why this identity exists at all (`controller.value.isRecordingVideo`
  /// alone cannot distinguish "already, terminally failed" from
  /// "genuinely new and untried").
  final int? recordingId;

  /// Fase 16.2-R4.3-R2.5 (§22/§23): the opaque producer token
  /// ([DashcamService._activeRecordingToken]) of the Recording this stop was
  /// issued against — captured atomically with [recordingId], for the same
  /// "capture, don't re-read later" reason, so the clip this stop eventually
  /// yields inherits the token of the Recording that PRODUCED it, never
  /// whatever a later Recording/session has since made current.
  final Object? producerToken;

  /// Fase 16.2-R4.3-R2.6.18: the START epoch of the Recording this stop was
  /// issued against ([DashcamService._activeRecordingStartEpoch]) — captured
  /// atomically with [recordingId], for the same reason. It is what lets a
  /// cleanup issued for ONE START attempt recognize the stop of that attempt's
  /// own Recording ([_StopIntent.acceptsStop]).
  final int? recordingStartEpoch;

  /// Fase 16.2-R4.3-R2.6 (§31/§32): the logical [_StopIntent.id] whose finalize
  /// PHYSICALLY issued this stop — `null` only if none was tracked. Distinct
  /// from [id] (the physical stop's own identity) and from the id of any intent
  /// that merely ADOPTS this stop later ([DashcamPendingStopHandle.intentId]):
  /// one physical stop, one producing intent, possibly several adopters.
  final int? originIntentId;

  /// Fase 16.2-R4.4-R1: the durable identity of the clip this stop yields —
  /// its canonical name in `dashcam_clips/` — frozen HERE, with every other
  /// value of the stop, from values captured atomically with it (the session
  /// in [producerToken], [recordingId], [startedAt], [stoppedAt],
  /// [protectClip], and the resolution/audio the controller was built with):
  /// nothing of it is read from mutable state once the stop is issued, so a
  /// late result names its clip exactly as a prompt one would, and the name is
  /// ready before the file path even arrives (the window between the path and
  /// the rename is only synchronous code and two `stat`s). `null` = unknown
  /// provenance (a Recording started without a session token): the clip gets a
  /// legacy name and is never indexed (R2.5: unknown provenance is never
  /// adopted).
  final DashcamClipDescriptor? descriptor;

  /// Captured before `stopVideoRecording()`'s own call — see
  /// [DashcamClip.recordedAt]'s own doc for why a captured, not re-read,
  /// value matters: a later `startLoopRecording()`'s own synchronous intent
  /// prefix can overwrite `DashcamService._segmentStartedAt` while this stop
  /// is still pending.
  final DateTime startedAt;

  /// Captured before `stopVideoRecording()`'s own call — see
  /// [DashcamService._doFinalizeCurrentSegment]'s own doc for why
  /// `durationSeconds` is stamped at stop-*request* time, not at whatever
  /// instant the real result eventually arrives.
  final DateTime stoppedAt;

  /// The protect-this-clip intent in effect when this stop was issued (see
  /// [DashcamService.markClipAsProtected]) — captured atomically with the
  /// native call itself so a *later* `markClipAsProtected()` call (for
  /// whatever segment/session comes after this one) cannot leak onto this
  /// stop's eventual clip, and this stop's own resolution cannot leak onto
  /// that later segment either.
  final bool protectClip;

  /// The single, absolute wall-clock deadline for this operation as a
  /// whole (native wait + processing) — Fase 16.2-R4.2A-R1 §8/§9/§12. A
  /// caller that discovers this operation already pending (e.g.
  /// [DashcamService.releaseIdleCamera]/[DashcamService.dispose]) computes
  /// its own remaining budget from this SAME instant instead of starting a
  /// fresh, independent [DashcamService.stopVideoRecordingTimeout]-length
  /// timer — avoiding the exact "two competing deadlines for one stop"
  /// defect an independent review found.
  final DateTime deadlineInstant;

  /// Fase 16.2-R4.2A-R1 (P3-E fix): only [completeVisibleSignal] flips this
  /// to [_NativeStopState.uiDeadlineExceededPending]/leaves it at
  /// [_NativeStopState.active] — reaching [_NativeStopState.completed]
  /// requires the *processing* of a real result to have actually finished,
  /// not merely that the raw native `Future` resolved.
  _NativeStopState state = _NativeStopState.active;

  /// Fase 16.2-R4.3-R2.6.14: `true` once [deadlineInstant] elapsed with this
  /// operation still unresolved — set together with
  /// [_NativeStopState.uiDeadlineExceededPending] and, unlike [state], never
  /// reset. [state] alone cannot answer "was this stop late" once the stop has
  /// settled (it reads `completed`/`failed` either way), and that is exactly
  /// what [DashcamService._doRotateSegment] must know to decide whether the
  /// next segment starts through the ordinary path or only after the
  /// late-settlement revalidation.
  bool deadlineExceeded = false;

  final Completer<void> _visibleSignal;

  /// The presentation boundary for THIS operation — completed by
  /// [DashcamService._doFinalizeCurrentSegment] when either the operation's
  /// own deadline elapses or it finishes for real, whichever is first,
  /// never both (see [completeVisibleSignal]/[failVisibleSignal]). It
  /// represents ONLY that: when a caller waiting on this specific stop may
  /// stop waiting. It does NOT represent teardown completion
  /// (`controller.dispose()`, closing [DashcamService.errors]) and does NOT
  /// represent [DashcamService._queueTail] releasing — those remain
  /// entirely [DashcamService._doFinalizeCurrentSegment]'s/
  /// [DashcamService._doReleaseController]'s own doing, unconditionally.
  ///
  /// A LATER `stopLoopRecording()` call that discovers this same operation
  /// already in flight attaches to this exact `Future` directly (this
  /// class's own doc, §1 bullet 3) — a stop's deadline belongs to the
  /// operation, not to whichever caller happened to be listening when it
  /// started.
  ///
  /// Fase 16.2-R4.2A-R2 (§28) first documented here that
  /// [DashcamService.releaseIdleCamera]/[DashcamService.dispose] do NOT
  /// wait on this `Future` directly, only on this same [deadlineInstant] —
  /// true of that round's own implementation, but Fase 16.2-R4.2A-R3
  /// changed it: [DashcamService._awaitTeardown] now DOES await this exact
  /// `Future` directly too, whenever the relevant [_PendingNativeStop] is
  /// already known (see its own doc) — the same completer
  /// [DashcamService._doFinalizeCurrentSegment] itself completes, not a
  /// second one. What remains true, and is the actual invariant worth
  /// documenting rather than which specific caller happens to `await` this
  /// `Future` in which round's implementation: every caller reacting to THIS
  /// stop, by whichever mechanism, derives its own presentation timing from
  /// this one operation — never an independently-started timer of its own
  /// racing it.
  Future<void> get visibleSignal => _visibleSignal.future;

  bool get visibleSignalCompleted => _visibleSignal.isCompleted;

  void completeVisibleSignal() {
    if (!_visibleSignal.isCompleted) _visibleSignal.complete();
  }

  void failVisibleSignal(Object error, StackTrace stack) {
    if (!_visibleSignal.isCompleted) _visibleSignal.completeError(error, stack);
  }

  /// Fase 16.2-R4.3-R2.1 (§8/§9, independent-review gap — "late STOP →
  /// session persistence ownership"): the REAL, unbounded settlement of
  /// THIS specific stop — unlike [visibleSignal] (the presentation
  /// boundary, which can and does resolve before native completion +
  /// clip processing have genuinely finished — see its own doc), this
  /// only ever resolves once [state] has reached a genuinely terminal
  /// value ([_NativeStopState.completed]/[_NativeStopState.failed]).
  /// Completed exactly once, from [DashcamService._clearPendingNativeStop]
  /// itself (the single, common convergence point every real outcome in
  /// [DashcamService._doFinalizeCurrentSegment] already reaches, always
  /// with [state] already set to its terminal value) — never duplicated
  /// at each individual outcome branch. A REJECTION here carries a generic
  /// marker, not the original failure's own error/stack: the real failure
  /// is already reported exactly once via [DashcamService._reportError]
  /// (recordingResult-scoped) at its own point of occurrence — this
  /// Future's only job is telling a LATE caller (see
  /// [DashcamService.pendingStopHandle]) whether a clip is genuinely
  /// coming, not re-delivering the failure itself.
  final Completer<void> _realSettlement = Completer<void>();

  Future<void> get realSettlement => _realSettlement.future;

  /// Called ONLY by [DashcamService._clearPendingNativeStop], which is
  /// itself only ever reached with [state] already terminal — see this
  /// field's own doc.
  void _settleFromState() {
    if (_realSettlement.isCompleted) return;
    if (state == _NativeStopState.completed) {
      _realSettlement.complete();
    } else {
      _realSettlement.completeError(StateError('Native STOP settled without completing (state: $state)'));
    }
    // Mirrors [_visibleSignal]'s own established safety catch (this
    // class's own constructor doc) — a late caller may never end up
    // awaiting [realSettlement] at all (e.g. no late continuation was
    // ever installed because the stop actually completed within its own
    // presentation deadline), which must not surface as an unhandled
    // async error.
    unawaited(_realSettlement.future.catchError((_) {}));
  }
}

/// Loop recording via [camera], on-disk storage-quota management, and clip
/// protection — the low-level camera driver for the Fase 15 Dashcam feature.
///
/// This class owns exactly one [CameraController] for its whole lifetime
/// (see [initialize]/[dispose]) and knows nothing about driving
/// sessions/telemetry/app lifecycle — that orchestration (tying recording to
/// session start/stop, pausing on backgrounding, isolating camera failures
/// from the rest of the app) is `DashcamSessionController`'s job, one layer
/// up. This class's own responsibilities:
///  * [startLoopRecording] / [stopLoopRecording] drive continuous recording
///    by rotating video files every [segmentDuration].
///  * Fase 16.2-R4.4-R2: no storage quota here any more — it is physical,
///    enforced in the index FIFO over the disk (`dashcam_storage_quota.dart`);
///    this class publishes clips and [forgetClips] the evicted ones.
///  * [markClipAsProtected] is the hook called by whatever listens for a
///    high/critical-severity [DetectedEvent] (see `DashcamSessionController`)
///    so the clip containing that moment survives quota cleanup.
///  * [errors] surfaces out-of-band failures with no direct call site to
///    catch them at (see its own doc) — `DashcamSessionController` is the
///    sole listener, mapping any emission to a user-visible error state.
///
/// ## Fase 16.2-R1 — ownership, serialization, and native-operation safety
///
/// An independent review of Fase 16.2's first cut found six real
/// concurrency/lifecycle races (see the individual method docs below for
/// each). The architectural fix has two, deliberately separate layers —
/// see this class's own §3–§7 report sections for the full reasoning:
///
/// 1. **Serialization** ([_enqueue]/[_queueTail]): every operation that
///    mutates [_controller]'s identity or calls a native
///    `CameraController` method that isn't purely a getter goes through a
///    single, hand-rolled Future-chaining queue — no external mutex
///    dependency, no generation counter. Two such operations can never
///    interleave; whichever was requested first runs to completion (however
///    long its own native awaits take) before the next one starts. This is
///    what makes `initialize()` vs `dispose()`, `startLoopRecording()` vs
///    `stopLoopRecording()`, and a segment rotation vs an explicit stop
///    structurally impossible to race against each other — and, since Fase
///    16.2-R4.2A, is also what keeps a still-unresolved native stop (bullet
///    3 below) a real barrier against a later `initialize()`/
///    `startLoopRecording()`/`releaseIdleCamera()`/`dispose()`: none of them
///    can reach their own turn in this queue until the pending stop's own
///    queued operation has fully returned.
/// 2. **Synchronous intent flags** ([_isRecording], [_disposed]): a public
///    method's *intent* (start recording / stop recording / tear down) is
///    recorded synchronously, before anything is enqueued — this can still
///    happen while an earlier operation is mid-native-await (queues don't
///    make the *caller* wait, only the *queued work*). Every `_do*` queued
///    operation re-reads these flags at the points where creating a
///    side effect (a [Timer], a persisted clip) would be wrong if the
///    intent that started it has since been superseded — the concrete fix
///    for a native start/stop completing *after* the intent that requested
///    it no longer holds.
///    Fase 16.2-R4.3-R2.6.15: a flag re-read like this says whether SOMEONE
///    still wants recording — not whether the run that queued the operation
///    is still the one that does. For a segment-rotation tick that
///    difference is the whole matter (a tick of one run acting on the intent
///    of the next one), so a tick also carries the identity of its own run:
///    see [_RotationRun] and [DashcamService._onRotationTick].
///    Fase 16.2-R4.3-R2.6.16: the same holds for a START waiting in the
///    queue — one superseded by a stop and then by a NEWER start found the
///    flag set again and started on that newer intent's behalf. Each START
///    now carries the epoch it was admitted with: see
///    [DashcamService._doStartLoopRecording].
/// 3. **Native-stop ownership** ([_PendingNativeStop]/[_pendingNativeStop],
///    Fase 16.2-R4.2A): [stopVideoRecordingTimeout] bounds how long a
///    *caller* of [stopLoopRecording]/[releaseIdleCamera]/[dispose] waits —
///    it is a UI response deadline, not a cancellation. The [_enqueue]d
///    operation that actually issued `controller.stopVideoRecording()`
///    keeps awaiting the real, original native `Future` regardless of
///    whether its own caller has already moved on, and only returns
///    (releasing bullet 1's queue barrier) once that real result — a late
///    `XFile` or a late error — is known and has been processed exactly
///    once. This replaced an R1-era approach that detached and discarded a
///    timed-out stop's eventual result instead. See
///    [_doFinalizeCurrentSegment]'s own doc for the full protocol.
///
/// None of these three layers can reach into the `camera` plugin's own
/// internals: once a native call hangs past its own configured timeout,
/// nothing in Dart can cancel it (the plugin exposes no such API — confirmed
/// by auditing `camera_android_camerax 0.7.4+8`). What Fase 16.2-R4.2A
/// changed is not that cancellation, but the answer to "does a missed
/// deadline mean nobody owns this anymore" — bullet 3 makes the answer no,
/// for `stopVideoRecording()` specifically (this subfase's own explicit
/// scope). Fase 16.2-R4.2B-R1 extends that same answer to
/// `startVideoRecording()` and `initialize()` too (see
/// [_startVideoRecordingWithTimeout]/[_doInitializeController]'s own docs)
/// and adds a fourth layer:
/// 4. **Process-wide ownership** ([_DashcamProcessOwner], Fase
///    16.2-R4.2B-R1): layers 1-3 above only ever protect ONE
///    [DashcamService] instance against itself. `camera_android_camerax
///    0.7.4+8` holds `recording`/`pendingRecording`/`videoOutputPath` state
///    that is plugin-wide, not per-controller (this class's own doc,
///    [_PendingNativeStop]'s own doc) — a second, independent
///    [DashcamService] instance in the same process is a real possibility
///    this app does not currently rule out architecturally, and two such
///    instances each running layers 1-3 correctly, in isolation, could
///    still race each other's native calls against that shared backend
///    state. [_DashcamProcessOwner] is a minimal, static, process-wide
///    exclusion: at most one [DashcamService] instance may be "the owner"
///    at a time; every [initialize] acquires it (reentrant for the same
///    instance) before touching the backend, and it is released only once
///    this instance's own teardown has *safely* concluded (this class's
///    own report, Fase 16.2-R4.2B-R1, §12/§13/§14) — never merely because a
///    presentation deadline elapsed. This is deliberately NOT a lifecycle
///    generation, session/Hive-ownership, or visual-status framework (all
///    of those remain R4.3's own, separate scope, same as
///    [_activeRecordingId]'s own doc already establishes for a narrower
///    case) — only the minimal identity needed for process-wide exclusion.

/// The outcome of a [_DashcamProcessOwner.acquire] call — Fase
/// 16.2-R4.2B-R2 (§14/§15 fail-closed precedence, §5-§12 pre-admission
/// safety). Deliberately three-way rather than a `bool`: a caller that
/// never actually touched the backend (`abandoned`) must be handled
/// completely differently from one that is permanently blocked
/// (`uncertain`) — the former is a quiet, no-op conclusion; the latter is a
/// real condition worth surfacing as an error (see
/// [DashcamService.initialize]'s own doc).
enum _OwnerAdmission {
  /// [token] is now (or already was) the current owner — safe to proceed.
  granted,

  /// Never granted, but NOT because of [_DashcamProcessOwner._uncertain] —
  /// this specific request's own admission intent was invalidated
  /// ([DashcamService._disposed], or its own presentation deadline already
  /// elapsed — see [_DashcamProcessOwner.acquire]'s `shouldAbandon`
  /// parameter) before the backend became available to it. The backend
  /// itself is NOT known to be broken; some other, still-valid request may
  /// still acquire it normally.
  abandoned,

  /// [_DashcamProcessOwner._uncertain] was already `true` — permanently
  /// fail-closed until a test-only process-restart simulation (see
  /// [_DashcamProcessOwner.simulateProcessRestartForTest]) or, in
  /// production, the app process actually restarting. No token, including
  /// the one already recorded as [_DashcamProcessOwner._owner], may ever be
  /// granted while this holds (Fase 16.2-R4.2B-R2 §14/§15/§16).
  uncertain,
}

/// Fase 16.2-R4.2B-R4 (intervention — test determinism correction, §18):
/// pairs a single real [initialize] operation's own monotonic [clock] with
/// [presentationExpired] — a conservative, additive signal set the instant
/// that SAME operation's own presentation view (`_boundedView`) has
/// rejected via timeout. See [DashcamService._initializeAttempt]'s own doc
/// for the full reasoning; kept as one small object (rather than two
/// separately-threaded fields) so every caller — the fresh closure, a
/// reentrant attach, [DashcamService._boundedView] — always reads and
/// writes the SAME pair, with no possibility of a stale field read.
class _InitializeAttempt {
  _InitializeAttempt() : clock = Stopwatch()..start();

  final Stopwatch clock;
  bool presentationExpired = false;
}

class _DashcamProcessOwner {
  _DashcamProcessOwner._();

  static Object? _owner;

  /// Fase 16.2-R4.2B-R1 (§14/§39 — fail-closed): set when a teardown for
  /// the current owner fails and the backend's real state can no longer be
  /// trusted. Once `true`, [release] is a permanent no-op (see its own
  /// doc) — nothing in this class ever clears it in production; only
  /// [simulateProcessRestartForTest] does, and only under its own,
  /// explicit, test-only conditions. Deliberately conservative:
  /// `camera_android_camerax 0.7.4+8` gives no basis to assume a failed
  /// `dispose()` still leaves the backend safely reusable.
  static bool _uncertain = false;

  static Completer<void>? _waiting;

  /// Grants ownership to [token], waiting first if a DIFFERENT token
  /// currently owns. Fase 16.2-R4.2B-R2 (§14/§15, independent review P1-B):
  /// [_uncertain] takes precedence over EVERYTHING else, including [token]
  /// already being the recorded [_owner] — a same-owner reentrant call must
  /// never bypass fail-closed just because it happens to already hold the
  /// (now-untrustworthy) slot. Checked first, on every loop iteration
  /// (including right after being woken — see [markUncertain]'s own doc for
  /// why a waiter can newly observe this), and returns
  /// [_OwnerAdmission.uncertain] immediately — never loops/retries/busy-waits
  /// on it (§16: "não criar busy loop" — there is nothing to wait FOR:
  /// [_uncertain] only ever clears via a test-only process-restart
  /// simulation, never spontaneously).
  ///
  /// Reentrant (Fase 16.2-R4.2B-R1 §22, preserved): if [token] already owns
  /// and the backend is not uncertain, returns [_OwnerAdmission.granted]
  /// immediately without waiting — the same [DashcamService] instance
  /// calling [DashcamService.initialize] more than once (or interleaving it
  /// with [DashcamService.startLoopRecording]/rotation/release) must never
  /// deadlock against itself.
  ///
  /// Deliberately has no timeout of its own (§17/§20, preserved): a
  /// presentation deadline belongs to the PUBLIC caller waiting on THIS
  /// admission (see [DashcamService.initialize]'s own doc). [shouldAbandon],
  /// when given, is consulted UNCONDITIONALLY immediately before every claim
  /// of a free slot — Fase 16.2-R4.2B-R3 (§4, independent review P1,
  /// confirmed regression): an EARLIER version of this method only consulted
  /// it after genuinely observing cross-instance contention (a private
  /// `_wasContended` flag), on the theory that an UNCONTENDED grant could
  /// only ever be reached "instantly," before any deadline could plausibly
  /// have elapsed. That theory is false: this instance's OWN local FIFO
  /// queue (`DashcamService._queueTail`) can delay the enqueued operation
  /// that calls [acquire] by an arbitrary amount — a still-pending, unrelated
  /// earlier operation on the SAME instance — with no OTHER
  /// [_DashcamProcessOwner] owner ever involved at all. The reviewer's own
  /// reproduction: instance A's own prior work occupies its queue; a
  /// recovery `initialize()` is requested with a short presentation
  /// deadline; that deadline elapses while still queued (never having
  /// touched this coordinator); the earlier work finally completes; this
  /// call finally runs and finds the slot free (nobody else was ever
  /// involved) — under the old, contention-only check, it would claim the
  /// slot and go on to emit a real, stale `controller.initialize()`. "No
  /// global contention was ever observed" does not mean "this intent is
  /// still valid" — those are independent facts, and validity must be
  /// re-derived from [shouldAbandon] regardless of which one happened.
  /// [_wasContended] has been removed entirely — it had no other legitimate
  /// use (§4 of that round's report).
  static Future<_OwnerAdmission> acquire(Object token, {bool Function()? shouldAbandon}) async {
    while (true) {
      if (_uncertain) return _OwnerAdmission.uncertain;
      if (identical(_owner, token)) return _OwnerAdmission.granted;
      if (_owner == null) {
        if (shouldAbandon != null && shouldAbandon()) return _OwnerAdmission.abandoned;
        _owner = token;
        return _OwnerAdmission.granted;
      }
      if (shouldAbandon != null && shouldAbandon()) return _OwnerAdmission.abandoned;
      final gate = _waiting ??= Completer<void>();
      await gate.future;
    }
  }

  /// Only the current, non-[_uncertain] owner can actually release —
  /// otherwise a no-op (Fase 16.2-R4.2B-R1 §13/§14): [token] not being the
  /// current owner means it already released (or never acquired), and
  /// [_uncertain] being set means a teardown failure already decided this
  /// backend must stay fail-closed regardless of who calls this. Callers
  /// (see [DashcamService]'s own release call sites) only ever reach this
  /// after their own teardown succeeded — the no-op path exists for
  /// idempotency/safety, not as a normal outcome.
  static void release(Object token) {
    if (!identical(_owner, token) || _uncertain) return;
    _owner = null;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  /// Marks the CURRENT owner's backend state fail-closed (§14) — a no-op if
  /// [token] is not the current owner (a stale call arriving after
  /// ownership already moved on has nothing left to mark).
  ///
  /// Fase 16.2-R4.2B-R2 (§16, independent review — fixed leak): also wakes
  /// every waiter blocked in [acquire]'s loop, the same way [release] does.
  /// Without this, a waiter blocked behind the now-uncertain owner would
  /// wait on a gate that can now never complete on its own ([release] is a
  /// permanent no-op once [_uncertain] is set) — each woken waiter
  /// re-checks [acquire]'s loop from the top, observes [_uncertain], and
  /// returns [_OwnerAdmission.uncertain] promptly instead of hanging
  /// forever.
  static void markUncertain(Object token) {
    if (!identical(_owner, token)) return;
    _uncertain = true;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  /// `true` only while [token] is the current owner AND the backend is not
  /// [_uncertain] — Fase 16.2-R4.2B-R2 (§10): the defense-in-depth half of
  /// the "revalidate immediately before the first native call" requirement,
  /// used by [DashcamService._doInitializeController] alongside
  /// [DashcamService._disposed] (see its own doc for why both are checked
  /// there, not only here).
  static bool isOwnedBy(Object token) => identical(_owner, token) && !_uncertain;

  /// Production-safe (non-test) accessor — Fase 16.2-R4.2B-R2 (§26): backs
  /// [DashcamService.isCameraBackendUncertain], the minimal runtime signal a
  /// caller like `DashcamSessionController` needs to distinguish "fail-closed,
  /// permanently blocked" from "a native operation is merely still pending"
  /// (see [DashcamService.pendingInitializeSettlement]'s own doc for the
  /// latter).
  static bool get isUncertain => _uncertain;

  @visibleForTesting
  static bool get isUncertainForTest => _uncertain;

  @visibleForTesting
  static Object? get currentOwnerForTest => _owner;

  /// Fase 16.2-R4.2B-R1 (§30), renamed and re-scoped in Fase 16.2-R4.2B-R2
  /// (§19-§23, independent review P2 — "reset atual pode apagar ownership
  /// ativo"): the shared test-harness's own isolation barrier — deliberately
  /// NOT a general "fix everything" reset, and deliberately NOT a claim
  /// about production recovery (§21/§62: production [_uncertain] never
  /// clears itself; this exists only to let the test PROCESS move on, the
  /// same way a real, physical process restart would leave nothing of the
  /// old, uncertain backend state behind).
  ///
  /// Unlike [release], this DOES clear [token]'s ownership even when
  /// [_uncertain] — that flag exists to fail closed against a REAL, unknown
  /// native backend state (§14), which is not what this represents: the
  /// caller is REQUIRED to have already finished proving whatever
  /// fail-closed/behavioral assertions the test cares about, and to have
  /// already drained every raw native op/queue/gate it itself controls
  /// (§19/§21 — this call cannot verify any of that on its own: it has no
  /// visibility into a specific [DashcamService] instance's controller/queue
  /// state, only into this coordinator's own three fields). Every test in
  /// this codebase gets its own fresh `FakeCameraPlatform` regardless, so
  /// there is no real, shared backend left for [_uncertain] to protect
  /// between tests once its own owning test has finished with it.
  ///
  /// Refuses (throws) if a DIFFERENT token currently owns — that scenario is
  /// a genuine cross-instance leak this must never silently mask. A no-op if
  /// nothing owns at all (idempotent, matching [release]).
  ///
  /// Fase 16.2-R4.2B-R2 (§23): only a test that DELIBERATELY produces
  /// [_uncertain] (or otherwise cannot rely on [release] alone — e.g. a
  /// permanently-stuck, never-completed native op it chooses not to drain)
  /// should ever need this. A normal test needing it is itself a signal to
  /// investigate a leak, not evidence this helper is missing a case.
  ///
  /// Fase 16.2-R4.2B-R3 (§21/§22/§26, independent review P2 — "reset usado
  /// cedo demais / apaga owner saudável"): ALSO refuses (throws) if [token]
  /// IS the current owner but [_uncertain] is `false` — a healthy owner must
  /// release NATURALLY via [release] (called by the instance's own
  /// `dispose()`/`releaseIdleCamera()` once its teardown genuinely
  /// completes), never be force-cleared by this test-only helper. This is
  /// what mechanically prevents the exact P2 the reviewer found: a test
  /// calling this on a token that still legitimately, healthily owns the
  /// coordinator, silently discarding evidence of a real leak instead of
  /// letting `waitForProcessOwner(null)`-style verification catch it.
  @visibleForTesting
  static void simulateProcessRestartForTest(Object token) {
    if (_owner == null) return;
    if (!identical(_owner, token)) {
      throw StateError(
        '_DashcamProcessOwner.simulateProcessRestartForTest() called for a token that is not the '
        'current owner — a DIFFERENT instance still owns the coordinator, which this must not '
        'silently mask.',
      );
    }
    if (!_uncertain) {
      throw StateError(
        '_DashcamProcessOwner.simulateProcessRestartForTest() called for a token that is the current '
        'owner but NOT uncertain — a healthy owner must release naturally via release() (e.g. through '
        'the owning DashcamService\'s own dispose()/releaseIdleCamera()), never be force-cleared by '
        'this test-only, process-restart-simulation helper.',
      );
    }
    _owner = null;
    _uncertain = false;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }
}

class DashcamService {
  DashcamService({
    required DashcamConfig config,
    this.segmentDuration = const Duration(minutes: 3),
    this.stopVideoRecordingTimeout = const Duration(seconds: 5),
    this.startVideoRecordingTimeout = const Duration(seconds: 5),
    this.initializeCameraTimeout = const Duration(seconds: 10),
  }) : _config = config {
    // Fase 16.2-R4.4-R1: resolved now, outside the camera FIFO, so a
    // promotion awaits an already-resolved Future instead of a platform-channel
    // call competing with the post-rotation burst on the main thread (see
    // [_clipsDirectory]). A failure here is retried by the first promotion.
    unawaited(_clipsDirectory().then<void>((_) {}, onError: (Object _) {}));
  }

  DashcamConfig _config;

  /// Fase 16.2-R4.4-R1: 128 random bits naming THIS instance in every clip it
  /// publishes ([DashcamClipDescriptor.namespace]) — with [_nextRecordingId]
  /// (which restarts at 1 in every instance) it makes a clip's identity unique
  /// across processes, even should two of them produce the same session id
  /// (a clock set back), and across several instances in one process (tests).
  /// Generated once, never changed: every retry and every restart reads a
  /// clip's identity from its name, never from a new namespace.
  final String _clipNamespace = _newClipNamespace();

  static String _newClipNamespace() {
    final random = Random.secure();
    return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  @visibleForTesting
  String get clipNamespaceForTest => _clipNamespace;

  /// Fase 16.2-R4.4-R1: the resolution and audio request [_controller] was
  /// BUILT with ([_doInitializeController]) — what its Recordings really asked
  /// the camera for, recorded in each clip's name. Not the preferences at the
  /// time a clip is indexed (what the index used to store): those may have
  /// changed since the controller was initialized.
  VideoResolution _controllerResolution = VideoResolution.hd720;
  bool _controllerAudioEnabled = false;
  final Duration segmentDuration;

  /// Bounds how long a *caller* of [stopLoopRecording]/[releaseIdleCamera]/
  /// [dispose] waits on `controller.stopVideoRecording()` before getting
  /// control back — a UI response deadline, not a cancellation (Fase
  /// 16.2-R4.2A; see [_doFinalizeCurrentSegment]'s own doc and this class's
  /// own doc, §1 bullet 3, for what happens to the real native call after
  /// this elapses). Physically confirmed on a Samsung SM-A326B capable of
  /// hanging indefinitely past the native `Recorder`'s own internal
  /// sub-timeout (see [_doFinalizeCurrentSegment]'s own doc for the exact
  /// log line). Real times observed: the native side's own internal wait is
  /// 1000ms; a genuinely healthy stop (including this app's own large-file
  /// finalize+disk-copy overhead, confirmed physically in Fase 15) completes
  /// within a couple of seconds even for a multi-hundred-MB segment. 5s is
  /// several multiples of the 1000ms native sub-timeout — comfortable margin
  /// against a false-positive deadline on a merely slow (not stuck) finalize
  /// — while still being a bounded wait rather than an indefinite one for
  /// the caller specifically. Configurable (like [segmentDuration]) purely
  /// so tests can use a short value instead of waiting out the real default.
  ///
  /// Fase 16.2-R4.3-R2.6.14: the "comfortable margin" above did not hold on
  /// that same phone — a healthy stop was measured at 6.95 s while the
  /// platform thread was saturated (see [_overdueRotationStop]). The answer
  /// is deliberately NOT a longer value: any fixed number can be exceeded by a
  /// stop that still succeeds. For a segment rotation the deadline therefore
  /// no longer decides anything about the camera — it only marks the stop as
  /// slow — and the rotation resumes when the stop settles.
  final Duration stopVideoRecordingTimeout;

  /// Same reasoning and same default as [stopVideoRecordingTimeout], applied
  /// symmetrically to `controller.startVideoRecording()` — Fase 16.2-R1
  /// (independent review, P1-4): a native start hanging the same way as a
  /// native stop was not independently physically reproduced in this phase,
  /// but the `camera` plugin gives no basis to assume it can't happen, and
  /// leaving this one call unbounded would undermine every other protection
  /// in this class (a hung start would block [_queueTail] indefinitely,
  /// which blocks every later `stopLoopRecording()`/`dispose()` too).
  final Duration startVideoRecordingTimeout;

  /// Bounds how long [_doInitializeController] waits on
  /// `controller.initialize()` — the camera-setup native call itself, not
  /// start/stop of a recording. Fase 16.2-R1 (found while writing this
  /// phase's own test suite, §18-G/H/I: without this, a stuck
  /// `initialize()` — e.g. from a recovery attempt already superseded by a
  /// `stopSession()`/`dispose()` that hasn't run yet — blocks [_queueTail]
  /// indefinitely, which in turn blocks that very `stopSession()`/`dispose()`'s
  /// own `releaseIdleCamera()`/teardown call from ever getting its turn: a
  /// real deadlock, not just a slow path). Given no basis to assume camera
  /// hardware setup is faster than a recording start/stop, and Fase 15
  /// physical testing showing real device camera setup can itself take a
  /// few seconds, this default is longer than
  /// [stopVideoRecordingTimeout]/[startVideoRecordingTimeout].
  final Duration initializeCameraTimeout;

  /// Fase 16.2-R4.2B-R1: this instance's own stable, private identity for
  /// [_DashcamProcessOwner] — an [Object] purely for its own identity
  /// ([identical]), never inspected otherwise. INSTANCE ownership identity,
  /// not a lifecycle generation (see [_DashcamProcessOwner]'s own doc).
  final Object _processOwnerToken = Object();

  @visibleForTesting
  Object get processOwnerTokenForTest => _processOwnerToken;

  @visibleForTesting
  static bool get processOwnerIsUncertainForTest => _DashcamProcessOwner.isUncertainForTest;

  @visibleForTesting
  static Object? get processOwnerCurrentForTest => _DashcamProcessOwner.currentOwnerForTest;

  /// Fase 16.2-R4.2B-R1 (§30), renamed in Fase 16.2-R4.2B-R2 (§21) — forwards
  /// to [_DashcamProcessOwner.simulateProcessRestartForTest]; see its own doc
  /// for the exact, narrow conditions under which this is safe to call.
  @visibleForTesting
  static void simulateProcessRestartForTest(Object token) => _DashcamProcessOwner.simulateProcessRestartForTest(token);

  /// Fase 16.2-R4.2B-R2 (§26): the minimal, production-safe runtime signal
  /// distinguishing "fail-closed, permanently blocked until a process
  /// restart" from "a native operation is merely still pending" (see
  /// [pendingInitializeSettlement]'s own doc for the latter) — deliberately
  /// does NOT expose the owner token or any other coordinator internal.
  /// `DashcamSessionController` reads this (alongside
  /// [pendingInitializeSettlement]) to decide whether a recovery attempt
  /// should even be considered possible, without duplicating
  /// [_DashcamProcessOwner]'s own state.
  bool get isCameraBackendUncertain => _DashcamProcessOwner.isUncertain;

  CameraController? _controller;

  /// Fase 16.2-R4.3-R2 (§41, independent-review fix — "error event deve
  /// poder carregar generation"): whatever `lifecycleGeneration` value
  /// [initialize]'s caller supplied when [_controller] was created (`null`
  /// for a direct/test caller that never passes one) — set atomically
  /// alongside [_controller] itself in [_doInitializeController], carried
  /// opaquely (this class attaches no meaning to the value — see
  /// [DashcamServiceError]'s own doc). This class still holds no
  /// lifecycle-generation authority of its own; this is purely a pass-through
  /// tag for whichever controller-scoped [_reportError] call needs to stamp
  /// it onto the [DashcamServiceError] it emits.
  int? _currentControllerGeneration;
  Timer? _segmentTimer;
  /// Fase 16.2-R4.4-HW-MIG-5-SIG-2: every write of `false` also withdraws the
  /// segment's video evidence, in the same step — a stop neutralizes REC before
  /// its native call, never at its `Finalize`.
  bool get _isRecording => _isRecordingValue;
  set _isRecording(bool value) {
    _isRecordingValue = value;
    if (!value) _withdrawSegmentEvidence(DashcamSegmentPresentation.inactive);
  }

  bool _isRecordingValue = false;
  DateTime? _segmentStartedAt;
  bool _protectNextFinalizedClip = false;
  bool _lastKnownHasError = false;

  /// Set once [dispose] has been called — terminal, matching its own doc:
  /// [initialize] refuses to run afterward rather than silently reusing (or
  /// worse, racing) a service whose [errors] stream is already closed. Fase
  /// 16.2-R1 (independent review, §12): a service that stays "sort of"
  /// reusable after `dispose()` is exactly the ambiguity that review asked
  /// to be resolved one way or the other — this class chooses "terminal."
  bool _disposed = false;

  /// Set by [notifyAppBackgrounded] when the app is backgrounded while a
  /// recording is in progress, cleared on the next successful [initialize].
  ///
  /// Fase 16.1 (Testes 2/3E/3F) physically confirmed that Android silently
  /// revokes camera access from a backgrounded, non-foreground-service app —
  /// with no Dart-visible signal: [_onControllerValueChanged] never fires
  /// for this condition, [CameraValue.hasError] stays false, nothing throws.
  /// The camera simply stops being real underneath a [CameraController] that
  /// still believes it's recording. The Fase 16.1 crash (reproduced
  /// byte-for-byte on a Samsung SM-A326B: `AssertionError` in CameraX's own
  /// `Recorder.onConfigured()`, `Recorder.java:1476`, fatal process death)
  /// happened because the segment-rotation timer called `stopVideoRecording()`
  /// against exactly this already-gone camera: the native `Recorder` waited
  /// 1000ms for a "non-streaming" confirmation that could never arrive, got
  /// stuck permanently in `STOPPING`, and later collided with the next
  /// foreground resume's own reconfiguration.
  ///
  /// This same flag is also set by a native start/stop timing out at all
  /// (Fase 16.2-R1) — a distinct but structurally identical situation:
  /// either way, the camera can no longer be trusted for recording until a
  /// fresh [initialize] proves otherwise.
  ///
  /// Fase 16.2-R4.2A-R4 (§1-§9): deliberately NOT set by a mere *discovery*
  /// timeout (see [_discoveryUncertain]) — an independent review reproduced
  /// a P1 where Fase 16.2-R4.2A-R3 had wrongly folded that presentation-only
  /// signal in here too, which then made [_doFinalizeCurrentSegment] (for
  /// [_FinalizeReason.explicitStop]/[_FinalizeReason.teardown], before this
  /// fix) abandon an unrelated, still-genuinely-recording segment — zero
  /// `stopVideoRecording()` call, zero clip — purely because some *other*
  /// caller's own wait for a scheduled-stop announcement took too long. This
  /// field is reserved for facts that actually concern the camera/controller
  /// itself: it must remain readable as "this generation is not to be
  /// trusted for a NEW native call" (still correctly gating
  /// [_doRotateSegment]'s restart, and [_FinalizeReason.rotation]'s own
  /// abandon-without-stop path) without also, incorrectly, meaning "an
  /// existing, already-confirmed Recording does not need collecting."
  ///
  /// Fase 16.2-R4.3-R2.6.14: a ROTATION's own stop outliving
  /// [stopVideoRecordingTimeout] no longer sets this — see
  /// [_overdueRotationStop]. "Slow" is not "lost": the flag is still set when
  /// that late stop ends in an error, and by every other cause listed above.
  ///
  /// Fase 16.2-R4.3-R2.6.20: nor does a rotation's own restart START outliving
  /// [startVideoRecordingTimeout] — see [_rotationRestartOverdue]. The flag is
  /// still set when that restart ends in an error, within the deadline or
  /// after it, and by a START of [startLoopRecording] that outlives its own
  /// deadline (a different event: see [_settleStartAttempt]).
  ///
  /// Fase 16.2-R4.3-R2.6.21: written only through this setter, which
  /// republishes [cameraKnownUnavailable] (see [cameraKnownUnavailableListenable]);
  /// same for the other three inputs of that getter.
  bool get _cameraKnownUnavailable => _cameraKnownUnavailableValue;
  set _cameraKnownUnavailable(bool value) {
    _cameraKnownUnavailableValue = value;
    // Fase 16.2-R4.4-HW-MIG-5-SIG-2: a return from the background needs a new
    // START and new evidence.
    if (value) _withdrawSegmentEvidence(DashcamSegmentPresentation.inactive);
    _publishCameraKnownUnavailable();
  }

  bool _cameraKnownUnavailableValue = false;

  /// Fase 16.2-R4.3-R2.6.14 — the rotation stop that is past its response
  /// deadline and still in flight (native call, or the processing of its
  /// file), if any. A SOFT fact about one operation, kept apart from
  /// [_cameraKnownUnavailable] (a hard fact about the camera generation).
  ///
  /// Physical finding (Samsung SM-A326B, 2026-10-07, debug build, validation
  /// campaign of R2.6.13): 1 of 24 segment rotations never recorded again.
  /// The published `camera_android_camerax 0.7.4+8` forwards every CameraX
  /// `VideoRecordEvent.Status` (one per encoded frame) to Dart and buffers
  /// them until `stopVideoRecording()`; when the Dart GC later releases those
  /// ~5,400 objects of a 3-minute segment, the resulting message flood keeps
  /// the platform thread saturated for 6–10 s. When that flood coincided with a
  /// rotation's stop, the plugin's own `stopVideoRecording()` — otherwise
  /// ~0.2 s — took 6.95 s and then SUCCEEDED. The deadline (5 s) had already
  /// set [_cameraKnownUnavailable], which nothing but a fresh [initialize]
  /// clears, so [_doRotateSegment] skipped the restart and every later tick
  /// did too: the session went on with no video until the app was
  /// backgrounded and resumed (the UI offers no retry in that state). Before
  /// Fase 16.2 the stop had no deadline at all — a slow one only lengthened
  /// the gap between two clips.
  ///
  /// R4.4-HW-MIG-4: the app now uses a copy of the plugin that drops `Status`
  /// before Dart (`third_party/camera_android_camerax_status_filter`), which
  /// removed this flood in the SM-A125M measurements. A stop can still be late
  /// for other reasons, so the rule below stands.
  ///
  /// The deadline is therefore, for a rotation, a liveness/diagnostic signal
  /// only: callers stop waiting ([_PendingNativeStop.visibleSignal]) and the
  /// state is published as degraded ([cameraKnownUnavailable],
  /// [rotationStopOverdue]) for as long as the stop stays in flight — while
  /// the raw native call remains the physical authority, exactly as before
  /// (the rotation's queued operation keeps awaiting it, so [_queueTail] keeps
  /// every `initialize()`/start/release behind it: no second camera can open).
  /// When the stop finally settles, [_doRotateSegment] decides — from the
  /// state as it is THEN, see [_lateRotationDecision] — whether the next
  /// segment starts. A stop that never settles keeps this set forever:
  /// fail-closed, as before.
  ///
  /// Set only by [_doFinalizeCurrentSegment] for [_FinalizeReason.rotation];
  /// cleared only by [_clearPendingNativeStop], the single point every outcome
  /// of a stop already reaches. Explicit stops and teardowns are unchanged:
  /// nothing resumes after them, and their overrun still sets
  /// [_cameraKnownUnavailable].
  _PendingNativeStop? get _overdueRotationStop => _overdueRotationStopValue;
  set _overdueRotationStop(_PendingNativeStop? value) {
    _overdueRotationStopValue = value;
    _publishCameraKnownUnavailable();
  }

  _PendingNativeStop? _overdueRotationStopValue;

  /// True while a segment rotation's own stop is past
  /// [stopVideoRecordingTimeout] and still in flight — see
  /// [_overdueRotationStop]. Tests/diagnostics only (like
  /// [hasPendingNativeStop]); the UI sees it through [cameraKnownUnavailable].
  bool get rotationStopOverdue => _overdueRotationStop != null;

  /// Fase 16.2-R4.3-R2.6.20 — `true` while the restart START of a segment
  /// rotation is past [startVideoRecordingTimeout] and still in flight. The
  /// START-side counterpart of [_overdueRotationStop]: a SOFT fact about one
  /// operation, kept apart from [_cameraKnownUnavailable] (a hard fact about
  /// the camera generation).
  ///
  /// Reproduced by the independent review of R2.6.17 (N2) and traced in this
  /// round with the product's own numbers: a rotation stops its segment, the
  /// native START of the next one takes longer than the 5 s deadline — 5.1 s,
  /// 6.95 s, 7 s, 10 s — and then SUCCEEDS. The deadline had set
  /// [_cameraKnownUnavailable], which nothing but a fresh [initialize] clears.
  /// The late Recording was tracked and went on recording, the run was still
  /// wanted and its timer still fired — but every later tick found the flag:
  /// no stop ([_FinalizeReason.rotation] skips it), no restart. The session
  /// was left with one endless segment and the status "camera unavailable",
  /// which offers no retry, until something re-initialized the camera.
  ///
  /// A fact about ONE slow call had been recorded as a fact about the camera.
  /// For a restart the deadline is therefore, like the rotation stop's, a
  /// liveness/diagnostic signal only: the state is published as degraded
  /// ([cameraKnownUnavailable], [rotationRestartOverdue]) for as long as the
  /// call stays in flight — no video is being captured — while the raw native
  /// call remains the physical authority, exactly as before (the rotation's
  /// queued operation keeps awaiting it, so [_queueTail] keeps every
  /// `initialize()`/start/release behind it: no second START, no second
  /// camera). When the call finally settles, [_doRotateSegment] decides — from
  /// the state as it is THEN, see [_settleLateRestart]. A START that never
  /// settles keeps this set forever: fail-closed, as before.
  ///
  /// Only the restart of a rotation. A START of [startLoopRecording] that
  /// outlives its deadline is a different event and is unchanged: its caller is
  /// told and its intent is taken down AT the deadline, so nobody is waiting
  /// for what it produces later ([_settleStartAttempt]).
  ///
  /// Set only by [_startVideoRecordingWithTimeout], for a rotation's restart;
  /// cleared only by [_doRotateSegment], where that call returns — whatever
  /// the outcome was.
  bool get _rotationRestartOverdue => _rotationRestartOverdueValue;
  set _rotationRestartOverdue(bool value) {
    _rotationRestartOverdueValue = value;
    _publishCameraKnownUnavailable();
  }

  bool _rotationRestartOverdueValue = false;

  /// True while a segment rotation's own restart START is past
  /// [startVideoRecordingTimeout] and still in flight — see
  /// [_rotationRestartOverdue]. Tests/diagnostics only (like
  /// [rotationStopOverdue]); the UI sees it through [cameraKnownUnavailable].
  bool get rotationRestartOverdue => _rotationRestartOverdue;

  /// Fase 16.2-R4.2A-R4 (§1-§9): incremented when a caller's own *discovery*
  /// of a scheduled-but-not-yet-published stop (see [_discoverScheduledStop])
  /// itself times out — purely a presentation signal about how long THAT
  /// caller had to wait, not a finding about whether the camera/controller
  /// the discovery concerns is actually broken (most of the time, by the
  /// time it fires, nothing is wrong at all — the queue was simply busy).
  /// Kept as a separate counter (not [_cameraKnownUnavailable]) so it can
  /// feed the public [cameraKnownUnavailable] getter (still useful for
  /// UI/status and for `DashcamSessionController`'s foreground-resume
  /// reinitialize check) without ever being read by a STOP-vs-skip or
  /// start/restart-control decision — see [_cameraKnownUnavailable]'s own
  /// doc for the bug this separation fixes.
  ///
  /// Fase 16.2-R4.2A-R5 (§20/§21, independent review P2): a plain `bool`,
  /// cleared only by the next successful [initialize], turned out to be the
  /// wrong lifecycle — the uncertainty belongs to the SPECIFIC caller whose
  /// discovery timed out, not to "the camera generation" as a whole, and an
  /// unrelated LATER caller's own still-unresolved uncertainty must survive
  /// an EARLIER one resolving (or vice versa) — a single bool cannot
  /// represent "N distinct callers are each still uncertain" without one of
  /// them clobbering another's. A counter, incremented by
  /// [_armDiscoveryUncertainty] the instant a discovery times out and
  /// decremented exactly once each, when THAT SAME caller's own real,
  /// already-enqueued obligation (see [_awaitTeardown]'s own `queued`
  /// parameter) actually concludes — success, failure, or otherwise —
  /// represents this correctly: each caller's own contribution is paired
  /// 1:1 with its own resolution, so no caller can clear another's. No
  /// external reset is applied anywhere else (deliberately removed the
  /// R4-era `initialize()`-success clear): [_queueTail]'s own strict FIFO
  /// ordering already guarantees every EARLIER caller's own queued
  /// obligation — and therefore its own decrement — has fully resolved by
  /// the time a LATER-enqueued `initialize()` reaches its own success path,
  /// so no explicit reset is ever needed for that case, and forcing one
  /// would risk exactly the "operation A clears operation B's uncertainty"
  /// bug this design avoids for a genuinely concurrent, still-pending B.
  int get _discoveryUncertainCount => _discoveryUncertainCountValue;
  set _discoveryUncertainCount(int value) {
    _discoveryUncertainCountValue = value;
    _publishCameraKnownUnavailable();
  }

  int _discoveryUncertainCountValue = 0;

  /// Fase 16.2-R4.2A-R5: pairs one increment of [_discoveryUncertainCount]
  /// with exactly one decrement, tied to [queued] — the caller's own real,
  /// already-enqueued obligation-fulfilling operation (see
  /// [_awaitTeardown]'s own doc) — rather than to any fixed timer or to a
  /// later, unrelated [initialize] call. [queued] is always already wrapped
  /// by [_observeTeardown] at its own call site (so it never itself throws),
  /// making [Future.whenComplete] here safe regardless of that operation's
  /// real outcome.
  void _armDiscoveryUncertainty(Future<void> queued) {
    _discoveryUncertainCount++;
    unawaited(queued.whenComplete(() => _discoveryUncertainCount--));
  }

  /// True while [_cameraKnownUnavailable] is set and/or at least one caller
  /// is still [_discoveryUncertainCount]-uncertain — see their own docs.
  /// Read by `DashcamSessionController` on foreground resume to decide
  /// whether the camera must be reinitialized even though [isRecording]
  /// never turned false (the old recording was never stopped, only
  /// abandoned), and to decide whether the status it exposes to the UI
  /// should say so truthfully (Fase 16.2-R1, P1-5). Deliberately an OR of
  /// both — a UI/reinitialize decision is exactly the kind of
  /// presentation-facing consumer [_discoveryUncertainCount] exists for;
  /// only the STOP-vs-skip/start-control decisions inside this class must
  /// not read it (Fase 16.2-R4.2A-R4).
  ///
  /// Fase 16.2-R4.3-R2.6.14: also true while a rotation's stop is overdue
  /// ([_overdueRotationStop]) — no video is being captured in that window, so
  /// the status must not say otherwise — and false again by itself once that
  /// stop settles and nothing else holds the camera unavailable. Same rule as
  /// for the counter: a presentation fact, never read by this class's own
  /// control decisions.
  ///
  /// Fase 16.2-R4.3-R2.6.20: and while a rotation's restart START is overdue
  /// ([_rotationRestartOverdue]) — for the same reason, under the same rule.
  bool get cameraKnownUnavailable => _cameraKnownUnavailable || _discoveryUncertainCount > 0 || _overdueRotationStop != null || _rotationRestartOverdue;

  /// Fase 16.2-R4.3-R2.6.21: [cameraKnownUnavailable], published — its value
  /// changes, and its listeners are told, in the same synchronous step as the
  /// write that changed it (each of its four inputs is written only through a
  /// setter that republishes it). Until this round the fact only changed:
  /// nothing told `DashcamSessionController`, whose status reads it, so a
  /// rotation's restart START or stop outliving its deadline left the REC
  /// indicator and the preview showing a recording that no longer existed,
  /// for as long as the call stayed in flight (their own repaint tickers run
  /// only while the status says `recording`). A [ValueNotifier]: a write that
  /// does not change the value tells nobody.
  ///
  /// Never disposed: this service keeps writing those inputs after [dispose]
  /// while its teardown settles. It holds nothing but its listeners, and the
  /// controller removes its own in its own `dispose()`.
  ValueListenable<bool> get cameraKnownUnavailableListenable => _cameraKnownUnavailablePublished;
  final ValueNotifier<bool> _cameraKnownUnavailablePublished = ValueNotifier<bool>(false);

  void _publishCameraKnownUnavailable() => _cameraKnownUnavailablePublished.value = cameraKnownUnavailable;

  /// Fase 16.2-R4.2A-R6 (§23): the raw count, exposed ONLY for tests —
  /// [cameraKnownUnavailable] already proves "at least one caller is
  /// uncertain," but proving the counter's own 0→1→2→1→0 balancing (two
  /// independent, concurrent discovery timeouts, each resolved separately)
  /// needs the actual number, which no other public state exposes.
  @visibleForTesting
  int get discoveryUncertainCountForTest => _discoveryUncertainCount;

  final List<DashcamClip> _clips = [];
  List<DashcamClip> get clips => List.unmodifiable(_clips);

  bool get isRecording => _isRecording;

  /// Fase 16.2-R4.4-HW-MIG-5-SIG-2: what REC may claim about the current
  /// segment, published in the same step as the write that changes it. Only
  /// presentation: nothing in the recording path reads it, waits for it or is
  /// started by it, and no timer writes it — no evidence means no REC.
  ValueListenable<DashcamSegmentPresentation> get segmentPresentationListenable => _segmentPresentation;
  final ValueNotifier<DashcamSegmentPresentation> _segmentPresentation = ValueNotifier<DashcamSegmentPresentation>(DashcamSegmentPresentation.inactive);

  /// The evidence slot being watched and the recording this service adopted in
  /// it. `null` when no recording of this service may turn REC on — a Recording
  /// identified only so it can be cleaned up is never adopted.
  ValueListenable<RecordingEvidence?>? _adoptedEvidenceSlot;
  int? _adoptedEvidenceToken;

  /// Called only where a START's Recording was accepted as the run's segment
  /// (never for one that is about to be stopped). The START's Future has
  /// returned, and this service's own queue ([_enqueue]) runs no other START
  /// before this adoption, so the slot holds this Recording's evidence — including
  /// any that arrived before this call.
  void _adoptSegmentEvidence() {
    _releaseEvidenceSlot();
    final slot = currentRecordingEvidenceSource()?.recordingEvidence;
    final evidence = slot?.value;
    if (slot == null || evidence == null) return;
    _adoptedEvidenceSlot = slot;
    _adoptedEvidenceToken = evidence.token;
    slot.addListener(_onAdoptedEvidenceChanged);
    _onAdoptedEvidenceChanged();
  }

  void _onAdoptedEvidenceChanged() {
    final token = _adoptedEvidenceToken;
    if (token == null) return;
    final evidence = _adoptedEvidenceSlot?.value;
    if (evidence == null || evidence.token != token) {
      // The plugin let go of this Recording (its dispose). No fact to report.
      _withdrawSegmentEvidence(DashcamSegmentPresentation.startPending);
    } else if (evidence.ended) {
      // A requested stop withdrew the adoption before asking, so an end that
      // still finds it adopted was not requested (storage full, encoder error,
      // source lost). Until the next STOP nothing else reads that Finalize.
      // Only reported and shown: recovering from it is a separate decision.
      _withdrawSegmentEvidence(DashcamSegmentPresentation.segmentEnded);
      _reportError('A gravação do segmento terminou sem pedido de parada (erro nativo ${evidence.endError})', scope: DashcamServiceErrorScope.recordingResult);
    } else if (evidence.videoProgress) {
      _segmentPresentation.value = DashcamSegmentPresentation.videoConfirmed;
    }
  }

  void _releaseEvidenceSlot() {
    _adoptedEvidenceSlot?.removeListener(_onAdoptedEvidenceChanged);
    _adoptedEvidenceSlot = null;
    _adoptedEvidenceToken = null;
  }

  void _withdrawSegmentEvidence(DashcamSegmentPresentation next) {
    _releaseEvidenceSlot();
    _segmentPresentation.value = next;
  }

  /// Marks the camera as no longer trustworthy for recording because the app
  /// has moved to the background — see [_cameraKnownUnavailable] for why.
  /// Safe to call unconditionally: a no-op unless a recording is actually in
  /// progress. Call sites live entirely in `DashcamSessionController`
  /// (this class knows nothing about app lifecycle itself, see this class's
  /// own doc).
  void notifyAppBackgrounded() {
    if (_isRecording) {
      _cameraKnownUnavailable = true;
    }
  }

  /// The live camera controller, once [initialize] has completed — `null`
  /// beforehand/after [dispose]. Callers (preview widgets, settings) only
  /// ever *read* this; construction/disposal stay exclusively inside this
  /// class (see this class's own doc).
  CameraController? get previewController => _controller;

  /// Fase 16.2-R4.3-R2 (§26, independent-review P2-A regression proof):
  /// test-only observability — mirrors [previewController]'s own
  /// established pattern — lets a test assert directly that a stale START's
  /// own success never armed [_segmentTimer] (see [_doStartLoopRecording]'s
  /// own §24/§25 doc), rather than inferring it indirectly from whether a
  /// LATER rotation ever fired.
  @visibleForTesting
  bool get hasActiveSegmentTimerForTest => _segmentTimer != null;

  /// Fase 16.2-R4.3-R2 (§28/§29, independent-review P2-B fix — "targeted
  /// cleanup"): read-only exposure of the CURRENT Recording's own identity —
  /// mirrors [previewController]'s own established pattern — so a caller
  /// (`DashcamSessionController`) can pass it back as [stopLoopRecording]'s
  /// own `expectedRecordingId` to prove a targeted stop is about the SAME
  /// Recording it observed moments earlier, not merely the same controller.
  int? get activeRecordingId => _activeRecordingId;

  /// The clips of THIS instance still in [clips] — not what the disk holds
  /// (Fase 16.2-R4.4-R2: that is the storage quota's snapshot).
  int get totalClipBytes => _clips.fold<int>(0, (sum, clip) => sum + clip.sizeBytes);

  /// The configured quota (`DashcamConfig.storageQuotaMb`) — what the storage
  /// quota reads when its pass runs.
  int get quotaBytes => _config.storageQuotaMb * 1024 * 1024;

  /// Fase 16.2-R4.4-R2: the configured resolution — the one whose largest
  /// measured segment sets the quota's minimum and the free-space floor.
  VideoResolution get configuredResolution => _config.resolution;

  final StreamController<String> _errorsController = StreamController<String>.broadcast();

  /// Out-of-band failures that have no corresponding direct call site to
  /// catch: asynchronous camera-lost errors the plugin itself reports via
  /// [CameraValue.hasError] (e.g. the hardware being taken by another app
  /// mid-recording — not something a `try`/`catch` around a single call
  /// would ever see), and a best-effort segment-finalize failure during
  /// [dispose] (which, by Flutter convention, must not itself throw).
  ///
  /// Ordinary failures from [initialize]/[startLoopRecording] still throw
  /// normally to their own direct caller. Fase 16.2-R4.2A-R7 (§25,
  /// doc-accuracy fix): [stopLoopRecording]/[releaseIdleCamera]/[dispose]
  /// are DIFFERENT — a native `stopVideoRecording()`/`controller.dispose()`
  /// failure reported through any of the three is always routed through
  /// this stream instead, exactly once, by whichever operation actually
  /// owns it ([_doRotateSegment]/[_doReleaseController]'s own direct catch,
  /// or [stopLoopRecording]'s own enqueued closure — see
  /// [_doFinalizeCurrentSegment]'s own doc), never delivered as a `throw`
  /// to any of those three methods' own caller. This is deliberate, not an
  /// oversight: none of the three can assume a caller is still listening
  /// by the time a bounded, presentation-only wait has already returned
  /// (see this class's own doc, §1 bullet 3) — `DashcamSessionController`'s
  /// own `try`/`catch` around a direct [initialize]/[startLoopRecording]
  /// call remains the sole handler for THOSE two specifically.
  Stream<String> get errors => _errorsController.stream;

  final StreamController<DashcamServiceError> _originatedErrorsController = StreamController<DashcamServiceError>.broadcast();

  /// Fase 16.2-R4.3-R1 (§40/§41, D0-approved lifecycle-generation
  /// architecture — "erro stale publicado"): a richer, ADDITIVE sibling of
  /// [errors] — same messages, same timing, paired 1:1 with every [errors]
  /// emission — that also carries [DashcamServiceError.origin]: the
  /// specific [CameraController] a controller-scoped failure concerns
  /// (`null` for a global/backend-level failure, e.g. backend uncertain —
  /// see [DashcamServiceError]'s own doc). [errors] itself is UNCHANGED —
  /// every existing consumer/test keeps seeing exactly the same
  /// `Stream<String>` contract. This exists because `DashcamSessionController`
  /// is the sole lifecycle-generation authority (see its own doc) and needs
  /// to tell "this failure is about a controller I've already superseded"
  /// apart from "this failure is about my current controller, or is
  /// global" — using nothing but the SAME [identical]-based controller
  /// identity already established throughout this class. This class still
  /// holds no lifecycle-generation state of its own.
  Stream<DashcamServiceError> get originatedErrors => _originatedErrorsController.stream;

  void _reportError(
    String message, {
    DashcamServiceErrorScope scope = DashcamServiceErrorScope.backendGlobal,
    CameraController? origin,
    int? generation,
  }) {
    if (!_errorsController.isClosed) _errorsController.add(message);
    if (!_originatedErrorsController.isClosed) {
      _originatedErrorsController.add(DashcamServiceError(message, scope: scope, origin: origin, generation: generation));
    }
  }

  /// Fase 16.2-R4.3-R2.2 (§35-§38, independent-review — "late Hive failure
  /// deve ser observável"): lets an external owner of a genuinely
  /// [DashcamServiceErrorScope]-scoped failure this class has no way to
  /// observe directly — currently only `DashcamSessionController`'s own
  /// clip-persistence Hive write, which happens entirely outside this class
  /// — publish through the SAME [errors]/[originatedErrors] streams instead
  /// of that caller maintaining a second, parallel error channel. A thin,
  /// deliberately narrow wrapper around [_reportError]: [scope] must still
  /// be supplied explicitly by every caller (no default), so nothing can
  /// silently under- or over-report through it.
  void reportExternalError(String message, {required DashcamServiceErrorScope scope, CameraController? origin, int? generation}) {
    _reportError(message, scope: scope, origin: origin, generation: generation);
  }

  void updateConfig(DashcamConfig config) {
    _config = config;
  }

  // ===========================================================================
  // Serialization — see this class's own doc, §1.
  // ===========================================================================

  Future<void> _queueTail = Future<void>.value();

  /// Runs [operation] only after every previously-[_enqueue]d operation has
  /// fully completed (successfully or not) — the sole serialization
  /// primitive for this class (Fase 16.2-R1). Deliberately a plain
  /// Future-chain, not an external mutex package: this class only ever
  /// needs strict FIFO ordering of a handful of async operations, which
  /// Dart's own `Future`/`.then()` already provides without a new
  /// dependency.
  ///
  /// MUST NOT be called from *within* an already-[_enqueue]d operation on
  /// this same queue — doing so would deadlock (the inner call would wait
  /// for the outer one to finish, which is itself waiting for the inner
  /// call). Every `_do*` method below is written to call the *other*
  /// `_do*` methods it needs directly, never via [_enqueue] — only the
  /// public entry points ([initialize]/[startLoopRecording]/
  /// [stopLoopRecording]/[releaseIdleCamera]/[dispose]) and the segment
  /// timer's own tick call [_enqueue] themselves.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previousTail = _queueTail;
    _queueTail = previousTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  // ===========================================================================
  // Native-stop ownership — see this class's own doc, §1 bullet 3, and
  // §6/§7 of the Fase 16.2-R4.2A report.
  // ===========================================================================

  /// The `controller.stopVideoRecording()` call currently in flight, if any
  /// — set the instant that native call is issued (inside
  /// [_doFinalizeCurrentSegment]) and cleared only once its real result (a
  /// late `XFile` or a late error) has been fully processed, regardless of
  /// whether [stopVideoRecordingTimeout] has already elapsed for whichever
  /// caller was waiting on it. See [_PendingNativeStop]'s own doc.
  _PendingNativeStop? _pendingNativeStop;
  int _nextNativeStopId = 0;

  /// Fase 16.2-R4.2A-R6 (§4/§5, independent review — dynamically reproduced
  /// P1): monotonic identity for "the Recording currently active on
  /// [_controller]" — deliberately NOT a lifecycle generation, NOT
  /// session/Hive ownership, NOT a process-wide coordinator (all of those
  /// remain R4.2B/R4.3's own, separate scope). Exists because
  /// `controller.value.isRecordingVideo` alone cannot distinguish "this is
  /// the SAME Recording a prior stop attempt already, terminally, FAILED
  /// against" from "this is a genuinely new Recording that legitimately
  /// needs its own first stop attempt": the plugin never flips
  /// `isRecordingVideo` back to `false` after a failed
  /// `stopVideoRecording()` call (confirmed against `camera-0.12.0+2`
  /// source, same fact this class's own doc already relies on elsewhere) —
  /// so that alone is not identity. Fase 16.2-R4.2A-R7 (§24, doc-accuracy
  /// fix): incremented, and the result assigned to [_activeRecordingId],
  /// only when `controller.startVideoRecording()` is observed to have
  /// succeeded per the Dart/`camera` plugin's own contract — i.e.
  /// [_startVideoRecordingWithTimeout] returning `true` (see
  /// [_doStartLoopRecording]'s and [_doRotateSegment]'s own restart, the
  /// only two places a Recording is ever created). A logical, local
  /// identity assigned on that Dart-level signal — not an instantaneous
  /// physical confirmation that capture is actually underway on the
  /// hardware, which this class has no way to observe directly.
  int _nextRecordingId = 0;

  /// The [_nextRecordingId] value of whatever Recording
  /// `controller.value.isRecordingVideo` currently reflects, if anything —
  /// see that field's own doc. `null` before any Recording has ever
  /// started. Deliberately never explicitly reset back to `null` once
  /// assigned (a fresh Recording simply advances it, per
  /// [_doStartLoopRecording]/[_doRotateSegment]) — Fase 16.2-R4.2A-R5's own
  /// precedent for [_discoveryUncertainCount] applies equally here: an
  /// external reset (e.g. on a later, unrelated [_doInitializeController]
  /// success) risks nothing this specific field needs, since comparisons
  /// against [_failedStopRecordingId] already naturally stop matching once
  /// this value legitimately advances.
  int? _activeRecordingId;

  /// Fase 16.2-R4.3-R2.5 (§22/§23): the opaque producer token
  /// ([startLoopRecording]'s `clipOwnerToken`) of the Recording
  /// [_activeRecordingId] identifies — assigned together with it, and read by
  /// [_doFinalizeCurrentSegment] into [_PendingNativeStop.producerToken] the
  /// instant a stop is issued, so a clip inherits the token of the Recording
  /// that PRODUCED it, never whatever a later Recording/session has since made
  /// current. Like [_activeRecordingId] it is never explicitly reset; a segment
  /// rotation's restart keeps it (same logical producer, new Recording id).
  Object? _activeRecordingToken;

  /// Fase 16.2-R4.3-R2.6.17: the START epoch ([_startIntentEpoch]) of the START
  /// whose native call created the Recording [_activeRecordingId] identifies —
  /// assigned together with it ([_doStartLoopRecording]). No new identity: it
  /// binds the two this class already had, which until now it could not relate
  /// to each other. [_activeRecordingId] is never reset, so after a Recording
  /// ends it goes on naming that Recording while a LATER START — accepted,
  /// waiting in the queue or with its native call in flight — has not created
  /// its own yet; and "Recording 1, over, with START epoch 2 on its way" was
  /// indistinguishable from "Recording 1, live and wanted".
  ///
  /// A segment rotation's restart does not touch it, like the token above: a
  /// rotation only ever restarts for its own, still current run
  /// ([_isCurrentRotationRun]), i.e. under the very epoch already stored here.
  int? _activeRecordingStartEpoch;

  /// Fase 16.2-R4.3-R2.6.17: whether the Recording [_activeRecordingId] names is
  /// the one the LATEST START intent stands for — the one that START's own
  /// native call created. `false` when it is an older Recording: one that is
  /// over, or one whose stop is pending or queued, while a later START has
  /// already been accepted. The recording intent ([_isRecording],
  /// [_segmentTimer]) then belongs to that later START, not to that Recording.
  bool get _activeRecordingIsLatestStarts => _activeRecordingStartEpoch == _startIntentEpoch;

  /// Test-only (Fase 16.2-R4.3-R2.6.18): the START epoch the Recording
  /// [activeRecordingId] names is bound to, and the epoch of the latest
  /// accepted START — so a test can pin that a Recording keeps the epoch of the
  /// START that created it through a segment rotation and through later STARTs.
  @visibleForTesting
  int? get activeRecordingStartEpochForTest => _activeRecordingStartEpoch;

  @visibleForTesting
  int get startIntentEpochForTest => _startIntentEpoch;

  /// Fase 16.2-R4.3-R2.6.18 (substitute independent review of R2.6.17, N1): the
  /// most recent native stop this service issued — kept after it settles,
  /// unlike [_pendingNativeStop]. Written in exactly one place
  /// ([_doFinalizeCurrentSegment], where every native stop is created).
  ///
  /// It answers one question the two identities above could not: whether the
  /// Recording [_activeRecordingId] names is still ALIVE. That id is never
  /// reset, and during a segment rotation it goes on naming the segment whose
  /// stop has already completed until the restart START returns and creates the
  /// next one — under the same START epoch, so [_activeRecordingIsLatestStarts]
  /// is `true` for a Recording that is, in fact, over.
  _PendingNativeStop? _lastNativeStop;

  /// Fase 16.2-R4.3-R2.6.18: whether [recordingId] is a segment a rotation is
  /// REPLACING right now — the service has already stopped it (its native stop
  /// returned and its clip was processed, [_NativeStopState.completed]) and a
  /// rotation is still at work ([_queuedRotationCount]), so the restart START
  /// that creates its successor may still be on its way. Nothing of that
  /// segment is left to clean up, and the recording intent standing is for the
  /// successor — if one comes. Whether it does is not known yet, so a cleanup
  /// that finds its segment in this state does not decide here: it decides
  /// when its own turn in the queue comes ([beginStopLoopRecording]).
  ///
  /// Deliberately narrow. A stop still in flight, a failed one and one past its
  /// deadline are not "completed": what they leave behind is exactly what a
  /// cleanup of that Recording is for. And once no rotation is at work nothing
  /// else is coming — e.g. the restart was not attempted after all and the run
  /// is wanted but dead: a cleanup naming its last segment then takes the
  /// intent down at once, as it always did (which is what lets a START issued
  /// right after it be accepted instead of absorbed by the dead run). (Fase
  /// 16.2-R4.3-R2.6.20: a restart START that FAILS no longer leaves such a run
  /// behind — the rotation ends it itself, see [_endRunLeftWithoutSegment].)
  bool _recordingIsBeingReplaced(int? recordingId) {
    final last = _lastNativeStop;
    return recordingId != null &&
        last != null &&
        last.recordingId == recordingId &&
        last.state == _NativeStopState.completed &&
        _queuedRotationCount > 0;
  }

  /// Fase 16.2-R4.2A-R6 (§6/§7/§10, independent review — dynamically
  /// reproduced P1): the [_PendingNativeStop.recordingId] of the most
  /// recent Recording whose own real `controller.stopVideoRecording()`
  /// attempt terminated with an ERROR (fast or late — see
  /// [_doFinalizeCurrentSegment]'s own doc for exactly where this is set).
  /// Sole purpose: a LATER caller (`stopLoopRecording`/`releaseIdleCamera`/
  /// `dispose`/[initialize]'s own internal release — any [_FinalizeReason]),
  /// discovering the SAME still-"recording" controller only after that
  /// attempt already concluded, must not read
  /// `controller.value.isRecordingVideo == true` as "still needs a stop"
  /// and issue a SECOND `stopVideoRecording()` against the exact same,
  /// already-failed Recording — this class defines no retry policy, and
  /// has no evidence a retry would be safe (see this class's own doc, final
  /// paragraph, and §19 limitations of the R4.2A-R6 report).
  ///
  /// Deliberately NOT the same thing as "pending"
  /// ([_pendingNativeStop]/[hasPendingNativeStop]) — a terminal failure is,
  /// by definition, no longer pending; this field exists specifically to
  /// survive [_pendingNativeStop] being cleared, which is exactly the gap
  /// an independent review found: `hasPendingNativeStop` correctly reports
  /// `false` after a failed attempt (it IS finished, not pending — see
  /// [_clearPendingNativeStop]), but nothing else remembered *that it had
  /// failed* once that happened, so a later caller saw only
  /// `isRecordingVideo == true` and concluded a fresh attempt was owed.
  ///
  /// Compared against [_activeRecordingId] (never against
  /// `controller.value.isRecordingVideo` alone) inside
  /// [_doFinalizeCurrentSegment] — see that method's own doc for the exact
  /// guard. Only ever *set* to a [_PendingNativeStop.recordingId] (the
  /// value captured atomically with the failed operation itself), never to
  /// [_activeRecordingId] directly at the point of failure, for the same
  /// "capture, don't re-read later" reason every other [_PendingNativeStop]
  /// field is captured rather than re-read.
  int? _failedStopRecordingId;

  /// True while a `controller.stopVideoRecording()` call's own operation is
  /// still active — the raw native `Future` unresolved, OR (Fase
  /// 16.2-R4.2A-R3, §23 doc fix) that `Future` has already resolved but the
  /// subsequent [_finalizeSegmentResult] processing of its `XFile` has not
  /// itself finished yet. This is NOT merely "the native result is
  /// unknown": [_clearPendingNativeStop] only runs once processing has
  /// fully concluded (success, or a reported failure) — see
  /// [_doFinalizeCurrentSegment]'s own doc for the exact points. Includes
  /// past [stopVideoRecordingTimeout], the point at which callers stop
  /// *waiting* on it but this class does not. Exposed only for
  /// tests/diagnostics — no UI/status surface reads this yet (that is Fase
  /// 16.2-R4.4's own scope).
  bool get hasPendingNativeStop => _pendingNativeStop != null;

  /// Fase 16.2-R4.3-R2.1 (§9): an immutable [DashcamPendingStopHandle] for
  /// whichever native STOP is currently pending, if any — `null` whenever
  /// none is (either nothing was ever stopped, or it already, genuinely
  /// settled within its own presentation deadline — see
  /// [DashcamPendingStopHandle]'s own doc). A caller reads this AFTER its
  /// own `stopLoopRecording()` call has returned (whether via the
  /// presentation-bounded path or genuine completion) — by that point, if
  /// the camera was genuinely recording when the stop was requested, the
  /// underlying [_PendingNativeStop] (if the operation is still retained)
  /// is guaranteed to already exist (published synchronously, inside
  /// [_doFinalizeCurrentSegment], before any presentation deadline of ITS
  /// OWN caller's could possibly have elapsed) — never requires the caller
  /// to poll.
  DashcamPendingStopHandle? get pendingStopHandle {
    final pending = _pendingNativeStop;
    if (pending == null) return null;
    return DashcamPendingStopHandle(recordingId: pending.recordingId, controller: pending.controller, settlement: pending.realSettlement);
  }

  void _clearPendingNativeStop(_PendingNativeStop operation) {
    if (identical(_pendingNativeStop, operation)) _pendingNativeStop = null;
    // Fase 16.2-R4.3-R2.6.14: "overdue" describes a stop still in flight —
    // it ends here, with the stop, whatever the outcome was.
    if (identical(_overdueRotationStop, operation)) _overdueRotationStop = null;
    // Fase 16.2-R4.3-R2.1 (§8): the single, common convergence point every
    // real outcome in [_doFinalizeCurrentSegment] already reaches, always
    // with [operation.state] already set to its terminal value — see
    // [_PendingNativeStop.realSettlement]'s own doc for why this is safe
    // to centralize here instead of duplicating at each outcome branch.
    operation._settleFromState();
  }

  /// Fase 16.2-R4.2A-R3 (§3/§4/§5): published SYNCHRONOUSLY the instant a
  /// caller decides to enqueue an operation that MAY create a
  /// [_PendingNativeStop] — [stopLoopRecording]'s fresh-stop path, or
  /// [releaseIdleCamera]/[dispose]'s own [_doReleaseController], whenever
  /// none of them finds an existing [_pendingNativeStop] — before that
  /// operation has even reached its turn in [_queueTail], let alone
  /// actually issued `controller.stopVideoRecording()`. Closes a race an
  /// independent review found: calling, with no `await` in between,
  /// ```
  /// final stopping = service.stopLoopRecording();
  /// final releasing = service.releaseIdleCamera();
  /// ```
  /// — `stopLoopRecording()`'s own finalize is already enqueued, but
  /// [_pendingNativeStop] is still `null` (it is only set once that queued
  /// operation actually runs), so `releaseIdleCamera()` would otherwise
  /// wrongly conclude no stop exists at all and enqueue a redundant,
  /// independent one of its own, observing a *different* (if only
  /// microtasks-different) presentation deadline than the real stop's own.
  /// A later caller synchronously chained this way discovers and reuses
  /// THIS SAME announcement instead (see [_claimStopIntent]/
  /// [_discoverScheduledStop]). Cleared the instant the announcement it
  /// refers to is actually published (see [_publishStopIntent]) —
  /// each new stop-creating operation gets a fresh slot.
  ///
  /// Fase 16.2-R4.2A-R4 (§13/§14): [_onRotationTick] now claims/reuses this
  /// SAME slot too, before its own [_doRotateSegment] is even enqueued —
  /// an independent review found the original three-call-site scope left a
  /// structurally identical race uncovered: a segment-rotation tick
  /// synchronously followed by `releaseIdleCamera()`/`dispose()`, with no
  /// `await` in between, could not previously be discovered at all (nothing
  /// published an announcement for it until [_doRotateSegment] itself
  /// reached its own turn in [_queueTail]).
  ///
  /// Fase 16.2-R4.2A-R5 (§18): [initialize] now also claims/reuses this slot
  /// itself, synchronously, before its own queued operation runs — an
  /// independent review found its internal [_doReleaseController] call (the
  /// one that releases whatever controller a PRIOR session left behind) was
  /// stop-capable but had never actually been wired to claim an
  /// announcement for it, unlike every other stop-capable call site,
  /// leaving it structurally invisible to the exact same synchronous-race
  /// discovery this field exists for. Five call sites participate now —
  /// [stopLoopRecording], [_onRotationTick], [initialize], and
  /// [releaseIdleCamera]/[dispose] (all four of the latter via
  /// [_doReleaseController]/[_doFinalizeCurrentSegment]) — still no
  /// static/global/process-wide coordinator: this remains strictly local to
  /// one [DashcamService] instance (out of scope for this subfase, see this
  /// class's own doc).
  ///
  /// Fase 16.2-R4.2A-R5 (§16, independent review — "is a single slot
  /// enough?"): yes, audited and confirmed sufficient, but only because of a
  /// companion invariant established in this same round: every stop-capable
  /// producer now ALWAYS enqueues its own obligation-fulfilling operation
  /// regardless of what it discovers here (see [stopLoopRecording]'s own
  /// doc, and [_doReleaseController]'s pre-existing identical behavior) —
  /// this single slot is therefore never load-bearing for correctness, only
  /// for how PRECISELY a caller can bound its own presentation wait / how
  /// early a later caller can discover something is already scheduled. When
  /// two producers are queued back-to-back (e.g. a rotation tick then this
  /// same call's own `stopLoopRecording()`), the SECOND one's own claim here
  /// legitimately reuses (or, once the first publishes, freshly replaces)
  /// this one slot — a third, later caller might therefore only ever
  /// discover the MOST RECENT producer's own announcement, never an older
  /// one already published-and-cleared. That is fine: [_queueTail]'s own
  /// strict FIFO ordering means the most-recent producer's own queued
  /// operation cannot even START running until every EARLIER one has fully
  /// resolved, so that third caller's own presentation wait, bound to the
  /// most recent announcement, is never SHORTER than the true wait for the
  /// whole local chain to settle — only, at worst, imprecise about exactly
  /// which producer in that chain is the slow one. A small FIFO of
  /// announcements (one per producer) was considered and deliberately not
  /// built: it would only improve that imprecision, never fix a correctness
  /// gap, at the cost of real complexity this subfase's own §13/§16 guidance
  /// explicitly weighs against ("essa semântica simples é preferível").
  ///
  /// Fase 16.2-R4.3-R2.5 (§5-§13, independent-review P1-3 — "announcement
  /// compartilhado entre rotation e explicit stop", reproduced twice by the
  /// reviewer against §9/§34-N1's own scenario): the "single slot is never
  /// load-bearing for correctness" argument above held for WHEN a caller could
  /// stop waiting, but was wrong about WHOSE RESULT the shared completer was.
  /// Every producer that found it unpublished REUSED the same `Completer`, so
  /// the first producer to conclude it — in the reproduced case rotation,
  /// publishing `null` because [_cameraKnownUnavailable] made ROTATION decline —
  /// terminally concluded it for every other producer too. An explicit
  /// session stop that had reused it then saw its handle resolve to `null`
  /// even though its OWN queued finalize went on to collect a real Recording;
  /// that later, correct publication was ignored (already completed). The
  /// physical protocol was right (both clips were produced) — the defect was
  /// obligation IDENTITY.
  ///
  /// The slot therefore now holds a [_StopIntent] — an object with identity,
  /// purpose and its own resolution — not a bare completer. It still exists
  /// only so a LATER caller can discover the most recently scheduled intent for
  /// presentation/discovery purposes (unchanged from R4.2A-R3); what changed is
  /// that a later caller only JOINS it when semantically equivalent (same
  /// purpose and explicit target — [_StopIntent.isCompatibleWith]). Otherwise
  /// it creates its own intent and takes the earlier one as a BARRIER — see
  /// [_claimStopIntent]. [_queueTail] still alone decides physical execution
  /// order; this is not a second queue.
  _StopIntent? _pendingStopIntent;
  int _nextStopIntentId = 0;

  /// Test-only: when `true`, every [_StopIntent] created from then on is
  /// recorded in [stopIntentsForTest]. Off by default so production never
  /// accumulates a history — see [stopIntentsForTest].
  @visibleForTesting
  bool trackStopIntentsForTest = false;
  final List<_StopIntent> _trackedStopIntentsForTest = [];

  /// Test-only: identity/purpose/outcome of every stop intent created since
  /// [trackStopIntentsForTest] was enabled, in creation order — how a test
  /// asserts e.g. "the rotation intent and the explicit-stop intent are
  /// different intents with different purposes, each with its own result".
  @visibleForTesting
  List<DashcamStopIntentSnapshot> get stopIntentsForTest => [
    for (final intent in _trackedStopIntentsForTest)
      DashcamStopIntentSnapshot(
        id: intent.id,
        purpose: intent.purpose.name,
        resolved: intent.isResolved,
        resolvedRecordingId: intent.resolvedStop?.recordingId,
        resolvedPhysicalStopId: intent.resolvedStop?.id,
        producerIntentId: intent.resolvedStop?.originIntentId,
        attemptEpoch: intent.attemptEpoch,
      ),
  ];

  /// Fase 16.2-R4.3-R2.6 (§27): intents registered by [_claimStopIntent] that
  /// are still unresolved — the lineage's boundedness proof: it must return to
  /// `0` once every intent has concluded, however long the chain was.
  final Set<_StopIntent> _liveStopIntents = {};

  @visibleForTesting
  int get liveStopIntentCountForTest => _liveStopIntents.length;

  /// Test-only: total ancestry references currently held by live intents
  /// ([_StopIntent.ancestors]) — `0` once every intent has resolved.
  @visibleForTesting
  int get stopIntentAncestryEntriesForTest => _liveStopIntents.fold(0, (sum, intent) => sum + intent.ancestors.length);

  /// Test-only: the longest ancestry any intent created since
  /// [trackStopIntentsForTest] was enabled ever held — proves a chain of N
  /// intents really was observed transitively, not just pairwise.
  @visibleForTesting
  int maxStopIntentAncestryForTest = 0;

  /// The currently scheduled-but-unresolved intent, or `null`. A resolved
  /// intent still occupying the slot (possible when it was resolved by barrier
  /// adoption, see [_claimStopIntent]) is never returned.
  _StopIntent? get _activeStopIntent {
    final intent = _pendingStopIntent;
    if (intent == null) return null;
    if (intent.isResolved) {
      _pendingStopIntent = null;
      return null;
    }
    return intent;
  }

  /// Returns the currently scheduled stop intent if it is semantically the
  /// SAME request (see [_StopIntent.isCompatibleWith]), or creates and
  /// registers a fresh one — see [_pendingStopIntent]'s own doc.
  ///
  /// Fase 16.2-R4.3-R2.5 (§9/§10, "incompatible intent = barrier /
  /// reevaluation"): when an UNRESOLVED intent exists but is NOT compatible,
  /// this never shares its result and never creates a parallel native STOP
  /// (there is still only one FIFO). The new intent instead observes the
  /// earlier one as a barrier: if that earlier intent resolves to a REAL stop
  /// this intent's own target accepts ([_StopIntent.acceptsStop]), this intent
  /// ADOPTS it — the materialized-STOP rule ("one Recording, at most one STOP
  /// emission", [beginStopLoopRecording]'s own top branch), applied at
  /// materialization time instead of only at call time. An earlier `null` is
  /// deliberately NOT adopted: it only says the EARLIER intent needed no stop;
  /// this intent's own finalize, queued behind it, re-evaluates the state
  /// fresh when its turn arrives (the same principle as the raw
  /// cross-generation initialize barrier).
  ///
  /// Adoption additionally requires that NO START was issued between the two
  /// intents ([_StopIntent.startEpoch]): a queued START in between produces a
  /// NEWER Recording — the one this intent's own finalize will find — so the
  /// earlier intent's stop concerns a different Recording and must not be
  /// handed to this intent as if it were its own (the mirror image of the
  /// stale-RecordingId defect, P1-2).
  ///
  /// Fase 16.2-R4.3-R2.6 (§19-§27, independent-review P1-B): "the earlier
  /// intent" above is the WHOLE unresolved chain ([_StopIntent.ancestors]), not
  /// only the slot's immediate predecessor — pairwise observation lost a real
  /// stop as soon as an intermediate intent resolved `null` (its own target did
  /// not match). The logical identity of this intent is unchanged by adopting
  /// an ancestor's stop: its handle still carries THIS intent's id
  /// ([DashcamPendingStopHandle.intentId]), with the physical stop's own
  /// identity ([DashcamPendingStopHandle.physicalStopId]) and the intent that
  /// produced it ([DashcamPendingStopHandle.producerIntentId]) reported
  /// separately.
  _StopIntent _claimStopIntent(_StopPurpose purpose, {CameraController? expectedController, int? expectedRecordingId, int? attemptEpoch}) {
    final existing = _activeStopIntent;
    if (existing != null && existing.isCompatibleWith(purpose, expectedController, expectedRecordingId, _startIntentEpoch, otherAttemptEpoch: attemptEpoch)) {
      return existing;
    }
    final fresh = _StopIntent(
      id: _nextStopIntentId++,
      purpose: purpose,
      startEpoch: _startIntentEpoch,
      expectedController: expectedController,
      expectedRecordingId: expectedRecordingId,
      attemptEpoch: attemptEpoch,
    );
    _pendingStopIntent = fresh;
    _liveStopIntents.add(fresh);
    if (trackStopIntentsForTest) _trackedStopIntentsForTest.add(fresh);
    if (existing != null) {
      // Fase 16.2-R4.3-R2.6 (§19-§27, independent-review P1-B): observe the
      // WHOLE unresolved chain, not only [existing]. [existing.ancestors] are
      // the unresolved intents [existing] itself was observing; anything that
      // has resolved since (to `null` or to a stop it did not hand on) needs no
      // watching. Each observed intent hands this one its real stop the moment
      // it resolves — independent of what any intermediate intent decides — so
      // an intermediate `null` can never hide a compatible physical stop that
      // an older ancestor produces. Only real stops are adopted, only ones this
      // intent's own target accepts, and only the FIRST (a chain within one
      // [_StopIntent.startEpoch] concerns one Recording, hence at most one real
      // stop) — so this can neither duplicate a native STOP nor lend an
      // ancestor's stop to a caller whose expected target does not match it.
      // Nothing here retries or creates a stop: a failed physical stop stays
      // terminal ([_failedStopRecordingId] still gates [_doFinalizeCurrentSegment]).
      final candidates = <_StopIntent>[existing, ...existing.ancestors];
      for (final ancestor in candidates) {
        if (ancestor.isResolved || ancestor.startEpoch != fresh.startEpoch) continue;
        fresh.ancestors.add(ancestor);
        unawaited(
          ancestor.resolution.then((stop) {
            if (stop != null && !fresh.isResolved && fresh.acceptsStop(stop)) _publishStopIntent(fresh, stop);
          }),
        );
      }
      if (trackStopIntentsForTest && fresh.ancestors.length > maxStopIntentAncestryForTest) {
        maxStopIntentAncestryForTest = fresh.ancestors.length;
      }
    }
    return fresh;
  }

  /// Monotonic count of START intents ([startLoopRecording] calls that were
  /// actually accepted) — see [_StopIntent.startEpoch].
  ///
  /// Fase 16.2-R4.3-R2.6.16: also the identity each START carries from the
  /// instant it is admitted ([startLoopRecording]) to wherever its queued
  /// operation acts ([_doStartLoopRecording]). No second counter was added for
  /// that: the value that already told two stop intents apart tells two START
  /// intents apart just as well.
  int _startIntentEpoch = 0;

  /// Fase 16.2-R4.3-R2.6.16: whether the START admitted as [startEpoch] is
  /// still the LATEST START intent of this service — no other
  /// [startLoopRecording] call was accepted since. Identity only: whether
  /// recording is still wanted ([_isRecording]) and on which controller stay
  /// the separate questions they were.
  bool _isLatestStartIntent(int startEpoch) => _startIntentEpoch == startEpoch;

  /// Fase 16.2-R4.3-R2.6.17: see [startAttemptSettling]. Written only by
  /// [_doStartLoopRecording], around [_settleStartAttempt]; the queue runs one
  /// operation at a time, so there is never more than one such attempt.
  bool _startAttemptSettling = false;

  /// Fase 16.2-R4.3-R2.6.17: whether a PHYSICAL START attempt of
  /// [startLoopRecording] is still settling — `true` from the instant its
  /// native `startVideoRecording()` call is issued until that call has really
  /// returned AND the attempt has finished stopping the Recording it created,
  /// when it had to ([_settleStartAttempt]).
  ///
  /// Deliberately a different fact from [isRecording] (the logical intent) and
  /// from the Future [startLoopRecording] returns (the logical result, which
  /// completes at [startVideoRecordingTimeout] at the latest): after a START
  /// deadline both say "over" while the plugin may still produce a Recording.
  /// While this is `true` the queue is held by that attempt — a later START
  /// waits behind it, and a release or a dispose does not let go of the camera
  /// or of the process owner. Like [hasPendingNativeStop], exposed for
  /// tests/diagnostics; nothing in this class decides from it.
  bool get startAttemptSettling => _startAttemptSettling;

  /// Fase 16.2-R4.3-R2.6.16: whether an operation ALREADY in [_queueTail] is
  /// going to stop [recordingId] on [controller] when its turn comes — read
  /// off the unresolved stop intents ([_liveStopIntents]), each of which
  /// belongs to an operation still waiting in the queue:
  ///  * an untargeted stop, a release, a re-initialize: stops whatever that
  ///    controller is recording;
  ///  * a targeted cleanup: only the Recording it names;
  ///  * a rotation: not counted — a tick never acts for another run.
  /// Used by [_doStartLoopRecording] (for a START whose intent was withdrawn
  /// while its native call was in flight) and, since Fase 16.2-R4.3-R2.6.20,
  /// by [_settleLateRestart] (for a rotation's restart that returned late and
  /// is not adopted), to tell "someone owns stopping this Recording" from
  /// "nobody does".
  ///
  /// Fase 16.2-R4.3-R2.6.18: [startEpoch] is the START attempt that created
  /// [recordingId]. A cleanup issued for ONE START attempt
  /// ([_StopIntent.attemptEpoch]) counts only for a Recording of THAT attempt,
  /// and only when it was issued while that attempt was still the latest START
  /// (`attemptEpoch == startEpoch` of the intent). Issued after a later START
  /// was accepted, it waits BEHIND that START in the queue: the camera is
  /// needed before its turn comes, so it is not what stops this Recording in
  /// time — the attempt stops it itself.
  bool _hasQueuedStopFor(CameraController controller, int? recordingId, int startEpoch) {
    for (final intent in _liveStopIntents) {
      if (intent.purpose == _StopPurpose.rotation) continue;
      if (intent.expectedController != null && !identical(intent.expectedController, controller)) continue;
      if (intent.expectedRecordingId != null && intent.expectedRecordingId != recordingId) continue;
      final attemptEpoch = intent.attemptEpoch;
      if (attemptEpoch != null && (attemptEpoch != startEpoch || intent.startEpoch != attemptEpoch)) continue;
      return true;
    }
    return false;
  }

  final List<int> _startFateCounts = List<int>.filled(_StartFate.values.length, 0);

  void _noteStart(_StartFate fate) => _startFateCounts[fate.index]++;

  /// Test-only: how many STARTs met each [_StartFate], by `name` — lets a test
  /// assert WHY a START did nothing, after asserting that it did.
  @visibleForTesting
  Map<String, int> get startFatesForTest => {
    for (final fate in _StartFate.values) fate.name: _startFateCounts[fate.index],
  };

  /// Fase 16.2-R4.3-R2.5: an intent that is already resolved at creation —
  /// for an outcome that adopted an already-materialized stop, or turned out
  /// to need none. Never registered in [_pendingStopIntent] (nothing left to
  /// discover), but still a real, identifiable intent: every
  /// [DashcamStopOutcome] describes exactly one.
  _StopIntent _resolvedStopIntent(
    _StopPurpose purpose,
    _PendingNativeStop? stop, {
    CameraController? expectedController,
    int? expectedRecordingId,
    int? attemptEpoch,
  }) {
    final intent = _StopIntent(
      id: _nextStopIntentId++,
      purpose: purpose,
      startEpoch: _startIntentEpoch,
      expectedController: expectedController,
      expectedRecordingId: expectedRecordingId,
      attemptEpoch: attemptEpoch,
    );
    if (trackStopIntentsForTest) _trackedStopIntentsForTest.add(intent);
    intent.resolve(stop);
    return intent;
  }

  /// Resolves [intent] with [stop] (a no-op if already resolved — every call
  /// site is allowed to call this unconditionally, and only the FIRST result
  /// for an intent ever counts) and, if [intent] is still the
  /// currently-registered [_pendingStopIntent], clears that slot so the next
  /// stop-creating operation gets a fresh one instead of silently reusing this
  /// already-resolved intent.
  void _publishStopIntent(_StopIntent? intent, _PendingNativeStop? stop) {
    if (intent == null || intent.isResolved) return;
    intent.resolve(stop);
    // Boundedness (§27): a resolved intent observes nobody and is no longer
    // live — its listeners on ancestors are released as those resolve.
    intent.ancestors.clear();
    _liveStopIntents.remove(intent);
    if (identical(_pendingStopIntent, intent)) {
      _pendingStopIntent = null;
    }
  }

  /// Fase 16.2-R4.2A-R3 (§6): waits for [announcement] — a stop that has
  /// been SCHEDULED but not yet PUBLISHED — bounded by
  /// [stopVideoRecordingTimeout] as a presentation deadline for the
  /// DISCOVERY itself, not for any stop (none is known to exist yet at this
  /// point, so this is not that stop's own deadline). On timeout, the
  /// [TimeoutException] is rethrown so callers can distinguish "discovery
  /// timed out" from "confirmed no stop was needed" (both otherwise resolve
  /// to the same `null` value) — Fase 16.2-R4.2A-R5: this method itself no
  /// longer mutates [_discoveryUncertainCount] on that path (an earlier
  /// version did); the caller (currently only [_awaitTeardown]) does, via
  /// [_armDiscoveryUncertainty], because only the caller has [queued] — the
  /// real obligation whose eventual resolution is what actually ends this
  /// specific uncertainty (see that counter's own doc). If the stop DOES
  /// publish within the window, it is returned so the caller can switch to
  /// observing that stop's own real
  /// [_PendingNativeStop.deadlineInstant]/[_PendingNativeStop.visibleSignal]
  /// instead of any further independent timing (this class's own doc, §1
  /// bullet 3).
  Future<_PendingNativeStop?> _discoverScheduledStop(_StopIntent intent) {
    return intent.resolution.timeout(stopVideoRecordingTimeout);
  }

  /// Fase 16.2-R4.2A-R3 (§9/§10): attaches a permanent error observer to
  /// [queued] the INSTANT it is created — before [_awaitTeardown] has had
  /// any chance to decide whether/how long to wait on it, and regardless of
  /// whether it ever does. Guarantees a late teardown failure (e.g.
  /// `controller.dispose()` itself throwing, once a long-pending stop it
  /// was queued behind finally resolves) is always reported via [errors]
  /// exactly once, never left as an unhandled async error — matching the
  /// existing, established contract for every other background/late
  /// failure in this class (see [_doFinalizeCurrentSegment]'s own doc):
  /// late failures are reported, not propagated, to avoid two
  /// independently-timed error paths for the same event. The returned
  /// [Future] never itself throws (the error is consumed here); callers
  /// that still want to wait for [queued] to finish (not merely for its
  /// error to be handled) `await` the returned [Future] instead of [queued]
  /// directly.
  Future<void> _observeTeardown(Future<void> queued) {
    return queued.then((_) {}, onError: (Object error) {
      // Fase 16.2-R4.3-R2 (§45): reachable only from [releaseIdleCamera]/
      // [dispose]'s own [_doReleaseControllerAndOwnership] rethrowing —
      // which, by then, has ALREADY marked process ownership uncertain (see
      // its own catch) — a genuine backend-wide fact, independent of any
      // controller/Recording identity. Explicit, not relying on this being
      // [_reportError]'s own default (§46: "não preservar null por
      // conveniência").
      _reportError('Falha ao finalizar liberação da câmera: $error', scope: DashcamServiceErrorScope.backendGlobal);
    });
  }

  /// Swallows both the success value and any error of [future] — used only
  /// for `controller.startVideoRecording()` ([_startVideoRecordingWithTimeout])
  /// and `controller.initialize()` ([_doInitializeController]) timing out.
  /// Fixing those two the way Fase 16.2-R4.2A fixed `stopVideoRecording()`
  /// (see [_PendingNativeStop]'s own doc) is explicitly out of that
  /// subfase's scope — this is the older, R1-era behavior, kept for them
  /// specifically: `camera_android_camerax 0.7.4+8` exposes no cancellation
  /// for any of these calls once issued, so the original native `Future` is
  /// still live and will complete on its own, later, independently of
  /// anything this class does from here on. Left completely unhandled, a
  /// late error from it would become an uncaught, unattributable async
  /// error capable of crashing the whole process on its own. This makes the
  /// *outcome* crash-safe; it does not (and per the plugin's own limits,
  /// cannot) make the underlying native call itself safe, and — unlike
  /// [_pendingNativeStop] — does not keep [_queueTail] blocked against a new
  /// camera generation opening on top of it. That residual risk for a hung
  /// start/initialize (as opposed to a hung stop) remains open — see this
  /// class's own doc, final paragraph.
  Future<void> _detachNativeOperation(Future<Object?> future) {
    return future.then((_) {}, onError: (_) {});
  }

  // ===========================================================================
  // initialize()
  // ===========================================================================

  Future<void>? _initializeFuture;

  /// Fase 16.2-R4.2B-R4 (intervention — test determinism correction, §18
  /// "contraprova de produção"): one instance per real [_initializeFuture]
  /// operation — created the instant that operation is created, reused by
  /// every caller of [initialize] that attaches to it afterward (including
  /// a reentrant one), exactly mirroring [_PendingNativeStop.deadlineInstant]'s
  /// own "one operation, one deadline" reasoning.
  ///
  /// Fase 16.2-R4.2B-R4 (§3-§8, independent review P1-A — "expiração
  /// reversível por relógio civil"): a [DateTime]-based deadline
  /// (`DateTime.now().add(initializeCameraTimeout)`, compared via
  /// `DateTime.now().isBefore(deadline)`) is a WALL-CLOCK computation —
  /// vulnerable to the civil clock being adjusted (manual change, NTP sync,
  /// DST) between the two reads, so [clock] measures ELAPSED time against
  /// the platform's monotonic clock instead — immune to civil-clock
  /// adjustment by construction.
  ///
  /// Fase 16.2-R4.2B-R4 (intervention round, causal-test-driven finding):
  /// [Stopwatch.elapsed] and `Future.timeout`'s own internal [Timer] are
  /// BOTH monotonic, but are not GUARANTEED to be perfectly synchronized
  /// against each other — a deterministic causal test (no fixed real-time
  /// margin: the presentation view's own rejection was awaited explicitly,
  /// via `expectLater`/`throwsA`, before releasing a gate held open past
  /// the deadline) reproducibly caught `Future.timeout`'s [Timer] firing
  /// (rejecting the PRESENTATION view) fractions of a millisecond BEFORE a
  /// freshly-read [Stopwatch.elapsed] on the very same operation reached
  /// the same nominal [initializeCameraTimeout] — a real, bounded
  /// Timer/Stopwatch precision skew (observed on this platform), not a
  /// flaky test. Left uncorrected, that narrow window lets
  /// [preEmissionValid] (Stopwatch-only) still answer "valid" a few
  /// checkpoints later even though the caller has ALREADY been told the
  /// request timed out — precisely the stale-native-emission class of bug
  /// this whole redesign exists to close. [presentationExpired] below
  /// closes that window: set synchronously inside [_boundedView]'s own
  /// `on TimeoutException` handler — which, by construction, always runs
  /// strictly BEFORE that rejection becomes observable to any caller — and
  /// consulted by [preEmissionValid] as an ADDITIONAL, purely-conservative
  /// OR-condition alongside the [Stopwatch] check, never a replacement for
  /// it. This deliberately is NOT the "boolean latch set only by
  /// `Future.timeout`'s own callback" the original P1-A analysis warned
  /// against adopting without a no-race proof: that concern was about
  /// relying on such a latch as the SOLE mechanism, where an unfired
  /// callback would wrongly read as "still valid". Here the Stopwatch
  /// comparison remains the unconditional baseline — if
  /// [presentationExpired] happens not to be set yet when checked, the
  /// result is simply today's pre-existing Stopwatch-only behavior, never
  /// worse. The flag can only make [preEmissionValid] MORE conservative,
  /// never less, so no ordering proof is required for correctness.
  _InitializeAttempt? _initializeAttempt;

  /// Picks a camera per [DashcamConfig.cameraSelection] and initializes the
  /// controller. Must be called (and awaited) before [startLoopRecording].
  ///
  /// Re-entrant-safe: a second call while one is already in flight returns
  /// the same in-flight [Future] instead of constructing a second
  /// [CameraController] — the structural half of this app's "no duplicate
  /// CameraController" guarantee (the other half is that only
  /// `DashcamSessionController` ever calls this method at all). This is an
  /// *efficiency* optimization layered on top of [_enqueue]'s own,
  /// independent correctness guarantee (Fase 16.2-R1): even without this
  /// dedup, two overlapping `initialize()` calls could never corrupt
  /// [_controller] (the queue would simply run the second one's full
  /// camera-setup right after the first, wastefully but safely) — this just
  /// avoids that waste.
  ///
  /// Also safe to call again *sequentially* after a previous call already
  /// completed — e.g. a new driving session starting reuses this same
  /// long-lived [DashcamService], so [DashcamSessionController] calls this
  /// once per session, not just once per app run (see its own doc). Each
  /// call always constructs a fresh [CameraController] (so a config change
  /// made in Settings between sessions — resolution, camera selection —
  /// takes effect on the next session), but does so via [_doReleaseController]
  /// first, which properly disposes whatever controller is already held.
  ///
  /// Throws [StateError] if called after [dispose] — see [_disposed]'s own
  /// doc.
  ///
  /// Fase 16.2-R4.2B-R1: acquires [_DashcamProcessOwner] (reentrant for
  /// this same instance) before touching the backend, and applies
  /// [initializeCameraTimeout] as a pure PRESENTATION deadline (this
  /// class's own doc, §3/§4) on top of the real, retained operation — see
  /// [_boundedView]'s own doc for how that split works, and
  /// [_doInitializeController]'s own doc for why the raw native call itself
  /// is never abandoned regardless of this deadline.
  ///
  /// Fase 16.2-R4.2B-R2 (§5-§12, independent review P1-A — "pre-admissão
  /// obsoleta"): a request that is still only waiting for
  /// [_DashcamProcessOwner] to free up — i.e. it has not yet reached the
  /// point of actually building/initializing a native [CameraController] —
  /// is a PRE-ADMISSION request, and this method's own presentation
  /// deadline elapsing, or [dispose] being called, while it is in that state
  /// safely invalidates it: [_DashcamProcessOwner.acquire]'s `shouldAbandon`
  /// callback below is what lets a request abandon cleanly, before ever
  /// emitting a native call, instead of silently emitting one later, stale,
  /// for a caller (or instance) that has already moved on. This is
  /// deliberately NOT a lifecycle-generation/ticket framework (§58) — just
  /// this one call's own [_disposed]/[deadline] state, re-derived, not a new
  /// persisted identity.
  ///
  /// Fase 16.2-R4.2B-R3 (§3/§7-§13, independent review P1 — "initialize
  /// obsoleto após espera na FIFO local"): [preEmissionValid] below is
  /// re-checked at every meaningful `await` boundary between here and the
  /// one real native call this whole chain leads to
  /// (`controller.initialize()`, inside [_doInitializeController]) — not
  /// only "was there cross-instance contention." This instance's OWN local
  /// [_queueTail] can delay this very closure by an arbitrary amount (an
  /// earlier, unrelated queued operation) with zero [_DashcamProcessOwner]
  /// involvement at all; "nobody else was contending for the coordinator"
  /// and "this intent is still worth emitting a native call for" are
  /// independent facts, and only the second one is what actually matters
  /// here. The checkpoints, in order: (1) immediately below, the instant
  /// this closure finally gets its own turn in [_queueTail] (after
  /// [_doReleaseController], which always runs regardless — releasing
  /// whatever this instance already held is this instance's own
  /// unconditional duty, independent of whether the NEW build below is
  /// still wanted); (2) inside [_DashcamProcessOwner.acquire] itself, both
  /// right before claiming a free slot and on every wake while genuinely
  /// waiting for a different owner; (3) immediately after [acquire] grants,
  /// before the potentially slow `availableCameras()`/[_doInitializeController]
  /// work; (4) inside [_doInitializeController], after `availableCameras()`
  /// resolves (a real, reviewer-identified discovery-latency point); (5) the
  /// final checkpoint, immediately before `controller.initialize()` itself,
  /// with no `await`/yield between that check and the call (see
  /// [_doInitializeController]'s own doc).
  /// Fase 16.2-R4.3-R1 (§11-§13/§24/§25, D0-approved lifecycle-generation
  /// architecture): [semanticStillValid], if given, is consulted as an
  /// ADDITIONAL, purely-conservative AND-condition inside [preEmissionValid]
  /// below — composed alongside the pre-existing [_disposed]/
  /// [presentationExpired]/deadline checks, never replacing them. This is
  /// the ENTIRE lifecycle-awareness surface this class exposes: a caller
  /// (`DashcamSessionController`, the sole lifecycle-generation authority —
  /// see its own doc) passes a predicate answering "is my caller's own
  /// operation still semantically current right now", and every checkpoint
  /// that already calls [preEmissionValid] (Checkpoints 1-5, documented
  /// above) automatically also respects it — with ZERO changes to those
  /// checkpoints themselves. This class holds no lifecycle-generation state
  /// of its own (no second counter, no epoch) — it only ever asks the
  /// predicate, at the same points it already asks about disposal/deadline.
  /// `null` (the default, used by every direct/test caller that constructs
  /// a [DashcamService] without a `DashcamSessionController` in front of
  /// it) means "always still valid" — this parameter changes NOTHING for
  /// any caller that does not pass it.
  /// Fase 16.2-R4.3-R2 (§41, independent-review fix): [lifecycleGeneration],
  /// if given, is carried opaquely — this class attaches no meaning to it —
  /// and stamped onto [_currentControllerGeneration] the instant a fresh
  /// [CameraController] this call creates is adopted as [_controller] (see
  /// [_doInitializeController]'s own doc), so a LATER controller-scoped
  /// [_reportError] call for that exact controller can tag its
  /// [DashcamServiceError.generation] with it. `null` (the default) changes
  /// nothing for any caller that does not pass it.
  Future<void> initialize({bool Function()? semanticStillValid, int? lifecycleGeneration}) {
    if (_disposed) {
      throw StateError('DashcamService.initialize() called after dispose()');
    }
    final inFlight = _initializeFuture;
    if (inFlight != null) {
      return _boundedView(inFlight, _initializeAttempt!, 'Camera initialization timed out');
    }
    // Synchronous intent prefix — see this class's own doc, §1 (2nd bullet).
    // Cancels whatever the previous owner of the camera was doing/recording
    // immediately, not only once this operation reaches its turn in the
    // queue.
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _isRecording = false;
    // Fase 16.2-R4.2A-R5 (§18, independent review P2): claimed SYNCHRONOUSLY
    // here, before this operation is even enqueued — matching
    // [_onRotationTick]'s own pattern (this class's own doc §1 bullet 3) —
    // so the internal [_doReleaseController] call below (which can itself
    // create a real stop for whatever segment the PRIOR controller was still
    // recording) is discoverable, via the shared [_pendingStopIntent],
    // by a `releaseIdleCamera()`/`dispose()` called synchronously right
    // after this, with no `await` in between. An earlier version of this
    // method claimed nothing at all, leaving that internal release
    // stop-capable but structurally invisible to that race.
    final announceStop = _claimStopIntent(_StopPurpose.reinitialize);
    // Fase 16.2-R4.2B-R4 (§4/§6): one attempt (clock + presentation-expiry
    // signal) for this ENTIRE operation — started here, reused by every
    // caller that attaches to it afterward, including a reentrant one.
    // Never a fresh budget per caller.
    final attempt = _InitializeAttempt();
    _initializeAttempt = attempt;
    // Fase 16.2-R4.2B-R3 (§7), retimed onto a monotonic clock in Fase
    // 16.2-R4.2B-R4 (§3/§8), and hardened against a real Timer/Stopwatch
    // precision skew in this same round's intervention (see
    // [_InitializeAttempt]'s own doc): the single, shared source of truth
    // for "is this specific request's pre-emission intent still valid" —
    // consulted at every checkpoint listed in this method's own doc above.
    // Deliberately just a closure over already-existing state
    // ([_disposed]/[attempt]), not a new persisted ticket/generation.
    bool preEmissionValid() =>
        !_disposed &&
        !attempt.presentationExpired &&
        attempt.clock.elapsed < initializeCameraTimeout &&
        (semanticStillValid?.call() ?? true);
    final future = _enqueue(() async {
      try {
        await _doReleaseController(announceStop: announceStop);
      } catch (_) {
        // Fase 16.2-R4.2B-R1 (§14): this instance's own PRIOR controller (if
        // any) failed to release — fail-closed, same as [releaseIdleCamera]/
        // [dispose]'s own identical handling of this exact class of failure.
        _DashcamProcessOwner.markUncertain(_processOwnerToken);
        rethrow;
      }
      // Checkpoint 1 (Fase 16.2-R4.2B-R3 §8): the instant this closure
      // finally gets its own turn — before ever touching the coordinator.
      // Catches a deadline/dispose that already elapsed purely from local
      // FIFO delay, with zero coordinator involvement. Fase 16.2-R4.2B-R4
      // (§9/§10/§13, independent review P1-B — "owner saudável retido após
      // abandono"): now releases ownership before returning — see
      // [_abandonInitializeBeforeNativeEmission]'s own doc for why this is
      // always the correct action here, whether this token never acquired
      // at all, or is reentrantly, already the owner from an earlier,
      // separate, successful [initialize] (this call's own
      // [_doReleaseController] immediately above has, either way,
      // unconditionally already run and left [_controller] `null`).
      if (!preEmissionValid()) {
        _abandonInitializeBeforeNativeEmission();
        return;
      }
      // Fase 16.2-R4.2B-R1 (§5/§12/§22): reentrant for this same instance —
      // a no-op wait if it is already the owner (e.g. every call after the
      // first) — and has no timeout of its own (see
      // [_DashcamProcessOwner.acquire]'s own doc for why). Checkpoint 2
      // (Fase 16.2-R4.2B-R3 §9) lives INSIDE [acquire] itself via
      // `shouldAbandon`, now consulted unconditionally (see its own doc for
      // why the earlier, contention-only version was wrong).
      final admission = await _DashcamProcessOwner.acquire(_processOwnerToken, shouldAbandon: () => !preEmissionValid());
      switch (admission) {
        case _OwnerAdmission.abandoned:
          // Fase 16.2-R4.2B-R2 (§8/§11/§57): never acquired — nothing was
          // ever touched natively, so there is nothing to release and
          // nothing to report. This caller's own presentation deadline
          // already delivered a `StateError` (if it hadn't yet fired when
          // this resolved, [_boundedView] below still will) — a second
          // signal here would be redundant, not additive. Still routed
          // through the shared helper (Fase 16.2-R4.2B-R4 §11): always a
          // no-op here (this token was never granted), but keeps every
          // abandonment path identical, not a special case to remember.
          _abandonInitializeBeforeNativeEmission();
          return;
        case _OwnerAdmission.uncertain:
          // Fase 16.2-R4.2B-R2 (§14/§60): NOT a "this caller gave up" case —
          // the backend itself is permanently fail-closed. Worth throwing,
          // not silently concluding, so a caller still listening learns why
          // no camera will ever become available on this process.
          throw StateError(
            'Camera backend is in an uncertain, fail-closed state (a previous teardown failed) and '
            'cannot be initialized again until the app process restarts',
          );
        case _OwnerAdmission.granted:
          break;
      }
      // Checkpoint 3 (Fase 16.2-R4.2B-R3 §10): immediately after acquiring —
      // no meaningful time can have passed since Checkpoint 1/2 for a
      // reentrant or immediately-free grant, but this stays correct and
      // cheap regardless.
      if (!preEmissionValid()) {
        _abandonInitializeBeforeNativeEmission();
        return;
      }
      bool initialized;
      try {
        initialized = await _doInitializeController(preEmissionValid, lifecycleGeneration);
      } catch (_) {
        // Fase 16.2-R4.2B-R1 (§15): initialize failed — this instance now
        // holds nothing (no controller, no pending native op) worth
        // protecting, so ownership is released... UNLESS
        // [_doInitializeController]'s own best-effort cleanup of the
        // partially-built controller itself failed, which already called
        // [_DashcamProcessOwner.markUncertain] — that makes this release a
        // correct no-op (fail-closed, §14).
        _abandonInitializeBeforeNativeEmission();
        rethrow;
      }
      if (!initialized) {
        // Fase 16.2-R4.2B-R2 (§10/§11): granted admission, but
        // [_doInitializeController]'s own revalidation — checkpoints 4/5,
        // immediately before its actual native call — found this request
        // invalidated in the async gap between admission and emission (e.g.
        // [dispose], or the deadline itself, arriving exactly then). No
        // native call was made; release cleanly, same as the `abandoned`
        // case above (same §16 reasoning: nothing was ever assigned to
        // [_controller]).
        _abandonInitializeBeforeNativeEmission();
      }
    });
    _initializeFuture = future;
    // Fase 16.2-R4.2B-R1: `.whenComplete()` re-throws whatever error
    // `future` had to ITS OWN resulting Future — `unawaited()` alone is
    // just a lint marker, not an error handler, so without `.catchError`
    // here this would become a SECOND, unhandled async error on top of the
    // one `_boundedView` below already correctly delivers to this method's
    // own caller.
    unawaited(future.whenComplete(() => _initializeFuture = null).catchError((_) {}));
    return _boundedView(future, attempt, 'Camera initialization timed out');
  }

  /// Fase 16.2-R4.2B-R4 (§11/§12, independent review P1-B — "owner
  /// saudável retido após abandono"): the single, shared abandonment
  /// action used by every pre-emission checkpoint in [initialize]/
  /// [_doInitializeController]. [_DashcamProcessOwner.release] is already
  /// exactly the right safety gate on its own (a no-op unless
  /// [_processOwnerToken] is CURRENTLY, HEALTHILY the owner — see its own
  /// doc): whether this specific call never actually acquired (nothing to
  /// release), reentrantly already owned from an earlier, separate,
  /// successful [initialize] (this call's own [_doReleaseController] step
  /// has, by every point this is called from, unconditionally already run
  /// and left [_controller] `null` — proven once, here, rather than at each
  /// call site: [_doReleaseController] either succeeds and nulls
  /// [_controller] before this closure can reach ANY checkpoint, or throws
  /// and this closure rethrows immediately, never reaching a checkpoint at
  /// all — so every checkpoint that CAN call this always finds [_controller]
  /// already `null`, fresh or reentrant grant alike), or is uncertain
  /// (correctly, permanently, NOT released) — calling
  /// [_DashcamProcessOwner.release] unconditionally is always the right
  /// action. Exists only so every checkpoint expresses the exact same
  /// abandonment action identically, not because [release] itself needed
  /// wrapping — deliberately never clears [_DashcamProcessOwner._uncertain]
  /// (it cannot: [release] itself already refuses while uncertain) and
  /// deliberately never touches a token other than [_processOwnerToken].
  void _abandonInitializeBeforeNativeEmission() {
    _DashcamProcessOwner.release(_processOwnerToken);
  }

  /// Fase 16.2-R4.2B-R2 (§26/§30): the real, retained native [initialize]
  /// operation this instance currently has in flight, if any — unlike
  /// [initialize]'s own return value, this is NOT bounded by
  /// [initializeCameraTimeout]: it resolves only once the real native call
  /// truly settles, however long that takes (including never, for a
  /// genuinely stuck call — see [_doInitializeController]'s own doc).
  ///
  /// Exists so a caller whose own presentation wait already gave up (a
  /// thrown `StateError` from [initialize]) can still learn the REAL,
  /// eventual outcome later — `DashcamSessionController` is the intended
  /// consumer (see its own `_watchLateRecoveryInitialize` doc) — without
  /// creating a second native call or a second presentation-timeout view of
  /// its own: calling [initialize] again after its own deadline has already
  /// elapsed immediately re-throws (see [_boundedView]'s own doc), it does
  /// not "wait more". `null` whenever no [initialize] call is currently in
  /// flight. This is not a coordinator/ownership internal (§26 explicitly
  /// prohibits exposing the owner token or coordinator internals) — just
  /// this one operation's own completion signal, the same idea
  /// [_PendingNativeStop.visibleSignal] already establishes for STOP,
  /// exposed read-only ([Future] itself has no mutation surface).
  Future<void>? get pendingInitializeSettlement => _initializeFuture;

  /// Fase 16.2-R4.2B-R1: splits a real, retained operation ([raw] — never
  /// itself abandoned, see this class's own doc §3/§4) from the bounded
  /// view a PUBLIC caller actually waits on — [raw] keeps running to its
  /// own real completion regardless of whether the budget elapses first
  /// (`Future.timeout` never cancels the [Future] it wraps; it only stops
  /// THIS view from waiting on it further). On timeout, throws
  /// [StateError] with [timeoutMessage] — the same public contract
  /// [initialize] already had before this subfase, just no longer paid for
  /// by abandoning [raw].
  ///
  /// Fase 16.2-R4.2B-R4 (§7, independent review P1-A): [attempt] is the
  /// SAME [_InitializeAttempt] [preEmissionValid] (see [initialize]'s own
  /// doc) measures against — the remaining wait handed to `Future.timeout`
  /// here is derived from that SAME monotonic elapsed-time reading, never
  /// converted back through [DateTime]. This is what keeps this
  /// presentation view and the pre-native validity decision permanently in
  /// agreement, immune to civil-clock adjustment.
  ///
  /// Fase 16.2-R4.2B-R4 (intervention round): on a genuine timeout, marks
  /// [_InitializeAttempt.presentationExpired] BEFORE throwing — see
  /// [DashcamService._initializeAttempt]'s own doc for why this closes a
  /// real (causally-proven, not flaky) Timer/Stopwatch precision skew
  /// between this method's own `Future.timeout` and [preEmissionValid]'s
  /// plain [Stopwatch] comparison, as a purely conservative addition, never
  /// a replacement for it.
  Future<void> _boundedView(Future<void> raw, _InitializeAttempt attempt, String timeoutMessage) async {
    final remaining = initializeCameraTimeout - attempt.clock.elapsed;
    try {
      await raw.timeout(remaining.isNegative ? Duration.zero : remaining);
    } on TimeoutException {
      attempt.presentationExpired = true;
      throw StateError(timeoutMessage);
    }
  }

  /// The native-touching half of [initialize] — release the previous
  /// controller (if any; done by the caller, immediately before this) is
  /// assumed already complete by the time this runs. Builds and initializes
  /// a fresh [CameraController] and adopts it as [_controller].
  ///
  /// Fase 16.2-R4.2A: no longer waits out a bounded "quarantine" for a
  /// still-outstanding native stop before proceeding — that R1-era
  /// mechanism let a new camera generation open on top of an unresolved
  /// stop once the quarantine itself elapsed, which is exactly the
  /// ownership gap this subfase closes. This method needs no explicit wait
  /// at all now: [_enqueue] (this class's own doc, §1 bullet 1) already
  /// guarantees this method's own queued operation cannot get its turn until
  /// every earlier one — including a still-pending [_doFinalizeCurrentSegment]
  /// call for a stop that missed [stopVideoRecordingTimeout] — has itself
  /// fully returned. See [_PendingNativeStop]'s own doc for why that return
  /// is delayed until the *real* native result is known, not just the UI
  /// deadline.
  ///
  /// Fase 16.2-R4.2B-R1: no longer races `controller.initialize()` against
  /// [initializeCameraTimeout] internally — that presentation deadline is
  /// now applied OUTSIDE this method entirely, at [initialize]'s own call
  /// site (see [_boundedView]'s own doc). This method itself simply awaits
  /// the real native call for as long as it takes, mirroring
  /// [_doFinalizeCurrentSegment]'s own retention of a late
  /// `stopVideoRecording()` (this class's own doc, §1 bullet 3) — a missed
  /// deadline ends the CALLER's own wait, never this raw native call, never
  /// [_enqueue]'s own [_queueTail] barrier, and never
  /// [_DashcamProcessOwner]'s ownership of this instance.
  ///
  /// Fase 16.2-R4.2B-R2 (§10, independent review — "B entrou em
  /// _doInitializeController() com _disposed == true"): revalidates,
  /// immediately before the one real, backend-exclusive native call this
  /// method makes (`controller.initialize()`), that this operation is still
  /// wanted and still safe — not only once, earlier, before
  /// [_DashcamProcessOwner.acquire] was even called. [availableCameras] and
  /// constructing a bare [CameraController] object are not backend-exclusive
  /// (they don't touch `recording`/`pendingRecording`/[_controller] — see
  /// this class's own doc, §4), so revalidating only AFTER those, right
  /// before the one call that matters, is both correct and precise. Returns
  /// `false` (never throws) if that revalidation fails — a clean,
  /// no-native-call conclusion, exactly like a pre-admission abandonment
  /// (see [initialize]'s own doc) just discovered one native call's width
  /// later.
  ///
  /// Fase 16.2-R4.2B-R3 (§6/§11/§13, independent review — "availableCameras
  /// é um ponto de atraso"): [preEmissionValid] (this instance's own
  /// [initialize]-local intent check — see its own doc) is now consulted
  /// TWICE here: immediately after `availableCameras()` resolves (checkpoint
  /// 4 — a real discovery-latency point the reviewer identified, distinct
  /// from the coordinator-ownership check that already existed), and again,
  /// combined with the pre-existing `_disposed`/`isOwnedBy` checks, as the
  /// FINAL checkpoint (5) immediately before `controller.initialize()`
  /// itself — with no `await`/yield between that final check and the call.
  Future<bool> _doInitializeController(bool Function() preEmissionValid, int? lifecycleGeneration) async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available on this device');
    }
    // Checkpoint 4: availableCameras() is a real await boundary — the
    // reviewer's own concern — and must not be treated as if it were still
    // the same instant as the admission grant above.
    if (!preEmissionValid()) {
      return false;
    }

    final selected = _pickCamera(cameras);
    // Fase 16.2-R4.4-R1: read once — the values the controller is built with
    // are the ones its clips are named with ([_controllerResolution]).
    final resolution = _config.resolution;
    final audioEnabled = _config.audioEnabled;
    final controller = CameraController(
      selected,
      _resolutionPresetFor(resolution),
      enableAudio: audioEnabled,
      fps: _config.frameRate,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    // Checkpoint 5 (FINAL): everything that could possibly invalidate this
    // request — disposed, deadline, ownership, uncertain — checked together,
    // synchronously, immediately before the one real native call. No
    // `await`/yield follows this check other than `controller.initialize()`
    // itself.
    if (_disposed || !_DashcamProcessOwner.isOwnedBy(_processOwnerToken) || !preEmissionValid()) {
      // Fase 16.2-R4.2B-R2 (§10/§11): this exact controller was never
      // handed to any real caller (it only exists as a local variable here)
      // and has not yet been natively initialized — best-effort dispose it
      // (releasing whatever local platform resources its bare construction
      // may have reserved) and conclude without ever calling
      // `controller.initialize()`.
      try {
        await controller.dispose();
      } catch (_) {
        _DashcamProcessOwner.markUncertain(_processOwnerToken);
      }
      return false;
    }
    try {
      await controller.initialize();
    } catch (_) {
      // Fase 16.2-R4.2B-R1 (§15): the just-constructed controller never
      // became usable — it must not become [_controller] (nothing could
      // ever record on it) — and per §15's own required flow, a
      // best-effort cleanup of it is attempted before this instance's own
      // caller (see [initialize]'s own catch) decides whether process
      // ownership is still safe to give up.
      try {
        await controller.dispose();
      } catch (_) {
        // Fase 16.2-R4.2B-R1 (§14/§15): the cleanup itself failed — fail
        // closed. [initialize]'s own catch releases ownership only when
        // this method's own failure did NOT also mark it uncertain, so
        // this is what makes that release correctly a no-op here.
        _DashcamProcessOwner.markUncertain(_processOwnerToken);
      }
      rethrow;
    }
    _controller = controller;
    _controllerResolution = resolution;
    _controllerAudioEnabled = audioEnabled;
    _currentControllerGeneration = lifecycleGeneration;
    _lastKnownHasError = controller.value.hasError;
    controller.addListener(_onControllerValueChanged);
    // A fresh controller just initialized successfully — whatever camera
    // was known-unavailable before (if any) is no longer this controller's
    // problem. See _cameraKnownUnavailable's own doc. Fase 16.2-R4.2A-R5:
    // deliberately does NOT also reset _discoveryUncertainCount here anymore
    // (an R4-era version did) — that counter's own lifecycle is now tied to
    // each individual caller's own real obligation resolving (see
    // _armDiscoveryUncertainty's own doc), not to camera-generation success;
    // forcing a reset here risked clearing a genuinely still-pending, newer
    // caller's own uncertainty out from under it.
    _cameraKnownUnavailable = false;
    return true;
  }

  /// Edge-triggered: only reports a *new* transition into the error state
  /// (e.g. the hardware being taken by another app mid-recording — an
  /// asynchronous camera-lost error the plugin reports this way, not
  /// something a `try`/`catch` around a single call would ever see), not
  /// every listener tick while already in one. Only ever attached to the
  /// controller currently held in [_controller], and always removed (see
  /// [_doReleaseController]) before that controller is disposed — a stale
  /// controller can never reach this callback (Fase 16.2-R1 audit).
  void _onControllerValueChanged() {
    final controller = _controller;
    if (controller == null) return;
    final hasError = controller.value.hasError;
    if (hasError && !_lastKnownHasError) {
      // Fase 16.2-R4.3-R2 (§45): concerns THIS specific controller's own
      // health — lifecycleCamera, tagged with both its identity and the
      // generation it was created under (read together, atomically, with
      // [controller] itself here — see this method's own doc for why
      // `controller == _controller` is guaranteed at this exact point).
      _reportError(
        controller.value.errorDescription ?? 'Erro desconhecido da câmera',
        scope: DashcamServiceErrorScope.lifecycleCamera,
        origin: controller,
        generation: _currentControllerGeneration,
      );
    }
    _lastKnownHasError = hasError;
  }

  CameraDescription _pickCamera(List<CameraDescription> cameras) {
    final direction = switch (_config.cameraSelection) {
      CameraSelection.front => CameraLensDirection.front,
      CameraSelection.rear => CameraLensDirection.back,
      // "both" is not supported by a single CameraController; default to
      // the rear camera until dual-camera capture is implemented.
      CameraSelection.both => CameraLensDirection.back,
    };
    return cameras.firstWhere(
      (camera) => camera.lensDirection == direction,
      orElse: () => cameras.first,
    );
  }

  ResolutionPreset _resolutionPresetFor(VideoResolution resolution) {
    return switch (resolution) {
      VideoResolution.sd480 => ResolutionPreset.medium,
      VideoResolution.hd720 => ResolutionPreset.high,
      VideoResolution.fhd1080 => ResolutionPreset.veryHigh,
      VideoResolution.uhd4k => ResolutionPreset.ultraHigh,
    };
  }

  // ===========================================================================
  // startLoopRecording() / stopLoopRecording()
  // ===========================================================================

  /// Starts continuous loop recording: a new video segment is started every
  /// [segmentDuration], the previous one is finalized to disk, and storage
  /// quota is enforced after each rotation.
  ///
  /// Fase 16.2-R4.2A-R1 (P2-C fix): rejects immediately, the same way
  /// [initialize] already did, once [dispose] has been called — checked
  /// synchronously, before [_isRecording]/any [Timer]/the queue/the
  /// [CameraController] are touched at all, so a call issued right after a
  /// visible `dispose()` can never resurrect recording intent on a service
  /// that is already terminal (see [_disposed]'s own doc).
  ///
  /// Fase 16.2-R4.2B-R1: [startVideoRecordingTimeout] is now a pure
  /// PRESENTATION deadline on top of a retained native call — see
  /// [_doStartLoopRecording]/[_startVideoRecordingWithTimeout]'s own docs.
  /// This method's own public contract is otherwise unchanged: still
  /// resolves without throwing on a presentation-timeout (matching the
  /// pre-existing [_isRecording]-flips-false-silently behavior), still
  /// throws for a fast, within-deadline native failure.
  /// Fase 16.2-R4.3-R1 (§29/§31, D0-approved lifecycle-generation
  /// architecture): [semanticStillValid], if given, is consulted once, at
  /// this call's own pre-native checkpoint (inside [_doStartLoopRecording],
  /// immediately before the real native `startVideoRecording()` call) — the
  /// exact same "AND-composed, never a replacement" pattern [initialize]'s
  /// own `semanticStillValid` uses (see its own doc). `null` (the default)
  /// means "always still valid" and changes nothing for any caller that
  /// does not pass it — including every direct/test caller of this class.
  ///
  /// Fase 16.2-R4.3-R2.5 (§22-§25/§31-§34, independent-review P1-1):
  /// [clipOwnerToken], if given, is an OPAQUE, immutable provenance token this
  /// class carries with the Recording this call produces and stamps onto every
  /// clip that Recording yields ([DashcamClip.producerToken]) — decided HERE,
  /// where the clip is born, not by whichever consumer later observes it first.
  /// This class attaches no meaning to it (in particular it does not know what
  /// a "session" is): `DashcamSessionController` passes its logical-session id,
  /// the SAME value across every lifecycle generation, segment rotation,
  /// recovery and camera switch of one logical session — a lifecycle
  /// generation is not a provenance. `null` (the default) means UNKNOWN
  /// provenance and changes nothing for a caller that does not pass it; every
  /// clip that Recording yields is then stamped `null`, which consumers must
  /// not adopt.
  Future<void> startLoopRecording({bool Function()? semanticStillValid, Object? clipOwnerToken}) {
    return beginStartLoopRecording(semanticStillValid: semanticStillValid, clipOwnerToken: clipOwnerToken).presentation;
  }

  /// Fase 16.2-R4.3-R2.6.18: the whole of [startLoopRecording], unchanged in
  /// every observable respect — which is why [startLoopRecording] stays the
  /// surface for a caller that only wants the Future — but also handing back,
  /// synchronously, the identity of the START this call was accepted as
  /// ([DashcamStartOutcome.attempt]). A caller that may later have to clean up
  /// what THIS START did ([beginStopLoopRecording] with `startAttempt`) must
  /// take that identity here, where the START is born: at cleanup time the
  /// service's "current" camera, Recording and intent may already be a later
  /// START's, and nothing read then can tell the two apart.
  DashcamStartOutcome beginStartLoopRecording({bool Function()? semanticStillValid, Object? clipOwnerToken}) {
    if (_disposed) {
      throw StateError('DashcamService.startLoopRecording() called after dispose()');
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('DashcamService.initialize() must complete first');
    }
    // An absorbed call is no START of its own: no epoch, no attempt.
    if (_isRecording) return DashcamStartOutcome(presentation: Future<void>.value(), attempt: null);

    // Fase 16.2-R4.3-R2 (§41): read atomically alongside [controller] —
    // both describe the SAME controller instance, at the SAME instant — so
    // a late START failure reported for [controller] (which may no longer
    // be [_controller] by the time that failure actually arrives) still
    // tags the GENERATION it was really created under, never whatever a
    // later, different controller's own [_currentControllerGeneration]
    // happens to read as by then.
    final controllerGeneration = _currentControllerGeneration;

    // Synchronous intent prefix — see this class's own doc, §1.
    _isRecording = true;
    _withdrawSegmentEvidence(DashcamSegmentPresentation.startPending);
    // Fase 16.2-R4.3-R2.5: a new START intent — any stop intent created from
    // here on concerns the Recording THIS start produces, not one created
    // before it (see [_StopIntent.startEpoch]).
    _startIntentEpoch++;
    // Fase 16.2-R4.3-R2.6.16: this START's own identity — read HERE, where the
    // intent is admitted, and carried by the operation queued below. What that
    // operation finds in [_startIntentEpoch] when its turn finally comes may
    // already be a later START's; this is how it still knows which one it was.
    final startEpoch = _startIntentEpoch;
    _segmentStartedAt = DateTime.now();
    final uiSignal = Completer<void>();
    // Fase 16.2-R4.2B-R1: mirrors [_PendingNativeStop]'s own identical
    // safety catch — this completer must never become an unhandled async
    // error just because nothing else ends up observing it (e.g. this
    // exact public [Future] is itself never awaited by its own caller).
    unawaited(uiSignal.future.catchError((_) {}));
    final queued = _enqueue(() => _doStartLoopRecording(controller, controllerGeneration, uiSignal, semanticStillValid, clipOwnerToken, startEpoch));
    // The real outcome is already fully delivered via [uiSignal] (a fast,
    // within-deadline result) or [errors] (a late one, reported inside
    // [_startVideoRecordingWithTimeout] itself) — [_doStartLoopRecording]
    // itself never throws (see its own doc), so this exists only as a
    // defensive backstop, not an expected path.
    unawaited(queued.then((_) {}, onError: (_) {}));
    return DashcamStartOutcome(presentation: uiSignal.future, attempt: DashcamStartAttempt._(startEpoch, controller));
  }

  /// Fase 16.2-R1 (independent review, P1-4 "start nativo tardio"): [controller]
  /// is the specific instance this call was requested for — captured by the
  /// caller *before* enqueueing, not re-read from [_controller] here, so a
  /// concurrent [initialize] that replaces [_controller] while this was
  /// waiting its turn in the queue is detected below rather than silently
  /// operating on the wrong generation.
  ///
  /// Fase 16.2-R4.2B-R1: [uiSignal] is this call's own presentation-facing
  /// signal (this class's own doc, §3/§4) — completed by
  /// [_startVideoRecordingWithTimeout] the instant either the real result
  /// is known within [startVideoRecordingTimeout], or that deadline itself
  /// elapses, whichever is first. This method itself never throws past
  /// [uiSignal] — a fast native failure is delivered THROUGH it (matching
  /// [startLoopRecording]'s pre-existing public contract of throwing to its
  /// direct caller), not re-thrown from here, since nothing else still
  /// needs to observe it once that delivery has happened.
  ///
  /// Fase 16.2-R4.3-R2.6.16 — START intent ownership. [startEpoch] is the
  /// identity this START was admitted with ([startLoopRecording]). Every guard
  /// here used to ask the service's CURRENT state, and `_isRecording` answers
  /// "does anyone want recording", not "does the intent that queued me still
  /// stand": after a logical stop and a new START it is `true` again, on
  /// behalf of that new START. The independent review of R2.6.15
  /// (P2-START-QUEUE) reproduced the consequence through the public API, on
  /// every version back to R2.6.13: START A waits in the queue behind a
  /// pending native stop; A is stopped (that stop adopts the pending one, so
  /// nothing of its own is queued behind A); START B is accepted; A reaches
  /// the front, sees B's intent, and emits the native START as A. B then
  /// fails against a camera already recording, and the service is left
  /// reporting "not recording" over an active Recording that the next
  /// `stopLoopRecording()` does not stop.
  ///
  /// A START therefore acts only while it is still the latest START intent
  /// ([_isLatestStartIntent]), checked from the state as it is at each point:
  ///  * when its turn in the queue comes — a superseded START is inert: no
  ///    native call, no Recording, no timer, no flag touched, and its Future
  ///    resolves without error exactly as it already did for a START
  ///    superseded by a stop alone. It is the LAST thing checked there: nothing
  ///    awaits, and no caller code runs, between it and the native call
  ///    ([_startVideoRecordingWithTimeout]'s first statement), so this is the
  ///    check "at the front of the queue" and the check "immediately before
  ///    the native START" in one;
  ///  * when its turn comes and it is inert for another reason while its own
  ///    intent still stands (its controller is gone, or its caller's context
  ///    is no longer current): it takes that intent down itself, so the
  ///    service does not go on reporting "recording" — and absorbing the next
  ///    START — on behalf of a START that did nothing;
  ///  * wherever it would clear [_isRecording] for a failure or a deadline of
  ///    its own — that flag may by then belong to the START that superseded
  ///    it while its native call was in flight;
  ///  * after the native call returned, before it arms the segment timer.
  ///
  /// A START superseded only AFTER its native call was issued cannot be made
  /// "never to have happened": the Recording exists and stays tracked (as it
  /// always did), and whoever superseded it normally has its own stop or
  /// teardown queued behind this operation. The one case where nobody has —
  /// see the end of [_settleStartAttempt] — is cleaned up there, by the START
  /// that created that Recording, and only that Recording.
  ///
  /// Fase 16.2-R4.3-R2.6.17: the checks made when this START's turn comes stay
  /// here; everything from the native call on — the physical attempt — is
  /// [_settleStartAttempt], which this method runs to its real end.
  Future<void> _doStartLoopRecording(
    CameraController controller,
    int? controllerGeneration,
    Completer<void> uiSignal,
    bool Function()? semanticStillValid,
    Object? clipOwnerToken,
    int startEpoch,
  ) async {
    if (!_isRecording || !identical(_controller, controller) || (semanticStillValid != null && !semanticStillValid())) {
      // Superseded before this even got its turn in the queue — a
      // stopLoopRecording()/dispose()/releaseIdleCamera()/re-initialize()'s
      // own synchronous intent prefix (see this class's own doc) already
      // changed its mind, OR (Fase 16.2-R4.3-R1 §29) the caller's own
      // lifecycle context is no longer current. Zero native START emitted
      // either way — see [startLoopRecording]'s own doc.
      //
      // Fase 16.2-R4.3-R2.6.16: an inert START must not leave its own intent
      // published either. When `_isRecording` still stands here, no stop made
      // this START inert — its controller is gone, or its caller's context is
      // — and when this is still the latest START, the flag is the one THIS
      // START raised on being admitted. Nothing else would ever take it down:
      // the service went on reporting "recording" with nothing recording, and
      // the next `startLoopRecording()` was absorbed by it and did nothing.
      // (A flag that belongs to a LATER START is left alone: that START is
      // queued behind this one and decides for itself.)
      if (_isRecording && _isLatestStartIntent(startEpoch)) {
        _noteStart(_StartFate.ownIntentRetracted);
        _isRecording = false;
      }
      uiSignal.complete();
      return;
    }
    if (!_isLatestStartIntent(startEpoch)) {
      // Fase 16.2-R4.3-R2.6.16: a later START was accepted while this one
      // waited. Checked on its own, because the condition above cannot see it
      // (`_isRecording` is `true` again, on behalf of that later START), and
      // checked LAST: from here to the native call nothing awaits and no
      // caller code runs ([semanticStillValid] just did).
      _noteStart(_StartFate.supersededBeforeEmission);
      uiSignal.complete();
      return;
    }
    // Fase 16.2-R4.3-R2.6.17: from here on this is a PHYSICAL attempt — the
    // native call is issued by the first statement of [_settleStartAttempt],
    // with no `await` in between. [startAttemptSettling] says so until that
    // attempt has really finished, whatever its caller was told meanwhile.
    _startAttemptSettling = true;
    try {
      await _settleStartAttempt(controller, controllerGeneration, uiSignal, semanticStillValid, clipOwnerToken, startEpoch);
    } finally {
      _startAttemptSettling = false;
    }
  }

  /// Fase 16.2-R4.3-R2.6.17 — START attempt settlement authority. The physical
  /// half of [_doStartLoopRecording]: the native START of the attempt admitted
  /// as [startEpoch] on [controller], and everything that attempt owes
  /// afterwards. It runs as (part of) one queued operation, so the queue — the
  /// physical barrier — is held from the native call until this returns.
  ///
  /// Five things that are NOT the same event, and where each one lives:
  ///  * the logical intent — [_isRecording] plus the epoch; taken down by a
  ///    stop, a release, a dispose, a re-initialize, or by this attempt's own
  ///    deadline or failure;
  ///  * the physical attempt — this method;
  ///  * the logical result for the caller — [uiSignal], completed by the real
  ///    result when it comes within [startVideoRecordingTimeout], and otherwise
  ///    AT that deadline (quietly, as before: `isRecording == false`,
  ///    `cameraKnownUnavailable == true`);
  ///  * the physical settlement — `controller.startVideoRecording()` actually
  ///    returning, which a deadline never cancels and which may come later;
  ///  * the physical cleanup — the native stop of the Recording that
  ///    settlement created, when by then nobody wants it.
  /// The caller's Future ending does not end the attempt: the attempt ends when
  /// the settlement AND the cleanup it owes, if it owes one, have completed.
  /// Until the independent review of R2.6.16 (P2-B) the cleanup was skipped
  /// whenever the attempt's own deadline had elapsed, which is exactly when it
  /// matters most: the native START returned late and successfully, the
  /// Recording stayed on the camera with `isRecording == false`, the START
  /// queued behind it failed against a camera already recording, and no
  /// `stopLoopRecording()` could reach it any more — only a teardown.
  Future<void> _settleStartAttempt(
    CameraController controller,
    int? controllerGeneration,
    Completer<void> uiSignal,
    bool Function()? semanticStillValid,
    Object? clipOwnerToken,
    int startEpoch,
  ) async {
    bool started;
    try {
      started = await _startVideoRecordingWithTimeout(
        controller,
        controllerGeneration,
        onPresentationDeadline: () {
          // Fase 16.2-R4.2B-R1: synchronous, at the exact instant the
          // deadline fires (mirroring _doFinalizeCurrentSegment's own
          // pending.completeVisibleSignal() timing) — not after any further
          // await, so a caller unblocked by [uiSignal] observes
          // [_isRecording] already correctly false, exactly as it does
          // today for a fast native failure.
          // Fase 16.2-R4.3-R2.6.16: ...unless a later START superseded this
          // one while its native call was in flight — the flag is then that
          // START's, not this one's to clear.
          // Fase 16.2-R4.3-R2.6.17: this ends the LOGICAL side of the attempt
          // only. The native call is still in flight, this operation keeps the
          // queue, and what the call produces when it finally returns is still
          // this attempt's to clean up (see the end of this method).
          if (identical(_controller, controller) && _isLatestStartIntent(startEpoch)) _isRecording = false;
          uiSignal.complete();
        },
      );
    } catch (error, stack) {
      // Fase 16.2-R1: a genuine (non-timeout) native failure — e.g. the
      // platform itself rejecting the start because it already considers a
      // recording active (§18 scenario C) — must not leave _isRecording
      // stuck true forever; no recording actually started. Only touches it
      // if this is still the current generation (see this class's own doc).
      // Fase 16.2-R4.3-R2.6.16: and only if this START is still the latest
      // one — a START superseded while in flight used to clear the flag of
      // the START queued behind it, which then resolved without error and
      // without ever recording.
      if (identical(_controller, controller) && _isLatestStartIntent(startEpoch)) _isRecording = false;
      // Fase 16.2-R4.2B-R1: delivered via [uiSignal] (this call's own
      // direct caller) instead of a `rethrow` — this class's own single
      // observer of a fast start failure remains exactly that one caller,
      // matching [stopLoopRecording]'s own established error contract
      // (Fase 16.2-R4.2A-R6 §21) rather than duplicating it via [errors].
      if (!uiSignal.isCompleted) uiSignal.completeError(error, stack);
      return;
    }
    if (!uiSignal.isCompleted) uiSignal.complete();
    if (!started) {
      // Fase 16.2-R4.2B-R1: only reachable via a LATE native failure inside
      // [_startVideoRecordingWithTimeout] (already reported via [errors]
      // there) — a presentation-timeout alone no longer reaches here at
      // all: this method keeps awaiting the real result regardless (this
      // class's own doc, §3/§4), so by the time control returns here,
      // [started] reflects the real, final outcome, not a mere deadline.
      // (Fase 16.2-R4.3-R2.6.16: same ownership rule as the catch above.)
      if (identical(_controller, controller) && _isLatestStartIntent(startEpoch)) _isRecording = false;
      return;
    }
    // Fase 16.2-R4.2A-R6 (§4/§5), doc corrected R4.2A-R7 (§24): `started`
    // above is a Dart/plugin-contract signal (startVideoRecording()'s own
    // Future resolved), not an instantaneous physical confirmation of
    // capture — but it is what this class has to work with, and a new
    // Recording identity is assigned on it regardless of whether this call
    // turns out to be superseded below. That check only
    // decides whether THIS method creates the segment Timer for it; the
    // Recording itself already exists either way, and whatever superseded
    // caller's own already-enqueued finalize (see the comment just below)
    // needs this identity in place before it runs, so a stop attempt against
    // this exact Recording can later be recognized as terminally failed if
    // it is. Guarded by `identical` for the same reason every other write
    // here is: a resolution arriving for a controller that is no longer
    // [_controller] at all must not touch this service's current identity
    // (that orphaned controller's own detached stop, below, is intentionally
    // outside this protocol's scope — see [_detachNativeOperation]'s own
    // doc).
    if (identical(_controller, controller)) {
      _activeRecordingId = ++_nextRecordingId;
      // Fase 16.2-R4.3-R2.5 (§23): the producer token is bound to the
      // Recording's identity in the SAME synchronous step that creates it —
      // never a separate, later assignment a stop could observe half-done.
      _activeRecordingToken = clipOwnerToken;
      // Fase 16.2-R4.3-R2.6.17: and so is the epoch of the START that created
      // it — THIS attempt's own, even when a later START has been accepted
      // since (see [_activeRecordingStartEpoch]).
      _activeRecordingStartEpoch = startEpoch;
    }
    // Fase 16.2-R4.3-R2 (§24/§25, independent-review P2-A fix — "START
    // stale cria _segmentTimer antes do cleanup"): the semantic predicate is
    // re-consulted HERE, after the raw native START has already, genuinely
    // succeeded — R4.3-R1 only ever checked it BEFORE emitting the call
    // (line ~1922 above), leaving a real window open: a lifecycle
    // transition landing WHILE this native call was in flight left the
    // Recording tracked (correctly — the raw call is never cancelled, see
    // this class's own doc) but still armed a live [_segmentTimer] for a
    // generation nobody wants anymore. Composed here via OR alongside this
    // class's own pre-existing `_isRecording`/`identical` staleness checks
    // — never a replacement for them — so a caller that never passes
    // [semanticStillValid] (every direct/test caller) sees zero behavior
    // change.
    //
    // Fase 16.2-R4.3-R2.6.16: ...and so is this START's own identity. A later
    // START accepted while this native call was in flight leaves `_isRecording`
    // `true`, so the checks above did not see it: this START went on to arm a
    // segment timer of its own, next to the one the later START armed — two
    // timers for one recording, and one of them never cancelled again.
    // (Last in the condition on purpose: [semanticStillValid] is consulted
    // exactly when it was before, and this reads the state as that call left
    // it.)
    if (!_isRecording || !identical(_controller, controller) || (semanticStillValid != null && !semanticStillValid()) || !_isLatestStartIntent(startEpoch)) {
      final supersededByNewerStart = !_isLatestStartIntent(startEpoch);
      if (supersededByNewerStart) _noteStart(_StartFate.supersededAfterEmission);
      // Fase 16.2-R1 (P1-4's exact scenario): the native start call itself
      // was in flight long enough for a stop/dispose/re-initialize's
      // synchronous prefix to fire in the meantime (the queue serializes
      // *queued* work, not these intent flags — see class doc). The
      // recording genuinely started on [controller], but nobody wants it
      // anymore: do NOT create a Timer for it (that would be the orphaned-
      // timer bug the review found) and do NOT report it as ours.
      //
      // Fase 16.2-R4.3-R2 (§25): a PURELY semantic staleness (this class's
      // own `_isRecording`/`identical` checks both still hold — only
      // [semanticStillValid] says no) leaves [controller] untouched here —
      // it is still genuinely [_controller], still genuinely recording, and
      // stays that way (Recording continues tracked, per this class's own
      // "raw emitted, never cancelled" contract). A generic detached stop
      // in that specific case would risk racing whichever TARGETED cleanup
      // the caller's own authorized flow is about to issue (see
      // [stopLoopRecording]'s own `expectedRecordingId`/`expectedController`
      // doc) — that targeted call, not this method, owns concluding it.
      if (!identical(_controller, controller)) {
        // [controller] is no longer even [_controller] — a dispose or
        // re-initialize happened, not just a stop, so whatever operation
        // superseded us was working with a different controller (or none).
        // Nothing else is ever going to stop this specific orphaned
        // instance: this is the one case that genuinely needs a direct,
        // best-effort cleanup call, detached the same way a timed-out call
        // is (see _detachNativeOperation's own doc).
        unawaited(_detachNativeOperation(controller.stopVideoRecording()));
      }
      // If [controller] is still [_controller], whatever flipped
      // _isRecording (stopLoopRecording()'s own synchronous prefix) has
      // already enqueued its own finalize operation, which will find
      // `isRecordingVideo == true` (this native start just succeeded) and
      // stop it properly, serialized through the queue. Calling
      // stopVideoRecording() here too — a real gap a test caught — would
      // race that already-queued call *outside* the queue's own protection,
      // the exact class of bug this whole section exists to close.
      //
      // Fase 16.2-R4.3-R2.6.16 — the one case where that is not so. The intent
      // behind this START was WITHDRAWN while its native call was in flight
      // (`_isRecording` cleared; a later START may have been accepted since,
      // which needs exactly that), and yet NOTHING in the queue will stop the
      // Recording that has just begun: whatever withdrew the intent queued no
      // stop able to reach it. Left alone, the new Recording has no owner:
      // this service reports "not recording" over it, the next
      // `stopLoopRecording()` stops nothing, and a later START fails against a
      // camera already recording. So the START that created it finalizes it,
      // HERE: inside this queued operation (nothing can run in between, unlike
      // the detached call warned about just above), and that one Recording
      // only — nothing else has started on this controller since.
      //
      // Not when a queued stop or teardown already owns it (it keeps its own
      // result and handle). Not for a purely semantic staleness (the intent
      // still stands; see above — the caller's own targeted cleanup concludes
      // it).
      //
      // Fase 16.2-R4.3-R2.6.17 (P2-B): R2.6.16 also made an exception for a
      // START whose own deadline had elapsed, and that exception is gone. It is
      // the main way to get here now: the deadline takes this attempt's intent
      // down by itself, with nothing queued behind it, and the native call may
      // still succeed afterwards. The late Recording is then stopped by the
      // attempt that created it, the queue is released only once that stop has
      // settled, and whatever waits behind — a later START included — finds the
      // camera free. (The other way R2.6.16 knew — a cleanup aimed at the
      // previous Recording withdrawing this START — no longer happens: see
      // [beginStopLoopRecording].) A late success is NOT turned into a
      // recording: the caller was already told this START did not make it.
      final intentWithdrawn = !_isRecording || supersededByNewerStart;
      if (intentWithdrawn && identical(_controller, controller) && !_hasQueuedStopFor(controller, _activeRecordingId, startEpoch)) {
        _noteStart(_StartFate.ownRecordingFinalized);
        try {
          await _doFinalizeCurrentSegment(reason: _FinalizeReason.explicitStop);
        } catch (error) {
          // A fast native/processing failure: with no `uiSignal`
          // [_doFinalizeCurrentSegment] rethrows (see its own doc), and
          // nothing is listening on this operation's Future.
          _reportError('Falha ao finalizar a gravação de um início superado: $error', scope: DashcamServiceErrorScope.recordingResult);
        }
      }
      return;
    }
    // Fase 16.2-R4.3-R2.6.15: the timer is armed FOR this run and says so —
    // the identity is read here, in the same synchronous step as the checks
    // just above (so it is exactly the run they found current), and every
    // tick carries it instead of looking up "whoever is recording" when it
    // eventually runs. See [_RotationRun].
    final run = _RotationRun(startEpoch: _startIntentEpoch, controller: controller);
    _segmentTimer = Timer.periodic(segmentDuration, (_) => _onRotationTick(run));
    segmentTimerArmedHookForTest?.call(() => _onRotationTick(run));
    _adoptSegmentEvidence();
  }

  /// Fase 16.2-R4.3-R2.6.15: an OPTIONAL test seam, called once each time a
  /// segment timer is armed, with a closure that delivers one tick of THAT
  /// timer — exactly what the timer itself calls. A Dart [Timer] never fires
  /// after `cancel()`, so this is the only way a test can deliver a tick of a
  /// run that has since ended and prove it is refused ([_onRotationTick]).
  /// `null` (the default) means zero behavior change.
  @visibleForTesting
  void Function(void Function() deliverTick)? segmentTimerArmedHookForTest;

  /// Calls `controller.startVideoRecording()` with [startVideoRecordingTimeout]
  /// applied as a PURE PRESENTATION deadline (this class's own doc, §3/§4)
  /// — never a cancellation. Returns `true` only if the recording
  /// genuinely, natively started (whether within the deadline or, per Fase
  /// 16.2-R4.2B-R1 below, discovered later).
  ///
  /// Fase 16.2-R4.1A: `enablePersistentRecording` explicitly `false` (the
  /// `camera` package's own default is `true`). Fase 16.2 R2 physically
  /// confirmed a persistent recording left `camera_android_camerax
  /// 0.7.4+2`'s internal `recording`/`pendingRecording` fields non-null
  /// after backgrounding, and that version's own `dispose()` never cleared
  /// them — the confirmed false-recording root cause. `0.7.4+8`'s
  /// `dispose()` does clear those fields, but that only proves the
  /// Dart-side reference is gone, not that the underlying native
  /// `Recording` had already finalized at that instant. This flag targets
  /// that separately: in the background scenarios physically reproduced in
  /// Fase 16.2 R3-C, a non-persistent recording was observed to
  /// auto-finalize natively (`VideoRecordEvent.Finalize`,
  /// `ERROR_SOURCE_INACTIVE`) once CameraX's own lifecycle binding marked
  /// the camera source `INACTIVE` — an experimental observation from those
  /// preserved runs, not a guaranteed time bound or a claim that every
  /// lifecycle transition behaves identically.
  ///
  /// Fase 16.2-R4.2B-R1: no longer detaches [rawFuture] on timeout — mirrors
  /// [_doFinalizeCurrentSegment]'s own retention of a late
  /// `stopVideoRecording()` (this class's own doc, §1 bullet 3, extended to
  /// `startVideoRecording()` by bullet 4). [onPresentationDeadline], if
  /// given, is invoked synchronously the instant the deadline fires — before
  /// this method continues to actually retain and await [rawFuture] — so a
  /// caller-specific side effect (e.g. [_doStartLoopRecording]'s own
  /// [_isRecording] flip and `uiSignal` completion) happens at exactly the
  /// same instant [_cameraKnownUnavailable] does here, not after some
  /// further, unbounded wait. Shared by [_doStartLoopRecording] (the
  /// initial start, which passes one) and [_doRotateSegment]'s own restart
  /// (which, since Fase 16.2-R4.3-R2.6.20, passes one only to learn that its
  /// deadline elapsed — nothing external is waiting on that one's own
  /// presentation timing).
  ///
  /// Fase 16.2-R4.3-R2.6.20: [rotationRestart] says which of those two callers
  /// this is, because the deadline does not MEAN the same for both — the
  /// distinction [_markDeadlineExceeded] already makes for a stop. For a START
  /// of [startLoopRecording] (the default) nothing changed: this camera
  /// generation is not to be trusted for a new native call
  /// ([_cameraKnownUnavailable], until a fresh [initialize]) and that START's
  /// own callback ends its logical side. For the restart of a rotation the
  /// overrun only marks the operation as slow ([_rotationRestartOverdue]);
  /// [_doRotateSegment] decides when the raw call really settles. Everything
  /// else — the raw call is never cancelled, a late failure is reported here —
  /// is the same for both.
  Future<bool> _startVideoRecordingWithTimeout(
    CameraController controller,
    int? controllerGeneration, {
    void Function()? onPresentationDeadline,
    bool rotationRestart = false,
  }) async {
    final rawFuture = controller.startVideoRecording(enablePersistentRecording: false);
    final deadlineInstant = DateTime.now().add(startVideoRecordingTimeout);
    try {
      await rawFuture.timeout(_remainingUntil(deadlineInstant));
      return true;
    } on TimeoutException {
      if (rotationRestart) {
        _rotationRestartOverdue = true;
      } else {
        _cameraKnownUnavailable = true;
      }
      onPresentationDeadline?.call();
      try {
        return await rawFuture.then((_) => true);
      } catch (error) {
        // Fase 16.2-R4.2B-R1: a late native failure, past the point any
        // direct caller (delivered via [onPresentationDeadline]'s own
        // signal, if any) is still listening — reported instead of left as
        // an unhandled async error, matching [_doFinalizeCurrentSegment]'s
        // own identical, established contract for a late STOP failure.
        // Fase 16.2-R4.3-R2 (§45): concerns [controller]'s own acquisition
        // health — lifecycleCamera, tagged with the generation it was
        // created under (captured by the caller, see [startLoopRecording]/
        // [_doRotateSegment]'s own docs — never re-read fresh here, which
        // could by now belong to a different controller entirely).
        _reportError(
          'Início nativo da gravação falhou após o prazo de resposta: $error',
          scope: DashcamServiceErrorScope.lifecycleCamera,
          origin: controller,
          generation: controllerGeneration,
        );
        return false;
      }
    }
  }

  /// Fase 16.2-R4.2A: the returned [Future] resolves no later than
  /// [stopVideoRecordingTimeout] after this call — it is bounded by the same
  /// UI-response deadline as the native call itself (see
  /// [_doFinalizeCurrentSegment]'s own doc), NOT by how long the real
  /// native `stopVideoRecording()` actually takes. This is deliberate:
  /// `DrivingSessionRecorder`/`DashcamSessionController` must be able to end
  /// a driving session without blocking indefinitely on CameraX (this
  /// class's own doc, §1 bullet 3).
  ///
  /// Deliberately NOT implemented as this call racing its own, second
  /// `.timeout(stopVideoRecordingTimeout)` against [_doFinalizeCurrentSegment]'s
  /// own identically-configured internal one: two independent `Timer`s of
  /// the same [Duration] give no ordering guarantee over which fires first,
  /// so a caller could regain control *before* [_doFinalizeCurrentSegment]
  /// has actually set [_cameraKnownUnavailable] — observed directly while
  /// writing Fase 16.2-R4.2A's own tests. Instead, the [Completer] below
  /// becomes the resulting [_PendingNativeStop]'s own
  /// [_PendingNativeStop.visibleSignal], completed by
  /// [_doFinalizeCurrentSegment] itself, synchronously immediately after it
  /// updates [_cameraKnownUnavailable] (or, on the fast path, only once a
  /// clip has actually been recorded) — a single source of truth for "the
  /// caller may proceed now", not a second timer racing the first.
  ///
  /// Fase 16.2-R4.2A-R1 (P1-A fix): if a native stop for the current
  /// segment is *already* in flight when this is called — most commonly
  /// because a segment rotation's own tick already issued one (see
  /// [_doRotateSegment]) — this does NOT enqueue a second
  /// [_doFinalizeCurrentSegment] call behind it. Doing so was the exact bug
  /// an independent review found: the new call's own `uiSignal` would only
  /// ever be completed once its turn in [_queueTail] arrived, which cannot
  /// happen before the existing pending stop's own queued operation first
  /// returns — meaning the caller could block for as long as that stop
  /// took, unbounded, defeating the whole point of a UI deadline. Instead,
  /// this attaches directly to the *existing* [_PendingNativeStop]'s own
  /// [_PendingNativeStop.visibleSignal] (this class's own doc, §1 bullet 3,
  /// and [_PendingNativeStop]'s own doc): a stop's deadline belongs to the
  /// operation, not to whichever caller happens to be listening when it
  /// started.
  ///
  /// The [_enqueue]d operation underneath a freshly-issued stop is NOT
  /// affected by its own `uiSignal`'s completion — it keeps running, and
  /// keeps [_queueTail] blocked, until the real native result is known; any
  /// error it hits after `uiSignal` has already completed is reported via
  /// [errors], not delivered here (nothing is listening on the queued
  /// operation's own Future by then).
  ///
  /// Fase 16.2-R4.2A-R5 (§1/§6/§7/§8, independent review, P1 — "announcement
  /// ≠ ownership"): an independent review dynamically reproduced a P1 in the
  /// R4-era version of this method, which — on finding a stop-creating
  /// operation already SCHEDULED by another producer (typically a rotation
  /// tick) but not yet PUBLISHED — merely awaited THAT announcement's own
  /// result and returned, treating it as if it satisfied this call's own
  /// obligation. It does not: an announcement only ever describes what its
  /// OWN producer decided (a real [_PendingNativeStop], or `null` meaning
  /// only "THIS producer did not create one" — see [_pendingStopIntent]
  /// and [_publishStopIntent]'s own docs). A rotation tick publishing
  /// `null` (its own [_FinalizeReason.rotation] policy, e.g. while
  /// [_cameraKnownUnavailable]) does NOT mean no Recording needs stopping —
  /// it means only that ROTATION specifically declined to be the one to stop
  /// it. The reproduced sequence: Recording A active,
  /// [_cameraKnownUnavailable]=true, a rotation tick claims the shared
  /// announcement, `stopLoopRecording()` discovers it and (in the old code)
  /// accepted rotation's eventual `null` as its own completion, returned —
  /// `isRecording` false, `controller.value.isRecordingVideo` still true,
  /// zero clips.
  ///
  /// This method now ALWAYS enqueues its own [_doFinalizeCurrentSegment]
  /// obligation ([_FinalizeReason.explicitStop]) — exactly the same
  /// principle [_doReleaseController] (via [releaseIdleCamera]/[dispose])
  /// already followed (this class's own doc §11) — rather than ever
  /// substituting a DISCOVERED announcement's result for that obligation.
  /// The one exception remains [_pendingNativeStop] already being non-null:
  /// that specifically means a REAL native stop is already in flight for the
  /// CURRENT, active Recording — attaching directly to it (no second native
  /// call) is correct and safe, including if it ultimately fails (§7: a
  /// fast/late failure of an already-issued stop is not, by itself, a
  /// reason to issue a second one against the same Recording without a
  /// separately-proven-safe policy — none exists yet, so none is attempted;
  /// see this class's own §19 limitations).
  ///
  /// An announcement discovered here (via [_awaitTeardown], shared with
  /// [releaseIdleCamera]/[dispose] — Fase 16.2-R4.2A-R5 extends that shared
  /// helper to this method too) still serves its original purpose: letting
  /// this call bound its own presentation wait on an EARLIER producer's real
  /// deadline instead of guessing one, and letting a LATER caller
  /// (`releaseIdleCamera()`/`dispose()` called synchronously right after,
  /// with no `await` in between) discover THIS call's own now-claimed,
  /// not-yet-published announcement in turn (this class's own doc §1 bullet
  /// 3). What changed is only that discovering `null` — from rotation or
  /// from anyone else — no longer short-circuits this call's own obligation:
  /// [_doFinalizeCurrentSegment] is always enqueued, and correctness is
  /// re-derived from `controller.value.isRecordingVideo`, fresh, at
  /// whichever turn in [_queueTail] this call's own operation actually gets
  /// — not from what an earlier, unrelated producer happened to decide.
  /// Double-stopping the SAME Recording an earlier producer already, really
  /// stopped is naturally avoided by that same fresh check: by the time this
  /// call's own operation runs, [_queueTail]'s strict FIFO guarantees any
  /// EARLIER producer's own real stop attempt has already fully resolved,
  /// so `controller.value.isRecordingVideo` already reflects it. A prior
  /// producer's own real stop attempt that instead terminated with an
  /// ERROR is likewise never retried here — see
  /// [_failedStopRecordingId]'s own doc and [_doFinalizeCurrentSegment]'s
  /// own guard (Fase 16.2-R4.2A-R6): `isRecordingVideo` staying `true`
  /// after a failed stop is not license for a second attempt.
  ///
  /// Fase 16.2-R4.2A-R6 (§21, independent review — error contract
  /// consistency): this method's returned [Future] never itself throws for
  /// a native stop failure, on EITHER of its two internal paths (an
  /// already-[_pendingNativeStop] discovered directly, or this call's own
  /// obligation via [_awaitTeardown]) — matching [releaseIdleCamera]/
  /// [dispose], which never do either. Every failure is instead reported
  /// via [errors] exactly once, by whichever operation actually owns it
  /// ([_doRotateSegment]/[_doReleaseController]'s own direct catch, or this
  /// method's own enqueued closure below). An R5-era version of this
  /// method let the first of those two paths propagate the error directly
  /// instead, meaning whether a caller of `stopLoopRecording()` could
  /// observe a `throw` depended on which internal path happened to run —
  /// not something a caller could reason about from this method's own
  /// public contract.
  /// Fase 16.2-R4.3-R2 (§28/§29, independent-review P2-B fix — "targeted
  /// cleanup"): [expectedController]/[expectedRecordingId], if given, make
  /// this call a NO-OP (checked BEFORE any of this method's own mutation —
  /// the synchronous intent prefix below, cancelling [_segmentTimer], etc.
  /// — this class's own doc, §1) unless they still match the CURRENT
  /// controller/Recording. Exists so a stale caller (e.g.
  /// `DashcamSessionController`'s own generation-invalidated cleanup) can
  /// issue a stop that only ever affects the exact controller/Recording it
  /// itself observed — never a NEWER one a hand-off has since made current
  /// — without needing to re-derive DashcamService's own internal identity
  /// rules. `null` (the default) means "no target restriction", identical
  /// to this method's pre-existing, unqualified behavior — every
  /// direct/test caller that does not pass either sees zero behavior
  /// change.
  ///
  /// Fase 16.2-R4.3-R2.6.18: [startAttempt] and what each of the three ways of
  /// naming a target may do — see [beginStopLoopRecording].
  Future<void> stopLoopRecording({int? expectedRecordingId, CameraController? expectedController, DashcamStartAttempt? startAttempt}) {
    return beginStopLoopRecording(expectedRecordingId: expectedRecordingId, expectedController: expectedController, startAttempt: startAttempt).presentation;
  }

  /// Fase 16.2-R4.3-R2.2 (§6/§7/§9/§41-43): the full [stopLoopRecording]
  /// logic, unchanged in every observable respect for existing callers
  /// (which is why [stopLoopRecording] remains the minimal, unchanged public
  /// surface for them — this class's own doc §8), but returning a
  /// [DashcamStopOutcome] instead of only [presentation] — see that class's
  /// own doc for why a caller that needs the stop's own identity/settlement
  /// (currently only `DashcamSessionController`'s own late-persistence
  /// continuation) must capture [DashcamStopOutcome.handle] here, at
  /// issuance, rather than reading [pendingStopHandle] again later.
  ///
  /// Fase 16.2-R4.3-R2.2 (§25-§27, independent-review P2 — "targeted cleanup
  /// na FIFO"): [expectedRecordingId]/[expectedController], if given, are now
  /// re-validated a SECOND time, synchronously, the instant the enqueued
  /// closure below actually begins running — not only once, early, before
  /// enqueue. Between this call being enqueued and its own turn in
  /// [_queueTail] arriving, an operation queued AHEAD of it can freely change
  /// which controller/Recording is current (e.g. a hand-off's own fresh
  /// `initialize()`+start for a newer generation) — the first check alone
  /// cannot see that; only re-checking right before this closure would
  /// actually touch anything closes it. A mismatch at that point is a silent
  /// no-op over whatever is CURRENT now — it must never emit a stop against a
  /// newer generation's own Recording, and must never disturb
  /// [_failedStopRecordingId]/[_cameraKnownUnavailable] on that newer
  /// generation's behalf.
  ///
  /// Fase 16.2-R4.3-R2.6.17 (independent review of R2.6.16, P2-A — "stale
  /// cleanup invalidates a newer START"): the two checks above compare what the
  /// caller NAMED against what is current; neither asked whose recording INTENT
  /// the call was about to take down. A cleanup that names a Recording acts for
  /// that Recording, so it may clear [_isRecording] and cancel the segment timer
  /// only while that Recording is the one the latest START stands for
  /// ([_activeRecordingIsLatestStarts]). Once a later START has been accepted the
  /// intent is that START's, and such a cleanup:
  ///  * still adopts the stop already pending for the Recording it names, or
  ///    still gets its own turn in the queue to stop it if it is the active one
  ///    by then — what belongs to the old attempt is still cleaned up;
  ///  * no longer touches the flag or the timer — the newer START is not
  ///    withdrawn by a request that declared another target.
  /// An untargeted call is unchanged: it means "nothing is wanted any more".
  ///
  /// Fase 16.2-R4.3-R2.6.18 (substitute independent review of R2.6.17, R1 and
  /// N1) — cleanup ownership. Stopping an old physical resource and changing
  /// the CURRENT logical state (the recording intent, the segment timer) are
  /// two different things. A cleanup may always clean what provably belongs to
  /// what it names; it changes the current logical state only when it also
  /// proves that state still belongs to what it names. What a call proves
  /// depends on what it names:
  ///  * nothing (untargeted): the newest request about the intent itself —
  ///    it takes down whatever intent stands, as always;
  ///  * a START attempt ([startAttempt], from [beginStartLoopRecording]): what
  ///    THAT START did. It takes the intent down only while that START is still
  ///    the latest one. It stops, adopts or owns only a Recording of that
  ///    attempt — its current segment, whatever id a rotation has given it, and
  ///    the one its native START is still about to produce. It is the way to
  ///    clean up a START that has no Recording to name;
  ///  * a Recording ([expectedRecordingId], with or without
  ///    [expectedController]): that ONE segment. It takes the intent down only
  ///    while that Recording is the latest START's (R2.6.17) AND is not a
  ///    segment a rotation is replacing ([_recordingIsBeingReplaced]). Once a
  ///    rotation has ended it and is starting its successor, the cleanup has
  ///    nothing left to clean, and the intent standing is for the segment on
  ///    its way — which a request that named another Recording would withdraw
  ///    and then never stop (N1). Such a request decides when its own turn in
  ///    the queue comes, behind that rotation: a successor exists — nothing to
  ///    do, the run goes on; none was created — the segment it named was the
  ///    run's last one after all, and the intent comes down then;
  ///  * only the camera ([expectedController] alone): no START and no
  ///    Recording — nothing it can prove is its own. It stops nothing and
  ///    withdraws nothing (R1). The same camera serves every START issued
  ///    between two `initialize()` calls; taking "this camera" for "the START I
  ///    asked for" let a cleanup of an old attempt withdraw a newer START,
  ///    which then resolved without error and never recorded.
  DashcamStopOutcome beginStopLoopRecording({int? expectedRecordingId, CameraController? expectedController, DashcamStartAttempt? startAttempt}) {
    assert(
      startAttempt == null || (expectedRecordingId == null && expectedController == null),
      'beginStopLoopRecording: name a START attempt OR a Recording/camera, not both',
    );
    // Fase 16.2-R4.3-R2.3 (§3-§9, independent-review P1-A exact reproduction
    // — "preexisting STOP obligation lost"): checked FIRST, before
    // [_isRecording] is ever consulted. `_isRecording == false` does NOT
    // mean "nothing to stop" — a stale cleanup's own targeted STOP (e.g.
    // [DashcamSessionController._teardownStartedRecording]'s own call, or a
    // rotation-triggered finalize) already flips [_isRecording] to `false`
    // SYNCHRONOUSLY, in its own prefix below, the INSTANT it is issued — not
    // once the real native call resolves. A later, independent caller (e.g.
    // a public `stopSession()`) arriving while that same Recording's own
    // native STOP is still genuinely pending must ADOPT that existing
    // obligation, never conclude "nothing is recording" and hand back a
    // `null` handle for a clip that is, in fact, still on its way. Fase
    // 16.2-R4.2A's own invariant — one real Recording, at most one STOP
    // emission — is what makes this safe: adopting is the ONLY correct
    // response to a materialized [_pendingNativeStop], never a second,
    // independent native call.
    // Fase 16.2-R4.3-R2.5 (§6/§7): purpose is part of this call's identity —
    // an untargeted call and a targeted stale cleanup are different requests
    // even though both end in [_FinalizeReason.explicitStop].
    final purpose = (expectedController != null || expectedRecordingId != null || startAttempt != null) ? _StopPurpose.targetedCleanup : _StopPurpose.explicitStop;
    // Fase 16.2-R4.3-R2.6.18: the two identities of a targeted request, taken
    // from what the caller handed in — never re-derived from what is current
    // now. Physical: the camera. Temporal: the START attempt, when it named one.
    final targetController = startAttempt?._controller ?? expectedController;
    final attemptEpoch = startAttempt?._startEpoch;
    DashcamStopOutcome noStopOutcome() {
      final intent = _resolvedStopIntent(purpose, null, expectedController: targetController, expectedRecordingId: expectedRecordingId, attemptEpoch: attemptEpoch);
      return DashcamStopOutcome(presentation: Future<void>.value(), handle: Future<DashcamPendingStopHandle?>.value(), intentId: intent.id);
    }

    // Fase 16.2-R4.3-R2.6.18 (R1): the camera alone names no START and no
    // Recording. Whatever is pending, queued, in flight or recording on it may
    // belong to a START this caller knows nothing about: nothing is adopted,
    // nothing is withdrawn, nothing is queued.
    if (purpose == _StopPurpose.targetedCleanup && expectedRecordingId == null && attemptEpoch == null) {
      return noStopOutcome();
    }

    // Fase 16.2-R4.3-R2.6.17, extended by R2.6.18: whether the recording intent
    // is this request's to take down — see this method's own doc. Read once:
    // nothing below changes what it depends on before it is used, and for a
    // cleanup that names a Recording both places that use it come AFTER that
    // Recording was matched — against the stop pending for it, or against
    // [_activeRecordingId] — so "the Recording named" and "the active Recording"
    // are the same one there.
    final bool withdrawsRecordingIntent;
    if (purpose == _StopPurpose.explicitStop) {
      withdrawsRecordingIntent = true;
    } else if (attemptEpoch != null) {
      withdrawsRecordingIntent = _isLatestStartIntent(attemptEpoch);
    } else {
      withdrawsRecordingIntent = _activeRecordingIsLatestStarts && !_recordingIsBeingReplaced(expectedRecordingId);
    }
    // Fase 16.2-R4.3-R2.6.18 (N1): the one request whose answer is not known
    // yet. A cleanup that names a segment a rotation is replacing cannot tell,
    // now, whether a successor is coming — the restart START is in flight. If
    // one comes, the run goes on and this request has nothing to do with it.
    // If none does (the restart fails, or is not attempted after all), the
    // segment it named was the run's last one, and the intent left standing is
    // for nothing. Deciding either way here would be a guess: "withdraw" is N1;
    // "never" leaves a dead run that absorbs the next START — which this same
    // request, issued one instant after the failure, would have taken down
    // ([_recordingIsBeingReplaced] is `false` by then). So it decides when its
    // own turn comes, behind that rotation, where it is a fact: see the queued
    // closure below. (Fase 16.2-R4.3-R2.6.20: when the restart FAILS the
    // rotation now ends the run itself, ahead of this request's turn — see
    // [_endRunLeftWithoutSegment]; what is left for this request to decide is
    // a restart that was not attempted after all.)
    final decidesIntentAtItsTurn =
        purpose == _StopPurpose.targetedCleanup && attemptEpoch == null && _activeRecordingIsLatestStarts && _recordingIsBeingReplaced(expectedRecordingId);

    final existing = _pendingNativeStop;
    // Fase 16.2-R4.3-R2.6.18: a cleanup of a START attempt adopts the pending
    // stop only when the Recording being stopped is that attempt's own. When it
    // is not, the request is not over, unlike one that named a Recording: its
    // attempt may be waiting right behind this stop, or have its native START
    // in flight — the rules further down decide.
    final existingIsOfTheAttempt = existing != null && identical(existing.controller, targetController) && existing.recordingStartEpoch == attemptEpoch;
    if (existing != null && (attemptEpoch == null || existingIsOfTheAttempt)) {
      if ((targetController != null && !identical(existing.controller, targetController)) ||
          (expectedRecordingId != null && existing.recordingId != expectedRecordingId)) {
        // A real STOP is pending, but for a DIFFERENT Recording/controller
        // than this caller is targeting — never adopted; this call
        // concerns something else entirely (this class's own established
        // targeted-cleanup contract, unchanged).
        return noStopOutcome();
      }
      // Fase 16.2-R4.3-R2.3 (§6, regression found via this class's own
      // "rotate during stop" test): adopting [existing] is still THIS
      // caller's own genuine stop intent — a rotation tick's own announced
      // stop never touches [_isRecording]/[_segmentTimer] itself (rotation
      // intends to keep recording, just in a new segment), so if an
      // explicit stop call adopts a rotation-created [existing] without
      // ALSO applying its own synchronous intent prefix here, [_isRecording]
      // would incorrectly keep reporting `true` after this call returns.
      // Safe regardless of who created [existing]: while a real STOP is
      // pending for it, Fase 16.2-R4.2A's own FIFO/ownership invariant
      // guarantees no NEWER recording can have started yet, so
      // [_isRecording]/[_segmentTimer] here can only still concern the same
      // Recording [existing] itself represents.
      //
      // Fase 16.2-R4.3-R2.6.17 (independent review of R2.6.16, P2-A): that last
      // sentence holds for a Recording, not for an INTENT. No newer Recording
      // can exist while this stop is pending, but a newer START can already
      // have been accepted and be waiting behind it — and then the flag is that
      // START's. A cleanup that NAMES the Recording being stopped still adopts
      // the stop (it is its target) but takes the intent down only while that
      // Recording is the one the latest START stands for
      // ([withdrawsRecordingIntent]). An untargeted stop is unchanged: it means
      // "nothing is wanted any more", whoever asked for it last.
      if (withdrawsRecordingIntent) {
        _isRecording = false;
        _segmentTimer?.cancel();
        _segmentTimer = null;
      }
      // Fase 16.2-R4.2A-R6 (§21, independent review — inconsistent error
      // contract): swallowed here, not propagated to this call's own
      // caller — [releaseIdleCamera]/[dispose] never throw for a stop
      // failure either (both always route through [_awaitTeardown], which
      // already catches this same [visibleSignal] internally); an earlier
      // version of this specific fast-path let it propagate instead,
      // meaning whether `stopLoopRecording()` could throw depended on
      // which of its two internal paths happened to run, not on anything
      // callers could reason about. The failure itself was already
      // reported via [errors] exactly once by whichever operation actually
      // owns [existing] (its own direct creator — [_doRotateSegment]/
      // [_doReleaseController] — see their own catch blocks); this is
      // purely a second observer of the SAME outcome, not a second report.
      final adopting = _resolvedStopIntent(
        purpose,
        existing,
        expectedController: targetController,
        expectedRecordingId: expectedRecordingId,
        attemptEpoch: attemptEpoch,
      );
      return DashcamStopOutcome(
        presentation: existing.visibleSignal.catchError((_) {}),
        handle: Future<DashcamPendingStopHandle?>.value(_handleFor(adopting, existing)),
        intentId: adopting.id,
      );
    }

    if (!_isRecording) {
      // Fase 16.2-R4.3-R2.3 (§7/§13, independent-review — "STOP announced
      // but not materialized"): `_isRecording == false` here is checked
      // ONLY AFTER confirming no [_pendingNativeStop] exists (above) — but
      // it can STILL be false for the SAME reason P1-A itself concerned: a
      // stop-creating operation may already have been ISSUED (its own
      // [_claimStopIntent] call already made, its own enqueued
      // closure already appended to [_queueTail], its own synchronous
      // `_isRecording = false` prefix already run) without having reached
      // [_doFinalizeCurrentSegment]'s own `_pendingNativeStop = pending;`
      // line yet — genuinely reachable whenever anything else is still
      // ahead of it in the FIFO. Checked HERE, inside the `!_isRecording`
      // branch specifically — never earlier, unconditionally — because a
      // ROTATION tick's own announcement (which never touches
      // [_isRecording] at all — only an explicit-stop-flavored caller's own
      // prefix does) must NOT be mistaken for this caller's own obligation
      // while a Recording is still genuinely, independently active: Fase
      // 16.2-R4.2A-R5's own established invariant (`_awaitTeardown`'s own
      // doc) — an announcement resolving to `null` only ever describes what
      // its OWN producer decided, never this caller's own obligation. Here,
      // reaching this branch at all with `_isRecording == false` already
      // proves this caller's own obligation is real (something explicitly
      // flipped it) — adopting whatever the announcement resolves to is
      // therefore correct; a plain "nothing to do" is only right when BOTH
      // no native stop exists yet AND nothing has claimed an announcement
      // either.
      //
      // Fase 16.2-R4.3-R2.5 (§9/§10, independent-review P1-3): the scheduled
      // intent is JOINED only if it is semantically this same request
      // ([_StopIntent.isCompatibleWith]) — e.g. two untargeted stops (X13-B/
      // X17). An unresolved intent of a DIFFERENT purpose (a release/
      // reinitialize/rotation that cleared [_isRecording] or merely happens
      // to be scheduled) is a BARRIER instead: this call falls through and
      // creates its own intent + its own queued finalize below, which
      // re-evaluates the state when its turn arrives and — via
      // [_claimStopIntent]'s barrier adoption — still receives the barrier's
      // REAL stop handle if that intent materializes one for the Recording
      // this call concerns. Never a shared terminal `null`.
      final scheduled = _activeStopIntent;
      if (scheduled == null) return noStopOutcome();
      if (scheduled.isCompatibleWith(purpose, targetController, expectedRecordingId, _startIntentEpoch, otherAttemptEpoch: attemptEpoch)) {
        return _adoptAnnouncedStop(scheduled);
      }
    }
    if (targetController != null && !identical(_controller, targetController)) {
      return noStopOutcome();
    }
    if (expectedRecordingId != null && _activeRecordingId != expectedRecordingId) {
      return noStopOutcome();
    }
    // Synchronous intent prefix — see this class's own doc, §1. Flipped
    // BEFORE this is enqueued, not inside the queued operation: if a
    // rotation's own finalize is already running (queued ahead of this),
    // its post-finalize restart check (`if (controller != null &&
    // _isRecording ...)`) must already see `false` by the time it looks,
    // or it would start a brand new recording that nothing is left to ever
    // stop or rotate again (the exact bug a real regression test caught in
    // Fase 16.2's first cut).
    //
    // Fase 16.2-R4.3-R2.6.17 (P2-A): ...when the intent is this request's to
    // take down. A cleanup that names a Recording which is no longer the latest
    // START's (see [withdrawsRecordingIntent]) passed the check just above only
    // because [_activeRecordingId] still names that older Recording; the
    // intent standing now is a later START's. It keeps everything else it had —
    // its own intent, its own queued turn, which stops the Recording it names
    // if that one is still the active one by then — and leaves the flag and
    // the timer alone.
    //
    // Fase 16.2-R4.3-R2.6.18: the same holds for the two other requests that
    // cannot prove the intent standing is theirs. A cleanup that names a
    // segment a rotation is REPLACING (N1 — the rotation has ended it and its
    // restart START is in flight; [_activeRecordingId] names it until the
    // successor exists): what it would withdraw is the run's intent for the
    // segment on its way, which its own queued turn, comparing ids, would then
    // never stop (it decides there instead — [decidesIntentAtItsTurn]). And a
    // cleanup of a START attempt that is no longer the latest START: the intent
    // is a later START's.
    if (withdrawsRecordingIntent) {
      _isRecording = false;
      _segmentTimer?.cancel();
      _segmentTimer = null;
    }

    // Fase 16.2-R4.3-R2.5 (§6-§13): THIS call's own intent — identity, purpose
    // and explicit target (only when the caller supplied one; an untargeted
    // stop deliberately freezes NO Recording id here, see
    // [_StopIntent.expectedRecordingId]). Joined only if a scheduled intent is
    // semantically the same request, otherwise a fresh intent that takes the
    // scheduled one as a barrier — never sharing its terminal result.
    final announceStop = _claimStopIntent(
      purpose,
      expectedController: targetController,
      expectedRecordingId: expectedRecordingId,
      attemptEpoch: attemptEpoch,
    );
    // Fase 16.2-R4.3-R2.2 (§6/§9): constructs the handle from the LOCAL
    // value [announceStop] resolves to — never from re-reading
    // [_pendingNativeStop] — the instant that resolution happens, which is
    // always synchronous with (and therefore strictly no later than) the
    // native stop's own creation inside [_doFinalizeCurrentSegment]. Safe
    // even if [_pendingNativeStop] is already cleared again by the time this
    // callback actually runs (a completed `Future` still carries its own
    // resolved value regardless of what any field pointing to it does
    // afterward).
    final handle = _intentHandle(announceStop);
    final queued = _observeTeardown(
      _enqueue(() async {
        // CHECK 2 (§25-§27) — re-validated here, the instant this closure
        // actually begins running, not merely at the synchronous call-time
        // check above.
        if (targetController != null && !identical(_controller, targetController)) {
          _publishStopIntent(announceStop, null);
          return;
        }
        if (expectedRecordingId != null && _activeRecordingId != expectedRecordingId) {
          _publishStopIntent(announceStop, null);
          return;
        }
        // Fase 16.2-R4.3-R2.6.18: a cleanup of a START attempt stops what THAT
        // attempt is recording when its turn comes — its current segment,
        // whatever id a rotation has given it since — and nothing a later
        // START recorded. The camera being the same proves neither.
        if (attemptEpoch != null && _activeRecordingStartEpoch != attemptEpoch) {
          _publishStopIntent(announceStop, null);
          return;
        }
        // Fase 16.2-R4.3-R2.6.18 (N1): the decision this request could not take
        // when it was issued ([decidesIntentAtItsTurn]). The rotation that was
        // replacing the segment it named has run to its real end ahead of it in
        // the queue — a restart START is awaited there until it settles, past
        // its deadline too — and [_activeRecordingId] still names that segment
        // (checked above): no successor was created. The intent still standing
        // is for a run with nothing recording and nothing on its way, and the
        // Recording named is that run's last one: the intent comes down, as it
        // does synchronously when this same request arrives after the rotation
        // has ended. Only while that Recording is still the latest START's — a
        // START accepted meanwhile owns the flag and the timer, and is left
        // alone.
        if (decidesIntentAtItsTurn && _activeRecordingIsLatestStarts) {
          _isRecording = false;
          _segmentTimer?.cancel();
          _segmentTimer = null;
        }
        try {
          await _doFinalizeCurrentSegment(reason: _FinalizeReason.explicitStop, announceStop: announceStop);
        } catch (error) {
          // A fast (within-deadline) native/processing failure — see
          // _doFinalizeCurrentSegment's own doc: with no uiSignal, it
          // rethrows here. Mirrors _doReleaseController's own identical
          // pattern, just with a message specific to an explicit stop.
          // Fase 16.2-R4.3-R2 (§45): this Recording's own finalize outcome
          // — recordingResult.
          _reportError('Falha ao finalizar clipe ao parar gravação: $error', scope: DashcamServiceErrorScope.recordingResult);
        }
      }),
    );
    return DashcamStopOutcome(
      presentation: _awaitTeardown(announceStop: announceStop, queued: queued),
      handle: handle,
      intentId: announceStop.id,
    );
  }

  /// Builds the public handle for [stop] as observed by [intent] — carrying
  /// [intent]'s own identity ([DashcamPendingStopHandle.intentId]), which is
  /// the service-side guarantee "this stop belongs to that intent".
  DashcamPendingStopHandle _handleFor(_StopIntent intent, _PendingNativeStop stop) {
    return DashcamPendingStopHandle(
      recordingId: stop.recordingId,
      controller: stop.controller,
      settlement: stop.realSettlement,
      intentId: intent.id,
      producerToken: stop.producerToken,
      physicalStopId: stop.id,
      producerIntentId: stop.originIntentId,
    );
  }

  /// [DashcamStopOutcome.handle] for [intent]: resolves to a handle only for a
  /// stop [intent] itself produced or legitimately adopted
  /// ([_StopIntent.acceptsStop]) — `null` for "this intent needed no stop" and
  /// for a foreign stop. Derived from [intent]'s own durable resolution, never
  /// from a presentation deadline (Fase 16.2-R4.3-R2.4, unchanged) and never
  /// from another intent's result.
  Future<DashcamPendingStopHandle?> _intentHandle(_StopIntent intent) {
    return intent.resolution.then((stop) => stop == null || !intent.acceptsStop(stop) ? null : _handleFor(intent, stop));
  }

  /// Fase 16.2-R4.3-R2.3 (§7/§13), reworked in Fase 16.2-R4.3-R2.5: JOINS
  /// [intent] — a stop-creating operation someone else already claimed via
  /// [_claimStopIntent] that is semantically THIS caller's own request (the
  /// caller has already established [_StopIntent.isCompatibleWith]; an
  /// incompatible intent is never joined, see [beginStopLoopRecording]) — not
  /// yet resolved to a real [_PendingNativeStop] (or to `null`, meaning that
  /// intent turned out not to need a stop at all), instead of this call
  /// creating its own, independent one. Reuses [_discoverScheduledStop] (the
  /// same presentation-bounded discovery [_awaitTeardown] already uses for
  /// [releaseIdleCamera]/[dispose]'s own identical "announced but not yet
  /// materialized" case), so a caller here waits no differently than those
  /// already-established callers do.
  ///
  /// A `null` resolution or a stop [intent] does not accept
  /// ([_StopIntent.acceptsStop]) yields a `null` handle and an
  /// already-resolved [DashcamStopOutcome.presentation]; this call never falls
  /// through to emit a second, its own independent stop in that case — the
  /// intent it joined was authoritative for whether a stop was needed at all.
  ///
  /// Fase 16.2-R4.3-R2.4 (§2/§3/§6-§9, independent-review P1-A —
  /// "announcement discovery expires"): [DashcamStopOutcome.handle] is
  /// resolved from [intent]'s own raw, un-timed-out resolution — never from
  /// [_discoverScheduledStop]'s own `.timeout(stopVideoRecordingTimeout)`
  /// wrapper. That wrapper bounds only [DashcamStopOutcome.presentation] (a
  /// UI-facing fact: how long THIS call's own caller should wait before
  /// regaining control) — it must never also decide the PHYSICAL question of
  /// whether an obligation exists. [intent] is guaranteed, by every
  /// [_publishStopIntent] call site reachable from whichever operation
  /// actually claimed it (_doFinalizeCurrentSegment's/_doReleaseController's
  /// own terminal branches — audited: every one of them calls
  /// [_publishStopIntent], with either a real [_PendingNativeStop] or `null`,
  /// and only the first result for an intent counts), to resolve exactly once,
  /// eventually — so awaiting it directly here, with no additional timeout,
  /// can never leak: it always reaches a terminal value, it may simply take
  /// longer than this call's own presentation window. A `null` resolution IS
  /// itself the terminal proof required by §8b — "no stop was needed" — not a
  /// timeout artifact.
  DashcamStopOutcome _adoptAnnouncedStop(_StopIntent intent) {
    final presentationCompleter = Completer<void>();

    unawaited(() async {
      _PendingNativeStop? stop;
      try {
        stop = await _discoverScheduledStop(intent);
      } on TimeoutException {
        // Presentation-only fact (this class's own doc, §1 bullet 3, and
        // this method's own doc above) — bounds [presentationCompleter]
        // ONLY. The handle keeps running via [_intentHandle]'s own durable
        // continuation; it is NOT resolved here.
        if (!presentationCompleter.isCompleted) presentationCompleter.complete();
        return;
      }
      if (stop == null || !intent.acceptsStop(stop)) {
        if (!presentationCompleter.isCompleted) presentationCompleter.complete();
        return;
      }
      await stop.visibleSignal.catchError((_) {});
      if (!presentationCompleter.isCompleted) presentationCompleter.complete();
    }());
    return DashcamStopOutcome(presentation: presentationCompleter.future, handle: _intentHandle(intent), intentId: intent.id);
  }

  // ===========================================================================
  // Segment rotation
  // ===========================================================================

  /// The `Timer.periodic` callback. Fase 16.2-R1 (P2, independent review):
  /// `Timer.periodic` does not wait for its callback, so two ticks can fire
  /// before the first tick's own work finishes — fire-and-forget into
  /// [_enqueue] here means a second tick's [_doRotateSegment] call simply
  /// waits its turn behind the first's, never overlapping it.
  ///
  /// Fase 16.2-R4.2A-R4 (§13/§14): claims/reuses [_pendingStopIntent]
  /// SYNCHRONOUSLY, here, before [_doRotateSegment] is even enqueued — see
  /// [_pendingStopIntent]'s own doc for the race this closes (a
  /// rotation tick synchronously followed by `releaseIdleCamera()`/
  /// `dispose()`, with no `await` in between, previously had no announcement
  /// to discover at all).
  ///
  /// Fase 16.2-R4.3-R2.6.15 — a tick belongs to the run that armed its timer
  /// ([run], see [_RotationRun]) and is ADMITTED here under two rules, both
  /// decided before anything is claimed or queued:
  ///  * ownership — a tick whose run is no longer the current one is dropped.
  ///    Every path that ends a run cancels its timer first, so this is the
  ///    last line of that defence rather than the usual one: it is what holds
  ///    if a tick is ever delivered for a run that already ended;
  ///  * one waiting tick per run — "a second tick waits its turn" (above) had
  ///    no limit: every tick that fired while a rotation was still in flight
  ///    queued one more operation. During a slow stop that was one per segment
  ///    period for as long as the stop lasted (without bound if it never
  ///    returned), and once it returned each of them ran a rotation of its
  ///    own, back to back. A tick that finds one already waiting adds nothing,
  ///    so [_queueTail] never holds more than the rotation that is running
  ///    plus one that waits. (An admitted tick therefore always claims a stop
  ///    intent of its own: the only rotation intent it could have "reused",
  ///    above, is the waiting tick's, and that one keeps it out.)
  ///
  /// The one tick that waits is kept rather than dropped on purpose: when
  /// recording is no longer wanted by the time its turn comes, it still
  /// finalizes the Recording the running rotation has just started, and the
  /// explicit stop queued behind it adopts that stop (a frozen contract). What
  /// it must not do is rotate again a segment that has only just begun — see
  /// "absorbed" in [_doRotateSegment].
  void _onRotationTick(_RotationRun run) {
    _rotationTicksFired++;
    if (!_isCurrentRotationRun(run)) {
      _noteRotationTick(_RotationTickFate.staleAtAdmission);
      return;
    }
    if (_rotationWaiting) {
      _noteRotationTick(_RotationTickFate.coalesced);
      return;
    }
    _rotationWaiting = true;
    _queuedRotationCount++;
    // The Recording this tick is for: the one active as the timer fires.
    final segmentRecordingId = _activeRecordingId;
    final announceStop = _claimStopIntent(_StopPurpose.rotation);
    unawaited(
      _enqueue(() async {
        _rotationWaiting = false;
        try {
          await _doRotateSegment(run: run, segmentRecordingId: segmentRecordingId, announceStop: announceStop);
        } finally {
          _queuedRotationCount--;
        }
      }),
    );
  }

  /// Fase 16.2-R4.3-R2.6.15: whether [run] is still THE recording run of this
  /// service — no newer START was accepted since its timer was armed, and the
  /// camera generation is the same. Ownership only: whether recording is
  /// still WANTED ([_isRecording], [_disposed]) and whether the camera can be
  /// trusted ([_cameraKnownUnavailable]) stay separate questions, answered by
  /// the guards that already existed.
  bool _isCurrentRotationRun(_RotationRun run) => _startIntentEpoch == run.startEpoch && identical(_controller, run.controller);

  /// True from the instant a tick is admitted ([_onRotationTick]) until its
  /// queued operation starts running — the "one waiting tick per run" bound.
  /// A rotation that is already running does not count: the tick that fires
  /// during it is the one that waits.
  bool _rotationWaiting = false;

  /// Rotation operations currently in [_queueTail], running or waiting — never
  /// more than two. Kept so a test can assert that bound and — Fase
  /// 16.2-R4.3-R2.6.18 — READ by [_recordingIsBeingReplaced]: "greater than
  /// zero" is how a cleanup learns that a rotation is still at work. What
  /// counts it did not change.
  int _queuedRotationCount = 0;
  int _rotationTicksFired = 0;
  final List<int> _rotationTickFateCounts = List<int>.filled(_RotationTickFate.values.length, 0);

  void _noteRotationTick(_RotationTickFate fate) => _rotationTickFateCounts[fate.index]++;

  /// Test-only: how many ticks the segment timers have delivered so far,
  /// whatever became of each — a test's clock for "N more ticks fired" that
  /// does not depend on what this class then decided to do with them.
  @visibleForTesting
  int get rotationTicksFiredForTest => _rotationTicksFired;

  /// Test-only: rotation operations in the queue right now (running +
  /// waiting) — the bound [_onRotationTick] enforces is 2.
  @visibleForTesting
  int get queuedRotationCountForTest => _queuedRotationCount;

  /// Test-only: how many ticks met each [_RotationTickFate], by `name` — lets
  /// a test assert WHY a tick did nothing, after asserting that it did.
  @visibleForTesting
  Map<String, int> get rotationTickFatesForTest => {
    for (final fate in _RotationTickFate.values) fate.name: _rotationTickFateCounts[fate.index],
  };

  /// [announceStop] is always published exactly once, by the time this
  /// returns, via [_doFinalizeCurrentSegment] itself (Fase 16.2-R4.2A-R4,
  /// §13/§14) — including on the [_FinalizeReason.rotation] abandon path
  /// (see that method's own doc). The only place this method publishes it
  /// directly is its own two early returns (Fase 16.2-R4.3-R2.6.15, below): a
  /// superseded or absorbed tick never reaches the finalize at all.
  ///
  /// Fase 16.2-R4.3-R2.6.14 — late settlement. A rotation is two steps, stop
  /// then start, inside ONE queued operation. When the stop outlives its
  /// response deadline this operation does not end and does not move on: it
  /// keeps awaiting the same raw native call (as it always did), and the start
  /// simply happens later — after [_lateRotationDecision] has confirmed, at
  /// that later instant, that recording is still what is wanted. There is no
  /// timer, no retry and no second attempt involved: a stop that never settles
  /// means a start that never happens.
  ///
  /// Fase 16.2-R4.3-R2.6.15 — ownership. [run] is the run whose timer produced
  /// this tick and [segmentRecordingId] the Recording that was active when it
  /// was admitted ([_onRotationTick]). The run is checked wherever this operation
  /// could act for someone else, each time from the state as it is at that
  /// instant, never from what an earlier check concluded:
  ///  1. on entry, before anything else — any amount of time may have passed
  ///     in the queue; a tick whose run was superseded meanwhile does nothing
  ///     at all: no stop, no start, no clip, no status change (its stop intent
  ///     is resolved to "no stop", which is the truth);
  ///  2. after the finalize step and immediately before the restart, with no
  ///     `await` in between — for a stop that met its deadline and for a tick
  ///     that had nothing to stop (a stop that missed its deadline already
  ///     takes [_lateRotationDecision], which reads the same two facts and
  ///     more). This is the check whose absence let a tick of run A start a
  ///     Recording under run B's intent.
  /// The Recording a restart produces is tracked after its own `await`
  /// exactly as before: whatever superseded this run while that START was in
  /// flight has queued its own stop or teardown behind this operation, and
  /// needs that identity to find it.
  ///
  /// "Absorbed": a tick only ever waits in the queue behind another rotation
  /// of its own run. If recording is still wanted when its turn comes and the
  /// active Recording is no longer [segmentRecordingId], that rotation has
  /// already replaced the segment this tick was for — rotating again would
  /// only cut a segment that has just begun. It does nothing. (When recording
  /// is NOT wanted any more it proceeds as it always did — see
  /// [_onRotationTick].)
  ///
  /// Fase 16.2-R4.3-R2.6.20 — late restart settlement. The second step can
  /// outlive its own response deadline too ([startVideoRecordingTimeout]), and
  /// the rule of R2.6.14 holds for it as well: this operation does not end and
  /// does not move on — it keeps awaiting the same raw native call, the queue
  /// stays held — and the deadline itself decides nothing and ends nothing
  /// ([_rotationRestartOverdue]). What the restart leaves behind is settled
  /// when the raw call really returns:
  ///  * success within the deadline — the run's next segment, as always; the
  ///    run keeps the timer it has;
  ///  * success after the deadline — decided from the state as it is at that
  ///    instant ([_settleLateRestart]): the run's next segment, with the run's
  ///    timer re-armed from there, or a Recording that is no longer this run's
  ///    to keep;
  ///  * failure, within the deadline or after it — no Recording, the camera
  ///    generation not trusted any more, and the run ENDS here
  ///    ([_endRunLeftWithoutSegment]) instead of staying wanted with nothing
  ///    recording.
  Future<void> _doRotateSegment({required _RotationRun run, required int? segmentRecordingId, required _StopIntent announceStop}) async {
    if (!_isCurrentRotationRun(run)) {
      _publishStopIntent(announceStop, null);
      _noteRotationTick(_RotationTickFate.staleAtExecution);
      return;
    }
    if (_isRecording && _activeRecordingId != segmentRecordingId) {
      _publishStopIntent(announceStop, null);
      _noteRotationTick(_RotationTickFate.absorbed);
      return;
    }
    // Fase 16.2-R4.3-R2.5 (§32): the segment this rotation ends and the one it
    // restarts belong to the SAME logical producer — captured before the
    // finalize so the restarted Recording keeps the token (new Recording id,
    // same producer) regardless of anything that could touch the field in
    // between.
    final producerToken = _activeRecordingToken;
    // Fase 16.2-R4.4-HW-MIG-5-SIG-2: past the guards above, so a stale or absorbed
    // tick does not touch a healthy segment; before the STOP, not at its Finalize.
    // Not for a tick that outlived a manual stop: its finalize finds nothing, and it
    // must not say a rotation is going on.
    if (_isRecording) _withdrawSegmentEvidence(DashcamSegmentPresentation.transitioning);
    final _PendingNativeStop? settled;
    try {
      settled = await _doFinalizeCurrentSegment(reason: _FinalizeReason.rotation, announceStop: announceStop);
    } catch (error) {
      // Fase 16.2-R4.2A-R2 (§20/§21 fix): a FAST (within-deadline) native
      // failure from a rotation-triggered stop used to propagate uncaught
      // out of this method — and since [_onRotationTick] calls [_enqueue]
      // with `unawaited`, nothing was ever listening on the resulting
      // Future, making this an unhandled async error (a real crash risk,
      // not just a swallowed one). [_doFinalizeCurrentSegment] still
      // rethrows here (no `uiSignal` was passed — see its own doc) so this
      // is the single, intended place that failure is finally consumed and
      // reported via [errors] exactly once — mirroring how
      // [_doReleaseController] already handles the identical class of
      // failure. Treated the same as a timeout for [_cameraKnownUnavailable]
      // purposes: an unexplained native stop failure makes this camera
      // generation just as untrustworthy as one that merely hung, and must
      // not be immediately followed by a same-generation restart attempt
      // below (no second finalize/start is issued this tick either way).
      // Fase 16.2-R4.3-R2 (§45): a finalize/STOP failure for the segment
      // that just ended — recordingResult (this Recording's own outcome),
      // never a reason on its own to poison a healthy CURRENT camera.
      _reportError('Falha ao finalizar clipe durante rotação de segmento: $error', scope: DashcamServiceErrorScope.recordingResult);
      _cameraKnownUnavailable = true;
      return;
    }
    // Fase 16.2-R4.3-R2.6.14: this rotation's own stop settled only AFTER its
    // response deadline (see [_overdueRotationStop] for the physical case).
    // The intent to keep recording was never abandoned — this queued operation
    // kept awaiting the raw native call, so nothing else could run in between
    // — but any amount of time passed, so the restart below is no longer taken
    // for granted: it happens only if nothing changed meanwhile.
    if (settled != null && settled.deadlineExceeded) {
      final decision = _lateRotationDecision(settled, announceStop);
      _lateRotationSettlementCount++;
      _lastLateRotationDecision = decision;
      if (decision != _LateRotationDecision.resume) return;
    }
    // Fase 16.2-R4.3-R2.6.15: the finalize above awaited — for a stop that met
    // its deadline, or for nothing at all when there was nothing to stop — and
    // this run may have been superseded meanwhile. `_isRecording` below cannot
    // tell: after a logical stop plus a new START it is `true` again, for a
    // run that is not this one. Checked here, synchronously with the restart.
    if (!_isCurrentRotationRun(run)) {
      _noteRotationTick(_RotationTickFate.staleAfterStop);
      return;
    }
    final controller = _controller;
    // Fase 16.2-R4.3-R2 (§41): read atomically alongside [controller] — see
    // [startLoopRecording]'s own identical doc for why this must not be
    // re-read later, once [controller] may no longer be [_controller].
    final controllerGeneration = _currentControllerGeneration;
    // Re-checked after the finalize (not just before it, above) —
    // _cameraKnownUnavailable can be set partway through this very await: by
    // a late failure of the stop itself (see _doFinalizeCurrentSegment), or by
    // the app being backgrounded while the stop was in flight. Without
    // re-checking here, this method would still restart a new recording on a
    // controller that is no longer to be trusted. (Until Fase
    // 16.2-R4.3-R2.6.14 the stop's own deadline also set it, which is what
    // kept a merely slow rotation from ever recording again — see
    // [_overdueRotationStop].)
    if (controller != null && _isRecording && !_cameraKnownUnavailable) {
      _segmentPresentation.value = DashcamSegmentPresentation.startPending;
      _segmentStartedAt = DateTime.now();
      // Fase 16.2-R4.3-R2.6.20: whether this START outlived its response
      // deadline — set at the instant the deadline fires, read below once the
      // raw call has really returned.
      var pastDeadline = false;
      var started = false;
      try {
        started = await _startVideoRecordingWithTimeout(
          controller,
          controllerGeneration,
          rotationRestart: true,
          onPresentationDeadline: () => pastDeadline = true,
        );
      } catch (error) {
        // Fase 16.2-R4.2B-R1 (§8/§26 audit — pre-existing gap found while
        // adding retention to this same call): a FAST restart failure here
        // used to propagate uncaught out of this method, the same
        // unhandled-async-error risk the FINALIZE catch above already
        // exists to prevent for its own native call — fixed the same way,
        // for consistency, not as a new architectural addition.
        // Fase 16.2-R4.3-R2 (§45): a START failure — concerns [controller]'s
        // own acquisition health — lifecycleCamera.
        _reportError(
          'Falha ao reiniciar gravação durante rotação de segmento: $error',
          scope: DashcamServiceErrorScope.lifecycleCamera,
          origin: controller,
          generation: controllerGeneration,
        );
        _cameraKnownUnavailable = true;
        // Fase 16.2-R4.3-R2.6.20: ...and the run has no segment and will get
        // none — see [_endRunLeftWithoutSegment].
        _endRunLeftWithoutSegment(run);
        return;
      } finally {
        // Fase 16.2-R4.3-R2.6.20: "overdue" describes a restart still in
        // flight — it ends here, with the native call, whatever the outcome
        // was (the START-side counterpart of [_clearPendingNativeStop]).
        //
        // Fase 16.2-R4.3-R2.6.21: a restart that did not start leaves the
        // camera unavailable (the `catch` above and the block below each say
        // so) — written BEFORE the mark is cleared, so the published
        // [cameraKnownUnavailable] never reads "available" in between: its
        // listener would be told, for that instant, that recording resumed.
        if (!started) _cameraKnownUnavailable = true;
        _rotationRestartOverdue = false;
      }
      if (!started) {
        // Fase 16.2-R4.3-R2.6.20: only reachable via a LATE native failure,
        // already reported via [errors] inside
        // [_startVideoRecordingWithTimeout]. It is the same physical event as
        // the fast failure caught just above and leaves the same behind: this
        // camera generation is not to be trusted for another native call
        // (until this round the deadline itself had already said so), and the
        // run is left without a segment.
        _cameraKnownUnavailable = true;
        _noteLateRestart(_LateRestartDecision.startFailed);
        _endRunLeftWithoutSegment(run);
        return;
      }
      // Fase 16.2-R4.2A-R6 (§4/§5), doc corrected R4.2A-R7 (§24): `started`
      // is a Dart/plugin-contract signal, not physical proof — see
      // _doStartLoopRecording's own doc for the same wording fix and for
      // why this identity is assigned on every such native start, not only
      // the very first one.
      // Guarded by `identical` for the same reason as there: nothing else
      // can actually reassign [_controller] while this queued operation is
      // still running (see [_enqueue]'s own doc), but this keeps the two
      // sites symmetric rather than relying on that as an unstated
      // invariant.
      //
      // Fase 16.2-R4.3-R2.6.20: also when the START returned late, and also
      // when the Recording will not be kept — whoever stops it has to find it.
      if (started && identical(_controller, controller)) {
        _activeRecordingId = ++_nextRecordingId;
        _activeRecordingToken = producerToken;
      }
      if (pastDeadline) {
        await _settleLateRestart(run, controller);
      } else if (_lateRestartDecision(run, controller) == _LateRestartDecision.adopted) {
        // Fase 16.2-R4.4-HW-MIG-5-SIG-2: the same conditions as a late one —
        // a stop may have been requested while this START was in flight.
        _adoptSegmentEvidence();
      }
    }
  }

  /// Fase 16.2-R4.3-R2.6.20 — late restart settlement authority: the restart
  /// START of [run]'s rotation returned SUCCESSFULLY, but only after its
  /// response deadline. Runs inside the rotation's own queued operation and
  /// decides synchronously with that settlement ([_lateRestartDecision]):
  /// nothing queued can have run in between, and everything REQUESTED in
  /// between is already visible.
  ///
  /// Adopted — the Recording is the run's next segment, under the identity
  /// [_doRotateSegment] has just given it, and the service is exactly as after
  /// a START that met the deadline (nothing is left marked: "slow" is not
  /// "lost"), with one difference: the run's timer is re-armed HERE. The mark
  /// the next period is counted from is this settlement — which is where the
  /// Recording is created (the same synchronous step, in [_doRotateSegment]) —
  /// and neither the instant the START was requested ([_segmentStartedAt]) nor
  /// the deadline that elapsed while it was in flight: the timer has to match
  /// the segment that really began. It is the contract of the run's FIRST
  /// segment, whose timer [_settleStartAttempt] arms in the step that creates
  /// its Recording, once its native START has returned. Left on its old
  /// cadence, a segment that started late would be cut short by exactly its
  /// lateness — down to a stop issued right after a START that has only just
  /// returned, when the lateness comes close to a whole period. Same run, so
  /// the same [_RotationRun]; the old timer is cancelled first, so there is
  /// never more than one; and a tick of the old timer that was already waiting
  /// in the queue is "absorbed" ([_doRotateSegment]) — the segment it was for
  /// is gone. A rotation whose restart met its deadline re-arms nothing, as
  /// before.
  ///
  /// Not adopted — the Recording exists and is tracked, but nothing is armed
  /// for it and no state is restored on its behalf. It needs someone to stop
  /// it:
  ///  * whatever withdrew the run (a stop, a release, a dispose, a
  ///    re-initialize) has its own stop or teardown queued behind this
  ///    operation, and that reaches it ([_hasQueuedStopFor]) — it keeps its own
  ///    result and handle, and this method does nothing;
  ///  * when nothing queued will — the one way known is the app going to the
  ///    background, which withdraws nothing and queues nothing
  ///    ([notifyAppBackgrounded]) — the operation that created the Recording
  ///    stops it itself, here, before it lets go of the queue: the rule
  ///    [_settleStartAttempt] already follows for a START nobody waits for any
  ///    more. Left alone it would go on recording on a camera generation this
  ///    class no longer trusts, on behalf of a run no rotation will ever serve
  ///    again. The run then has no segment and ends
  ///    ([_endRunLeftWithoutSegment]).
  Future<void> _settleLateRestart(_RotationRun run, CameraController controller) async {
    final decision = _lateRestartDecision(run, controller);
    _noteLateRestart(decision);
    if (decision == _LateRestartDecision.adopted) {
      _segmentTimer?.cancel();
      _segmentTimer = Timer.periodic(segmentDuration, (_) => _onRotationTick(run));
      segmentTimerArmedHookForTest?.call(() => _onRotationTick(run));
      _adoptSegmentEvidence();
      return;
    }
    if (!identical(_controller, controller) || _hasQueuedStopFor(controller, _activeRecordingId, run.startEpoch)) return;
    try {
      await _doFinalizeCurrentSegment(reason: _FinalizeReason.explicitStop);
    } catch (error) {
      // A fast native/processing failure: with no `uiSignal`
      // [_doFinalizeCurrentSegment] rethrows (see its own doc), and nothing is
      // listening on this operation's Future.
      _reportError('Falha ao finalizar a gravação de um reinício de rotação tardio: $error', scope: DashcamServiceErrorScope.recordingResult);
    }
    _endRunLeftWithoutSegment(run);
  }

  /// Fase 16.2-R4.3-R2.6.20: whether the Recording a rotation's restart START
  /// produced only after its response deadline is still that run's next
  /// segment — decided from the state as it is NOW, at settlement, never from
  /// what was true when the START was issued. The START-side counterpart of
  /// [_lateRotationDecision]: the same facts, read in the same order (see its
  /// own doc for how a session, a generation or a lifecycle transition reaches
  /// this class as each of them):
  ///  * intent — a stop, release, re-initialize or dispose requested meanwhile
  ///    cleared [_isRecording] when it was requested;
  ///  * a newer START — the intent standing is then that START's, not [run]'s;
  ///  * raw generation — an explicit statement of the queue's invariant, like
  ///    the `identical` guards around it;
  ///  * lifecycle — [notifyAppBackgrounded] set [_cameraKnownUnavailable]
  ///    meanwhile (the one writer of that flag that does not run in the queue):
  ///    this camera generation is not to be trusted for recording, and the next
  ///    foreground resume owns recovery, on a fresh controller.
  ///
  /// What tells this apart from a START of [startLoopRecording] that outlived
  /// its deadline — which is never turned into a recording
  /// ([_settleStartAttempt]) — is not a guess about the state. That START's own
  /// deadline took its intent down and told its caller, so nobody is waiting
  /// for the Recording it produces. A rotation's restart told nobody anything
  /// and withdrew nothing: only the tick of a run reaches this code, it carries
  /// that run, and when every fact above still holds the late success is
  /// exactly what the run asked for.
  _LateRestartDecision _lateRestartDecision(_RotationRun run, CameraController controller) {
    if (_disposed || !_isRecording) return _LateRestartDecision.recordingNoLongerWanted;
    if (_startIntentEpoch != run.startEpoch) return _LateRestartDecision.supersededByNewerStart;
    if (!identical(_controller, controller)) return _LateRestartDecision.controllerReplaced;
    if (_cameraKnownUnavailable) return _LateRestartDecision.cameraUnavailable;
    return _LateRestartDecision.adopted;
  }

  /// Fase 16.2-R4.3-R2.6.20 — [run]'s rotation ended its segment and its
  /// restart has settled, for good, without leaving the run one: the native
  /// START failed, or the Recording it produced late could not be kept and has
  /// just been stopped. Nothing is recording and nothing is on its way.
  ///
  /// Until this round the run was left as it was — `isRecording == true` — until
  /// someone else took it down, and a `startLoopRecording()` issued meanwhile
  /// was absorbed by it: its Future resolved without error and nothing ever
  /// recorded (the independent review of R2.6.18, findings C and D). The
  /// rotation knows, here, that the run has no segment and will get none, so
  /// the rotation ends it — when the run is still the current one and still
  /// wanted. An intent that someone withdrew meanwhile is already down; one
  /// that belongs to a later START is that START's, and is left alone.
  ///
  /// Only at the restart's TERMINAL settlement, never at its deadline: a START
  /// that is merely slow ends nothing ([_rotationRestartOverdue]). And only
  /// for a restart: a rotation that never got as far as one — its own stop
  /// failed, or the camera was marked unavailable while that stop was in
  /// flight — leaves the run as it always did.
  void _endRunLeftWithoutSegment(_RotationRun run) {
    if (!_isRecording || !_isCurrentRotationRun(run)) return;
    _isRecording = false;
    _segmentTimer?.cancel();
    _segmentTimer = null;
  }

  int _lateRestartSettlementCount = 0;
  _LateRestartDecision? _lastLateRestartDecision;

  void _noteLateRestart(_LateRestartDecision decision) {
    _lateRestartSettlementCount++;
    _lastLateRestartDecision = decision;
  }

  /// Test-only: how many rotation restarts settled after their response
  /// deadline — each one decided exactly once
  /// ([lastLateRestartDecisionForTest]).
  @visibleForTesting
  int get lateRestartSettlementCountForTest => _lateRestartSettlementCount;

  /// Test-only: the [_LateRestartDecision] (its `name`) of the most recent
  /// rotation restart that settled after its response deadline, or `null` if
  /// none did — lets a test assert WHY a late restart was or was not adopted,
  /// not merely what the camera did afterwards.
  @visibleForTesting
  String? get lastLateRestartDecisionForTest => _lastLateRestartDecision?.name;

  /// Fase 16.2-R4.3-R2.6.14: whether a rotation whose stop [settled] only
  /// after its response deadline may still start the next segment — decided
  /// from the state as it is NOW, at settlement, never from what was true when
  /// the stop was issued. Runs inside the rotation's own queued operation,
  /// synchronously with the restart it guards (no `await` between this and
  /// [_doRotateSegment]'s start), so what it reads cannot go stale in between.
  ///
  /// This class knows nothing about sessions or app lifecycle (see the class
  /// doc); each of those reaches it as one of the facts read here:
  ///  * the stop itself — only a stop that actually produced its clip
  ///    continues; a late failure keeps the pre-existing policy for a failed
  ///    rotation stop (no restart, [_cameraKnownUnavailable] set by
  ///    [_doFinalizeCurrentSegment]);
  ///  * intent / session — every stop, release, re-initialize and dispose
  ///    clears [_isRecording] synchronously when REQUESTED, long before its own
  ///    turn in [_queueTail]; a session that ended, or a recovery that already
  ///    asked for a fresh camera, is therefore visible here even though its
  ///    queued work is still waiting behind this very operation;
  ///  * a newer START ([_startIntentEpoch] moved on since [intent] was
  ///    claimed) — its own queued start owns starting; this rotation starting
  ///    first would make that START fail against an already-active Recording;
  ///  * raw generation — [settled] was issued on a specific controller. The
  ///    queue makes a replacement impossible while this operation runs (every
  ///    write to [_controller] is queued behind it), so this leg is an
  ///    explicit statement of that invariant, like the `identical` guards
  ///    around it, not a state a test can produce;
  ///  * lifecycle — [notifyAppBackgrounded] (or any native failure) set
  ///    [_cameraKnownUnavailable] meanwhile: the next foreground resume owns
  ///    recovery, on a fresh controller, as for any background camera loss.
  ///
  /// Process ownership is not re-read: it is released only by this instance's
  /// own queued teardown, which cannot have run while this operation holds
  /// the queue.
  ///
  /// Fase 16.2-R4.3-R2.6.15: the "newer START" and "raw generation" legs are
  /// the two facts of [_isCurrentRotationRun], which [_doRotateSegment] now
  /// checks for EVERY rotation (on entry, and before the restart) — not only
  /// for one whose stop missed its deadline, which is all this method ever
  /// covered. They stay here, named, because this is where a late rotation's
  /// outcome is reported.
  _LateRotationDecision _lateRotationDecision(_PendingNativeStop settled, _StopIntent intent) {
    if (settled.state != _NativeStopState.completed) return _LateRotationDecision.stopFailed;
    if (_disposed || !_isRecording) return _LateRotationDecision.recordingNoLongerWanted;
    if (_startIntentEpoch != intent.startEpoch) return _LateRotationDecision.supersededByNewerStart;
    if (!identical(_controller, settled.controller)) return _LateRotationDecision.controllerReplaced;
    if (_cameraKnownUnavailable) return _LateRotationDecision.cameraUnavailable;
    return _LateRotationDecision.resume;
  }

  int _lateRotationSettlementCount = 0;
  _LateRotationDecision? _lastLateRotationDecision;

  /// Test-only: how many rotations settled after their response deadline —
  /// each one decided exactly once ([lastLateRotationDecisionForTest]).
  @visibleForTesting
  int get lateRotationSettlementCountForTest => _lateRotationSettlementCount;

  /// Test-only: the [_LateRotationDecision] (its `name`) of the most recent
  /// rotation that settled after its response deadline, or `null` if none did —
  /// lets a test assert WHY a late rotation did or did not start the next
  /// segment, not merely whether a native start happened.
  @visibleForTesting
  String? get lastLateRotationDecisionForTest => _lastLateRotationDecision?.name;

  // ===========================================================================
  // Finalize (the only call site within the native-stop-ownership protocol
  // that invokes stopVideoRecording() — see this method's own doc for the
  // one narrow, deliberately out-of-scope exception)
  // ===========================================================================

  /// The only call site *within the native-stop-ownership protocol this
  /// class's own doc describes (§1 bullet 3)* that invokes
  /// `controller.stopVideoRecording()` (called by [_doRotateSegment],
  /// [_doReleaseController], and [stopLoopRecording]'s own queued operation
  /// — every caller that means to finalize a Recording this service still
  /// considers current funnels through here). Fase 16.2-R4.2A-R6
  /// (§41, independent review — doc-accuracy fix): NOT the only place this
  /// call ever appears in this file — [_doStartLoopRecording]'s own
  /// superseded-start branch also issues one, directly, detached (see
  /// [_detachNativeOperation]'s own doc), against a controller already
  /// confirmed to no longer be [_controller] at all. That path is
  /// deliberately outside this protocol (a residual, out-of-scope risk —
  /// see this class's own doc, final paragraph, and R4.2B), not a second
  /// instance of it: it can only ever run against an already-orphaned
  /// controller nothing else will ever touch again, never against the
  /// current, active one this method's own [_activeRecordingId]/
  /// [_failedStopRecordingId] bookkeeping is about.
  ///
  /// Fase 16.2-R1: no longer has its own dedup wrapper —
  /// [_enqueue] already guarantees this can never run concurrently with
  /// itself or with [_doStartLoopRecording]/[_doInitializeController]/
  /// [_doReleaseController], since all of them are only ever called either
  /// directly by an already-[_enqueue]d operation (this one included) or as
  /// the [_enqueue]d operation itself — never both, and never two of them
  /// live at once (see [_enqueue]'s own doc).
  ///
  /// Fase 16.2-R4.2A protocol: [stopVideoRecordingTimeout] bounds this
  /// method's *own internal wait* for the raw native `Future`, but a timeout
  /// no longer means "abandon and detach." Instead:
  ///  * the raw `Future` (`rawFuture` below) is tracked in
  ///    [_pendingNativeStop] the instant it's issued, capturing
  ///    [_PendingNativeStop.startedAt]/[_PendingNativeStop.stoppedAt]/
  ///    [_PendingNativeStop.protectClip] atomically with it — see that
  ///    class's own doc for why each must be captured then, not re-read
  ///    later;
  ///  * on timeout, [_cameraKnownUnavailable] flips true immediately
  ///    (unchanged Fase 16.2 behavior — a caller must not keep trusting this
  ///    camera generation), but THIS method keeps running: it keeps
  ///    awaiting the SAME `rawFuture`, still inside this one [_enqueue]d
  ///    operation, so [_queueTail] — and therefore every later
  ///    `initialize()`/`startLoopRecording()`/`releaseIdleCamera()`/
  ///    `dispose()` — stays blocked until the real result is known (this
  ///    class's own doc, §1 bullet 3);
  ///  * whenever the real result arrives — before or long after the
  ///    deadline — it is processed exactly once: a genuine `XFile` is moved/
  ///    sized/added to [_clips] as normal (see [_finalizeSegmentResult]), a
  ///    genuine error is reported via [errors] instead of being rethrown
  ///    (nothing is listening on this method's own direct caller by then —
  ///    see [stopLoopRecording]'s own doc) and never left as an unhandled
  ///    async error;
  ///  * [_pendingNativeStop] is cleared only once that processing has fully
  ///    finished, in every path (success, late success, or failure) — this
  ///    is what actually releases the [_queueTail] barrier, not the
  ///    deadline itself;
  ///  * [_PendingNativeStop.state] only ever reaches
  ///    [_NativeStopState.completed] once [_finalizeSegmentResult] has
  ///    itself actually finished — reaching that state, per its own doc, is
  ///    a claim that processing is done, not merely that the raw native
  ///    `Future` resolved (Fase 16.2-R4.2A-R1, P3-E fix).
  ///
  /// Fase 16.2-R4.2A-R1 (§9, P2/P3-D fix): [stopVideoRecordingTimeout]
  /// covers the WHOLE operation — the native wait AND the subsequent
  /// [_finalizeSegmentResult] file work — not only the native call in
  /// isolation. A native call that resolves comfortably within the deadline
  /// but whose file processing then runs long is handled exactly like a
  /// native-level timeout: the caller may proceed, [_cameraKnownUnavailable]
  /// flips true, and the real processing keeps running, still owning
  /// [_queueTail], until it genuinely finishes.
  ///
  /// Fase 16.2-R4.3-R2.6.14: for [_FinalizeReason.rotation] the deadline is a
  /// SOFT one. Everything above still holds — the caller may proceed, the raw
  /// `Future` stays owned, [_queueTail] stays blocked, the result is processed
  /// exactly once — except that the overrun is recorded as
  /// [_overdueRotationStop] instead of [_cameraKnownUnavailable]
  /// ([_markDeadlineExceeded]), so a rotation whose stop merely took long can
  /// still continue once it settles ([_doRotateSegment],
  /// [_lateRotationDecision]). This method returns the [_PendingNativeStop] it
  /// issued (`null` when it issued none) for exactly that purpose; the other
  /// two callers ignore the value.
  ///
  /// A fast (within-deadline) native or processing failure that occurs
  /// while [uiSignal] is `null` (this method called directly by
  /// [_doRotateSegment]/[_doReleaseController], not via [stopLoopRecording])
  /// is unaffected: it still propagates normally to this method's own
  /// direct caller, exactly like before Fase 16.2-R4.2A. Either way, the
  /// same failure is also always routed into [_PendingNativeStop
  /// .failVisibleSignal] — see [_PendingNativeStop]'s own doc for why a
  /// listener there always exists regardless.
  ///
  /// [uiSignal], when provided (by [stopLoopRecording]'s own fresh-stop
  /// path only — see its doc for the case where it instead attaches to an
  /// *existing* [_pendingNativeStop] and never calls this method at all),
  /// becomes this operation's [_PendingNativeStop.visibleSignal] itself —
  /// not a second, independent signal.
  ///
  /// [announceStop], when provided (by [stopLoopRecording]'s own
  /// fresh-stop path, by [_onRotationTick] — Fase 16.2-R4.2A-R4, §13/§14 —
  /// or by [_doReleaseController] — shared by [releaseIdleCamera]/[dispose],
  /// Fase 16.2-R4.2A-R2 §7/§8, and by [initialize]'s own internal release of
  /// a prior controller), is completed exactly once, synchronously, the
  /// instant it becomes known
  /// whether this call actually created a [_PendingNativeStop] — with that
  /// operation if it did, or `null` if this segment turned out to need no
  /// stop at all (already abandoned/not recording). This is a narrow,
  /// one-shot handshake, not a general pub/sub: it exists solely so a
  /// caller that itself triggered this stop (rather than discovering one
  /// already in flight) can learn the operation's own real
  /// [_PendingNativeStop.deadlineInstant] instead of guessing one from its
  /// own, potentially microtasks-earlier, call instant — see this class's
  /// own doc, §1 bullet 3, for why even a microtask-scale gap between two
  /// independently-started timers is a real (if narrow) defect, not merely
  /// cosmetic.
  ///
  /// Fase 16.2-R4.2A-R4 (§3-§9): [reason] decides whether
  /// [_cameraKnownUnavailable] being `true` is itself a reason to abandon
  /// the segment WITHOUT attempting `stopVideoRecording()` at all — see
  /// [_FinalizeReason]'s own doc for why only [_FinalizeReason.rotation]
  /// still does. An independent review dynamically reproduced a P1 this
  /// split fixes: a discovery timeout belonging to a completely unrelated
  /// caller (see [_discoverScheduledStop]) used to retroactively make THIS
  /// call — for [_FinalizeReason.explicitStop]/[_FinalizeReason.teardown] —
  /// abandon an actively-recording segment (`controller.value
  /// .isRecordingVideo == true`, already confirmed just above): zero
  /// `stopVideoRecording()` call, zero clip, `controller.dispose()` run
  /// directly over a still-live native Recording. [_cameraKnownUnavailable]
  /// no longer being fed by mere discovery timeouts (see its own doc)
  /// already closes most of that gap; [reason] closes the rest, for the
  /// case where [_cameraKnownUnavailable] is genuinely true (backgrounding,
  /// or a prior native call on this same controller timing out) but the
  /// caller is [_FinalizeReason.explicitStop]/[_FinalizeReason.teardown]
  /// rather than [_FinalizeReason.rotation]: neither of those two triggers
  /// a same-controller restart afterward the way rotation does, so for them
  /// skipping the stop only ever loses a clip — architecturally, it is not
  /// the same-generation-restart-after-a-hung-stop sequence the original
  /// Fase 16.1 crash needed (Fase 16.2-R4.2A-R7, §26: a verifiable claim
  /// about this class's own local control flow, not a hardware-validated
  /// safety claim). This also matches the desired architecture
  /// Fase 16.2 R3-C physically observed (`camera_android_camerax 0.7.4+8`
  /// auto-finalizing a recording once its source goes `INACTIVE`, e.g. on
  /// backgrounding): the public stop is still the mechanism that collects
  /// that already-(or about-to-be-)finalized native Recording, obtains its
  /// `XFile`, and only then lets a fresh generation begin — not a call to
  /// skip. Not itself a claim of physical safety beyond that existing
  /// evidence; hardware validation of this specific path remains pending
  /// (see this class's own doc, §8 limitations).
  Future<_PendingNativeStop?> _doFinalizeCurrentSegment({
    required _FinalizeReason reason,
    Completer<void>? uiSignal,
    _StopIntent? announceStop,
  }) async {
    void announceNoStop() => _publishStopIntent(announceStop, null);

    final controller = _controller;
    if (controller == null || !controller.value.isRecordingVideo) {
      uiSignal?.complete();
      announceNoStop();
      return null;
    }
    // Fase 16.2-R4.2A-R6 (§6/§7/§10/§11/§12, independent review — dynamically
    // reproduced P1): a prior, REAL stopVideoRecording() attempt for THIS
    // EXACT Recording already terminated with an error.
    // `controller.value.isRecordingVideo` staying `true` here is exactly the
    // plugin's own documented behavior in that case (see
    // [_PendingNativeStop]'s own doc) — not evidence a fresh attempt is safe
    // or owed. Applies to every [_FinalizeReason] alike (rotation,
    // explicitStop, teardown): none of them retries without an explicitly
    // proven-safe policy, which this class does not define (see this
    // method's own doc, final paragraph). The original failure was already
    // reported via [errors] exactly once by whichever call first discovered
    // it (see [_reportError]'s own call sites below) — this path must not
    // re-report it, and must not fabricate a clip for a Recording that was
    // never actually collected.
    if (_activeRecordingId != null && _activeRecordingId == _failedStopRecordingId) {
      uiSignal?.complete();
      announceNoStop();
      return null;
    }
    if (reason == _FinalizeReason.rotation && _cameraKnownUnavailable) {
      // Fase 16.2: the app is (or was, since the last background transition)
      // backgrounded with the camera silently revoked, or a prior native
      // call on this same controller already timed out — see
      // _cameraKnownUnavailable. Skip this ROTATION's stop attempt: the very
      // next thing [_doRotateSegment] does afterward is try to START a new
      // recording on this SAME controller (see its own doc) — the exact
      // sequence the original Fase 16.1 crash involved (a hung stop
      // colliding with a later reconfiguration). [_FinalizeReason
      // .explicitStop]/[_FinalizeReason.teardown] deliberately do NOT take
      // this branch (see this method's own doc, Fase 16.2-R4.2A-R4): neither
      // restarts anything afterward, so for them skipping would only lose
      // the clip — it would not be avoiding the same-generation-restart
      // sequence the original crash needed (Fase 16.2-R4.2A-R7, §26:
      // an architectural, verifiable distinction, not a hardware-validated
      // safety claim — see this class's own doc, final paragraph).
      //
      // Fase 16.2-R4.2A-R5 (§23/§24, independent review P2): deliberately
      // does NOT clear [_protectNextFinalizedClip] here — an earlier version
      // did, on the R1-era assumption that rotation declining to stop meant
      // this segment was abandoned for good. It is not: [stopLoopRecording]/
      // [_doReleaseController] still own their own, separate obligation to
      // collect this exact segment (see their own docs) once their turn in
      // [_queueTail] arrives, and MUST still apply this same protect intent
      // when they do — clearing it here would silently strip protection from
      // a clip that is, in fact, still going to be saved. The flag is
      // consumed (read then reset) exactly once, by whichever call below
      // actually issues the real stop for this segment — rotation here, or
      // explicitStop/teardown later — never by this abandon path.
      uiSignal?.complete();
      announceNoStop();
      return null;
    }

    final startedAt = _segmentStartedAt ?? DateTime.now();
    // Captured atomically with the native call below, not read again once
    // it resolves — see [_PendingNativeStop.protectClip]'s own doc. Fase
    // 16.2-R4.2A-R3 (§22 doc fix): a `markClipAsProtected()` call arriving
    // while THIS stop is still pending is never retroactively applied to
    // THIS segment — but it does NOT automatically "belong to whatever
    // comes after" either (an R2-era overclaim corrected here): it is
    // discarded entirely unless [_currentSegmentEligibleForProtection] is
    // true at the moment it arrives (see that getter's own doc — while this
    // stop is pending, it never is). The retroactive half ([clips].last)
    // still applies regardless.
    final protectClip = _protectNextFinalizedClip;
    _protectNextFinalizedClip = false;
    // Stamped *before* stopVideoRecording()'s own await, mirroring exactly
    // how [startedAt]/[_segmentStartedAt] is itself stamped before
    // startVideoRecording()'s await in startLoopRecording() (see DashcamClip
    // .recordedAt's own doc for why that symmetry matters) — Fase 15
    // hardware-testing fix: the original code stamped durationSeconds with a
    // fresh DateTime.now() taken at the very end, *after* both
    // stopVideoRecording()'s own finalize latency and the
    // _moveToClipsDirectory() disk copy of the whole video file had already
    // elapsed, silently inflating every clip's stored duration by that
    // finalize+copy time (confirmed physically: a real recorded clip's
    // stored durationSeconds read consistently ~2s longer than the same
    // file's own actual playable length per VideoPlayerController).
    final stoppedAt = DateTime.now();
    // The single, absolute deadline for the WHOLE operation (native wait +
    // processing) — Fase 16.2-R4.2A-R1 §9. Computed once, from the same
    // instant `stoppedAt` captures, so the two `.timeout()` calls below
    // (one on the native wait, one on the remaining budget for processing)
    // are two views of ONE continuous deadline, never two independent
    // `stopVideoRecordingTimeout`-length timers.
    final deadlineInstant = stoppedAt.add(stopVideoRecordingTimeout);
    final rawFuture = controller.stopVideoRecording();

    final recordingId = _activeRecordingId;
    final producerToken = _activeRecordingToken;
    final pending = _PendingNativeStop(
      id: _nextNativeStopId++,
      controller: controller,
      recordingId: recordingId,
      producerToken: producerToken,
      recordingStartEpoch: _activeRecordingStartEpoch,
      originIntentId: announceStop?.id,
      startedAt: startedAt,
      stoppedAt: stoppedAt,
      protectClip: protectClip,
      deadlineInstant: deadlineInstant,
      descriptor: producerToken is String && recordingId != null
          ? DashcamClipDescriptor.tryCreate(
              sessionId: producerToken,
              recordedAt: startedAt,
              namespace: _clipNamespace,
              recordingId: recordingId,
              durationSeconds: _clipDurationSeconds(startedAt, stoppedAt),
              isProtected: protectClip,
              resolution: _controllerResolution,
              audioEnabled: _controllerAudioEnabled,
            )
          : null,
      visibleSignal: uiSignal,
    );
    _pendingNativeStop = pending;
    // Fase 16.2-R4.3-R2.6.18: remembered past its settlement, where
    // [_pendingNativeStop] is cleared — see [_lastNativeStop].
    _lastNativeStop = pending;
    // Fase 16.2-R4.2A-R2/R3 (§7/§8, §3/§4/§5): publish the operation just
    // created, if anyone is waiting to learn about it (its own caller, via
    // `announceStop`, and/or a later caller that discovered this same
    // announcement synchronously chained ahead of it in _queueTail — see
    // [_pendingStopIntent]'s own doc) — synchronously, before any
    // further await, so they observe its real deadlineInstant instead of an
    // independently-started one.
    _publishStopIntent(announceStop, pending);

    XFile rawFile;
    try {
      // Fase 16.2-R4.2A-R2 (§5 fix): derives from the SAME deadlineInstant
      // computed above, not a fresh stopVideoRecordingTimeout — structurally
      // tying this wait to the one real deadline this operation owns,
      // rather than relying on "these two lines run back-to-back" as an
      // implicit, refactor-fragile invariant.
      rawFile = await rawFuture.timeout(_remainingUntil(deadlineInstant));
    } on TimeoutException {
      // Fase 16.2 — physically confirmed on a Samsung SM-A326B: even a
      // completely normal, foreground, user-initiated stop (no backgrounding
      // involved) can hang here. Root cause, from the native log at the
      // moment it happened: CameraX's own reconnection after a *previous*
      // camera loss is itself unreliable — it can silently drop back to
      // "not streaming" on its own within about a second of reconnecting,
      // with no Dart-visible signal (the same blind spot
      // _cameraKnownUnavailable exists for) — and a later stopVideoRecording()
      // against that half-reconnected state hits the exact native chokepoint
      // the original Fase 16.1 crash did: `Recorder: The source didn't
      // become non-streaming before timeout. Waited 1000ms`, after which the
      // platform call never returns on its own timeline.
      //
      // Fase 16.2-R4.2A: unlike the R1-era version of this branch, this no
      // longer detaches [rawFuture] and returns — see this method's own doc
      // above. [_cameraKnownUnavailable] still flips immediately (a caller
      // must not keep trusting this camera generation past this point), but
      // ownership of [rawFuture] itself is retained below.
      //
      // Fase 16.2-R4.3-R2.6.14: for a ROTATION the overrun is recorded as
      // [_overdueRotationStop] instead — see that field's own doc. The public
      // [cameraKnownUnavailable] reads the same either way from this instant;
      // what differs is what a late SUCCESS leaves behind.
      _markDeadlineExceeded(pending, reason);
      // The caller may proceed now — see this method's own doc and
      // stopLoopRecording()'s doc for why this must happen HERE
      // (synchronously after the state update above), not via a second,
      // independently-timed `.timeout()` racing this same deadline.
      pending.completeVisibleSignal();
      try {
        rawFile = await rawFuture;
      } catch (error) {
        // A late failure, past the point where stopLoopRecording()'s own
        // caller is still listening (the visible signal already completed
        // above) — report instead of leaving it as an unhandled async
        // error.
        pending.state = _NativeStopState.failed;
        // Fase 16.2-R4.2A-R6 (§6/§9/§10): the NATIVE call itself is what
        // failed here (not _finalizeSegmentResult) — record this
        // Recording's identity as terminally failed so a LATER caller does
        // not read controller.value.isRecordingVideo (still true; the
        // plugin never flips it back after a failed stop) as license to
        // issue a second stopVideoRecording() against it.
        _failedStopRecordingId = pending.recordingId;
        // An explicit stop/teardown already set this when its deadline fired;
        // a rotation (Fase 16.2-R4.3-R2.6.14) did not — a stop that ends in an
        // error leaves the generation untrusted in every case.
        _cameraKnownUnavailable = true;
        // Fase 16.2-R4.3-R2 (§45): this Recording's own STOP outcome —
        // recordingResult, never a reason on its own to poison a healthy
        // CURRENT camera.
        _reportError('Finalização nativa da câmera falhou após o prazo de resposta: $error', scope: DashcamServiceErrorScope.recordingResult);
        _clearPendingNativeStop(pending);
        return pending;
      }
      try {
        await _finalizeSegmentResult(rawFile, startedAt: startedAt, stoppedAt: stoppedAt, protectClip: protectClip, pending: pending);
        // Fase 16.2-R4.2A-R1 (P3-E): only now, after processing has itself
        // finished, does this operation actually count as completed.
        pending.state = _NativeStopState.completed;
      } catch (error) {
        // Fase 16.2-R4.2A (§30): a late XFile that arrived but couldn't be
        // processed (e.g. disk I/O failure moving it into place) must not
        // become an unhandled async error either — same reasoning as a late
        // native failure above.
        pending.state = _NativeStopState.failed;
        // Same as the late native failure above (Fase 16.2-R4.3-R2.6.14): a
        // rotation whose clip could not be processed does not restart —
        // exactly what [_doRotateSegment]'s own catch already does when the
        // same failure arrives within the deadline.
        _cameraKnownUnavailable = true;
        // Fase 16.2-R4.3-R2 (§45): clip processing/storage — recordingResult.
        _reportError('Falha ao processar clipe finalizado tardiamente: $error', scope: DashcamServiceErrorScope.recordingResult);
      } finally {
        _clearPendingNativeStop(pending);
      }
      return pending;
    } catch (error, stack) {
      // A genuine, fast (within-deadline) native failure.
      pending.state = _NativeStopState.failed;
      // Fase 16.2-R4.2A-R6 (§6/§10/§11, independent review — dynamically
      // reproduced P1): recorded here, unconditionally, before this
      // propagates to whichever caller is listening — a fast failure must
      // block a retry exactly as reliably as a late one does (§10 fixed
      // above only covers the late path). Previously only the TIMEOUT
      // branches of this method set _cameraKnownUnavailable — this fast
      // path did not, an inconsistency across _doReleaseController's/
      // stopLoopRecording()'s own callers (only _doRotateSegment's own
      // catch happened to set it itself); moving it here, into the one
      // method that actually knows a native call failed, fixes that at the
      // source instead of requiring every caller to remember to.
      _failedStopRecordingId = pending.recordingId;
      _cameraKnownUnavailable = true;
      _clearPendingNativeStop(pending);
      pending.failVisibleSignal(error, stack);
      if (uiSignal == null) {
        // Called directly by _doRotateSegment/_doReleaseController —
        // unchanged existing behavior: rethrow so that direct,
        // still-listening caller sees it.
        rethrow;
      }
      return pending;
    }

    // Resolved within the native-call deadline — but Fase 16.2-R4.2A-R1
    // (§9, P2/P3-D): file processing itself must not be allowed to run
    // unbounded just because the native call was fast. The remaining budget
    // is whatever is left of the SAME deadlineInstant computed above, never
    // a fresh full stopVideoRecordingTimeout.
    final finalizeFuture = _finalizeSegmentResult(rawFile, startedAt: startedAt, stoppedAt: stoppedAt, protectClip: protectClip, pending: pending);
    try {
      await finalizeFuture.timeout(_remainingUntil(deadlineInstant));
      pending.state = _NativeStopState.completed;
      pending.completeVisibleSignal();
      _clearPendingNativeStop(pending);
    } on TimeoutException {
      // The native call was fast, but processing itself exceeded the
      // remaining budget — same "caller may proceed, ownership retained"
      // contract as a native-level timeout (and, Fase 16.2-R4.3-R2.6.14, the
      // same rotation-vs-everything-else split: see [_markDeadlineExceeded]).
      _markDeadlineExceeded(pending, reason);
      pending.completeVisibleSignal();
      try {
        await finalizeFuture;
        pending.state = _NativeStopState.completed;
      } catch (error) {
        pending.state = _NativeStopState.failed;
        // See the late-processing failure of the native-timeout branch above.
        _cameraKnownUnavailable = true;
        // Fase 16.2-R4.3-R2 (§45): clip processing/storage — recordingResult.
        _reportError('Falha ao processar clipe finalizado após o prazo de resposta: $error', scope: DashcamServiceErrorScope.recordingResult);
      } finally {
        _clearPendingNativeStop(pending);
      }
    } catch (error, stack) {
      pending.state = _NativeStopState.failed;
      _clearPendingNativeStop(pending);
      pending.failVisibleSignal(error, stack);
      if (uiSignal == null) rethrow;
    }
    return pending;
  }

  /// The response deadline of [pending] just elapsed with the operation still
  /// unresolved (the native call, or the processing of its file) — the one
  /// place that records it, for both deadline branches of
  /// [_doFinalizeCurrentSegment].
  ///
  /// Fase 16.2-R4.3-R2.6.14: what the overrun MEANS depends on who is waiting.
  /// An explicit stop or a teardown starts nothing afterwards, so the
  /// pre-existing conservative reading stands: this camera generation is not
  /// to be trusted for a new native call ([_cameraKnownUnavailable], until a
  /// fresh [initialize]). A rotation exists to keep recording: there the
  /// overrun only marks the operation as slow ([_overdueRotationStop]) and the
  /// decision is taken when the raw call really settles
  /// ([_lateRotationDecision]).
  void _markDeadlineExceeded(_PendingNativeStop pending, _FinalizeReason reason) {
    pending.state = _NativeStopState.uiDeadlineExceededPending;
    pending.deadlineExceeded = true;
    if (reason == _FinalizeReason.rotation) {
      _overdueRotationStop = pending;
    } else {
      _cameraKnownUnavailable = true;
    }
  }

  /// Moves/sizes/records a genuinely finalized [XFile] into [_clips] and
  /// publishes it — the shared tail of both the within-deadline
  /// and late-resolution paths of [_doFinalizeCurrentSegment] (Fase
  /// 16.2-R4.2A), so a late `XFile` is processed by the exact same code as
  /// a normal one, not a separate, easier-to-drift-out-of-sync copy.
  ///
  /// Fase 16.2-R4.3-R2.5 (§20-§28, independent-review P1-1 — "clip provenance
  /// é first-observer-wins"): [pending] is the stop this segment belongs to —
  /// its captured [_PendingNativeStop.producerToken]/[_PendingNativeStop
  /// .recordingId] (taken atomically when the stop was issued) are stamped
  /// into the clip's own constructor, so producer provenance and public
  /// visibility are ONE synchronous step: there is no `await` between
  /// building the clip (with its provenance) and `_clips.add`, hence no instant
  /// — in particular not the test hook's `await` below — at which a
  /// clip is in [clips] without its producer already known. The reviewer's
  /// reproduction (3/3) sat exactly in that window: the clip was already added,
  /// provenance still absent, and a persistence pass of ANOTHER session, running
  /// outside this class's FIFO during that `await`, adopted it as "new". The
  /// authority is decided here, at the producer, and no consumer's observation
  /// order can change it.
  ///
  /// Fase 16.2-R4.4-R1 (D1): the recording is PROMOTED to its canonical name
  /// ([_PendingNativeStop.descriptor]) by `rename(2)` — the recovery frontier:
  /// from that instant a process death no longer loses the clip, the next
  /// start indexes it — instead of copied to `clip_<ms>.mp4`, which left the
  /// association only in memory until the session's STOP, and a twin in the
  /// cache forever (see [promoteDashcamClip] for the cross-filesystem fallback,
  /// the collision rule and the 0-byte rule). A promotion failure leaves here
  /// exactly as the copy's failure did — the same exception out of this
  /// method, the same `recordingResult` reports and lifecycle consequences in
  /// its callers. A 0-byte recording is not published at all.
  ///
  /// The clip is then announced on [publishedClips], without waiting for
  /// anyone: its index write happens outside this FIFO (`ensureClipIndexed`),
  /// so a slow Hive never delays a camera operation, and the index is written
  /// per SEGMENT, no longer only at the session's STOP. Fase 16.2-R4.4-R2: the
  /// storage quota runs after that write, in the index FIFO — no longer here,
  /// where it used to delete the clip just published whenever one segment was
  /// larger than the quota (D3-Q), and where its failure stopped the recording.
  Future<void> _finalizeSegmentResult(
    XFile rawFile, {
    required DateTime startedAt,
    required DateTime stoppedAt,
    required bool protectClip,
    required _PendingNativeStop pending,
  }) async {
    final directory = await _clipsDirectory();
    final promotion = await promoteDashcamClip(
      sourcePath: rawFile.path,
      directory: directory,
      // Unknown provenance: a name the v1 parser never accepts, so the clip is
      // never indexed (R2.5) — but it is still moved, never copied.
      name: pending.descriptor?.basename ?? 'clip_${_nextLegacyClipMs(legacyClipNowMsForTest?.call() ?? DateTime.now().millisecondsSinceEpoch)}.mp4',
      ops: promotionFileOpsForTest ?? const DashcamClipFileOps(),
    );
    if (promotion == null) {
      _reportError('Gravação vazia (0 bytes) não publicada; o arquivo da câmera foi preservado onde estava', scope: DashcamServiceErrorScope.recordingResult);
      return;
    }
    if (promotion.sourceResidue) {
      _reportError('Clipe publicado por cópia, mas o arquivo da câmera não pôde ser removido', scope: DashcamServiceErrorScope.recordingResult);
    }
    // Test-only: the canonical name exists, nothing else has happened yet — the
    // point a process death after the recovery frontier is simulated at.
    final promoted = afterPromotionHookForTest;
    if (promoted != null) await promoted(promotion.file);

    // Provenance + publication, atomically: the token is part of the clip
    // object itself, and nothing awaits between constructing it and adding it.
    final clip = DashcamClip(
      file: promotion.file,
      recordedAt: startedAt,
      sizeBytes: promotion.sizeBytes,
      durationSeconds: _clipDurationSeconds(startedAt, stoppedAt),
      isProtected: protectClip,
      producerToken: pending.producerToken,
      recordingId: pending.recordingId,
    );
    _clips.add(clip);

    // Test-only: the closest observable point after publication, before ANY
    // later await — see [afterClipPublishedHookForTest].
    final published = afterClipPublishedHookForTest;
    if (published != null) await published(clip);

    // Fase 16.2-R4.4-R2: no quota pass here any more — it runs in the index
    // FIFO, over the disk (`dashcam_storage_quota.dart`), once the clip is
    // indexed. The camera FIFO only publishes.
    if (_clips.contains(clip) && !_publishedClipsController.isClosed) _publishedClipsController.add(clip);
  }

  /// Fase 16.2-R4.4-R1: whole seconds from the START request to the STOP
  /// request — the existing meaning, never negative (a clock set back).
  static int _clipDurationSeconds(DateTime startedAt, DateTime stoppedAt) => max(0, stoppedAt.difference(startedAt).inSeconds);

  /// Fase 16.2-R4.4-R2.1.1-REG-2: the value of the latest legacy name. Static,
  /// like the directory those names live in: every service of this isolate
  /// publishes into the same `dashcam_clips/`, so a new instance must not start
  /// over. Not persisted: after a process restart with the clock set back, a
  /// name can still be taken, and the promotion refuses it without overwriting.
  static int _lastLegacyClipMs = 0;

  /// Fase 16.2-R4.4-R2.1.1-REG-2: two recordings finishing within the same
  /// millisecond got the same `clip_<ms>.mp4`, and the second stayed unpublished
  /// ([DashcamClipCollision]). Strictly increasing whatever the clock does, and
  /// synchronous, so no concurrent caller can read the same value. The result
  /// only names the file and may run ahead of the clock: `recordedAt` stays the
  /// real start of the recording.
  static int _nextLegacyClipMs(int nowMs) => _lastLegacyClipMs = max(nowMs, _lastLegacyClipMs + 1);

  /// Fase 16.2-R4.4-R1: every clip this service has published, once its
  /// finalize is over (see [_finalizeSegmentResult]). Broadcast and asynchronous:
  /// delivered after the operation returned. `DashcamSessionController` indexes
  /// each one. Never closed (like [cameraKnownUnavailableListenable]): a
  /// listener cancels its own subscription, and a clip published after the last
  /// one did simply reaches nobody — its canonical file is indexed by the late
  /// STOP pass or by the next start.
  Stream<DashcamClip> get publishedClips => _publishedClipsController.stream;
  final StreamController<DashcamClip> _publishedClipsController = StreamController<DashcamClip>.broadcast();

  /// Fase 16.2-R4.4-R1: test-only — replaces filesystem operations of the
  /// promotion ([promoteDashcamClip]) to fail exactly at one of them.
  @visibleForTesting
  DashcamClipFileOps? promotionFileOpsForTest;

  /// Fase 16.2-R4.4-R2.1.1-REG-2: test-only — the clock of the legacy clip name,
  /// so a repeated or regressive millisecond needs no waiting on the real one.
  @visibleForTesting
  int Function()? legacyClipNowMsForTest;

  /// Fase 16.2-R4.4-R1: test-only, awaited right after a recording got its
  /// canonical name and before the clip is published or announced — where a
  /// test kills the process just past the recovery frontier.
  @visibleForTesting
  Future<void> Function(File canonicalFile)? afterPromotionHookForTest;

  /// Fase 16.2-R4.3-R2.5 (§35/§36, X24/X25): an OPTIONAL test seam invoked
  /// synchronously right after [clip] becomes visible in [clips] and before it
  /// is announced (until Fase 16.2-R4.4-R2: before the in-FIFO quota pass's
  /// first `await`) — the exact window the independent reviewer exploited. A test may observe [clips]/[DashcamClip.producerToken]
  /// at that instant, and may hold this call open to force another consumer to
  /// run while the clip is visible but this operation has not finished. `null`
  /// (the default) means zero behavior change — the production path is
  /// byte-for-byte the same.
  @visibleForTesting
  Future<void> Function(DashcamClip clip)? afterClipPublishedHookForTest;

  /// Fase 16.2-R4.4-R1: `dashcam_clips/`, resolved and created ONCE per
  /// instance (started by the constructor) — it used to be resolved through
  /// path_provider for every clip, a platform-channel call inside the camera
  /// FIFO, between the moment the recording's path arrives and the moment it is
  /// promoted (the window a process death loses the clip in: D2). A failed
  /// resolution is forgotten, so the next clip tries again.
  Future<Directory> _clipsDirectory() => _clipsDirectoryResolution ??= _resolveClipsDirectory();

  Future<Directory>? _clipsDirectoryResolution;

  Future<Directory> _resolveClipsDirectory() async {
    try {
      final directory = await dashcamClipsDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return directory;
    } catch (_) {
      _clipsDirectoryResolution = null;
      rethrow;
    }
  }

  /// Marks the current clip as protected, so quota enforcement will never
  /// delete it — called when a high/critical-severity event is detected.
  ///
  /// A just-fired event almost always falls inside the segment that's
  /// *currently recording*, not yet finalized into [clips] (segments rotate
  /// every [segmentDuration], typically minutes; events resolve in
  /// milliseconds to a few seconds). Marking only [clips].last would
  /// therefore protect the wrong, usually-irrelevant *previous* segment
  /// while leaving the one that actually contains the event exposed to
  /// deletion. This marks both: [clips].last retroactively (covers the rare
  /// case the event landed right at a segment boundary), and sets a flag so
  /// the segment currently being recorded is also marked protected the
  /// moment it finalizes — or, if that segment is instead abandoned (camera
  /// lost, or a native call timed out), the flag is cleared rather than
  /// silently carried forward (see [_doFinalizeCurrentSegment]'s own doc,
  /// Fase 16.2-R1 P2).
  ///
  /// Fase 16.2-R4.2A-R1 (P2-B/§15/§16) first closed this for the case where
  /// [_pendingNativeStop] is non-null. Fase 16.2-R4.2A-R2 (§13/§14) closed a
  /// second, wider gap an independent review found: once that stop resolves
  /// and [_pendingNativeStop] clears, the camera can remain in a
  /// **recovery gap** — known-unavailable, no new segment started yet — for
  /// an arbitrary stretch of real time before a fresh [initialize]/
  /// [startLoopRecording] (segment B) begins. An event landing in that gap
  /// must not silently arm [_protectNextFinalizedClip] either, or it would
  /// still leak onto B, an unrelated future recording — checking
  /// [_pendingNativeStop] alone is not sufficient. See
  /// [_currentSegmentEligibleForProtection]'s own doc for the actual
  /// condition. Arming this field here would silently attach to whichever
  /// segment starts *next* (see [_PendingNativeStop.protectClip]'s own doc
  /// for the analogous reasoning on the pending-stop side), not to the one
  /// the event actually concerned. The retroactive half ([clips].last)
  /// still applies normally in every case.
  Future<void> markClipAsProtected() async {
    if (_clips.isNotEmpty) {
      _clips.last.isProtected = true;
    }
    if (!_currentSegmentEligibleForProtection) {
      return;
    }
    _protectNextFinalizedClip = true;
  }

  /// True only when a real segment is genuinely, currently capturing frames
  /// — the sole condition under which [markClipAsProtected] may arm
  /// [_protectNextFinalizedClip] (Fase 16.2-R4.2A-R2, §14). Deliberately the
  /// narrowest combination of already-existing signals, not a new state
  /// machine:
  ///  * [_isRecording] — the loop's own intent must still be active (not
  ///    stopped, not disposed);
  ///  * [_cameraKnownUnavailable] must be `false` — this is what actually
  ///    covers the "gap between A and recovery B" case: a timed-out stop
  ///    (this doc's own §1 bullet 3) leaves this `true` until a fresh
  ///    [initialize] succeeds, spanning exactly the window where A has
  ///    resolved but B has not yet started;
  ///  * [_pendingNativeStop] must be `null` — the original R1 condition,
  ///    still necessary: nothing can be "currently recording" while a stop
  ///    for it is unresolved (controller.value.isRecordingVideo alone
  ///    cannot distinguish this, since the camera plugin only flips it once
  ///    the native stop itself resolves — see [_PendingNativeStop]'s own
  ///    doc);
  ///  * the controller must exist and the plugin must itself confirm
  ///    `isRecordingVideo` — the actual, native source of truth, not merely
  ///    this class's own intent flags.
  bool get _currentSegmentEligibleForProtection {
    final controller = _controller;
    return !_disposed &&
        _isRecording &&
        !_cameraKnownUnavailable &&
        _pendingNativeStop == null &&
        controller != null &&
        controller.value.isRecordingVideo;
  }

  /// Fase 16.2-R4.4-R2: forgets the clips whose files the storage quota has
  /// just evicted (`runDashcamQuotaPass`, in the index FIFO — this class no
  /// longer enforces any quota). Synchronous: a clip evicted takes its
  /// provenance ([DashcamClip.producerToken]) with it in one step, and nothing
  /// left in [clips] names a file that is gone. [clips] is not the quota's
  /// authority — the disk is — but what still references it (a session's
  /// persistence baseline, the controller's provenance claims) stays bounded
  /// by the clips that exist.
  void forgetClips(Set<String> paths) {
    if (paths.isEmpty) return;
    _clips.removeWhere((clip) => paths.contains(clip.file.path));
  }

  // ===========================================================================
  // Release / dispose
  // ===========================================================================

  /// Releases whatever [CameraController] is currently held (a no-op if
  /// none is). Best-effort finalizes a currently-recording segment first
  /// (properly moving/sizing/indexing it, same as a normal
  /// [stopLoopRecording]) rather than bare-calling `stopVideoRecording()`
  /// and discarding the returned file, so a mid-recording teardown (e.g.
  /// widget-tree disposal without process death) doesn't silently lose the
  /// in-flight segment. Wrapped so a finalize failure never blocks
  /// releasing the hardware.
  ///
  /// Fase 16.2-R1: this is the *native-touching* half only — always called
  /// either as the [_enqueue]d operation itself ([releaseIdleCamera]) or
  /// directly from within another already-[_enqueue]d operation
  /// ([initialize]/[dispose]'s own queued work) — never both, per
  /// [_enqueue]'s own doc. The synchronous intent prefix
  /// (`_segmentTimer?.cancel(); _isRecording = false;`) lives in each of
  /// those three public callers instead of here, so it takes effect
  /// immediately regardless of how long this method's own turn in the queue
  /// takes to arrive.
  ///
  /// [announceStop], when provided (by [releaseIdleCamera]/[dispose] only —
  /// Fase 16.2-R4.2A-R2 §7/§8), is forwarded to [_doFinalizeCurrentSegment]
  /// and additionally completed with `null` here directly, in the two paths
  /// that never even reach that call (no controller held, or the held
  /// controller isn't recording) — so the caller learns "no stop was
  /// needed" just as promptly as "here is the stop that was created."
  /// Fase 16.2-R4.3-R2.2 (§25-§27, independent-review P2 — "targeted cleanup
  /// na FIFO"): [expectedController], if given, is re-validated a SECOND
  /// time HERE — the instant this closure actually begins running, not only
  /// once, early, by [releaseIdleCamera] before it was even enqueued — see
  /// [beginStopLoopRecording]'s own identical doc for the exact race this
  /// closes. A mismatch here is a silent no-op over whatever controller is
  /// CURRENT now; it must never dispose a newer generation's own controller
  /// on a stale caller's behalf.
  Future<_ReleaseDisposition> _doReleaseController({_StopIntent? announceStop, CameraController? expectedController}) async {
    final controller = _controller;
    if (expectedController != null && !identical(controller, expectedController)) {
      _publishStopIntent(announceStop, null);
      return _ReleaseDisposition.targetMismatch;
    }
    if (controller != null) {
      if (controller.value.isRecordingVideo) {
        try {
          await _doFinalizeCurrentSegment(reason: _FinalizeReason.teardown, announceStop: announceStop);
        } catch (error) {
          // Fase 16.2-R4.3-R2 (§45): the outgoing camera's own clip finalize
          // — recordingResult, not a fact about the incoming controller.
          _reportError('Falha ao finalizar clipe ao trocar de câmera: $error', scope: DashcamServiceErrorScope.recordingResult);
        }
      } else {
        _publishStopIntent(announceStop, null);
      }
      controller.removeListener(_onControllerValueChanged);
      await controller.dispose();
    } else {
      _publishStopIntent(announceStop, null);
    }
    // Fase 16.2-R1 (P1-3): only clear _controller if nothing else already
    // replaced it. In practice nothing ever does — every write to
    // _controller goes through this same serialized queue — but this keeps
    // the invariant explicit rather than assumed.
    if (identical(_controller, controller)) {
      _controller = null;
    }
    return _ReleaseDisposition.released;
  }

  /// Releases the camera hardware once a session has ended and none is
  /// about to start — unlike [dispose], this [DashcamService] instance stays
  /// fully alive and reusable (its [errors] stream stays open, and the very
  /// next [initialize] call works exactly as normal; [_doReleaseController]
  /// is itself idempotent/a no-op if nothing is currently held).
  ///
  /// Fase 15 hardware-testing fix: before this existed, the controller
  /// created by a session's [initialize] call was left held open for the
  /// *rest of the app process's lifetime* once that session ended, if no
  /// further session ever started. Confirmed physically via
  /// `adb shell dumpsys media.camera`: this app's own idle, held-open
  /// camera-0 client was directly, repeatedly blocking an unrelated system
  /// service (Samsung's own adaptive-brightness component) from opening a
  /// *different* camera on the same device, logged by the platform's own
  /// camera service as "Too many cameras already open" — a real,
  /// externally-visible resource cost, not just a theoretical one.
  ///
  /// Fase 16.2-R4.2A (§19): if a native stop is still pending (see
  /// [_pendingNativeStop]), this call does NOT itself dispose the
  /// controller concurrently with it, and does NOT block the caller
  /// indefinitely waiting for it either — the returned [Future] resolves no
  /// later than the pending stop's own deadline, while
  /// [_doReleaseController]'s real `controller.dispose()` call only runs
  /// once the pending stop's own [_enqueue]d operation has fully returned
  /// (this class's own doc, §1 bullet 3).
  ///
  /// Fase 16.2-R4.2A-R1 (§8/§12) first tried bounding this by the REMAINING
  /// time on the existing stop's own [_PendingNativeStop.deadlineInstant]
  /// via a second, independently-computed `.timeout()` call. Fase
  /// 16.2-R4.2A-R2 (§4/§10) found that still reproduces the exact class of
  /// race this whole protocol exists to close: two separately-scheduled
  /// `Timer`s "aimed at" the same instant have no guaranteed relative firing
  /// order, so this call could regain control *before*
  /// [_doFinalizeCurrentSegment] itself had actually set
  /// [_cameraKnownUnavailable] — caught by this class's own §25 regression
  /// test. [_awaitTeardown] now derives entirely from the stop's own
  /// [_PendingNativeStop.visibleSignal] instead of any independently-timed
  /// wait — see its own doc for the full reasoning, including why that
  /// alone is not sufficient either (a naive await/race on `visibleSignal`
  /// would return *before* the real teardown runs in the fast-resolution
  /// case — this class's own "dispose during rotation" regression test
  /// exists specifically to catch that).
  ///
  /// Fase 16.2-R4.2A-R2 (§7/§8): when no stop is pending YET, this call's
  /// own [_doReleaseController] may still create one (if a segment happens
  /// to be recording) — learned via a small handshake ([_awaitTeardown]'s
  /// own `announceStop` parameter) rather than assumed from this call's own
  /// instant, which is a *different* instant than the one the stop itself
  /// computes once it actually starts (see [_PendingNativeStop
  /// .deadlineInstant]'s own doc).
  ///
  /// Fase 16.2-R4.2A-R3 (§3/§4/§5): that handshake is now the SHARED
  /// [_pendingStopIntent] (via [_claimStopIntent]) rather than a
  /// private one — if [stopLoopRecording] (or a previous call to this
  /// method/[dispose]) already scheduled a stop-creating operation ahead of
  /// this call in [_queueTail], this reuses and discovers THAT SAME
  /// announcement instead of wrongly concluding no stop is coming at all
  /// (this class's own doc §1 bullet 3, and [_pendingStopIntent]'s
  /// own doc, for the exact race this closes).
  /// Fase 16.2-R4.3-R2 (§28, independent-review P2-B fix — "targeted
  /// cleanup"): [expectedController], if given, makes this call a NO-OP
  /// (checked BEFORE any of this method's own mutation, below) unless it
  /// still matches the CURRENT controller — see [stopLoopRecording]'s own
  /// identical doc for the full reasoning. `null` (the default) is this
  /// method's pre-existing, unqualified behavior.
  Future<void> releaseIdleCamera({CameraController? expectedController}) {
    if (expectedController != null && !identical(_controller, expectedController)) {
      return Future<void>.value();
    }
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _isRecording = false;
    final existing = _pendingNativeStop;
    if (existing != null) {
      final queued = _observeTeardown(_enqueue(() => _doReleaseControllerAndOwnership(expectedController: expectedController)));
      return _awaitTeardown(existingStop: existing, queued: queued);
    }
    final announceStop = _claimStopIntent(_StopPurpose.release, expectedController: expectedController);
    final queued = _observeTeardown(
      _enqueue(() => _doReleaseControllerAndOwnership(announceStop: announceStop, expectedController: expectedController)),
    );
    return _awaitTeardown(announceStop: announceStop, queued: queued);
  }

  /// Fase 16.2-R4.2B-R1 (§12/§13/§14): [_doReleaseController] plus the
  /// process-ownership decision that belongs at every TOP-LEVEL call site
  /// (as opposed to [initialize]'s own internal, pre-reinit call, which
  /// must NOT release ownership between releasing the old controller and
  /// immediately building a new one — see [initialize]'s own doc). Reached
  /// only on [_doReleaseController]'s own success (a throw skips past this
  /// entirely, leaving ownership exactly where fail-closed, §14, requires
  /// it to stay) — [_DashcamProcessOwner.release] is itself idempotent, so
  /// this is safe to call even when [_controller] was already `null`.
  Future<void> _doReleaseControllerAndOwnership({_StopIntent? announceStop, CameraController? expectedController}) async {
    _ReleaseDisposition disposition;
    try {
      disposition = await _doReleaseController(announceStop: announceStop, expectedController: expectedController);
    } catch (_) {
      _DashcamProcessOwner.markUncertain(_processOwnerToken);
      rethrow;
    }
    // Fase 16.2-R4.3-R2.3 (§14-§18, independent-review P1-B exact
    // reproduction — "targeted release libera process owner de G2"):
    // ownership is only ever this call's to release when [disposition]
    // confirms its own real work is what left the service without a
    // controller. A [_ReleaseDisposition.targetMismatch] means a NEWER
    // controller (G2) is still current, untouched, still alive — releasing
    // [_DashcamProcessOwner] here would reopen physical camera exclusivity
    // to a second service while G2 is still genuinely open, exactly the gap
    // the reviewer reproduced. The decision now crosses the boundary this
    // method itself represents, instead of stopping at [_doReleaseController]'s
    // own local no-op.
    if (disposition == _ReleaseDisposition.released) {
      _DashcamProcessOwner.release(_processOwnerToken);
    }
  }

  /// Fase 16.2-R4.2A-R2/R3 (§4/§6/§7/§8/§9/§10/§15), extended in
  /// Fase 16.2-R4.2A-R5 (§1/§6) to [stopLoopRecording] too: shared by
  /// [releaseIdleCamera]/[dispose]/[stopLoopRecording] to wait for their own
  /// real, already-enqueued obligation ([queued] — already wrapped by
  /// [_observeTeardown] at its call site, so it is observed for errors from
  /// the instant it is created, regardless of which branch below returns
  /// without itself awaiting it further) without ever starting a second,
  /// independently-timed deadline for a stop that already has (or will
  /// have) one of its own. This method only ever bounds how long ITS OWN
  /// CALLER waits — it never defines [queued]'s real lifetime, and never
  /// itself releases [_queueTail] (that remains [_doFinalizeCurrentSegment]'s
  /// own doing, unconditionally). Critically (Fase 16.2-R4.2A-R5, §1): this
  /// method never treats [announceStop] resolving to `null` as its OWN
  /// caller's obligation being satisfied — `null` only ever describes what
  /// the DISCOVERED producer decided; [queued] — this caller's own real
  /// work — is what [queued] is for, and it is always awaited (bounded) on
  /// that `null` path, never skipped.
  ///
  /// Exactly one of [existingStop] (a stop already known when this call
  /// started) or [announceStop] (the shared [_pendingStopIntent],
  /// completed either by [_doFinalizeCurrentSegment] once it becomes known
  /// whether a stop-creating operation ahead of THIS call's own
  /// [_doReleaseController] in [_queueTail] created one, or by
  /// [_doReleaseController]'s own call within it) is provided.
  ///
  ///  * If [announceStop] is given and [existingStop] is not, this first
  ///    discovers whichever [_PendingNativeStop] (if any) that announcement
  ///    resolves to via [_discoverScheduledStop] — bounded by
  ///    [stopVideoRecordingTimeout] purely as a presentation deadline for
  ///    the DISCOVERY itself (this class's own doc, §6): not a fresh stop's
  ///    deadline, since none is known to exist yet. If that discovery times
  ///    out, [_armDiscoveryUncertainty] is called (Fase 16.2-R4.2A-R5:
  ///    deliberately not [_cameraKnownUnavailable], see that field's own
  ///    doc) and this returns immediately — [queued] is NOT awaited further
  ///    here (it is still observed, via [_observeTeardown], and keeps
  ///    running regardless, still able to genuinely collect an existing
  ///    Recording once it reaches its own turn — see
  ///    [_doFinalizeCurrentSegment]'s own doc for why a mere discovery
  ///    timeout must never suppress that). Critically, [announceStop]
  ///    resolving to `null` here does NOT mean this method is done either
  ///    (Fase 16.2-R4.2A-R5, §1: an announcement result only ever describes
  ///    what its OWN producer decided, never this caller's own obligation) —
  ///    see the `stop == null` branch immediately below, which still falls
  ///    through to [queued]: THIS caller's own real work, already enqueued
  ///    regardless of what any earlier producer decided.
  ///  * Once the relevant [_PendingNativeStop] is known (or confirmed, not
  ///    merely timed out, to not exist):
  ///     * if none exists, [queued] is awaited with a fresh
  ///       [stopVideoRecordingTimeout] of its own — a legitimate "teardown
  ///       without a Recording" deadline (this class's own doc, §9), not a
  ///       duplicate of any stop's deadline;
  ///     * otherwise, this awaits that stop's own
  ///       [_PendingNativeStop.visibleSignal] DIRECTLY (Fase
  ///       16.2-R4.2A-R3 §24 doc fix: yes, directly — an R2-era doc here
  ///       claimed this class never does) — the same completer
  ///       [_doFinalizeCurrentSegment] itself completes, so
  ///       [_cameraKnownUnavailable] is *guaranteed* already updated by the
  ///       time this resumes, if the deadline is what fired it (no
  ///       independent timer involved at all, closing the R1-era race). If
  ///       that state turns out to be
  ///       [_NativeStopState.uiDeadlineExceededPending], this returns
  ///       immediately without waiting on [queued] further (ownership is
  ///       retained regardless; the real teardown keeps running behind
  ///       it, still observed). Otherwise (the stop's own native+processing
  ///       work finished fast, successfully or not), [queued] itself is
  ///       *not* necessarily done yet — `controller.dispose()` is still its
  ///       own, separate step — so this waits for it too, bounded
  ///       defensively by a fresh [stopVideoRecordingTimeout] (should be
  ///       near-instant in practice: at this point the stop's own work is
  ///       the only thing that could have been slow, and it just
  ///       finished).
  Future<void> _awaitTeardown({
    _PendingNativeStop? existingStop,
    _StopIntent? announceStop,
    required Future<void> queued,
  }) async {
    var stop = existingStop;
    if (stop == null && announceStop != null) {
      try {
        stop = await _discoverScheduledStop(announceStop);
      } on TimeoutException {
        _armDiscoveryUncertainty(queued);
        return;
      }
    }
    if (stop == null) {
      await queued.timeout(stopVideoRecordingTimeout, onTimeout: () {});
      return;
    }
    try {
      await stop.visibleSignal;
    } catch (_) {
      // A fast native/processing failure — already handled/reported inside
      // _doFinalizeCurrentSegment itself (see its own doc). Nothing further
      // to do with the error here; fall through to wait for the real
      // teardown below, same as a fast success.
    }
    if (stop.state == _NativeStopState.uiDeadlineExceededPending) {
      return;
    }
    await queued.timeout(stopVideoRecordingTimeout, onTimeout: () {});
  }

  /// Releases the camera hardware for good (see [_doReleaseController]) and
  /// closes [errors] — call only when this [DashcamService] itself is being
  /// torn down (app/widget-tree disposal). Terminal (Fase 16.2-R1, see
  /// [_disposed]'s own doc): a *new* session starting after this must go
  /// through a brand new [DashcamService] instance, not reuse this one — a
  /// future [initialize] call on this instance throws instead of silently
  /// reopening a camera on a service whose [errors] stream is already
  /// closed. [_disposed] itself is set synchronously above, so that check
  /// takes effect immediately — it does not wait for anything below.
  ///
  /// Fase 16.2-R4.2A (§22): if a native stop is still pending, this call
  /// does NOT dispose the controller concurrently with it (see
  /// [releaseIdleCamera]'s own doc — the same reasoning, including the
  /// R4.2A-R2/R3 fixes [_awaitTeardown]/[_observeTeardown]/
  /// [_claimStopIntent] provide, applies here identically), and does
  /// NOT itself block indefinitely. [errors] is deliberately closed only
  /// once the real teardown (after any pending stop resolves) has run,
  /// never before: closing it earlier could make a late result's own
  /// [_reportError] call — including [_observeTeardown]'s own, for a late
  /// `controller.dispose()` failure — write to an already-closed stream.
  /// Deliberately NOT wrapped in its own `try`/`finally` to force-close
  /// [errors] even when [_doReleaseController] itself fails: doing so would
  /// close the stream before [_observeTeardown]'s error report below could
  /// ever reach it, silently losing that report instead of merely leaving
  /// [errors] open a little longer (harmless — nothing else writes to it
  /// once this instance is terminal).
  Future<void> dispose() {
    _disposed = true;
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _isRecording = false;
    final existing = _pendingNativeStop;
    if (existing != null) {
      final queued = _observeTeardown(_enqueue(() async {
        await _doReleaseControllerAndOwnership();
        await _errorsController.close();
        await _originatedErrorsController.close();
      }));
      return _awaitTeardown(existingStop: existing, queued: queued);
    }
    final announceStop = _claimStopIntent(_StopPurpose.release);
    final queued = _observeTeardown(_enqueue(() async {
      await _doReleaseControllerAndOwnership(announceStop: announceStop);
      await _errorsController.close();
      await _originatedErrorsController.close();
    }));
    return _awaitTeardown(announceStop: announceStop, queued: queued);
  }

  /// Fase 16.2-R4.2A-R1: `Duration.timeout()` rejects a negative
  /// [Duration] — clamps to [Duration.zero] (fire immediately) when
  /// [instant] has already passed, e.g. a pending stop whose own deadline
  /// elapsed slightly before [releaseIdleCamera]/[dispose] was called.
  Duration _remainingUntil(DateTime instant) {
    final remaining = instant.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }
}
