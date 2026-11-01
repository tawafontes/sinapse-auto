import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/dashcam_clip_descriptor.dart';
import '../models/dashcam_clip_record.dart';
import '../models/dashcam_config.dart';
import '../models/driving_session.dart';
import 'dashcam_clip_files.dart';
import 'dashcam_clip_index.dart' show runInClipIndexQueue;
import 'dashcam_storage_probe.dart';
import 'driving_session_recorder.dart' show sessionDeletionCommitted;
import 'hive_boxes.dart';

/// Fase 16.2-R4.4-R2 — the dashcam's PHYSICAL storage quota and free-space
/// guard (design: `scratchpad/fase16_2_r4_4_r2_d0_quota_diagnostic/
/// DIAGNOSTICO_R4_4_R2_STORAGE_QUOTA.md`, §5–§13).
///
/// The quota used to live in `DashcamService`: a sum over its in-memory list
/// of THIS process's clips, enforced inside the camera FIFO right after each
/// promotion. It never saw a clip of an earlier process (D3-M2), deleted a
/// segment larger than the quota as soon as it was born (D3-Q: 720p segments
/// measure 262.8 MiB, the setting starts at 256 MiB), and a failure of it
/// stopped the recording as "camera unavailable". Here, instead:
///
///  * **authority = the disk, read again by every pass**: `dashcam_clips/` is
///    listed and every v1 file `stat`ed — never a list held in memory, a sum
///    stored anywhere, or the `sizeBytes` of an index entry. The index and
///    `driving_sessions` are read only for what they alone know (indexed or
///    not, protected or not, whose and whether being deleted);
///  * **what the quota manages** = the canonical v1 clips and their `.partial`
///    copies ("managed bytes"). Legacy `clip_<ms>.mp4`, other names, the
///    plugin's `cache/REC*` files and telemetry are measured, never counted in
///    the quota and never deleted here (R4.4-R3 / D2) — they still occupy the
///    volume, which the free-space guard sees through `statfs`;
///  * **what may leave** ([DashcamStorageClass.evictable]): a canonical clip
///    indexed in its own session, not protected (by its name, its entry, or in
///    memory), of a session that exists and is not being deleted, without an
///    identity conflict, and not IMMUNE — never the newest canonical clip, the
///    clip whose publication triggered the pass, nor any path the caller names
///    (this process's newest clip). An orphan, an unindexed clip, a partial, a
///    protected clip and a file of unknown ownership never leave;
///  * **effective quota** `Q_eff = max(Q_cfg, 2 × S_res)` — `S_res` the largest
///    canonical clip of the current resolution: a quota below two segments is
///    raised to two, so the newest segment and the one before it always
///    survive. The quota is a retention target, never a licence to delete the
///    last segment;
///  * **eviction order**: oldest first by [DashcamClipDescriptor.compareOrder];
///    each one file FIRST (and its absence confirmed), its index entry after —
///    a death in between leaves an entry without a file (removed by the next
///    start), never a canonical file without its entry, which the startup
///    reconciliation would index again (resurrection);
///  * **serialization**: every pass is ONE turn of the index FIFO
///    ([runInClipIndexQueue]) — the same as `ensureClipIndexed`, never the
///    camera FIFO;
///  * **free space** (Android only, [DashcamStorageProbe]): below the floor
///    ([dashcamStorageFloorBytes]) a pass also evicts under pressure — still
///    oldest first, still never an immune, protected, orphan or unindexed clip,
///    possibly below `Q_eff` — and a START is refused when even that is not
///    enough ([evaluateDashcamStartStorage]). The native side reports; the
///    policy is here.
///
/// It does not make a segment being recorded durable (D2: the plugin records
/// into `cache/`, which Android may empty) — the guard only keeps this app's
/// own recordings from pushing the volume into Android's cache trimming.

const _mib = 1024 * 1024;

/// What started a quota pass.
enum DashcamQuotaTrigger {
  /// A segment was published and indexed (`DashcamSessionController`).
  publication,

  /// A START found the volume below the floor and needs space.
  start,

  /// The quota setting changed.
  settingChanged,
}

/// How one file of `dashcam_clips/` stands for the quota — one class per file.
enum DashcamStorageClass {
  /// A — canonical, indexed in its own session, unprotected, owned: a candidate.
  evictable,

  /// A held by immunity: the newest canonical clip, the pass's trigger, or a
  /// path the caller protects this way.
  immune,

  /// H — indexed and protected (name, entry or memory): counts, never leaves.
  protected,

  /// B — its session exists, but it is not indexed (yet): counts, never
  /// leaves. The startup reconciliation indexes it.
  unindexed,

  /// C — no record of its session: counts, never leaves (R4.4-R3 decides).
  orphan,

  /// G — its session is marked for deletion, or the deletion is committed:
  /// counts until the deletion removes it.
  deletionPending,

  /// Its clip id is named by another file or another entry: nothing is
  /// decided for it.
  conflict,

  /// D — a `.partial` of the promotion's copy fallback: counts, never leaves
  /// (only its session's deletion removes it).
  partial,
}

/// The storage state, most severe first in [dashcamStorageHealthOf].
enum DashcamStorageHealth {
  ok,

  /// Managed bytes stay above the effective quota: nothing left to evict.
  quotaSaturated,

  /// Protected clips alone exceed the effective quota minus two segments.
  protectedSaturated,

  /// The volume is below the floor a new segment needs.
  lowDisk,

  /// The volume is below the threshold at which Android starts trimming
  /// caches — this app's `cache/` first.
  critical,

  /// The volume could not be read (or is never read on this platform).
  unknown,
}

/// The AOSP default "low storage" threshold cap (`StorageManager`
/// `DEFAULT_THRESHOLD_MAX_BYTES`). Overrides in `Settings.Global` and OEM
/// changes are not read (D0, LIMITATIONS).
const dashcamAndroidLowStorageCapBytes = 500 * _mib;

