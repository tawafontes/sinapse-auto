// Fase 16.2-R4.4-R2.1.1-F1-R — positive controls of the index FIFO's boundary
// between tests (indexQueueSettledForTest, test/support/index_queue_isolation.dart).
//
// The tests below leave index work in the process-wide FIFO when their bodies
// end, on purpose — the way a test that does not read the index leaves its
// STOP's passes (F1-R) — with each turn made slow, as by the review's latency
// probe. Every test of the file, in any order (--test-randomize-ordering-seed),
// starts by checking that nothing an earlier test queued is still in the FIFO,
// that it settled while the test that queued it was still running, and how;
// tearDownAll checks the last one. Removing or misplacing the boundary in this
// file's tearDown fails the test that follows a leaving one.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';
import 'package:synapse_auto/services/dashcam_clip_index.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/index_queue_isolation.dart';

/// Index work a test left in the FIFO on purpose: which test queued it (by its
/// position in the run), in which test it settled, and what it was left for.
class _Left {
  _Left(this.what, this.queuedIn, {this.outcome, this.reportsOnce = false, this.errorOnce = false});

  final String what;
  final int queuedIn;
  final ClipIndexOutcome? outcome;
  final bool reportsOnce;
  final bool errorOnce;
  int? settledIn;
  ClipIndexOutcome? settledWith;
  final List<int> reportedIn = [];
  final List<int> erroredIn = [];

  void check() {
    expect(settledIn, queuedIn, reason: '$what: settled within the test that queued it (null: still in the FIFO)');
    if (outcome != null) expect(settledWith, outcome, reason: '$what: settled as it was left to, in its own test\'s boxes');
    if (reportsOnce) expect(reportedIn, [queuedIn], reason: '$what: its failure reported once, to the test that queued it');
    if (errorOnce) expect(erroredIn, [queuedIn], reason: '$what: its error surfaced once — not swallowed — in the test that queued it');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory clipsDir;
  var testNumber = 0;
  var rid = 0;
  final left = <_Left>[];
  final ns = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padRight(32, 'f');

  _Left leave(String what, {ClipIndexOutcome? outcome, bool reportsOnce = false, bool errorOnce = false}) {
    final work = _Left(what, testNumber, outcome: outcome, reportsOnce: reportsOnce, errorOnce: errorOnce);
    left.add(work);
    return work;
  }

  String publishClip(String sessionId) {
    final descriptor = DashcamClipDescriptor.tryCreate(
      sessionId: sessionId,
      recordedAt: DateTime(2026, 10, 29, 9).add(Duration(seconds: ++rid)),
      namespace: ns,
      recordingId: rid,
      durationSeconds: 3,
      isProtected: false,
      resolution: VideoResolution.hd720,
      audioEnabled: false,
    )!;
    final path = '${clipsDir.path}/${descriptor.basename}';
    File(path).writeAsBytesSync(List<int>.filled(64, 1));
    return path;
  }

  /// Whether nothing that needs the event loop is ahead in the FIFO: a turn
  /// queued now runs before a timer armed now.
  Future<bool> fifoIdle() async {
    var eventLoopTurned = false;
    Timer.run(() => eventLoopTurned = true);
    var idle = false;
    await runInClipIndexQueue(() async => idle = !eventLoopTurned);
    return idle;
  }

  /// The boundary's contract: what every earlier test left settled while that
  /// test was still running, as it was left to — and the FIFO is idle.
  Future<void> nothingOfAnEarlierTest() async {
    for (final work in left) {
      work.check();
    }
    expect(await fifoIdle(), isTrue, reason: 'nothing of an earlier test is ahead in the index FIFO');
  }

  /// X536's own release of the write it holds (null once released).
  void Function()? releaseHeldWrite;

  setUp(() async {
    await nothingOfAnEarlierTest();
    testNumber++;

    dir = Directory.systemTemp.createTempSync('index_queue_isolation_test');
    clipsDir = Directory('${dir.path}/$dashcamClipsDirectoryName')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(VideoResolutionAdapter());
      Hive.registerAdapter(DashcamClipRecordAdapter());
    }
    Hive.init(dir.path);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
  });

