// Fase 16.2-R4.3-R2.6.11 — X170–X177, X181: the durable per-session telemetry outcome
// under the REAL DashcamSessionController (+ DashcamService over the fake
// camera platform, the real recorder over real Hive, the real
// DashcamTelemetryWriter). Independent review (P2, reproduced —
// scratchpad/fase16_2_r4_3_independent_review): session A stopped, session B
// started, A's telemetry file failed afterwards — 19 of 19 samples lost, A's
// STOP without error, A's record unchanged, the History silent. The fixture is
// the one of dashcam_telemetry_failure_session_test.dart (X151–X156): samples
// come from DetectedEvents with speeds 1..N, so the accepted set is known
// exactly; A's file is behind test/support/telemetry_io_gate.dart (hold = a
// hung disk, failNext = a write error) and B's is plain dart:io. Assertions are
// on consequences: what each session's record holds (also re-read from disk),
// what B's camera, writer and file are, and what native calls happened.
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
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_camera_platform.dart';
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

/// Every call the generated adapter makes on a writer, in order. Instants are
/// kept at Hive's own precision (milliseconds), so a record compares equal to
/// itself re-read from disk.
class _FieldCapture implements BinaryWriter {
  final entries = <Object?>[];

  @override
  void writeByte(int value) => entries.add(value);

  @override
  void write<T>(T value, {bool writeTypeId = true}) => entries.add(
    value is DateTime
        ? value.millisecondsSinceEpoch
        : value is List
        ? 'List(${value.length})'
        : value,
  );

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

/// Fields 0–25: everything a session persisted before R2.6.11.
Map<int, Object?> _legacy(Map<int, Object?> fields) => {
  for (final entry in fields.entries)
    if (entry.key <= 25) entry.key: entry.value,
};

/// Session A stopped with its telemetry finalization pending, session B
/// recording — see `aStoppedBRecording`.
typedef _AB = ({
  DrivingSession a,
  DrivingSession b,
  DashcamTelemetryWriter wA,
  DashcamTelemetryWriter wB,
  _Watched stopA,
  Object cameraB,
  Object? ownerB,
});

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

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

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

  String jsonl(String id) => '${dir.path}/dashcam_telemetry/$id.jsonl';

  Future<List<int?>> speedsOf(String id) async => [for (final s in await loadDashcamTelemetry(id)) s.speedKmh?.toInt()];

  List<int> range(int from, int to) => [for (var i = from; i <= to; i++) i];

  bool cameraReleased() => DashcamService.processOwnerCurrentForTest == null && service.previewController == null;