/// Android's own cache-trimming trigger: `DeviceStorageMonitorService` frees
/// caches once the usable space drops below 1.5 × `min(5 % of the volume,
/// 500 MiB)` (D0 §3, §10 `TRIM`).
int dashcamStorageTrimBytes(int totalBytes) => min(totalBytes * 5 ~/ 100, dashcamAndroidLowStorageCapBytes) * 3 ~/ 2;

/// The free space a new segment needs: Android's trim trigger, plus one
/// segment ([segmentBytes], the largest measured at the resolution), plus one
/// more while the last promotion had to copy ([copyReserve]) — so this app's
/// own recording never drives the volume into the trimming that would empty
/// its `cache/`, where the segment being recorded lives (D0 §10). A segment
/// size not measured yet at a resolution reserves nothing for it (D0 §9.3).
int dashcamStorageFloorBytes({required int totalBytes, required int segmentBytes, required bool copyReserve}) =>
    dashcamStorageTrimBytes(totalBytes) + segmentBytes + (copyReserve ? segmentBytes : 0);

/// What the disk held at one pass (or at startup) — sizes in bytes, counts in
/// files; never a path, an id or anything of a session's content.
class DashcamStorageSnapshot {
  const DashcamStorageSnapshot({
    required this.trigger,
    required this.bytesByClass,
    required this.countByClass,
    required this.protectedBytes,
    required this.legacyClipBytes,
    required this.legacyClipCount,
    required this.otherBytes,
    required this.otherCount,
    required this.largestSegmentBytes,
    required this.health,
    this.configuredQuotaBytes,
    this.effectiveQuotaBytes,
    this.evictedCount = 0,
    this.evictedBytes = 0,
    this.pressureEvictedCount = 0,
    this.availableBytes,
    this.totalBytes,
    this.floorBytes,
    this.probeFailed = false,
    this.recBytes,
    this.recCount,
    this.recEmptyCount,
    this.telemetryBytes,
  });

  /// `null` at startup.
  final DashcamQuotaTrigger? trigger;

  /// After this pass's evictions.
  final Map<DashcamStorageClass, int> bytesByClass;
  final Map<DashcamStorageClass, int> countByClass;

  /// Every protected canonical clip, whatever its class.
  final int protectedBytes;

  /// L — legacy `clip_<ms>.mp4` in `dashcam_clips/` (outside the quota).
  final int legacyClipBytes;
  final int legacyClipCount;

  /// X — any other entry of `dashcam_clips/` (outside the quota).
  final int otherBytes;
  final int otherCount;

  /// The largest canonical clip per resolution — `S_res`.
  final Map<VideoResolution, int> largestSegmentBytes;

  final DashcamStorageHealth health;

  /// `null` at startup (no eviction runs there, so no quota is applied).
  final int? configuredQuotaBytes;
  final int? effectiveQuotaBytes;

  final int evictedCount;
  final int evictedBytes;

  /// Of [evictedCount], those taken for free space, beyond the quota.
  final int pressureEvictedCount;

  /// The volume, when read (Android); `null` otherwise.
  final int? availableBytes;
  final int? totalBytes;
  final int? floorBytes;

  /// The volume read was attempted and failed.
  final bool probeFailed;

  /// The plugin's `cache/REC*.mp4` (read-only, at startup only).
  final int? recBytes;
  final int? recCount;
  final int? recEmptyCount;

  /// `dashcam_telemetry/` (at startup only).
  final int? telemetryBytes;

  int bytesOf(DashcamStorageClass storageClass) => bytesByClass[storageClass] ?? 0;
  int countOf(DashcamStorageClass storageClass) => countByClass[storageClass] ?? 0;

  /// What the quota manages: every canonical clip and partial, of any class.
  int get managedBytes => bytesByClass.values.fold(0, (sum, bytes) => sum + bytes);
  int get managedCount => countByClass.values.fold(0, (sum, count) => sum + count);

  /// The one aggregate line (sizes and counts only).
  String describe() {
    String cls(DashcamStorageClass c) => '${c.name}=${countOf(c)}/${bytesOf(c)}';
    final parts = <String>[
      'trigger=${trigger?.name ?? 'startup'}',
      'managed=$managedCount/$managedBytes',
      if (configuredQuotaBytes != null) 'quotaCfg=$configuredQuotaBytes quotaEff=$effectiveQuotaBytes',
      for (final c in DashcamStorageClass.values) cls(c),
      'protectedAny=$protectedBytes',
      'legacyClip=$legacyClipCount/$legacyClipBytes',
      'other=$otherCount/$otherBytes',
      'largestSegment=${{for (final MapEntry(:key, :value) in largestSegmentBytes.entries) key.name: value}}',
      'evicted=$evictedCount/$evictedBytes pressure=$pressureEvictedCount',
      if (recCount != null) 'rec=$recCount/$recBytes empty=$recEmptyCount',
      if (telemetryBytes != null) 'telemetry=$telemetryBytes',
      if (availableBytes != null) 'free=$availableBytes/$totalBytes floor=$floorBytes',
      if (probeFailed) 'probe=FAILED',
      'health=${health.name}',
    ];
    return 'dashcam storage: ${parts.join(' ')}';
  }
}

/// The result of one [runDashcamQuotaPass]. Never an exception.
class DashcamQuotaPassResult {
  const DashcamQuotaPassResult({this.snapshot, this.evictedPaths = const [], this.aborted = false});

  /// `null` when the pass could not run at all ([aborted]).
  final DashcamStorageSnapshot? snapshot;

  /// The canonical clips whose file this pass removed (and confirmed absent).
  final List<String> evictedPaths;

  /// The pass could not run (boxes not open, directory not listable): nothing
  /// was deleted or written.
  final bool aborted;
}

/// Whether a START may record, and why not.
class DashcamStartStorageDecision {
  const DashcamStartStorageDecision._({required this.allowed, this.refusal, this.availableBytes, this.floorBytes, this.pass});

