import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/dashcam_clip_descriptor.dart';
import '../models/dashcam_clip_record.dart';
import '../models/driving_session.dart';
import 'dashcam_clip_files.dart';
import 'driving_session_recorder.dart' show discardClipFilesOfDeletedSession, sessionDeletionCommitted;
import 'hive_boxes.dart';

/// Fase 16.2-R4.4-R1 — the dashcam clip index (`dashcam_session_videos`) and its
/// ONE writer (design closure
/// `scratchpad/fase16_2_r4_4_r1_d1_design_closure/FECHAMENTO_DESIGN_R4_4_R1.md`,
/// INDEXING PROTOCOL / ENSURE INDEXED / STARTUP RECONCILIATION).
///
/// D1 (R4.4-D0, P1): the index used to be written once per session, at its STOP
/// — a process killed at any point of a session lost the association of every
/// clip it had recorded (the files stayed, nameless, forever). Now every clip
/// is published under a canonical name that says whose it is
/// ([DashcamClipDescriptor]); that FILE is the durable obligation, and this
/// module discharges it, the same way from every place:
///  * [ensureClipIndexed] — the single writer of the index (the session
///    deletion only ever removes a key). Called for every published segment, by
///    the STOP's passes, after a protection, and by the startup;
///  * [reconcileCanonicalClipsAtStartup] — once per process, before the UI:
///    every canonical file of `dashcam_clips/` through [ensureClipIndexed].
///
/// R4.4-R1 guarantees that every clip that REACHED `dashcam_clips/` under its
/// canonical name is indexed exactly once in its session, if that session
/// exists and is not deleted. It does not recover video whose process died
/// before that publication — that remains D2 (R4.4-D0).
///
/// The index holds only clips: nothing here writes `driving_sessions`, ends or
/// finalizes a session, touches an end time, a checkpoint or a telemetry
/// outcome (R2.6.11–R2.6.13 stay the recorder's).
///
/// Fase 16.2-R4.4-R2: [ensureClipIndexed] is still the one writer that ADDS to
/// the index (an entry, or a protection). Entries are removed only by the
/// session deletion (its whole key) and by the storage quota
/// (`dashcam_storage_quota.dart`: an evicted clip's entry after its file is
/// gone, and at startup a v1 entry whose file is gone) — the quota's writes run
/// as turns of the same FIFO ([runInClipIndexQueue]).

/// Who asks [ensureClipIndexed] to index a clip — it decides the deletion guard.
enum ClipIndexOrigin {
  /// Published by this process's `DashcamService`. Only a COMMITTED deletion
  /// ([sessionDeletionCommitted]) refuses it: a session whose record is merely
  /// absent (a START whose put failed — frozen X98) or whose deletion failed at
  /// its marker (frozen X113) still gets its clip.
  producedInThisProcess,

  /// Found in `dashcam_clips/` at startup. Indexed only for a session whose
  /// record EXISTS and is NOT marked for deletion — read from the box the boxes
  /// were just loaded from, i.e. from disk. An absent record is an orphan: it
  /// cannot be told apart from a session whose deletion completed (the marker
  /// is the record, removed last).
  recovered,
}

/// What [ensureClipIndexed] did. It never throws.
enum ClipIndexOutcome {
  /// Inserted now (the write returned).
  indexed,

  /// Already there under its own session, by its canonical name: nothing
  /// written.
  alreadyIndexed,

  /// Already there; its protection went from `false` to `true` (written).
  protectionRaised,

  /// No regular file under that path (evicted by the quota, deleted): nothing
  /// written.
  notPresent,

  /// A 0-byte file: never indexed.
  emptyPreserved,

  /// Not a canonical v1 name: never indexed (nor deleted).
  invalidName,

  /// [ClipIndexOrigin.producedInThisProcess] — the session's deletion is
  /// committed: not indexed, and the file is discarded (R2.6.7).
  deletionRefused,

  /// [ClipIndexOrigin.recovered] — the session has no record: not indexed, not
  /// deleted, not attributed to anyone, no session created (R4.4-R3 decides).
  orphanPreserved,

  /// [ClipIndexOrigin.recovered] — the session is marked for deletion (or its
  /// deletion is committed): left to the deletion, which removes it.
  deletionBlocked,

  /// The clip's identity is already taken by ANOTHER name — in this session or
  /// another — or its entry's immutable fields disagree with its name: nothing
  /// written, nothing re-attributed, reported once.
  identityConflict,

