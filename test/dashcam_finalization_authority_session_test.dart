// Fase 16.2-R4.3-R2.6.12 — X190–X193: a late telemetry outcome never finalizes a
// session in its recorder's place, under the REAL DashcamSessionController (+
// DashcamService over the fake camera platform, the real recorder over real
// Hive, the real DashcamTelemetryWriter). Independent review of R2.6.11 (P2,
// reproduced — scratchpad/fase16_2_r4_3_independent_review_r2611, probes O2,
// O4 and the app's real root teardown): the recorder's finalization failed, the
// host was torn down — recorder.dispose(), then controller.dispose(), the order
// of DrivingSessionHost.dispose() — and the STOP's own pending callback then
// closed the telemetry file and recorded its outcome: with no recorder left in
// control it wrote the cached record, end time of the failed finalization
// included. On disk: a finished session declaring 3 samples with none stored,
// which the startup recovery no longer reclaimed.
//
// The fixture is the one of dashcam_telemetry_outcome_session_test.dart:
// telemetry samples come from DetectedEvents with speeds 1..N; a session's
// telemetry file is behind test/support/telemetry_io_gate.dart when it is
// started inside `gate.run` (hold = a hung disk, failNext = a write error).
// The recorder's own samples come from its snapshot stream. Its finalization is
// made to fail at the samples checkpoint with the suite's own injections: the
// samples box closed, or an adapter that throws while serializing (the box
// open, the write failing before it takes effect). What is durable is read
// from the box FILES (support/hive_file_snapshot.dart), and a next start is
// every box closed and reopened plus the real startup recovery.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/screens/sessions/session_history_screen.dart' show visibleSessionsSortedByRecency;
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_camera_platform.dart';
import 'support/hive_file_snapshot.dart';
import 'support/index_queue_isolation.dart';
import 'support/telemetry_io_gate.dart';

/// Outcome of a Future observed without awaiting it.
class _Watched {
  _Watched(Future<Object?> future) {
    future.then<void>(
      (_) {
        done = true;
      },
      onError: (Object e, StackTrace _) {
        done = true;
        error = e;
      },
    );
  }
  bool done = false;
  Object? error;
}

/// Runs [body] in one error zone and returns its uncaught asynchronous
/// errors; a failure of [body] itself is rethrown outside the zone.
Future<List<Object>> _uncaughtErrorsOf(Future<void> Function() body) {
  final uncaught = <Object>[];
  final done = Completer<List<Object>>();
  runZonedGuarded(() async {
    try {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      done.complete(uncaught);
    } catch (e, s) {
      done.completeError(e, s);
    }
  }, (e, s) => uncaught.add(e));
  return done.future;
}