  /// The volume could not be read: not blocking (D0 D-6, fail-open — the clip
  /// integrity still rests on R4.4-R1 and CameraX's own 50 MiB floor).
  const DashcamStartStorageDecision.unknown({DashcamQuotaPassResult? pass}) : this._(allowed: true, pass: pass);

  const DashcamStartStorageDecision.allowed({required int availableBytes, required int floorBytes, DashcamQuotaPassResult? pass})
    : this._(allowed: true, availableBytes: availableBytes, floorBytes: floorBytes, pass: pass);

  const DashcamStartStorageDecision.refused({
    required String refusal,
    required int availableBytes,
    required int floorBytes,
    required DashcamQuotaPassResult pass,
  }) : this._(allowed: false, refusal: refusal, availableBytes: availableBytes, floorBytes: floorBytes, pass: pass);

  final bool allowed;

  /// For the user, when refused — sizes only.
  final String? refusal;
  final int? availableBytes;
  final int? floorBytes;

  /// The pass under pressure this decision ran, if it needed one — its
  /// evictions are the caller's to forget.
  final DashcamQuotaPassResult? pass;
}

/// Process-wide counters of the quota and the guard — no paths, no ids.
class DashcamStorageCounters {
  DashcamStorageCounters._();

  static int passes = 0;
  static int passesAborted = 0;
  static int evictedClips = 0;
  static int evictedBytes = 0;
  static int pressureEvictedClips = 0;
  static int evictionFileFailures = 0;
  static int evictionEntryFailures = 0;
  static int quotaSaturations = 0;
  static int protectedSaturations = 0;
  static int startRefusals = 0;
  static int probeFailures = 0;
  static int groupRepairs = 0;
  static int groupRepairFailures = 0;
  static int danglingEntriesRemoved = 0;
  static int danglingEntryFailures = 0;

  static Map<String, int> snapshot() => {
    'passes': passes,
    'passesAborted': passesAborted,
    'evictedClips': evictedClips,
    'evictedBytes': evictedBytes,
    'pressureEvictedClips': pressureEvictedClips,
    'evictionFileFailures': evictionFileFailures,
    'evictionEntryFailures': evictionEntryFailures,
    'quotaSaturations': quotaSaturations,
    'protectedSaturations': protectedSaturations,
    'startRefusals': startRefusals,
    'probeFailures': probeFailures,
    'groupRepairs': groupRepairs,
    'groupRepairFailures': groupRepairFailures,
    'danglingEntriesRemoved': danglingEntriesRemoved,
    'danglingEntryFailures': danglingEntryFailures,
  };

  @visibleForTesting
  static void resetForTest() {
    passes = passesAborted = evictedClips = evictedBytes = pressureEvictedClips = 0;
    evictionFileFailures = evictionEntryFailures = quotaSaturations = protectedSaturations = 0;
    startRefusals = probeFailures = groupRepairs = groupRepairFailures = 0;
    danglingEntriesRemoved = danglingEntryFailures = 0;
  }
}

/// The most recent snapshot of this process (startup, or the last pass).
DashcamStorageSnapshot? get latestDashcamStorageSnapshot => _latestSnapshot;
DashcamStorageSnapshot? _latestSnapshot;

@visibleForTesting
void resetDashcamStorageForTest() {
  _latestSnapshot = null;
  _lastLoggedClamp = null;
  DashcamStorageCounters.resetForTest();
}

/// Test-only: awaited inside a pass's turn once every file is classified and
/// before the first eviction — where a test holds the pass to run something
/// against it (a protection, a deletion, an indexing).
@visibleForTesting
Future<void> Function()? quotaPassDecidedHookForTest;

/// Test-only: awaited between an evicted file's confirmed absence and the
/// removal of its index entry — where a test simulates a process death.
@visibleForTesting
Future<void> Function(String clipPath)? afterEvictedFileDeletedHookForTest;

/// Fase 16.2-R4.4-R2 — one quota pass, as one turn of the index FIFO
/// ([runInClipIndexQueue]); never in the camera FIFO. Never throws.
///
/// 1. `dashcam_clips/` is listed and every v1 file `stat`ed — this turn's own
///    reading of the disk;
/// 2. in one synchronous slice, every canonical clip is classified
///    ([DashcamStorageClass]) from its name, its session's record, the index
///    and [protectedInMemory];
/// 3. `Q_eff = max(quotaBytes(), 2 × S_res)`; while the managed bytes exceed
///    it, the oldest evictable clip leaves (file, absence confirmed, entry);
/// 4. Android: the volume is read; below [dashcamStorageFloorBytes] the next
///    oldest evictable clips leave too, until the space they free (their
///    sizes) reaches the floor, and the volume is read again;
/// 5. [triggerClipPath]'s group is repaired (P3-HW-1);
/// 6. a snapshot is published ([latestDashcamStorageSnapshot]), and one line
///    is printed when the pass evicted, failed or found the storage short.
///
/// A file whose deletion fails stops the pass (reported; the next pass tries
/// again); so does an entry whose removal fails (the file is gone: the entry
/// is removed by the next start). [quotaBytes], [resolution],
/// [protectedInMemory] and [immunePaths] are read when the turn runs, not when
/// it is queued.
Future<DashcamQuotaPassResult> runDashcamQuotaPass({
  required DashcamQuotaTrigger trigger,
  required int Function() quotaBytes,
  required VideoResolution Function() resolution,
  required DashcamStorageProbe probe,
  String? triggerClipPath,
  Set<String> Function()? protectedInMemory,
  Set<String> Function()? immunePaths,
  DashcamClipFileOps fileOps = const DashcamClipFileOps(),
}) {
  return runInClipIndexQueue(() async {
    try {
      return await _passInTurn(
        trigger: trigger,
        quotaBytes: quotaBytes,
        resolution: resolution,
        probe: probe,
        triggerClipPath: triggerClipPath,
        protectedInMemory: protectedInMemory ?? _none,
        immunePaths: immunePaths ?? _none,
        fileOps: fileOps,
      );
    } catch (error) {
      DashcamStorageCounters.passesAborted++;
      debugPrint('dashcam storage: pass ${trigger.name} aborted (${error.runtimeType}); nothing was deleted or written');
      return const DashcamQuotaPassResult(aborted: true);
    }
  });
}