  /// The write failed (or the boxes are not open). The file stays the
  /// obligation: the next in-process trigger retries, the next start replays.
  indexPending,
}

/// The test seam that used to wrap `DashcamSessionController`'s own write
/// (`persistClipIndexHookForTest`, same signature): called with the session,
/// the clip's path and the real write, which the hook must call itself. The
/// write re-decides everything in its own synchronous slice when called.
typedef ClipIndexWriteHook = Future<void> Function(String sessionId, List<String> clipPaths, Future<void> Function() writeCall);

/// Process-wide counters of the index — R4.4-R1's minimal observability (no
/// paths, no ids). Read with [snapshot].
class DashcamClipIndexCounters {
  DashcamClipIndexCounters._();

  static final Map<ClipIndexOutcome, int> _outcomes = {};
  static int sizeDivergences = 0;

  static int of(ClipIndexOutcome outcome) => _outcomes[outcome] ?? 0;

  static Map<String, int> snapshot() => {
    for (final outcome in ClipIndexOutcome.values) outcome.name: of(outcome),
    'sizeDivergences': sizeDivergences,
  };

  static void _count(ClipIndexOutcome outcome) => _outcomes[outcome] = of(outcome) + 1;

  @visibleForTesting
  static void resetForTest() {
    _outcomes.clear();
    sizeDivergences = 0;
  }
}

/// The tail of the process-wide FIFO of index writes — separate from the camera
/// FIFO of `DashcamService` (nothing here is ever awaited by a camera
/// operation) and from the recorder. One write at a time: the next call reads
/// the index only once the previous write has SETTLED, so what it reads in
/// memory is what Hive took as written (a write that failed inside
/// `writeFrames` is rolled back from memory; one that wrote its frame and then
/// failed, R2.6.5, is on disk). Without it, two transactions in flight on one
/// key would make Hive's cancellation semantics part of the argument. The
/// argument assumes a single isolate writing the index; it must be redone if
/// another isolate or process ever does.
Future<void> _indexQueueTail = Future<void>.value();

/// Fase 16.2-R4.4-R2 — runs [job] as ONE whole turn of the index FIFO: after
/// every index write queued before it has settled, and before any queued after
/// it starts. The storage quota (`dashcam_storage_quota.dart`) runs its passes
/// here — scan, decisions, file deletions and the removal of evicted entries —
/// so an eviction can never interleave with an [ensureClipIndexed] (an
/// indexing, a protection raise) or another pass: there is one serialization of
/// the index and of what it says about the clip files, never a second one, and
/// never the camera FIFO's. The turn ends when [job] has settled; its error is
/// [job]'s caller's.
Future<T> runInClipIndexQueue<T>(Future<T> Function() job) {
  final turn = Completer<void>();
  final previous = _indexQueueTail;
  _indexQueueTail = turn.future;
  final outcome = Completer<T>();
  unawaited(
    previous.then((_) async {
      try {
        outcome.complete(await job());
      } catch (error, stackTrace) {
        outcome.completeError(error, stackTrace);
      } finally {
        turn.complete();
      }
    }),
  );
  return outcome.future;
}

/// Failures already reported, by kind and clip id — each is reported once per
/// process: a persistent failure seen by every trigger of every pass (segment,
/// STOP, late STOP) is ONE report per clip (frozen X26, X28).
final Set<String> _reported = {};