Future<Object?> _errorOf(Future<Object?> f) async {
  try {
    await f.timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

/// How the recorder's finalization is made to fail at its samples checkpoint.
enum _SamplesFailure {
  /// The samples box is unavailable (a HiveError).
  boxClosed,

  /// The box is open and the write fails before a byte reaches the file.
  writeFailsBeforeEffect,
}

/// A sample adapter whose every serialization fails.
class _WriteFailingSampleAdapter extends DrivingSessionSampleAdapter {
  @override
  void write(BinaryWriter writer, DrivingSessionSample obj) => throw StateError('injected failure while serializing a sample');
}

/// Every call the generated adapter makes on a writer, in order.
class _FieldCapture implements BinaryWriter {
  final entries = <Object?>[];

  @override
  void writeByte(int value) => entries.add(value);

  @override
  void write<T>(T value, {bool writeTypeId = true}) => entries.add(value is List ? 'List(${value.length})' : value);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('$invocation');
}

/// What the adapter persists for [s]: field index → value.
Map<int, Object?> _fieldsOf(DrivingSession s) {
  final capture = _FieldCapture();
  DrivingSessionAdapter().write(capture, s);
  final e = capture.entries;
  return {for (var i = 1; i + 1 < e.length; i += 2) e[i]! as int: e[i + 1]};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeCameraPlatform fakePlatform;
  late StreamController<TelemetrySnapshot> recorderSnapshots;
  late StreamController<TelemetrySnapshot> controllerSnapshots;
  late StreamController<DetectedEvent> events;
  late DrivingSessionRecorder recorder;
  late DashcamPreferences preferences;
  late DashcamService service;
  late DashcamSessionController controller;
  late TelemetryIoGate gate;
  late int emitted;
  late List<DashcamTelemetryWriter> writers;
  late List<FlutterErrorDetails> reported;
  late void Function(FlutterErrorDetails details)? previousOnError;
  var disposed = false;
  var clock = DateTime(2026, 7, 1, 8);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const samplesBox = HiveBoxNames.drivingSessionSamples;

  Future<void> until(bool Function() condition, String label, {Duration timeout = const Duration(seconds: 5)}) async {
    final sw = Stopwatch()..start();
    while (!condition()) {
      if (sw.elapsed > timeout) fail('timed out waiting for: $label');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// [n] DetectedEvents (warning: no clip protection); event #i carries speed
  /// i, and becomes exactly one telemetry sample.
  void emit(int n) {
    for (var k = 0; k < n; k++) {
      emitted++;
      final now = DateTime.now();
      events.add(
        DetectedEvent(
          type: DetectedEventType.hardCorneringLeft,
          timestamp: now,
          severity: EventSeverity.warning,
          snapshot: TelemetrySnapshot(timestamp: now, speedKmh: emitted.toDouble(), gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable),
        ),
      );
    }
  }

  /// [n] snapshots to the recorder, 2 s apart: [session] accepts each as one
  /// sample. Returns once the record's own write of each has landed.
  Future<void> recorderSamples(DrivingSession session, int n) async {
    final target = session.sampleCount + n;
    for (var i = 0; i < n; i++) {
      clock = clock.add(const Duration(seconds: 2));
      recorderSnapshots.add(TelemetrySnapshot(timestamp: clock, speedKmh: 40, gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable));
    }
    await until(() => session.sampleCount == target, 'the recorder accepted $n samples');
    await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).flush();
  }

  String jsonl(String id) => '${dir.path}/dashcam_telemetry/$id.jsonl';

  Future<List<int?>> speedsOf(String id) async => [for (final s in await loadDashcamTelemetry(id)) s.speedKmh?.toInt()];

  List<int> range(int from, int to) => [for (var i = from; i <= to; i++) i];

  bool cameraReleasedOf(DashcamService s) => DashcamService.processOwnerCurrentForTest == null && s.previewController == null;

  bool cameraReleased() => cameraReleasedOf(service);

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);

  Future<void> openBoxes() async {
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(samplesBox);
    await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
  }

  /// The next start of the app, as far as sessions go: every box as its file
  /// has it, the real startup recovery, and every box closed and reopened once
  /// more — so what the recovery did is read from the files too.
  Future<void> nextStart() async {
    await Hive.close();
    await openBoxes();
    await recoverDrivingSessionsAtStartup();
    await Hive.close();
    await openBoxes();
  }

  /// What the FILES hold about session [id], as text.
  Future<String> onDisk(String id) async {
    final r = await sessionRecordOnDisk(dir, id);
    final stored = await sessionSamplesOnDisk(dir, id);
    if (r == null) return 'no record, stored=${stored?.length}';
    final outcome = r.dashcamTelemetryOutcome == DashcamTelemetryOutcome.unknown
        ? 'unknown'
        : '${r.dashcamTelemetryOutcome.name} ${r.dashcamTelemetryAcceptedCount}/${r.dashcamTelemetryPersistedCount}/${r.dashcamTelemetryRefusedCount}';
    return '${r.deletionPending ? 'MARKED ' : ''}${r.endTime == null ? 'ACTIVE' : 'ENDED'} declared=${r.sampleCount} stored=${stored?.length ?? 0} telemetry=$outcome';
  }

  /// Makes the next finalization fail at its samples checkpoint; returns what
  /// undoes the injection.
  Future<Future<void> Function()> failSamplesCheckpoint(_SamplesFailure how) async {
    switch (how) {
      case _SamplesFailure.boxClosed:
        await Hive.lazyBox(samplesBox).close();
        return () => Hive.openLazyBox(samplesBox);
      case _SamplesFailure.writeFailsBeforeEffect:
        Hive.registerAdapter<DrivingSessionSample>(_WriteFailingSampleAdapter(), override: true);
        return () async => Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
    }
  }

  Matcher errorOf(_SamplesFailure how) => how == _SamplesFailure.boxClosed ? isA<HiveError>() : isA<StateError>();

  DashcamService buildService() => DashcamService(
    config: DashcamConfig(
      cameraSelection: CameraSelection.rear,
      storageQuotaMb: 1024,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
    ),
    segmentDuration: const Duration(minutes: 10),
  );

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_finalization_authority_session_test');
    fakePlatform = FakeCameraPlatform(tempDir: dir);
    CameraPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
      Hive.registerAdapter(CameraSelectionAdapter());
      Hive.registerAdapter(VideoResolutionAdapter());
      Hive.registerAdapter(DashcamConfigAdapter());
      Hive.registerAdapter(DashcamClipRecordAdapter());
    }
    Hive.init(dir.path);
    await openBoxes();

    recorderSnapshots = StreamController<TelemetrySnapshot>.broadcast();
    controllerSnapshots = StreamController<TelemetrySnapshot>.broadcast();
    events = StreamController<DetectedEvent>.broadcast();
    recorder = DrivingSessionRecorder(recorderSnapshots.stream);
    preferences = DashcamPreferences();
    service = buildService();
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: controllerSnapshots.stream,
      eventStream: events.stream,
    );
    await preferences.setEnabled(true);
    gate = TelemetryIoGate();
    emitted = 0;
    writers = [];
    disposed = false;
    reported = [];
    previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    controller.openTelemetryWriterHookForTest = (w, open) {
      writers.add(w);
      return open();
    };
  });

  tearDown(() async {
    FlutterError.onError = previousOnError;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
    // A failed assertion must not leave a delivery held behind the teardown.
    gate.hold = false;
    gate.releaseAll();
    // …nor a telemetry outcome still being written when the boxes close.
    await controller.telemetryFinalizationsForTest();
    if (!disposed) {
      try {
        controller.dispose();
      } catch (_) {}
    }
    for (var i = 0; i < 300 && DashcamService.processOwnerCurrentForTest != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Fase 16.2-R4.4-R2.1.1-F1-R (test isolation): every camera is released, so
    // no late STOP pass can still queue; the index turns this test left (a test
    // that does not read the index does not wait for them) settle here, against
    // this test's boxes and directory — never inside the next test's FIFO.
    await indexQueueSettledForTest();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await recorderSnapshots.close();
    await controllerSnapshots.close();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    await Hive.close();
    // Also fails the test if a telemetry file handle is still open (Windows).
    dir.deleteSync(recursive: true);
  });

  group('Fase 16.2-R4.3-R2.6.12 — a late telemetry outcome under the session controller', () {
    for (final how in _SamplesFailure.values) {
      for (final telemetryLost in [false, true]) {
        test('X190 [${how.name}, telemetry ${telemetryLost ? 'LOST' : 'complete'}] (gated) the recorder\'s finalization fails with the '
            'telemetry close pending; the host is torn down — recorder.dispose(), then controller.dispose() — and the STOP\'s own '
            'callback then finishes the file: nothing of the session is written. The file keeps the unfinalized record — no end '
            'time, no outcome, whether the telemetry file is complete or lost — the STOP fails with the recorder\'s error, and the '
            'next start reclaims the session, declaring the samples that are stored', () async {
          const ioError = FileSystemException('late write of A failed (injected)', 'x190.jsonl');
          late DrivingSession a;
          late _Watched stop;
          final errors = await _uncaughtErrorsOf(() async {
            gate.run(() => a = controller.startSession());
            await until(() => controller.status == DashcamStatus.recording, 'A recording');
            await recorderSamples(a, 3);
            emit(19);
            await until(() => writers.single.acceptedSampleCount == 19, 'the telemetry writer accepted 19');
            expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'setup');

            final undo = await failSamplesCheckpoint(how);
            gate.hold = true;
            stop = _Watched(controller.stopSession());
            await gate.untilHeld();
            await until(() => recorder.state == DrivingSessionRecorderState.finalizationFailed && cameraReleased(), 'A: recorder finalization failed, camera released, telemetry close held');
            await undo();
            expect(stop.done, isFalse, reason: 'setup: the STOP still waits for the telemetry file');
            expect(a.endTime, isNotNull, reason: 'setup: the failed STOP left its end time on the recorder\'s instance, in memory');
            expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'setup: none of it is on disk');

            // DrivingSessionHost.dispose(): the recorder first, then the controller.
            recorder.dispose();
            controller.dispose();
            disposed = true;
            expect(DrivingSessionRecorder.controllingState(a.id), isNull, reason: 'setup: no recorder controls A any more');

            if (telemetryLost) gate.failNext(ioError);
            gate.hold = false;
            gate.releaseAll();
            await until(() => stop.done, 'A\'s STOP settled');
            expect([writers.single.state, writers.single.acceptedSampleCount, writers.single.persistedSampleCount], [DashcamTelemetryWriterState.closed, 19, telemetryLost ? 0 : 19], reason: 'setup: the telemetry file ended');
          });

          expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown',
              reason: 'pre-fix: "ENDED declared=3 stored=0 telemetry=${telemetryLost ? 'failed 19/0/0' : 'success 19/19/0'}" — finalized on disk by the telemetry outcome');
          expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'nothing is set on the abandoned instance either');
          expect(controller.canStartSession, isFalse, reason: 'and it released nothing: no START while the session\'s finalization is pending');
          expect(stop.error, errorOf(how), reason: 'the STOP keeps the recorder\'s own failure');
          expect(await speedsOf(a.id), telemetryLost ? isEmpty : range(1, 19), reason: 'the telemetry file is what it is: its result is simply not recorded — neither invented nor inverted');
          expect(errors, isEmpty);
          expect(reported.map((d) => d.exception), telemetryLost ? [same(ioError)] : isEmpty, reason: 'a lost file is still diagnosed in the log (X155); withholding the outcome reports nothing more');

          await nextStart();
          expect(await onDisk(a.id), 'ENDED declared=0 stored=0 telemetry=unknown', reason: 'pre-fix: the recovery skipped it — 3 samples declared, none stored, for good');
          expect(sessions().get(a.id)!.endTime, sessions().get(a.id)!.startTime, reason: 'the recovery\'s end time (nothing was stored), not the failed STOP\'s');
          expect(await durablyFinalizedViolations(dir), isEmpty);
          expect(visibleSessionsSortedByRecency(sessions().values).map((s) => s.id), [a.id]);
        });
      }
    }

    test('X191 (gated) the host is torn down WHILE the recorder finalizes, the telemetry file already closed and its outcome '
        'waiting for the recorder. When the finalization then FAILS, the outcome writes nothing and the next start reclaims '
        'the session; when it SUCCEEDS, the session is finalized by its recorder and carries its telemetry outcome — the '
        'teardown did not cost a durably finalized session its result', () async {
      const samplesBoxName = HiveBoxNames.drivingSessionSamples;
      Future<({String id, Object? stopError})> round({required bool finalizationFails}) async {
        Completer<void>? cancelGate;
        // A recorder whose snapshot subscription cancel() waits for
        // [cancelGate]: that holds its stopSession() inside the finalization,
        // before anything is written (the technique of X181).
        final gatedRecorder = DrivingSessionRecorder(
          Stream<TelemetrySnapshot>.multi((c) {
            final sub = recorderSnapshots.stream.listen(c.add);
            c.onCancel = () async {
              await sub.cancel();
              final held = cancelGate;
              if (held != null) await held.future;
            };
          }),
        );
        final c2Service = buildService();
        final c2 = DashcamSessionController(
          dashcamService: c2Service,
          dashcamPreferences: preferences,
          sessionRecorder: gatedRecorder,
          snapshotStream: controllerSnapshots.stream,
          eventStream: events.stream,
        );
        final c2Writers = <DashcamTelemetryWriter>[];
        c2.openTelemetryWriterHookForTest = (w, open) {
          c2Writers.add(w);
          return open();
        };
        var c2Disposed = false;
        try {
          late DrivingSession a;
          gate.run(() => a = c2.startSession());
          await until(() => c2.status == DashcamStatus.recording, 'A recording');
          final w = c2Writers.single;
          await recorderSamples(a, 3);
          final first = emitted + 1;
          emit(19);
          await until(() => w.acceptedSampleCount == 19, 'A accepted 19');

          cancelGate = Completer<void>();
          final stopA = _Watched(c2.stopSession());
          await until(() => w.state == DashcamTelemetryWriterState.closed && cameraReleasedOf(c2Service), 'A: telemetry file closed and camera released, the recorder held inside its finalization');
          await pumpEventQueue(times: 20);
          expect([gatedRecorder.state, stopA.done, c2.status], [DrivingSessionRecorderState.finalizing, false, DashcamStatus.idle], reason: 'setup: the outcome waits for the recorder (X181)');
          expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'setup');

          gatedRecorder.dispose();
          c2.dispose();
          c2Disposed = true;
          expect(DrivingSessionRecorder.controllingState(a.id), DrivingSessionRecorderState.finalizing, reason: 'setup: the attempt in flight still writes the session');
          if (finalizationFails) await Hive.lazyBox(samplesBoxName).close();
          cancelGate.complete();
          cancelGate = null;
          await until(() => stopA.done, 'A\'s STOP settled');
          if (finalizationFails) await Hive.openLazyBox(samplesBoxName);
          expect(await speedsOf(a.id), range(first, first + 18), reason: 'setup: the telemetry file is complete');
          return (id: a.id, stopError: stopA.error);
        } finally {
          final held = cancelGate;
          if (held != null && !held.isCompleted) held.complete();
          if (!Hive.isBoxOpen(samplesBoxName)) await Hive.openLazyBox(samplesBoxName);
          if (!c2Disposed) {
            try {
              c2.dispose();
            } catch (_) {}
            try {
              gatedRecorder.dispose();
            } catch (_) {}
          }
          for (var i = 0; i < 300 && DashcamService.processOwnerCurrentForTest != null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
      }

      final errors = await _uncaughtErrorsOf(() async {
        final failedOne = await round(finalizationFails: true);
        expect(await onDisk(failedOne.id), 'ACTIVE declared=3 stored=0 telemetry=unknown',
            reason: 'pre-fix: "ENDED declared=3 stored=0 telemetry=success 19/19/0" — the waiting outcome, resuming with no recorder in control, finalized it');
        expect(failedOne.stopError, isA<HiveError>(), reason: 'the STOP keeps the recorder\'s own failure');

        final finalizedOne = await round(finalizationFails: false);
        expect(await onDisk(finalizedOne.id), 'ENDED declared=3 stored=3 telemetry=success 19/19/0', reason: 'finalized by its recorder after the teardown, and its outcome recorded');
        expect(finalizedOne.stopError, isNull);

        await nextStart();
        expect(
          [await onDisk(failedOne.id), await onDisk(finalizedOne.id)],
          ['ENDED declared=0 stored=0 telemetry=unknown', 'ENDED declared=3 stored=3 telemetry=success 19/19/0'],
          reason: 'after the next start',
        );
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);
    });

    test('X192 (real) the outcome that arrives BEFORE the recorder finalizes — a telemetry file that never opened is recorded '
        'in the STOP\'s own slice, ahead of the recorder\'s stop: it is handed to the recorder, and when the finalization then '
        'fails nothing of it is on disk — no end time, no outcome. The retry stores the finalized record with it; a teardown '
        'instead of the retry writes nothing, and the next start reclaims the session', () async {
      final errors = await _uncaughtErrorsOf(() async {
        Future<DrivingSession> stoppedWithFailedFinalization() async {
          await until(() => recorder.state == DrivingSessionRecorderState.idle && cameraReleased(), 'idle');
          final s = controller.startSession();
          Directory(jsonl(s.id)).createSync(recursive: true); // before the writer opens: no fake
          await until(() => controller.status == DashcamStatus.error, 'START settled in error: the telemetry file never opened');
          await recorderSamples(s, 3);
          final undo = await failSamplesCheckpoint(_SamplesFailure.boxClosed);
          final stopError = await _errorOf(controller.stopSession());
          await undo();
          expect(stopError, isA<HiveError>(), reason: 'setup: the recorder\'s finalization failed');
          expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup');
          return s;
        }

        // Recorder alive: handed over, then the retry.
        final a = await stoppedWithFailedFinalization();
        expect(await onDisk(a.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'not finalized ahead of its samples, and no outcome on disk');
        expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.failed, reason: 'the recorder\'s own instance carries it for the retry');
        await controller.stopSession(); // the retry
        expect(await onDisk(a.id), 'ENDED declared=3 stored=3 telemetry=failed 0/0/0', reason: 'the retry stores the finalized record together with the outcome it was handed');

        // Torn down instead of retried.
        final b = await stoppedWithFailedFinalization();
        recorder.dispose();
        controller.dispose();
        disposed = true;
        await controller.telemetryFinalizationsForTest();
        expect(await onDisk(b.id), 'ACTIVE declared=3 stored=0 telemetry=unknown', reason: 'what only the abandoned instance carries is not on disk');

        await nextStart();
        expect([await onDisk(a.id), await onDisk(b.id)], ['ENDED declared=3 stored=3 telemetry=failed 0/0/0', 'ENDED declared=0 stored=0 telemetry=unknown'], reason: 'after the next start');
        expect(await durablyFinalizedViolations(dir), isEmpty);
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);
    });

    test('X193 (gated) a teardown alone costs a finalized session nothing, and writes nothing on an unfinalized one: A was '
        'durably finalized by its recorder with its telemetry close pending, B records, and the host is torn down — '
        'recorder.dispose(), then controller.dispose(). A\'s file then fails: the loss IS recorded on A — failed, 19 accepted, '
        '0 persisted — and every other field of A is what its recorder wrote. B, abandoned while recording, is not written: '
        'its record is exactly what it was, with no outcome, and the next start reclaims it', () async {
      const ioError = FileSystemException('late write of A failed (injected)', 'x193.jsonl');
      late DrivingSession a;
      late DrivingSession b;
      late _Watched stopA;
      late Map<int, Object?> aFinalized;
      late Map<int, Object?> bBefore;
      final errors = await _uncaughtErrorsOf(() async {
        gate.run(() => a = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'A recording');
        final wA = writers.single;
        await recorderSamples(a, 3);
        emit(19);
        await until(() => wA.acceptedSampleCount == 19, 'A accepted 19');
        gate.hold = true;
        stopA = _Watched(controller.stopSession());
        await gate.untilHeld();
        await until(
          () => cameraReleased() && recorder.state == DrivingSessionRecorderState.idle && controller.status == DashcamStatus.finalizing,
          'A: camera released, recorder idle, telemetry file pending',
        );
        expect(await onDisk(a.id), 'ENDED declared=3 stored=3 telemetry=unknown', reason: 'setup: A was durably finalized by its recorder');
        aFinalized = _fieldsOf((await sessionRecordOnDisk(dir, a.id))!);

        b = controller.startSession(); // outside the gate: its own, real file
        await until(() => controller.status == DashcamStatus.recording, 'B recording');
        final wB = writers.last;
        await recorderSamples(b, 2);
        emit(7);
        await until(() => wB.acceptedSampleCount == 7, 'B accepted 7');
        expect(await onDisk(b.id), 'ACTIVE declared=2 stored=0 telemetry=unknown', reason: 'setup');
        bBefore = _fieldsOf((await sessionRecordOnDisk(dir, b.id))!);

        recorder.dispose();
        controller.dispose();
        disposed = true;
        expect([DrivingSessionRecorder.controllingState(a.id), DrivingSessionRecorder.controllingState(b.id)], [null, null], reason: 'setup: no recorder controls A or B any more');

        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await until(() => stopA.done, 'A\'s STOP settled');
        await controller.telemetryFinalizationsForTest();
        expect([wA.failure, wA.persistedSampleCount], [same(ioError), 0], reason: 'setup: A lost every accepted sample');
      });

      // A: finalized by its recorder — the outcome is recorded, on A only.
      expect(await onDisk(a.id), 'ENDED declared=3 stored=3 telemetry=failed 19/0/0', reason: 'a teardown is not a reason to withhold the outcome of a session its recorder finalized');
      final aAfter = _fieldsOf((await sessionRecordOnDisk(dir, a.id))!);
      expect({for (final e in aAfter.entries) if (e.key <= 25) e.key: e.value}, {for (final e in aFinalized.entries) if (e.key <= 25) e.key: e.value},
          reason: 'A: end time, sample count, summary — fields 0–25 are what its recorder wrote');
      expect(stopA.error, isNull, reason: 'A\'s STOP completes (X155)');
      // B: unfinalized, abandoned — nothing wrote it.
      expect(_fieldsOf((await sessionRecordOnDisk(dir, b.id))!), bBefore, reason: 'B: its record on disk is field by field what it was — A\'s outcome is not written on it, and nothing else is');
      expect(await onDisk(b.id), 'ACTIVE declared=2 stored=0 telemetry=unknown');
      expect(await speedsOf(b.id), range(20, 26), reason: 'B\'s own telemetry file was closed by the teardown with what it had — and no outcome is recorded for a session that was never stopped (X177)');
      expect(errors, isEmpty);
      expect(reported.map((d) => d.exception), [same(ioError)], reason: 'A\'s loss is also diagnosed in the log (X155)');

      await nextStart();
      expect([await onDisk(a.id), await onDisk(b.id)], ['ENDED declared=3 stored=3 telemetry=failed 19/0/0', 'ENDED declared=0 stored=0 telemetry=unknown'], reason: 'after the next start: A untouched, B reclaimed');
      expect(await durablyFinalizedViolations(dir), isEmpty);
    });
  });
}
