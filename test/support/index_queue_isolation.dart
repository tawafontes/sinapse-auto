// Fase 16.2-R4.4-R2.1.1-F1-R — the boundary of the index FIFO between tests
// (test isolation; not a product change).
//
// The index FIFO (`ensureClipIndexed`, `runInClipIndexQueue` — the storage
// quota's passes run there too) is one queue per process, and `flutter test`
// runs the tests of a file one after the other in one process. Since
// R4.4-R2.1.1 (RES-1) `stopSession()` no longer waits for its index passes, by
// owner decision, so a test that does not read the index — and rightly does
// not wait for it — can end with turns still queued. At real speed they settle
// during the tearDown's own waits; with each turn slower (the review's latency
// probe, +250 to +500 ms) they ran inside LATER tests: L5-T and X65 found the
// turns of up to 50 earlier tests ahead of their own, and their bounded polls
// ran out. A leftover quota pass also resolves `dashcam_clips/` through
// path_provider when it RUNS — in the next test's directory.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/dashcam_clip_index.dart' show DashcamClipIndexCounters, runInClipIndexQueue;
import 'package:synapse_auto/services/dashcam_service.dart' show DashcamService;
import 'package:synapse_auto/services/dashcam_storage_quota.dart' show DashcamStorageCounters;

/// Returns once the process-wide index FIFO holds nothing: every turn queued so
/// far has settled, and so has every turn those queued behind them as they
/// settled (a segment's index write queues its quota pass; a STOP pass queues a
/// retry after the write it waited for).
///
/// Call it in a tearDown, after the test released what it holds — its own
/// gates and hooks, in its `finally` — and every camera is released (the late
/// STOP pass of a native STOP still in flight would queue a turn after this
/// returned: a camera still held fails the test here), and before the boxes
/// close and the directory goes. The test's assertions have all run by then,
/// so the turns it waits for cannot change what the test checked; whatever
/// they report — an error included — reaches the test that queued them (they
/// run in its zone), before the next test starts.
///
/// It waits for no guessed time: a turn that never settles holds it, and the
/// test fails on its timeout — a leak is never let through.
///
/// Why the whole FIFO and not each controller's own passes
/// (`clipIndexFollowUpsSettledForTest`): those are the STOP's passes only, of a
/// controller the tearDown can see. A segment's index write and the quota pass
/// after it belong to no one, and most tests build their own controllers.
/// Every one of them is a turn of this FIFO, and the previous test's call left
/// it empty: what it holds when this runs was queued by this test.
Future<void> indexQueueSettledForTest() async {
  expect(
    DashcamService.processOwnerCurrentForTest,
    isNull,
    reason: 'indexQueueSettledForTest: a camera is still held — its late STOP pass could queue an index turn after the boundary',
  );
  for (var round = 0; ; round++) {
    final activity = _indexActivity();
    var eventLoopTurned = false;
    Timer.run(() => eventLoopTurned = true);
    var quiet = false;
    await runInClipIndexQueue(() async {
      // Nothing that needed the event loop (an index write's I/O, a quota
      // pass's scan) was still ahead of this turn, and no index turn or quota
      // pass settled since the previous one.
      quiet = !eventLoopTurned && _indexActivity() == activity;
      // While this turn holds the FIFO, every continuation already runnable
      // runs — a quota pass or a retry that a settled turn queues among them —
      // so what they queue lands behind this turn, where the next round sees
      // it.
      await _runnableContinuationsRun();
    });
    // Round 0 cannot conclude: what settled just before it may queue more
    // while it holds the FIFO.
    if (quiet && round > 0) return;
  }
}

/// Every ensureClipIndexed outcome and every quota pass, counted when it
/// settles. Compared for equality: a test may reset them.
int _indexActivity() {
  var total = DashcamStorageCounters.passes + DashcamStorageCounters.passesAborted;
  for (final count in DashcamClipIndexCounters.snapshot().values) {
    total += count;
  }
  return total;
}

/// Completes in the event loop's next timer phase, which comes only once the
/// microtask queue is empty: every continuation runnable when it was called has
/// run by then. Not a wait for time to pass — zero duration, the same at any
/// speed.
Future<void> _runnableContinuationsRun() {
  final done = Completer<void>();
  Timer.run(done.complete);
  return done.future;
}