/// Fase 16.2-R4.4-R1 — makes the canonical clip at [clipPath] present, exactly
/// once, in the index of the session its NAME carries — never of a session a
/// caller passes. Idempotent: called N times for one clip, by any mix of
/// callers, it leaves one entry.
///
/// Queued in the process FIFO of index writes; on its turn:
///  1. the name is parsed ([DashcamClipDescriptor.parse]) — not canonical →
///     [ClipIndexOutcome.invalidName];
///  2. for [ClipIndexOrigin.recovered], the session record is checked before
///     anything is read from disk (an orphan costs a name, a parse and one
///     lookup in a box already in memory);
///  3. the file is `lstat`ed: not a regular file → [ClipIndexOutcome
///     .notPresent], 0 bytes → [ClipIndexOutcome.emptyPreserved];
///  4. in ONE synchronous slice, with no `await` in between: the deletion guard
///     of [origin], the identity check, the CURRENT entry list of the session
///     (never a copy read before an await), the merge, and the `put`:
///     * the same name already there → nothing written, except that a
///       protection asked for ([protectedNow], or the name's own) raises the
///       entry's `isProtected` from false to true — protection only ever goes
///       up, never down;
///     * the same clip id under another name, in this session or another →
///       [ClipIndexOutcome.identityConflict];
///     * absent → the record `f(name, size)` is inserted at its place in
///       [DashcamClipDescriptor.compareOrder] — existing entries are never
///       reordered, legacy (`clip_<ms>`) entries are kept as they are;
///  5. the write is awaited; a failure is [ClipIndexOutcome.indexPending],
///     reported through [report] once per clip per process;
///  6. a [ClipIndexOutcome.deletionRefused] clip produced in this process is
///     discarded ([discardClipFilesOfDeletedSession], R2.6.7).
///
/// [writeHookForTest] wraps step 4: it must call the write itself, which then
/// decides again in its own slice — a deletion committed while the hook held
/// the call is seen there (frozen X96). The FIFO's turn ends when the write has
/// settled (or was found unnecessary), not when the hook returns: a hook that
/// keeps holding AFTER its write only delays its own caller, never another
/// clip's write (frozen R2.2-X7).
///
/// No timer, no loop: a failed clip is retried only by the next in-process
/// trigger and replayed by the next start.
Future<ClipIndexOutcome> ensureClipIndexed(
  String clipPath, {
  required ClipIndexOrigin origin,
  bool protectedNow = false,
  ClipIndexWriteHook? writeHookForTest,
  void Function(String message)? report,
}) {
  final turn = Completer<void>();
  final previous = _indexQueueTail;
  _indexQueueTail = turn.future;
  void releaseTurn() {
    if (!turn.isCompleted) turn.complete();
  }

  final outcome = Completer<ClipIndexOutcome>();
  unawaited(
    previous.then((_) async {
      ClipIndexOutcome result;
      try {
        result = await _ensureInTurn(clipPath, origin, protectedNow, writeHookForTest, report, releaseTurn);
      } catch (error) {
        // Not expected (every step handles its own failure); the clip stays
        // the obligation it is.
        result = ClipIndexOutcome.indexPending;
      } finally {
        releaseTurn();
      }
      DashcamClipIndexCounters._count(result);
      outcome.complete(result);
    }),
  );
  return outcome.future;
}

Future<ClipIndexOutcome> _ensureInTurn(
  String clipPath,
  ClipIndexOrigin origin,
  bool protectedNow,
  ClipIndexWriteHook? hook,
  void Function(String message)? report,
  void Function() releaseTurn,
) async {
  final descriptor = DashcamClipDescriptor.parse(dashcamClipBasename(clipPath));
  if (descriptor == null) return ClipIndexOutcome.invalidName;
  final sessionId = descriptor.sessionId;

  if (origin == ClipIndexOrigin.recovered) {
    try {
      final guard = _recoveredGuard(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions), sessionId);
      if (guard != null) return guard;
    } catch (error) {
      _reportOnce('index', descriptor, report, 'Falha ao indexar clipe(s) da sessão $sessionId: $error');
      return ClipIndexOutcome.indexPending;
    }
  }

  final int? size;
  try {
    size = await dashcamClipRegularFileSize(clipPath);
  } catch (_) {
    return ClipIndexOutcome.notPresent;
  }
  if (size == null) return ClipIndexOutcome.notPresent;
  if (size == 0) return ClipIndexOutcome.emptyPreserved;
  final fileSize = size;

  _Decision decide() => _decide(descriptor, clipPath: clipPath, origin: origin, protectedNow: protectedNow, size: fileSize);

  _Decision before;
  try {
    before = decide();
  } catch (error) {
    _reportOnce('index', descriptor, report, 'Falha ao indexar clipe(s) da sessão $sessionId: $error');
    return ClipIndexOutcome.indexPending;
  }
  if (before.write == null) return _conclude(before, descriptor, clipPath, origin, report);

  _Decision? applied;
  Future<void> writeCall() async {
    final decision = applied = decide();
    final write = decision.write;
    if (write == null) {
      releaseTurn();
      return;
    }
    final put = Hive.box(HiveBoxNames.dashcamSessionVideos).put(sessionId, write);
    unawaited(put.then<void>((_) {}, onError: (Object _) {}).whenComplete(releaseTurn));
    await put;
  }

  try {
    if (hook != null) {
      await hook(sessionId, [clipPath], writeCall);
    } else {
      await writeCall();
    }
  } catch (error) {
    _reportOnce('index', descriptor, report, 'Falha ao indexar clipe(s) da sessão $sessionId: $error');
    return ClipIndexOutcome.indexPending;
  }
  final decision = applied;
  if (decision == null) return ClipIndexOutcome.indexPending;
  if (decision.write == null) return _conclude(decision, descriptor, clipPath, origin, report);
  if (decision.sizeDivergence) _noteSizeDivergence(descriptor, report);
  return decision.outcome;
}