  tearDown(() async {
    // The boundary under test: after the test released what it holds (its own
    // addTearDown/finally), before the boxes close and the directory goes.
    await indexQueueSettledForTest();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, null);
    dir.deleteSync(recursive: true);
  });

  // The last test of the run has no next one to check it.
  tearDownAll(nothingOfAnEarlierTest);

  group('Fase 16.2-R4.4-R2.1.1-F1-R — a test leaves index work in the FIFO on purpose', () {
    test(
      'X533 — an index write still running when the body ends (300 ms a turn), and the turn its settling queues behind it '
      '(as a segment\'s write queues its quota pass): both settle in this test, the write into this test\'s boxes',
      () async {
        final path = publishClip('X533-S');
        final write = leave('X533 write', outcome: ClipIndexOutcome.indexed);
        final queuedBehind = leave('X533 turn queued as the write settles');
        unawaited(
          ensureClipIndexed(
            path,
            origin: ClipIndexOrigin.producedInThisProcess,
            writeHookForTest: (sessionId, paths, writeCall) async {
              // The slow index is the scenario, not a wait.
              await Future<void>.delayed(const Duration(milliseconds: 300));
              await writeCall();
            },
          ).then((outcome) {
            write
              ..settledWith = outcome
              ..settledIn = testNumber;
            unawaited(
              runInClipIndexQueue(() => Future<void>.delayed(const Duration(milliseconds: 100))).then((_) => queuedBehind.settledIn = testNumber),
            );
          }),
        );
        expect(write.settledIn, isNull, reason: 'setup: the write is still in the FIFO when the body ends — never awaited, as by a test that does not read the index');
      },
    );

    test('X534 — a pass that fails after the body ends: it settles as pending, its failure reported once, to this test', () async {
      final path = publishClip('X534-S');
      final failing = leave('X534 failing write', outcome: ClipIndexOutcome.indexPending, reportsOnce: true);
      unawaited(
        ensureClipIndexed(
          path,
          origin: ClipIndexOrigin.producedInThisProcess,
          writeHookForTest: (sessionId, paths, writeCall) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            throw StateError('X534: injected index write failure');
          },
          report: (message) => failing.reportedIn.add(testNumber),
        ).then((outcome) {
          failing
            ..settledWith = outcome
            ..settledIn = testNumber;
        }),
      );
      expect(failing.settledIn, isNull, reason: 'setup: the pass is still in the FIFO when the body ends');
    });

    test(
      'X535 — a turn whose error nobody handles, after the body ends: it surfaces in this test (into the zone this test set '
      'up to receive it), never swallowed, never in the next test',
      () async {
        final unexpected = leave('X535 unexpected error', errorOnce: true);
        runZonedGuarded(
          () {
            // Its Future is deliberately left unhandled: the error is unexpected.
            unawaited(
              runInClipIndexQueue<void>(() async {
                await Future<void>.delayed(const Duration(milliseconds: 300));
                unexpected.settledIn = testNumber;
                throw StateError('X535: unexpected error in an index turn');
              }),
            );
          },
          (error, stackTrace) => unexpected.erroredIn.add(testNumber),
        );
        expect(unexpected.settledIn, isNull, reason: 'setup: the turn is still in the FIFO when the body ends');
      },
    );

    test(
      'X536 — a test holds its own index write and releases it itself: while held, the turn behind it waits (FIFO order, '
      'the test\'s own contract, untouched); once the test released it, both settle in this test',
      () async {
        final path = publishClip('X536-S');
        final held = leave('X536 held write', outcome: ClipIndexOutcome.indexed);
        final behind = leave('X536 turn behind the held write');
        final gate = Completer<void>();
        final entered = Completer<void>();
        releaseHeldWrite = () {
          if (!gate.isCompleted) gate.complete();
          releaseHeldWrite = null;
        };
        // The test's own release — before the file's tearDown and its boundary.
        addTearDown(() => releaseHeldWrite?.call());
        unawaited(
          ensureClipIndexed(
            path,
            origin: ClipIndexOrigin.producedInThisProcess,
            writeHookForTest: (sessionId, paths, writeCall) async {
              entered.complete();
              await gate.future;
              await Future<void>.delayed(const Duration(milliseconds: 300));
              await writeCall();
            },
          ).then((outcome) {
            held
              ..settledWith = outcome
              ..settledIn = testNumber;
          }),
        );
        unawaited(runInClipIndexQueue(() async {}).then((_) => behind.settledIn = testNumber));
        await entered.future;
        await pumpEventQueue(times: 20);
        expect(held.settledIn, isNull, reason: 'the write is held by this test');
        expect(behind.settledIn, isNull, reason: 'the turn behind the held write waits for it');
      },
    );
  });

  test(
    'X538 — the test waits for its write, but the turn that write queues as it settles reaches the FIFO only after a long chain '
    'of continuations, once the body ended — while the boundary\'s first turn holds the FIFO: it settles in this test',
    () async {
      final path = publishClip('X538-S');
      final write = leave('X538 write', outcome: ClipIndexOutcome.indexed);
      final queuedLate = leave('X538 turn queued after a long chain of continuations');
      final outcome = ensureClipIndexed(path, origin: ClipIndexOrigin.producedInThisProcess);
      unawaited(
        outcome.then((settled) async {
          write
            ..settledWith = settled
            ..settledIn = testNumber;
          for (var i = 0; i < 1000; i++) {
            await Future<void>.microtask(() {});
          }
          unawaited(runInClipIndexQueue(() => Future<void>.delayed(const Duration(milliseconds: 300))).then((_) => queuedLate.settledIn = testNumber));
        }),
      );
      await outcome;
    },
  );

  test('X537 — a test that leaves nothing starts, like every test here, with nothing of an earlier test in the FIFO', () async {
    // Its check is the file's setUp; the FIFO is still idle here.
    expect(await fifoIdle(), isTrue);
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