Set<String> _none() => const {};

Future<DashcamQuotaPassResult> _passInTurn({
  required DashcamQuotaTrigger trigger,
  required int Function() quotaBytes,
  required VideoResolution Function() resolution,
  required DashcamStorageProbe probe,
  required String? triggerClipPath,
  required Set<String> Function() protectedInMemory,
  required Set<String> Function() immunePaths,
  required DashcamClipFileOps fileOps,
}) async {
  // Unavailable boxes are not "no record": nothing is decided without them.
  Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  Hive.box(HiveBoxNames.dashcamSessionVideos);
  final directory = await dashcamClipsDirectory();
  final scan = await _scanClipsDirectory(directory);
  DashcamStorageCounters.passes++;

  final res = resolution();
  final configured = max(0, quotaBytes());
  final classified = _classify(scan, protectedInMemory: protectedInMemory(), immune: {?triggerClipPath, ...immunePaths()});
  final largest = _largestByResolution(scan);
  final segment = largest[res] ?? 0;
  final effective = max(configured, 2 * segment);

  final decided = quotaPassDecidedHookForTest;
  if (decided != null) await decided();

  final candidates = [
    for (final clip in classified)
      if (clip.storageClass == DashcamStorageClass.evictable) clip,
  ]..sort((a, b) => DashcamClipDescriptor.compareOrder(a.descriptor, b.descriptor));
  var managed = scan.managedBytes;
  final evicted = <_ClassifiedClip>[];
  var pressureEvicted = 0;
  var stopped = false;
  var next = 0;

  // 3. The quota.
  while (!stopped && managed > effective && next < candidates.length) {
    final victim = candidates[next++];
    switch (await _evict(victim, protectedInMemory: protectedInMemory, immunePaths: immunePaths, fileOps: fileOps)) {
      case _EvictionOutcome.evicted:
        evicted.add(victim);
        managed -= victim.size;
      case _EvictionOutcome.entryFailed:
        evicted.add(victim);
        managed -= victim.size;
        stopped = true;
      case _EvictionOutcome.fileFailed:
        stopped = true;
      case _EvictionOutcome.noLongerEvictable:
        break;
    }
  }

  // 4. Free space (Android).
  DashcamVolumeStats? volume;
  var probeFailed = false;
  int? floor;
  if (probe.isSupported) {
    volume = await _readVolume(probe, directory);
    probeFailed = volume == null;
    if (volume != null) {
      floor = dashcamStorageFloorBytes(
        totalBytes: volume.totalBytes,
        segmentBytes: segment,
        copyReserve: DashcamClipStorageCounters.lastPlacement == DashcamClipPlacement.copied,
      );
      var projected = volume.availableBytes;
      while (!stopped && projected < floor && next < candidates.length) {
        final victim = candidates[next++];
        switch (await _evict(victim, protectedInMemory: protectedInMemory, immunePaths: immunePaths, fileOps: fileOps)) {
          case _EvictionOutcome.evicted:
            evicted.add(victim);
            pressureEvicted++;
            projected += victim.size;
          case _EvictionOutcome.entryFailed:
            evicted.add(victim);
            pressureEvicted++;
            stopped = true;
          case _EvictionOutcome.fileFailed:
            stopped = true;
          case _EvictionOutcome.noLongerEvictable:
            break;
        }
      }
      if (pressureEvicted > 0) {
        volume = await _readVolume(probe, directory);
        probeFailed = volume == null;
      }
    }
  }

  // 5. P3-HW-1 for the clip just published.
  var groupRepairFailed = false;
  if (probe.isSupported && triggerClipPath != null && DashcamClipDescriptor.parse(dashcamClipBasename(triggerClipPath)) != null) {
    groupRepairFailed = !await _repairGroups(probe, [triggerClipPath]);
  }

  final evictedSet = evicted.toSet();
  final remaining = [
    for (final clip in classified)
      if (!evictedSet.contains(clip)) clip,
  ];
  final evictedBytes = evicted.fold<int>(0, (sum, clip) => sum + clip.size);
  DashcamStorageCounters.evictedClips += evicted.length;
  DashcamStorageCounters.evictedBytes += evictedBytes;
  DashcamStorageCounters.pressureEvictedClips += pressureEvicted;

  final snapshot = _snapshotOf(
    remaining,
    scan,
    largest,
    trigger: trigger,
    configured: configured,
    effective: effective,
    segment: segment,
    evictedCount: evicted.length,
    evictedBytes: evictedBytes,
    pressureEvicted: pressureEvicted,
    volume: volume,
    floor: floor,
    probeFailed: probeFailed,
  );
  _latestSnapshot = snapshot;
  if (snapshot.health == DashcamStorageHealth.quotaSaturated) DashcamStorageCounters.quotaSaturations++;
  if (snapshot.health == DashcamStorageHealth.protectedSaturated) DashcamStorageCounters.protectedSaturations++;
  final clamped = effective > configured ? effective : null;
  final clampChanged = clamped != _lastLoggedClamp;
  _lastLoggedClamp = clamped;
  if (evicted.isNotEmpty || stopped || probeFailed || groupRepairFailed || clampChanged || _shortOfStorage(snapshot.health)) {
    debugPrint(snapshot.describe() + (stopped ? ' STOPPED (a deletion failed: retried by the next pass)' : ''));
  }
  return DashcamQuotaPassResult(snapshot: snapshot, evictedPaths: [for (final clip in evicted) clip.path]);
}

int? _lastLoggedClamp;

bool _shortOfStorage(DashcamStorageHealth health) => health != DashcamStorageHealth.ok && health != DashcamStorageHealth.unknown;