  int nativeCalls(String name) => fakePlatform.calls.where((c) => c == name).length;

  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);

  /// The telemetry outcome [id]'s record carries, as text.
  String outcomeOf(String id) {
    final s = sessions().get(id);
    if (s == null) return 'absent';
    return '${s.dashcamTelemetryOutcome.name} ${s.dashcamTelemetryAcceptedCount}/${s.dashcamTelemetryPersistedCount}/${s.dashcamTelemetryRefusedCount}';
  }

  /// The sessions box closed and reopened: only its file answers from here on.
  Future<void> reopenSessions() async {
    await sessions().close();
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
  }

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

  /// A records under the gate; with [autoFlushHeld] its first automatic flush
  /// (25 samples) is held with 3 more behind it, otherwise it accepts 19 (below
  /// the automatic flush) and its close's own write is the one held. STOP A:
  /// the camera is released and the recorder has released A while A's telemetry
  /// finalization is still pending. B is then started on a plain dart:io file:
  /// it gets its own camera and its own writer, and accepts 7 samples.
  Future<_AB> aStoppedBRecording({bool autoFlushHeld = false}) async {
    late DrivingSession a;
    gate.run(() => a = controller.startSession());
    await until(() => controller.status == DashcamStatus.recording, 'A recording');
    final wA = writers.single;
    if (autoFlushHeld) {
      gate.hold = true;
      emit(25);
      await gate.untilHeld();
      emit(3);
      await until(() => wA.acceptedSampleCount == 28, 'A accepted 28');
    } else {
      emit(19);
      await until(() => wA.acceptedSampleCount == 19, 'A accepted 19');
      gate.hold = true;
    }
    final stopA = _Watched(controller.stopSession());
    await gate.untilHeld();
    await until(
      () => cameraReleased() && recorder.state == DrivingSessionRecorderState.idle && controller.status == DashcamStatus.finalizing,
      'A: camera released, recorder idle, telemetry file pending',
    );
    expect(stopA.done, isFalse, reason: 'setup: A\'s telemetry finalization is not terminal yet');
    expect(sessions().get(a.id)!.endTime, isNotNull, reason: 'setup: A has ended');

    final b = controller.startSession(); // outside the gate: its own, real file
    await until(() => controller.status == DashcamStatus.recording, 'B recording');
    expect(writers, hasLength(2), reason: 'setup: B has its own writer');
    final wB = writers.last;
    expect([wA.sessionId, wB.sessionId], [a.id, b.id], reason: 'setup: each writer was created for its own session');
    emit(7);
    await until(() => wB.acceptedSampleCount == 7, 'B accepted 7');
    return (a: a, b: b, wA: wA, wB: wB, stopA: stopA, cameraB: service.previewController!, ownerB: DashcamService.processOwnerCurrentForTest);
  }

  /// B is exactly what it was: recording, the same camera and process owner,
  /// the same writer with the same counters, the same file, the same record —
  /// and no native camera call of any kind happened since [nativeCallsBefore].
  void expectBUntouched(_AB ab, {required List<String> nativeCallsBefore, required Map<int, Object?> recordBefore, required int fileLengthBefore}) {
    expect(controller.status, DashcamStatus.recording, reason: 'B: still recording — A\'s outcome is not B\'s status');
    expect(controller.errorMessage, isNull, reason: 'B: no camera error');
    expect(controller.telemetryFailureMessage, isNull, reason: 'B: its own telemetry is healthy');
    expect(identical(service.previewController, ab.cameraB), isTrue, reason: 'B: the same camera');
    expect(identical(DashcamService.processOwnerCurrentForTest, ab.ownerB), isTrue, reason: 'B: the same process owner');
    expect(service.isRecording, isTrue);
    expect([controller.recordingSessionIdForTest, recorder.activeSession?.id], [ab.b.id, ab.b.id], reason: 'B: still the session being recorded');
    expect(writers, hasLength(2), reason: 'B: no writer created');
    expect(identical(writers.last, ab.wB), isTrue, reason: 'B: the same writer');
    expect(
      [ab.wB.sessionId, ab.wB.state, ab.wB.acceptedSampleCount, ab.wB.persistedSampleCount, ab.wB.refusedSampleCount, ab.wB.failure],
      [ab.b.id, DashcamTelemetryWriterState.open, 7, 0, 0, null],
      reason: 'B: the same producer identity and the same counters',
    );
    expect(fakePlatform.calls, nativeCallsBefore, reason: 'B: no native camera call — no STOP, no START, no retry');
    expect(File(jsonl(ab.b.id)).lengthSync(), fileLengthBefore, reason: 'B: its file was not written');
    expect(_fieldsOf(sessions().get(ab.b.id)!), recordBefore, reason: 'B: its record is untouched — A\'s outcome is not written on B');
  }

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_telemetry_outcome_session_test');
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
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);

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
    for (var i = 0; i < 300 && !cameraReleased(); i++) {
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

  group('Fase 16.2-R4.3-R2.6.11 — telemetry outcome under the session controller', () {
    test('X170 (gated) session A\'s telemetry file fails AFTER session B started: the failure is recorded durably ON A — 19 '
        'accepted, 0 persisted — with every other field of A as it was; B is untouched in every respect and later records '
        'its own success; both are what the disk holds', () async {
      const ioError = FileSystemException('late write of A failed (injected)', 'x170.jsonl');
      final errors = await _uncaughtErrorsOf(() async {
        final ab = await aStoppedBRecording();
        final aBefore = _fieldsOf(sessions().get(ab.a.id)!);
        final bBefore = _fieldsOf(sessions().get(ab.b.id)!);
        final bFileBefore = File(jsonl(ab.b.id)).lengthSync();
        final nativeBefore = List.of(fakePlatform.calls);
        expect(outcomeOf(ab.a.id), 'unknown null/null/null', reason: 'while the file is pending nothing is claimed about it — in particular not a success');

        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await until(() => ab.stopA.done, 'A\'s STOP settled');
        expect(ab.stopA.error, isNull, reason: 'the STOP request itself completes (X155)');
        expect([ab.wA.state, ab.wA.acceptedSampleCount, ab.wA.persistedSampleCount, ab.wA.failure], [DashcamTelemetryWriterState.closed, 19, 0, same(ioError)],
            reason: 'setup: A lost every accepted sample');
        expect(await speedsOf(ab.a.id), isEmpty, reason: 'setup: nothing of A reached its file');

        // A: the result belongs to A, durably.
        expect(outcomeOf(ab.a.id), 'failed 19/0/0', reason: 'pre-fix: A\'s record was unchanged — the loss existed only in a log line');
        expect(_legacy(_fieldsOf(sessions().get(ab.a.id)!)), _legacy(aBefore), reason: 'A: end time, sample count, events, deletion marker… are what they were');
        // B: nothing of it changed.
        expectBUntouched(ab, nativeCallsBefore: nativeBefore, recordBefore: bBefore, fileLengthBefore: bFileBefore);
        expect(outcomeOf(ab.b.id), 'unknown null/null/null', reason: 'B is still recording: no outcome yet, and certainly not A\'s');

        // B goes on, and ends with its own result.
        emit(2);
        await until(() => ab.wB.acceptedSampleCount == 9, 'B accepted 2 more');
        await controller.stopSession();
        expect(controller.status, DashcamStatus.idle);
        expect(await speedsOf(ab.b.id), range(20, 28), reason: 'B: every sample of its own, none of A\'s');
        expect([outcomeOf(ab.a.id), outcomeOf(ab.b.id)], ['failed 19/0/0', 'success 9/9/0']);

        await reopenSessions();
        expect([outcomeOf(ab.a.id), outcomeOf(ab.b.id)], ['failed 19/0/0', 'success 9/9/0'], reason: 'what the disk holds, after the boxes are reopened');
        expect(_legacy(_fieldsOf(sessions().get(ab.a.id)!)), _legacy(aBefore), reason: 'on disk: A is still the finished session it was');
        expect(sessions().get(ab.b.id)!.endTime, isNotNull);
      });
      expect(errors, isEmpty, reason: 'a close-only failure is fully owned');
      expect(reported.map((d) => d.exception), [same(ioError)], reason: 'the report of X155 stays — it is no longer the only trace');
      expect(reported.single.library, 'dashcam session controller');
    });

    test('X171 (gated) session A\'s telemetry file completes AFTER session B started: the success is recorded on A — 19 of 19 '
        '— and B is untouched', () async {
      final errors = await _uncaughtErrorsOf(() async {
        final ab = await aStoppedBRecording();
        final aBefore = _fieldsOf(sessions().get(ab.a.id)!);
        final bBefore = _fieldsOf(sessions().get(ab.b.id)!);
        final bFileBefore = File(jsonl(ab.b.id)).lengthSync();
        final nativeBefore = List.of(fakePlatform.calls);

        gate.hold = false;
        gate.releaseAll();
        await until(() => ab.stopA.done, 'A\'s STOP settled');
        expect(ab.stopA.error, isNull);
        expect(await speedsOf(ab.a.id), range(1, 19), reason: 'setup: A\'s file is complete');

        expect(outcomeOf(ab.a.id), 'success 19/19/0', reason: 'the healthy path is recorded too: a session with no outcome is not "a success nobody checked"');
        expect(_legacy(_fieldsOf(sessions().get(ab.a.id)!)), _legacy(aBefore));
        expectBUntouched(ab, nativeCallsBefore: nativeBefore, recordBefore: bBefore, fileLengthBefore: bFileBefore);

        await controller.stopSession();
        await reopenSessions();
        expect([outcomeOf(ab.a.id), outcomeOf(ab.b.id)], ['success 19/19/0', 'success 7/7/0'], reason: 'on disk');
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);
    });

    test('X172 (gated) the same with A\'s HELD AUTOMATIC FLUSH failing after B started (28 accepted, none written): A is '
        'recorded as failed 28/0; B is untouched', () async {
      const ioError = FileSystemException('held automatic flush of A failed (injected)', 'x172.jsonl');
      final errors = await _uncaughtErrorsOf(() async {
        final ab = await aStoppedBRecording(autoFlushHeld: true);
        final aBefore = _fieldsOf(sessions().get(ab.a.id)!);
        final bBefore = _fieldsOf(sessions().get(ab.b.id)!);
        final bFileBefore = File(jsonl(ab.b.id)).lengthSync();
        final nativeBefore = List.of(fakePlatform.calls);

        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await until(() => ab.stopA.done, 'A\'s STOP settled');
        expect(ab.stopA.error, isNull);

        expect(outcomeOf(ab.a.id), 'failed 28/0/0');
        expect(_legacy(_fieldsOf(sessions().get(ab.a.id)!)), _legacy(aBefore));
        expectBUntouched(ab, nativeCallsBefore: nativeBefore, recordBefore: bBefore, fileLengthBefore: bFileBefore);

        await controller.stopSession();
        await reopenSessions();
        expect([outcomeOf(ab.a.id), outcomeOf(ab.b.id)], ['failed 28/0/0', 'success 7/7/0'], reason: 'on disk');
      });
      expect(errors, [same(ioError)], reason: 'the automatic flush\'s own failure, by contract (X138)');
      expect(reported.map((d) => d.exception), [same(ioError)]);
    });

    test('X173 (gated) a write failure while recording, with NO newer session: the STOP still ends in `error` with the loss '
        '(X152), and the same loss — 50 accepted, 25 persisted, 3 refused — is recorded on the session, where the next START, '
        'which clears that status, cannot erase it', () async {
      const ioError = FileSystemException('write failed (injected)', 'x173.jsonl');
      late DrivingSession a;
      final errors = await _uncaughtErrorsOf(() async {
        gate.run(() => a = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'A recording');
        final w = writers.single;
        emit(25);
        await until(() => w.persistedSampleCount == 25, 'first automatic flush written');
        gate.failNext(ioError);
        emit(25);
        await until(() => w.failure != null, 'the second automatic flush failed');
        emit(3);
        await until(() => w.refusedSampleCount == 3, '3 refused after the failure');
        expect(outcomeOf(a.id), 'unknown null/null/null', reason: 'not terminal while the session records: the outcome is the closed writer\'s');

        await controller.stopSession();
        expect(controller.status, DashcamStatus.error, reason: 'unchanged (X152)');
        expect(controller.errorMessage, allOf(contains('25 de 50 amostras gravadas'), contains('3 recusadas')));
        expect(outcomeOf(a.id), 'failed 50/25/3', reason: 'pre-fix: only that status said so, until the next START');

        gate.run(() => controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'B recording');
        expect(controller.errorMessage, isNull, reason: 'setup: the live status no longer says anything about A');
        expect(outcomeOf(a.id), 'failed 50/25/3');
        await controller.stopSession();
        await reopenSessions();
        expect(outcomeOf(a.id), 'failed 50/25/3', reason: 'on disk');
      });
      expect(errors, [same(ioError)], reason: 'the automatic flush\'s own failure, once');
      expect(reported, isEmpty, reason: 'published as the status (X152): not reported, and recording the outcome reported nothing either');
      expect(await speedsOf(a.id), range(1, 25));
    });

    test('X174 (real) a telemetry file that never opened: the STOP keeps the open error as the status (X151) and records on '
        'the session that its telemetry was not written — failed 0/0; when a retry opens the file, the session\'s outcome is '
        'the one of the writer it then recorded with', () async {
      final errors = await _uncaughtErrorsOf(() async {
        // (i) Never opened.
        final a = controller.startSession();
        Directory(jsonl(a.id)).createSync(recursive: true); // before the writer opens: no fake
        await until(() => controller.status == DashcamStatus.error, 'START settled in error');
        expect(writers.single.state, DashcamTelemetryWriterState.failed, reason: 'setup');
        expect(outcomeOf(a.id), 'unknown null/null/null', reason: 'a retry may still open it: not terminal before the STOP');
        await controller.stopSession();
        expect(controller.status, DashcamStatus.error, reason: 'unchanged (X151)');
        expect(controller.errorMessage, contains('Cannot open file'));
        expect(controller.errorMessage, isNot(contains('Telemetria da dashcam incompleta')), reason: 'the status message is not rewritten');
        expect(outcomeOf(a.id), 'failed 0/0/0', reason: 'pre-fix: nothing durable distinguished "never written" from "no dashcam"');
        expect(controller.pendingTelemetryFinalizationsForTest, 0);
        await until(cameraReleased, 'camera released');

        // (ii) The open fails, then a retry opens the file.
        final c = controller.startSession();
        final obstacle = Directory(jsonl(c.id))..createSync(recursive: true);
        await until(() => controller.status == DashcamStatus.error, 'C: START settled in error');
        obstacle.deleteSync();
        await controller.retryCamera();
        await until(() => controller.status == DashcamStatus.recording, 'C recording after the retry');
        expect(writers, hasLength(3), reason: 'setup: the retry created the writer C records with');
        expect(writers.last.state, DashcamTelemetryWriterState.open);
        emit(5);
        await until(() => writers.last.acceptedSampleCount == 5, 'C accepted 5');
        await controller.stopSession();
        expect(outcomeOf(c.id), 'success 5/5/0', reason: 'the writer that recorded C — not the attempt that never opened');
        expect(await speedsOf(c.id), range(1, 5));

        await reopenSessions();
        expect([outcomeOf(a.id), outcomeOf(c.id)], ['failed 0/0/0', 'success 5/5/0'], reason: 'on disk');
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);
    });

    test('X175 (gated) session A is deleted while its telemetry finalization is pending and B records; A\'s file then fails: '
        'the late outcome does not bring A back, does not clear its deletion marker and writes nothing on it; the deletion '
        'completes; B is untouched', () async {
      const ioError = FileSystemException('late write of A failed (injected)', 'x175.jsonl');
      final errors = await _uncaughtErrorsOf(() async {
        final ab = await aStoppedBRecording();
        Object? deletionError;
        try {
          await deleteDrivingSession(ab.a.id);
        } catch (e) {
          deletionError = e;
        }
        // Windows (the validated host): A's file is in use by its writer, so
        // the deletion stops there and A stays marked. Where an open file can
        // be unlinked the deletion completes; both are asserted below.
        final markedRecord = sessions().get(ab.a.id);
        if (deletionError != null) {
          expect(deletionError, isA<FileSystemException>(), reason: 'setup: the telemetry file is in use');
          expect(markedRecord?.deletionPending, isTrue, reason: 'setup: the deletion is pending');
        } else {
          expect(markedRecord, isNull, reason: 'setup: the deletion completed');
        }
        final markedBefore = markedRecord == null ? null : _fieldsOf(markedRecord);
        final bBefore = _fieldsOf(sessions().get(ab.b.id)!);
        final bFileBefore = File(jsonl(ab.b.id)).lengthSync();
        final nativeBefore = List.of(fakePlatform.calls);

        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await until(() => ab.stopA.done, 'A\'s STOP settled');
        expect(ab.stopA.error, isNull);
        expect(ab.wA.failure, same(ioError), reason: 'setup: A\'s late outcome was a failure');

        final after = sessions().get(ab.a.id);
        if (markedBefore != null) {
          expect(after, isNotNull);
          expect(_fieldsOf(after!), markedBefore, reason: 'the marked record is exactly what it was: marker kept, no outcome written');
          expect(after.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown);
        } else {
          expect(after, isNull, reason: 'a deleted session is not recreated');
        }
        expectBUntouched(ab, nativeCallsBefore: nativeBefore, recordBefore: bBefore, fileLengthBefore: bFileBefore);

        await completePendingSessionDeletions();
        expect(sessions().get(ab.a.id), isNull, reason: 'the deletion completes: the late outcome did not stand in its way');
        expect(File(jsonl(ab.a.id)).existsSync(), isFalse, reason: 'and A\'s telemetry file is not left behind, nor recreated');
        expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(ab.a.id), isFalse);
        expect(sessions().get(ab.b.id)!.deletionPending, isFalse, reason: 'B is not part of it');

        await controller.stopSession();
        await reopenSessions();
        expect([outcomeOf(ab.a.id), outcomeOf(ab.b.id)], ['absent', 'success 7/7/0'], reason: 'on disk');
      });
      expect(errors, isEmpty);
      expect(reported.map((d) => d.exception), [same(ioError)], reason: 'the failure is still diagnosed in the log (X155)');
    });

    test('X176 (gated) a background/foreground cycle between A\'s STOP and A\'s late result: B loses and recovers ITS camera '
        'and keeps its writer, A\'s pending finalization is not disturbed, and when A\'s file then fails the failure is '
        'recorded on A; with no session active, a result arriving after the cycle is recorded just the same', () async {
      const ioError = FileSystemException('late write of A failed (injected)', 'x176.jsonl');
      final errors = await _uncaughtErrorsOf(() async {
        // (i) With B recording.
        final ab = await aStoppedBRecording();
        final createsBefore = nativeCalls('createCameraWithSettings');
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await pumpEventQueue(times: 20);
        expect(controller.pendingTelemetryFinalizationsForTest, 1, reason: 'A\'s finalization is still owned in the background');
        expect(outcomeOf(ab.a.id), 'unknown null/null/null');
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await until(
          () => controller.status == DashcamStatus.recording && controller.activeCameraAttemptSessionIdForTest == null && nativeCalls('createCameraWithSettings') > createsBefore,
          'B\'s camera recovered after the resume',
        );
        expect(controller.recordingSessionIdForTest, ab.b.id, reason: 'the recovery was B\'s');
        expect(writers, hasLength(2), reason: 'the recovery reused B\'s writer');
        expect(ab.stopA.done, isFalse, reason: 'setup: A is still pending after the cycle');

        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await until(() => ab.stopA.done, 'A\'s STOP settled');
        expect(outcomeOf(ab.a.id), 'failed 19/0/0', reason: 'A\'s result, on A, after the cycle');
        expect(controller.status, DashcamStatus.recording, reason: 'B records with its recovered camera');
        expect(controller.errorMessage, isNull);
        expect([identical(writers.last, ab.wB), ab.wB.state, ab.wB.acceptedSampleCount, ab.wB.failure], [isTrue, DashcamTelemetryWriterState.open, 7, null]);
        expect(outcomeOf(ab.b.id), 'unknown null/null/null');
        await controller.stopSession();
        expect(outcomeOf(ab.b.id), 'success 7/7/0');
        await until(cameraReleased, 'camera released');

        // (ii) Nobody recording during the cycle.
        late DrivingSession c;
        gate.run(() => c = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'C recording');
        emit(4);
        await until(() => writers.last.acceptedSampleCount == 4, 'C accepted 4');
        gate.hold = true;
        final stopC = _Watched(controller.stopSession());
        await gate.untilHeld();
        await until(() => cameraReleased() && controller.status == DashcamStatus.finalizing, 'C: camera released, file pending');
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await pumpEventQueue(times: 20);
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue(times: 20);
        expect(stopC.done, isFalse, reason: 'setup: still pending');
        gate.hold = false;
        gate.releaseAll();
        await until(() => stopC.done, 'C\'s STOP settled');
        expect(outcomeOf(c.id), 'success 4/4/0');
        expect(controller.status, DashcamStatus.idle);

        await reopenSessions();
        expect([outcomeOf(ab.a.id), outcomeOf(ab.b.id), outcomeOf(c.id)], ['failed 19/0/0', 'success 7/7/0', 'success 4/4/0'], reason: 'on disk');
      });
      expect(errors, isEmpty);
      expect(reported.map((d) => d.exception), [same(ioError)]);
    });

    test('X177 (gated) who owns the result: a STOP\'s pending finalization still records it after the controller is disposed; '
        'a recording torn down by dispose — a session that was never stopped — records NO outcome, whether its close '
        'succeeds or fails: it stays unknown, never an invented success', () async {
      const ioError = FileSystemException('final write failed (injected)', 'x177.jsonl');
      late DrivingSession a;
      final errors = await _uncaughtErrorsOf(() async {
        // (1) STOP pending, then dispose.
        gate.run(() => a = controller.startSession());
        await until(() => controller.status == DashcamStatus.recording, 'A recording');
        emit(19);
        await until(() => writers.single.acceptedSampleCount == 19, 'A accepted 19');
        gate.hold = true;
        final stopA = _Watched(controller.stopSession());
        await gate.untilHeld();
        await until(() => cameraReleased() && controller.status == DashcamStatus.finalizing, 'A: camera released, file pending');
        controller.dispose();
        disposed = true;
        expect(outcomeOf(a.id), 'unknown null/null/null');
        gate.hold = false;
        gate.releaseAll();
        await controller.telemetryFinalizationsForTest();
        await until(() => stopA.done, 'A\'s STOP completes after dispose');
        expect(outcomeOf(a.id), 'success 19/19/0', reason: 'the STOP owns A\'s result: the controller\'s own life does not');
      });
      expect(errors, isEmpty);
      expect(reported, isEmpty);

      // (2) A fresh controller, disposed WHILE recording.
      for (final failing in [false, true]) {
        final c2 = DashcamSessionController(
          dashcamService: buildService(),
          dashcamPreferences: preferences,
          sessionRecorder: recorder,
          snapshotStream: controllerSnapshots.stream,
          eventStream: events.stream,
        );
        final c2Writers = <DashcamTelemetryWriter>[];
        c2.openTelemetryWriterHookForTest = (w, open) {
          c2Writers.add(w);
          return open();
        };
        late DrivingSession s;
        final errors2 = await _uncaughtErrorsOf(() async {
          await until(() => recorder.state == DrivingSessionRecorderState.idle, 'recorder idle');
          gate.run(() => s = c2.startSession());
          await until(() => c2.status == DashcamStatus.recording, 'recording');
          emit(3);
          await until(() => c2Writers.single.acceptedSampleCount == 3, '3 accepted');
          if (failing) gate.failNext(ioError);
          c2.dispose();
          await c2.telemetryFinalizationsForTest();
          expect(c2Writers.single.state, DashcamTelemetryWriterState.closed, reason: 'setup: dispose closed the writer');
          expect(c2Writers.single.persistedSampleCount, failing ? 0 : 3, reason: 'setup');
          expect(outcomeOf(s.id), 'unknown null/null/null', reason: 'failing=$failing: not stopped, so nothing is recorded about its telemetry');
          expect(sessions().get(s.id)!.endTime, isNull, reason: 'the session itself was left active, for the next start to reclaim');
          // End it in the recorder, so the next round starts a session of its own.
          await recorder.stopSession();
          for (var i = 0; i < 300 && DashcamService.processOwnerCurrentForTest != null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        expect(errors2, isEmpty);
        expect(reported.map((d) => d.exception), failing ? [same(ioError)] : isEmpty, reason: 'failing=$failing: the close failure is reported once (X156), as before');
        expect(outcomeOf(s.id), 'unknown null/null/null', reason: 'failing=$failing');
      }
    });

    test('X181 (gated) the result is never written ahead of the recorder, and waiting for the recorder is not "Finalizando…": '
        'with the recorder held inside A\'s finalization, A\'s telemetry file closes — the dashcam is `idle` and nothing is '
        'set or written about A yet; the finalization then FAILS (samples box unavailable): the STOP fails with that error '
        'and the record on disk is still the unfinalized one, with no outcome; the retry stores the finalized record '
        'together with A\'s telemetry result', () async {
      Completer<void>? cancelGate;
      // A recorder whose snapshot subscription cancel() waits for [cancelGate]
      // when one is set: that holds its stopSession() inside the finalization,
      // before anything is written.
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
      const samplesBox = HiveBoxNames.drivingSessionSamples;
      try {
        final errors = await _uncaughtErrorsOf(() async {
          late DrivingSession a;
          gate.run(() => a = c2.startSession());
          await until(() => c2.status == DashcamStatus.recording, 'A recording');
          final w = c2Writers.single;
          emit(19);
          await until(() => w.acceptedSampleCount == 19, 'A accepted 19');
          await sessions().flush(); // the START's own record write has landed

          cancelGate = Completer<void>();
          final stopA = _Watched(c2.stopSession());
          await until(
            () => w.state == DashcamTelemetryWriterState.closed && DashcamService.processOwnerCurrentForTest == null && c2Service.previewController == null,
            'A: telemetry file closed and camera released, with the recorder held inside its finalization',
          );
          await pumpEventQueue(times: 20);
          expect(gatedRecorder.state, DrivingSessionRecorderState.finalizing, reason: 'setup: the recorder is still finalizing A');
          expect(stopA.done, isFalse, reason: 'setup');
          expect(c2.status, DashcamStatus.idle, reason: 'the telemetry FILE is finalized: recording its result waits for the recorder, which is not "Finalizando…"');
          expect(a.dashcamTelemetryOutcome, DashcamTelemetryOutcome.unknown, reason: 'nothing is set or written about A while its recorder finalizes it');

          await Hive.lazyBox(samplesBox).close(); // the finalization will fail at its samples checkpoint
          cancelGate!.complete();
          cancelGate = null;
          await until(() => stopA.done, 'A\'s STOP settled');
          expect(stopA.error, isA<HiveError>(), reason: 'the recorder\'s failure reaches the caller, as before');
          expect(gatedRecorder.state, DrivingSessionRecorderState.finalizationFailed);
          await reopenSessions();
          final onDisk = sessions().get(a.id)!;
          expect([onDisk.endTime, onDisk.dashcamTelemetryOutcome], [null, DashcamTelemetryOutcome.unknown],
              reason: 'on disk the record is still the unfinalized one: the telemetry result did not finalize it ahead of its recorder');

          await Hive.openLazyBox(samplesBox);
          await c2.stopSession(); // the retry
          expect(gatedRecorder.state, DrivingSessionRecorderState.idle);
          await reopenSessions();
          expect(sessions().get(a.id)!.endTime, isNotNull, reason: 'on disk: finalized by its recorder');
          expect(outcomeOf(a.id), 'success 19/19/0', reason: 'on disk: with the telemetry result the recorder was handed');
          expect(await speedsOf(a.id), range(1, 19));
        });
        expect(errors, isEmpty);
        expect(reported, isEmpty);
      } finally {
        final held = cancelGate;
        if (held != null && !held.isCompleted) held.complete();
        if (!Hive.isBoxOpen(samplesBox)) await Hive.openLazyBox(samplesBox);
        for (var i = 0; i < 3 && gatedRecorder.hasPendingFinalization; i++) {
          try {
            await gatedRecorder.stopSession();
          } catch (_) {}
        }
        try {
          c2.dispose();
        } catch (_) {}
        gatedRecorder.dispose();
        for (var i = 0; i < 300 && DashcamService.processOwnerCurrentForTest != null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
    });
  });
}