Future<ClipIndexOutcome> _conclude(
  _Decision decision,
  DashcamClipDescriptor descriptor,
  String clipPath,
  ClipIndexOrigin origin,
  void Function(String message)? report,
) async {
  final sessionId = descriptor.sessionId;
  switch (decision.outcome) {
    case ClipIndexOutcome.identityConflict:
      _reportOnce('conflict', descriptor, report, 'Conflito de identidade do clipe ${descriptor.clipId} da sessão $sessionId: nada foi escrito nem reatribuído');
    case ClipIndexOutcome.deletionRefused when origin == ClipIndexOrigin.producedInThisProcess:
      // R2.6.7: the file of a deleted session's clip is in no index; nothing
      // else would ever remove it.
      final notDeleted = await discardClipFilesOfDeletedSession(sessionId, [clipPath]);
      if (notDeleted.isNotEmpty) {
        _reportOnce('discard', descriptor, report, 'Falha ao descartar clipe(s) da sessão excluída $sessionId: ${dashcamClipBasename(clipPath)}');
      }
    case ClipIndexOutcome.alreadyIndexed:
      if (decision.sizeDivergence) _noteSizeDivergence(descriptor, report);
    default:
      break;
  }
  return decision.outcome;
}

void _noteSizeDivergence(DashcamClipDescriptor descriptor, void Function(String message)? report) {
  if (!_reported.add('size|${descriptor.clipId}')) return;
  DashcamClipIndexCounters.sizeDivergences++;
  report?.call('O tamanho do clipe ${descriptor.clipId} da sessão ${descriptor.sessionId} difere do indexado; a entrada não foi reescrita');
}

void _reportOnce(String kind, DashcamClipDescriptor descriptor, void Function(String message)? report, String message) {
  if (!_reported.add('$kind|${descriptor.clipId}')) return;
  report?.call(message);
}

/// The startup guard: `null` lets the clip through.
ClipIndexOutcome? _recoveredGuard(Box<DrivingSession> sessions, String sessionId) {
  final record = sessions.get(sessionId);
  if (record == null) return ClipIndexOutcome.orphanPreserved;
  if (record.deletionPending || sessionDeletionCommitted(sessionId)) return ClipIndexOutcome.deletionBlocked;
  return null;
}

class _Decision {
  const _Decision(this.outcome, {this.write, this.sizeDivergence = false});

  final ClipIndexOutcome outcome;

  /// The session's new entry list to put, or `null` for nothing to write.
  final List<DashcamClipRecord>? write;

  /// The entry is the clip's, but its `sizeBytes` is not the file's size. It
  /// decides nothing (the entry is not rewritten); reported once.
  final bool sizeDivergence;
}