/// Fase 16.2-R4.4-R2 — the free-space guard of a START (D0 §10), run by
/// `DashcamSessionController` before it acquires the camera for a new
/// Recording. Never throws.
///
/// 1. the volume is read — outside any FIFO: a START never waits behind an
///    index write merely to learn there is space;
/// 2. the floor needs `S_res`: a read-only listing of `dashcam_clips/`;
/// 3. at or above the floor → allowed. Below → a pass under pressure, in the
///    index FIFO ([runDashcamQuotaPass]); allowed only if the volume, read
///    again by that pass, is then at or above the floor;
/// 4. a volume that cannot be read → [DashcamStartStorageDecision.unknown]
///    (allowed, reported).
Future<DashcamStartStorageDecision> evaluateDashcamStartStorage({
  required int Function() quotaBytes,
  required VideoResolution Function() resolution,
  required DashcamStorageProbe probe,
  Set<String> Function()? protectedInMemory,
  Set<String> Function()? immunePaths,
  DashcamClipFileOps fileOps = const DashcamClipFileOps(),
}) async {
  try {
    final directory = await dashcamClipsDirectory();
    final volume = await _readVolume(probe, directory);
    if (volume == null) {
      debugPrint('dashcam storage: START with the volume unknown (the storage probe failed); not blocked');
      return const DashcamStartStorageDecision.unknown();
    }
    final segment = _largestByResolution(await _scanClipsDirectory(directory))[resolution()] ?? 0;
    final floor = dashcamStorageFloorBytes(
      totalBytes: volume.totalBytes,
      segmentBytes: segment,
      copyReserve: DashcamClipStorageCounters.lastPlacement == DashcamClipPlacement.copied,
    );
    if (volume.availableBytes >= floor) return DashcamStartStorageDecision.allowed(availableBytes: volume.availableBytes, floorBytes: floor);

    final pass = await runDashcamQuotaPass(
      trigger: DashcamQuotaTrigger.start,
      quotaBytes: quotaBytes,
      resolution: resolution,
      probe: probe,
      protectedInMemory: protectedInMemory,
      immunePaths: immunePaths,
      fileOps: fileOps,
    );
    final available = pass.snapshot?.availableBytes;
    final passFloor = pass.snapshot?.floorBytes;
    if (available == null || passFloor == null) {
      debugPrint('dashcam storage: START with the volume unknown after a pass under pressure; not blocked');
      return DashcamStartStorageDecision.unknown(pass: pass);
    }
    if (available >= passFloor) return DashcamStartStorageDecision.allowed(availableBytes: available, floorBytes: passFloor, pass: pass);
    DashcamStorageCounters.startRefusals++;
    final protectedBytes = pass.snapshot!.protectedBytes;
    final refusal =
        'Armazenamento insuficiente para gravar: ${_inMiB(available)} MB livres, mínimo ${_inMiB(passFloor)} MB'
        '${protectedBytes > 0 ? ' (clipes protegidos ocupam ${_inMiB(protectedBytes)} MB)' : ''}';
    debugPrint('dashcam storage: START refused available=$available floor=$passFloor protected=$protectedBytes');
    return DashcamStartStorageDecision.refused(refusal: refusal, availableBytes: available, floorBytes: passFloor, pass: pass);
  } catch (error) {
    DashcamStorageCounters.probeFailures++;
    debugPrint('dashcam storage: START storage check failed (${error.runtimeType}); not blocked');
    return const DashcamStartStorageDecision.unknown();
  }
}

String _inMiB(int bytes) => (bytes / _mib).toStringAsFixed(0);

/// Fase 16.2-R4.4-R2 — the storage part of the startup (D0 §11.1, after the
/// deletion recovery and the R4.4-R1 reconciliation, before `runApp`). Never
/// throws; deletes no clip.
///
/// 1. in one turn of the index FIFO: a v1 entry whose file is gone (neither
///    at its indexed path nor at `dashcam_clips/<its name>`) is removed —
///    what an eviction killed between its file and its entry leaves. Legacy
///    entries and sessions being deleted are left alone;
/// 2. the accounting of the disk (the clip directory; `cache/REC*` and
///    telemetry read-only);
/// 3. Android: the volume, and the group of every canonical clip and partial
///    (P3-HW-1) — idempotent, a failure only counted;
/// 4. one line.
Future<DashcamStorageSnapshot?> measureDashcamStorageAtStartup({DashcamStorageProbe probe = const MethodChannelDashcamStorageProbe()}) async {
  try {
    Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
    Hive.box(HiveBoxNames.dashcamSessionVideos);
    final directory = await dashcamClipsDirectory();
    final dangling = await runInClipIndexQueue(() => _removeDanglingV1Entries(directory));
    final scan = await _scanClipsDirectory(directory);
    final classified = _classify(scan, protectedInMemory: const {}, immune: const {});
    final rec = await _recordingsInCache();
    final telemetry = await _telemetryBytes(directory.parent);
    DashcamVolumeStats? volume;
    var probeFailed = false;
    var groupRepairFailed = false;
    if (probe.isSupported) {
      volume = await _readVolume(probe, directory);
      probeFailed = volume == null;
      final clipPaths = [for (final clip in scan.files) clip.path];
      if (clipPaths.isNotEmpty) groupRepairFailed = !await _repairGroups(probe, clipPaths);
    }
    final snapshot = _snapshotOf(
      classified,
      scan,
      _largestByResolution(scan),
      trigger: null,
      volume: volume,
      probeFailed: probeFailed,
      rec: rec,
      telemetryBytes: telemetry,
    );
    _latestSnapshot = snapshot;
    final seen = scan.files.isNotEmpty || scan.legacyClipCount > 0 || scan.otherCount > 0 || (rec?.count ?? 0) > 0;
    if (seen || dangling > 0 || probeFailed || groupRepairFailed) {
      debugPrint('${snapshot.describe()} danglingEntriesRemoved=$dangling${groupRepairFailed ? ' groupRepair=FAILED' : ''}');
    }
    return snapshot;
  } catch (error) {
    debugPrint('dashcam storage: startup accounting aborted (${error.runtimeType}); nothing was deleted');
    return null;
  }
}

// ---------------------------------------------------------------------------
// The disk
// ---------------------------------------------------------------------------

class _ScannedFile {
  _ScannedFile(this.path, this.name, this.descriptor, this.size, {required this.partial});

  final String path;
  final String name;
  final DashcamClipDescriptor descriptor;
  final int size;
  final bool partial;
}

class _Scan {
  final List<_ScannedFile> files = [];
  int legacyClipBytes = 0;
  int legacyClipCount = 0;
  int otherBytes = 0;
  int otherCount = 0;

  int get managedBytes => files.fold(0, (sum, file) => sum + file.size);
}

final _legacyClipName = RegExp(r'^clip_[0-9]+\.mp4$');

/// This turn's own reading of [directory]: every entry listed, every regular
/// file `stat`ed. A canonical or partial name that is no longer a regular file
/// when stated (deleted meanwhile) is left out.
Future<_Scan> _scanClipsDirectory(Directory directory) async {
  final scan = _Scan();
  for (final entry in await listDashcamClipsDirectory(directory)) {
    final size = await dashcamClipRegularFileSize(entry.path);
    switch (entry.kind) {
      case DashcamClipEntryKind.canonical:
      case DashcamClipEntryKind.partial:
        if (size != null) scan.files.add(_ScannedFile(entry.path, entry.name, entry.descriptor!, size, partial: entry.kind == DashcamClipEntryKind.partial));
      case DashcamClipEntryKind.invalid:
        if (_legacyClipName.hasMatch(entry.name)) {
          scan.legacyClipCount++;
          scan.legacyClipBytes += size ?? 0;
        } else {
          scan.otherCount++;
          scan.otherBytes += size ?? 0;
        }
    }
  }
  return scan;
}

Map<VideoResolution, int> _largestByResolution(_Scan scan) {
  final largest = <VideoResolution, int>{};
  for (final file in scan.files) {
    if (file.partial) continue;
    final resolution = file.descriptor.resolution;
    largest[resolution] = max(largest[resolution] ?? 0, file.size);
  }
  return largest;
}

Future<DashcamVolumeStats?> _readVolume(DashcamStorageProbe probe, Directory clipsDirectory) async {
  try {
    // The documents directory exists whenever the boxes are open;
    // `dashcam_clips/` may not exist yet. Same volume.
    return await probe.volumeStats(clipsDirectory.parent.path);
  } catch (error) {
    DashcamStorageCounters.probeFailures++;
    debugPrint('dashcam storage: the volume could not be read (${error.runtimeType})');
    return null;
  }
}

/// `true` when nothing failed.
Future<bool> _repairGroups(DashcamStorageProbe probe, List<String> paths) async {
  try {
    final repair = await probe.normalizeClipGroups(paths);
    DashcamStorageCounters.groupRepairs += repair.normalized;
    DashcamStorageCounters.groupRepairFailures += repair.failed;
    if (repair.failed > 0) {
      debugPrint('dashcam storage: cache-group repair failed for ${repair.failed} clip(s) (kept; retried at the next start)');
      return false;
    }
    return true;
  } catch (error) {
    DashcamStorageCounters.groupRepairFailures++;
    debugPrint('dashcam storage: cache-group repair could not run (${error.runtimeType}); clips kept, retried at the next start');
    return false;
  }
}

class _RecordingsInCache {
  const _RecordingsInCache(this.count, this.bytes, this.empty);

  final int count;
  final int bytes;
  final int empty;
}

final _recordingName = RegExp(r'^REC.*\.mp4$');

/// The plugin's recordings in `cache/` — read only, never written, deleted or
/// adopted (R4.4-R3 / D2). `null` when the directory cannot be read.
Future<_RecordingsInCache?> _recordingsInCache() async {
  try {
    final cache = await getTemporaryDirectory();
    var count = 0;
    var bytes = 0;
    var empty = 0;
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is! File || !_recordingName.hasMatch(dashcamClipBasename(entity.path))) continue;
      final size = await dashcamClipRegularFileSize(entity.path);
      if (size == null) continue;
      count++;
      bytes += size;
      if (size == 0) empty++;
    }
    return _RecordingsInCache(count, bytes, empty);
  } catch (_) {
    return null;
  }
}