/// Step 4 of [ensureClipIndexed], synchronous from its first line to its last.
/// [size] is the file's, measured just before (a file deleted between that and
/// the write leaves a dangling entry — the quota's, D3; never a resurrection).
_Decision _decide(DashcamClipDescriptor descriptor, {required String clipPath, required ClipIndexOrigin origin, required bool protectedNow, required int size}) {
  final sessionId = descriptor.sessionId;
  switch (origin) {
    case ClipIndexOrigin.producedInThisProcess:
      if (sessionDeletionCommitted(sessionId)) return const _Decision(ClipIndexOutcome.deletionRefused);
    case ClipIndexOrigin.recovered:
      final guard = _recoveredGuard(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions), sessionId);
      if (guard != null) return _Decision(guard);
  }
  final videos = Hive.box(HiveBoxNames.dashcamSessionVideos);
  if (_identityTakenByAnotherSession(videos, descriptor)) return const _Decision(ClipIndexOutcome.identityConflict);
  final raw = videos.get(sessionId);
  // Same cast-on-read as everywhere else: Hive hands a stored List back as
  // List<dynamic>.
  final entries = raw is List ? List<DashcamClipRecord>.from(raw) : <DashcamClipRecord>[];
  final name = descriptor.basename;
  final protect = descriptor.isProtected || protectedNow;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final entryName = dashcamClipBasename(entry.filePath);
    final existing = DashcamClipDescriptor.parse(entryName);
    if (existing == null || existing.clipId != descriptor.clipId) continue;
    if (entryName != name || !_sameImmutableFields(entry, descriptor)) return const _Decision(ClipIndexOutcome.identityConflict);
    if (protect && !entry.isProtected) {
      entries[i] = DashcamClipRecord(
        filePath: entry.filePath,
        recordedAt: entry.recordedAt,
        durationSeconds: entry.durationSeconds,
        sizeBytes: entry.sizeBytes,
        isProtected: true,
        resolution: entry.resolution,
        audioEnabled: entry.audioEnabled,
      );
      return _Decision(ClipIndexOutcome.protectionRaised, write: entries, sizeDivergence: entry.sizeBytes != size);
    }
    return _Decision(ClipIndexOutcome.alreadyIndexed, sizeDivergence: entry.sizeBytes != size);
  }
  final record = DashcamClipRecord(
    filePath: clipPath,
    recordedAt: descriptor.recordedAt,
    durationSeconds: descriptor.durationSeconds,
    sizeBytes: size,
    isProtected: protect,
    resolution: descriptor.resolution,
    audioEnabled: descriptor.audioEnabled,
  );
  entries.insert(_positionFor(entries, descriptor), record);
  return _Decision(ClipIndexOutcome.indexed, write: entries);
}

bool _sameImmutableFields(DashcamClipRecord entry, DashcamClipDescriptor descriptor) =>
    entry.recordedAt.millisecondsSinceEpoch == descriptor.recordedAt.millisecondsSinceEpoch &&
    entry.durationSeconds == descriptor.durationSeconds &&
    entry.resolution == descriptor.resolution &&
    entry.audioEnabled == descriptor.audioEnabled;

/// Whether an index entry of a session OTHER than [descriptor]'s carries the
/// same clip id — evidence is never re-attributed. A cheap substring filter
/// first: the full parse runs only for names that can match.
bool _identityTakenByAnotherSession(Box videos, DashcamClipDescriptor descriptor) {
  final marker = '_${descriptor.clipId}_';
  for (final key in videos.keys) {
    if (key == descriptor.sessionId) continue;
    final raw = videos.get(key);
    if (raw is! List) continue;
    for (final entry in raw) {
      if (entry is! DashcamClipRecord || !entry.filePath.contains(marker)) continue;
      if (DashcamClipDescriptor.parse(dashcamClipBasename(entry.filePath))?.clipId == descriptor.clipId) return true;
    }
  }
  return false;
}

/// Before the first entry that sorts after [descriptor]: a v1 entry by
/// [DashcamClipDescriptor.compareOrder], a legacy one by its `recordedAt`
/// (strictly later). Nothing already there moves.
int _positionFor(List<DashcamClipRecord> entries, DashcamClipDescriptor descriptor) {
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final existing = DashcamClipDescriptor.parse(dashcamClipBasename(entry.filePath));
    final later = existing != null
        ? DashcamClipDescriptor.compareOrder(existing, descriptor) > 0
        : entry.recordedAt.millisecondsSinceEpoch > descriptor.recordedAt.millisecondsSinceEpoch;
    if (later) return i;
  }
  return entries.length;
}

/// What [reconcileCanonicalClipsAtStartup] found and did, in aggregate.
class DashcamClipReconciliation {
  int seen = 0;
  int canonical = 0;
  int partials = 0;
  int invalid = 0;
  int duplicateIdentities = 0;
  final Map<ClipIndexOutcome, int> outcomes = {};

  /// The reconciliation could not run (directory not listable, boxes not open):
  /// nothing was written.
  bool aborted = false;

  int of(ClipIndexOutcome outcome) => outcomes[outcome] ?? 0;

  @override
  String toString() =>
      'dashcam clip reconciliation: seen=$seen canonical=$canonical partial=$partials invalid=$invalid '
      'duplicateIdentity=$duplicateIdentities indexed=${of(ClipIndexOutcome.indexed)} '
      'alreadyIndexed=${of(ClipIndexOutcome.alreadyIndexed) + of(ClipIndexOutcome.protectionRaised)} '
      'orphan=${of(ClipIndexOutcome.orphanPreserved)} blockedByDeletion=${of(ClipIndexOutcome.deletionBlocked)} '
      'conflict=${of(ClipIndexOutcome.identityConflict)} empty=${of(ClipIndexOutcome.emptyPreserved)} '
      'notPresent=${of(ClipIndexOutcome.notPresent)} pending=${of(ClipIndexOutcome.indexPending)}${aborted ? ' ABORTED' : ''}';
}