Future<int?> _telemetryBytes(Directory documents) async {
  try {
    final directory = Directory('${documents.path}/dashcam_telemetry');
    if (!await directory.exists()) return 0;
    var bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) bytes += await dashcamClipRegularFileSize(entity.path) ?? 0;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

class _ClassifiedClip {
  _ClassifiedClip(this.file, this.storageClass, {required this.isProtected});

  final _ScannedFile file;
  final DashcamStorageClass storageClass;
  final bool isProtected;

  String get path => file.path;
  DashcamClipDescriptor get descriptor => file.descriptor;
  int get size => file.size;
}

/// Step 2 of a pass — synchronous from its first line to its last.
List<_ClassifiedClip> _classify(_Scan scan, {required Set<String> protectedInMemory, required Set<String> immune}) {
  final sessions = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  final videos = Hive.box(HiveBoxNames.dashcamSessionVideos);
  final entries = _indexEntriesByClipId(videos);

  final canonical = [
    for (final file in scan.files)
      if (!file.partial) file,
  ];
  final namesPerClipId = <String, int>{};
  for (final file in canonical) {
    namesPerClipId[file.descriptor.clipId] = (namesPerClipId[file.descriptor.clipId] ?? 0) + 1;
  }
  _ScannedFile? newest;
  for (final file in canonical) {
    if (newest == null || DashcamClipDescriptor.compareOrder(file.descriptor, newest.descriptor) > 0) newest = file;
  }

  return [
    for (final file in scan.files)
      if (file.partial)
        _ClassifiedClip(file, DashcamStorageClass.partial, isProtected: file.descriptor.isProtected)
      else
        _classifyCanonical(file, sessions, entries, namesPerClipId, protectedInMemory, immune: identical(file, newest) || immune.contains(file.path)),
  ];
}

_ClassifiedClip _classifyCanonical(
  _ScannedFile file,
  Box<DrivingSession> sessions,
  Map<String, List<_IndexedEntry>> entries,
  Map<String, int> namesPerClipId,
  Set<String> protectedInMemory, {
  required bool immune,
}) {
  final descriptor = file.descriptor;
  final sessionId = descriptor.sessionId;
  final named = entries[descriptor.clipId] ?? const <_IndexedEntry>[];
  final own = [
    for (final entry in named)
      if (entry.sessionId == sessionId && entry.name == file.name) entry,
  ];
  final isProtected = descriptor.isProtected || own.any((entry) => entry.record.isProtected) || protectedInMemory.contains(file.path);
  _ClassifiedClip classed(DashcamStorageClass storageClass) => _ClassifiedClip(file, storageClass, isProtected: isProtected);

  if (namesPerClipId[descriptor.clipId]! > 1 || own.length != named.length || own.length > 1) return classed(DashcamStorageClass.conflict);
  final record = sessions.get(sessionId);
  if (record == null) return classed(DashcamStorageClass.orphan);
  if (record.deletionPending || sessionDeletionCommitted(sessionId)) return classed(DashcamStorageClass.deletionPending);
  if (own.isEmpty) return classed(DashcamStorageClass.unindexed);
  if (isProtected) return classed(DashcamStorageClass.protected);
  return classed(immune ? DashcamStorageClass.immune : DashcamStorageClass.evictable);
}

class _IndexedEntry {
  const _IndexedEntry(this.sessionId, this.name, this.record);

  final Object? sessionId;
  final String name;
  final DashcamClipRecord record;
}

/// Every v1 entry of the index, by clip id — for the identity check and the
/// protection of the entry.
Map<String, List<_IndexedEntry>> _indexEntriesByClipId(Box videos) {
  final byClipId = <String, List<_IndexedEntry>>{};
  for (final key in videos.keys) {
    final raw = videos.get(key);
    if (raw is! List) continue;
    for (final entry in raw) {
      if (entry is! DashcamClipRecord) continue;
      final name = dashcamClipBasename(entry.filePath);
      final descriptor = DashcamClipDescriptor.parse(name);
      if (descriptor == null) continue;
      byClipId.putIfAbsent(descriptor.clipId, () => []).add(_IndexedEntry(key, name, entry));
    }
  }
  return byClipId;
}

DashcamStorageSnapshot _snapshotOf(
  List<_ClassifiedClip> clips,
  _Scan scan,
  Map<VideoResolution, int> largest, {
  required DashcamQuotaTrigger? trigger,
  int? configured,
  int? effective,
  int segment = 0,
  int evictedCount = 0,
  int evictedBytes = 0,
  int pressureEvicted = 0,
  DashcamVolumeStats? volume,
  int? floor,
  bool probeFailed = false,
  _RecordingsInCache? rec,
  int? telemetryBytes,
}) {
  final bytes = <DashcamStorageClass, int>{};
  final counts = <DashcamStorageClass, int>{};
  var protectedBytes = 0;
  for (final clip in clips) {
    bytes[clip.storageClass] = (bytes[clip.storageClass] ?? 0) + clip.size;
    counts[clip.storageClass] = (counts[clip.storageClass] ?? 0) + 1;
    if (clip.isProtected && clip.storageClass != DashcamStorageClass.partial) protectedBytes += clip.size;
  }
  final managed = bytes.values.fold<int>(0, (sum, value) => sum + value);
  final health = dashcamStorageHealthOf(
    managedBytes: managed,
    effectiveQuotaBytes: effective,
    protectedBytes: protectedBytes,
    segmentBytes: segment,
    availableBytes: volume?.availableBytes,
    totalBytes: volume?.totalBytes,
    floorBytes: floor,
  );
  return DashcamStorageSnapshot(
    trigger: trigger,
    bytesByClass: Map.unmodifiable(bytes),
    countByClass: Map.unmodifiable(counts),
    protectedBytes: protectedBytes,
    legacyClipBytes: scan.legacyClipBytes,
    legacyClipCount: scan.legacyClipCount,
    otherBytes: scan.otherBytes,
    otherCount: scan.otherCount,
    largestSegmentBytes: Map.unmodifiable(largest),
    health: health,
    configuredQuotaBytes: configured,
    effectiveQuotaBytes: effective,
    evictedCount: evictedCount,
    evictedBytes: evictedBytes,
    pressureEvictedCount: pressureEvicted,
    availableBytes: volume?.availableBytes,
    totalBytes: volume?.totalBytes,
    floorBytes: floor,
    probeFailed: probeFailed,
    recBytes: rec?.bytes,
    recCount: rec?.count,
    recEmptyCount: rec?.empty,
    telemetryBytes: telemetryBytes,
  );
}

/// The most severe state that holds. The protected ceiling is the effective
/// quota minus two segments (D0 §8) — above it, protected clips alone keep
/// the quota from retaining the segments the loop needs.
DashcamStorageHealth dashcamStorageHealthOf({
  required int managedBytes,
  required int? effectiveQuotaBytes,
  required int protectedBytes,
  required int segmentBytes,
  required int? availableBytes,
  required int? totalBytes,
  required int? floorBytes,
}) {
  if (availableBytes != null && totalBytes != null) {
    if (availableBytes < dashcamStorageTrimBytes(totalBytes)) return DashcamStorageHealth.critical;
    if (floorBytes != null && availableBytes < floorBytes) return DashcamStorageHealth.lowDisk;
  }
  if (effectiveQuotaBytes != null) {
    if (protectedBytes > effectiveQuotaBytes - 2 * segmentBytes) return DashcamStorageHealth.protectedSaturated;
    if (managedBytes > effectiveQuotaBytes) return DashcamStorageHealth.quotaSaturated;
  }
  if (availableBytes == null) return DashcamStorageHealth.unknown;
  return DashcamStorageHealth.ok;
}

// ---------------------------------------------------------------------------
// Eviction
// ---------------------------------------------------------------------------

enum _EvictionOutcome { evicted, noLongerEvictable, fileFailed, entryFailed }

/// One clip out (D0 §11.2), inside the pass's turn:
///  a. in ONE synchronous slice: the clip is decided again from the CURRENT
///     record, entry, [protectedInMemory] and [immunePaths] — and its deletion
///     is issued in that same slice, so nothing (a protection above all) can
///     run between the last check and the unlink;
///  b. the file must be gone afterwards (`lstat`): an absent file is done, one
///     still there is a failure (the pass stops; nothing else is touched);
///  c. in one synchronous slice: unless the session's deletion is committed
///     (it owns the key) or the key is gone, the entry with the clip's name is
///     removed from the CURRENT list — the key itself when that empties it —
///     and the write is awaited.
/// File FIRST: the file is the durable obligation (R4.4-R1). The entry first
/// and a death before the file would leave a canonical clip without an entry,
/// which the next start's reconciliation indexes again.
Future<_EvictionOutcome> _evict(
  _ClassifiedClip victim, {
  required Set<String> Function() protectedInMemory,
  required Set<String> Function() immunePaths,
  required DashcamClipFileOps fileOps,
}) async {
  final path = victim.path;
  if (!_stillEvictable(victim, protectedInMemory(), immunePaths())) return _EvictionOutcome.noLongerEvictable;
  final deleting = fileOps.delete(path);
  try {
    await deleting;
  } on FileSystemException {
    // Already gone, or failed: what is on disk decides, right below.
  }
  bool stillThere;
  try {
    stillThere = await fileOps.isOccupied(path);
  } catch (_) {
    stillThere = true;
  }
  if (stillThere) {
    DashcamStorageCounters.evictionFileFailures++;
    debugPrint('dashcam storage: eviction failed at the file (kept, indexed; the next pass tries again)');
    return _EvictionOutcome.fileFailed;
  }
  final deleted = afterEvictedFileDeletedHookForTest;
  if (deleted != null) await deleted(path);
  try {
    await _removeIndexEntry(victim.descriptor, victim.file.name);
  } catch (error) {
    DashcamStorageCounters.evictionEntryFailures++;
    debugPrint('dashcam storage: eviction failed at the index entry (${error.runtimeType}); the file is gone, the entry is removed by the next start');
    return _EvictionOutcome.entryFailed;
  }
  return _EvictionOutcome.evicted;
}

bool _stillEvictable(_ClassifiedClip victim, Set<String> protectedInMemory, Set<String> immune) {
  final descriptor = victim.descriptor;
  final sessionId = descriptor.sessionId;
  if (protectedInMemory.contains(victim.path) || immune.contains(victim.path)) return false;
  final record = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(sessionId);
  if (record == null || record.deletionPending || sessionDeletionCommitted(sessionId)) return false;
  final raw = Hive.box(HiveBoxNames.dashcamSessionVideos).get(sessionId);
  if (raw is! List) return false;
  final own = [
    for (final entry in raw)
      if (entry is DashcamClipRecord && dashcamClipBasename(entry.filePath) == victim.file.name) entry,
  ];
  return own.length == 1 && !own.single.isProtected;
}

Future<void> _removeIndexEntry(DashcamClipDescriptor descriptor, String name) async {
  final sessionId = descriptor.sessionId;
  if (sessionDeletionCommitted(sessionId)) return;
  final videos = Hive.box(HiveBoxNames.dashcamSessionVideos);
  final raw = videos.get(sessionId);
  if (raw is! List) return;
  final entries = List<DashcamClipRecord>.from(raw);
  final kept = [
    for (final entry in entries)
      if (dashcamClipBasename(entry.filePath) != name) entry,
  ];
  if (kept.length == entries.length) return;
  // The History lists a session's video by the key's presence.
  if (kept.isEmpty) {
    await videos.delete(sessionId);
  } else {
    await videos.put(sessionId, kept);
  }
}

/// Startup step 1 — the number of entries removed. Per session, the dangling
/// names are found first (I/O), then removed from the CURRENT list in one
/// synchronous slice with the write.
Future<int> _removeDanglingV1Entries(Directory directory) async {
  final sessions = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  final videos = Hive.box(HiveBoxNames.dashcamSessionVideos);
  var removed = 0;
  for (final key in videos.keys.toList()) {
    final raw = videos.get(key);
    if (raw is! List || key is! String) continue;
    final record = sessions.get(key);
    if (sessionDeletionCommitted(key) || (record != null && record.deletionPending)) continue;
    final dangling = <String>{};
    for (final entry in raw) {
      if (entry is! DashcamClipRecord) continue;
      final name = dashcamClipBasename(entry.filePath);
      if (DashcamClipDescriptor.parse(name) == null) continue;
      if (await dashcamClipPathOccupied(entry.filePath) || await dashcamClipPathOccupied('${directory.path}/$name')) continue;
      dangling.add(name);
    }
    if (dangling.isEmpty) continue;
    try {
      final current = videos.get(key);
      if (current is! List || sessionDeletionCommitted(key)) continue;
      final entries = List<DashcamClipRecord>.from(current);
      final kept = [
        for (final entry in entries)
          if (!dangling.contains(dashcamClipBasename(entry.filePath))) entry,
      ];
      if (kept.length == entries.length) continue;
      if (kept.isEmpty) {
        await videos.delete(key);
      } else {
        await videos.put(key, kept);
      }
      removed += entries.length - kept.length;
    } catch (error) {
      DashcamStorageCounters.danglingEntryFailures += dangling.length;
      debugPrint('dashcam storage: ${dangling.length} index entr(ies) without a file could not be removed (${error.runtimeType}); retried at the next start');
    }
  }
  DashcamStorageCounters.danglingEntriesRemoved += removed;
  return removed;
}