/// Test-only: awaited after each candidate of [reconcileCanonicalClipsAtStartup]
/// — the point at which a test can kill the process in the middle of it.
@visibleForTesting
Future<void> Function(String clipPath, ClipIndexOutcome outcome)? afterReconciledClipHookForTest;

/// Fase 16.2-R4.4-R1 — the startup half of D1: every canonical clip in
/// `dashcam_clips/` is passed to [ensureClipIndexed] as
/// [ClipIndexOrigin.recovered]. Awaited once per process by the bootstrap
/// (main.dart), AFTER `recoverDrivingSessionsAtStartup` — pending deletions are
/// completed first (they remove the canonical files of their sessions, against
/// a stable index, and a completed one leaves its session absent), then active
/// sessions are reclaimed — and BEFORE `runApp`: nothing can list, open or
/// record a session yet, so nothing runs concurrently with it.
///
/// 1. the directory is resolved; none → nothing to do; the boxes are not open,
///    or the directory cannot be listed → reported, nothing written;
/// 2. its entries, not recursive, links not followed: canonical names are the
///    candidates; partials, legacy and invalid names, links and directories are
///    left exactly as they are;
/// 3. two canonical names with ONE clip id: neither is indexed (reported);
/// 4. each candidate → [ensureClipIndexed] (the same function, the same FIFO,
///    the same guards as at runtime);
/// 5. one aggregate line, never one per file.
///
/// It renames, copies and deletes nothing, touches neither `cache/` nor
/// `driving_sessions`, repopulates no in-memory clip list and stores no "done"
/// mark: a death in the middle of it is simply run again by the next start,
/// and what was already applied stays single. Never throws.
Future<DashcamClipReconciliation> reconcileCanonicalClipsAtStartup() async {
  final result = DashcamClipReconciliation();
  try {
    // Unavailable boxes are not "no record": nothing is decided without them.
    Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
    Hive.box(HiveBoxNames.dashcamSessionVideos);
    final entries = await listDashcamClipsDirectory(await dashcamClipsDirectory());
    result.seen = entries.length;
    final byIdentity = <String, List<DashcamClipDirectoryEntry>>{};
    for (final entry in entries) {
      switch (entry.kind) {
        case DashcamClipEntryKind.canonical:
          result.canonical++;
          byIdentity.putIfAbsent(entry.descriptor!.clipId, () => []).add(entry);
        case DashcamClipEntryKind.partial:
          result.partials++;
        case DashcamClipEntryKind.invalid:
          result.invalid++;
      }
    }
    final candidates = <DashcamClipDirectoryEntry>[];
    final duplicated = <String>[];
    for (final MapEntry(key: clipId, value: named) in byIdentity.entries) {
      if (named.length == 1) {
        candidates.add(named.single);
      } else {
        result.duplicateIdentities += named.length;
        duplicated.add(clipId);
      }
    }
    candidates.sort((a, b) => a.name.compareTo(b.name));
    for (final candidate in candidates) {
      final outcome = await ensureClipIndexed(candidate.path, origin: ClipIndexOrigin.recovered);
      result.outcomes[outcome] = result.of(outcome) + 1;
      final hook = afterReconciledClipHookForTest;
      if (hook != null) await hook(candidate.path, outcome);
    }
    if (duplicated.isNotEmpty || result.of(ClipIndexOutcome.identityConflict) > 0 || result.of(ClipIndexOutcome.indexPending) > 0) {
      _reportReconciliation(
        StateError('${result.of(ClipIndexOutcome.indexPending)} clip(s) not indexed (retried at the next start); '
            '${duplicated.length + result.of(ClipIndexOutcome.identityConflict)} identity conflict(s) left untouched'),
        StackTrace.current,
        result,
      );
    }
  } catch (error, stackTrace) {
    result.aborted = true;
    _reportReconciliation(error, stackTrace, result);
  }
  if (result.seen > 0 || result.aborted) debugPrint(result.toString());
  return result;
}

void _reportReconciliation(Object error, StackTrace stackTrace, DashcamClipReconciliation result) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'dashcam clip index',
      context: ErrorDescription('while reconciling the dashcam clips at startup ($result)'),
    ),
  );
}
