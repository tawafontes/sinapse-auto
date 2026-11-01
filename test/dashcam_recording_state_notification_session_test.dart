// Fase 16.2-R4.3-R2.6.21 — what the UI SHOWS when the camera stops recording in the
// middle of a session: the real AppBar REC indicator, the real preview and the real
// session screen, driven by a real DashcamSessionController + DashcamService over the
// fake camera platform.
//
// Until this round, a rotation's restart START (or stop) outliving its 5 s deadline
// changed the status the controller computes (`cameraUnavailable`) without telling
// anyone; the REC indicator and the preview repaint on their own only while the
// status says `recording`, so they kept showing "Gravando" / "REC" for as long as the
// call stayed in flight — forever, if it never returned.
//
// How a render is checked: `tester.pump()` with no time builds only what a
// notification marked dirty; `tester.pump(1 s)` also runs the widgets' own 1 s
// tickers. The service and the controller run in real time (`tester.runAsync`).
//
// This file uses no API added by this round: the same tests run against the
// previous tree and show what it got wrong.
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
import 'package:synapse_auto/screens/sessions/session_recording_screen.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/dashcam_service.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/unit_preferences.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_preview_view.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_rec_indicator.dart';

import 'support/fake_camera_platform.dart';
import 'support/index_queue_isolation.dart';

/// The project's fake camera platform, able to render a preview surface (the
/// preview only shows its REC bar over a real `CameraPreview`).
class _PreviewFake extends FakeCameraPlatform {
  _PreviewFake({required super.tempDir});

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand(key: Key('x21-camera-surface'));
}

const _recKey = Key('x21-rec-indicator');
const _previewKey = Key('x21-preview');
const _sessionKey = Key('x21-session-screen');

const _shortDeadline = Duration(milliseconds: 300);
const _patience = Duration(seconds: 8);

/// What the three consumers render.
typedef _Shown = ({String rec, String preview, String session});

class _Rig {
  static const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;
  late _PreviewFake platform;
  late DashcamService service;
  late DashcamSessionController controller;
  late DrivingSessionRecorder recorder;
  late DashcamPreferences preferences;
  final snapshots = StreamController<TelemetrySnapshot>.broadcast();
  final events = StreamController<DetectedEvent>.broadcast();
  final ticks = <void Function()>[];

  /// Gates a test held; all released (successfully) at teardown.
  final held = <Completer<void>>[];

  /// Each notification of the controller: the status AT that instant, the
  /// recorder's session and whether the camera was recording.
  final notified = <({DashcamStatus status, String? session, bool camera})>[];

  int count(String call) => platform.calls.where((c) => c == call).length;
  bool get cameraRecording => service.previewController?.value.isRecordingVideo ?? false;

  List<DashcamStatus> statusesNotifiedSince(int mark) => notified.skip(mark).map((n) => n.status).toList();

  String state() =>
      'status=${controller.status.name}, unavailable=${service.cameraKnownUnavailable}, cameraRecording=$cameraRecording, '
      'isRecording=${service.isRecording}, rotationsQueued=${service.queuedRotationCountForTest}, pendingStop=${service.hasPendingNativeStop}, '
      'notified=${notified.map((n) => n.status.name).join(',')}, calls=${platform.calls.join(',')}';

  Future<void> until(bool Function() condition, String what, {Duration within = _patience}) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < within) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (condition()) return;
    fail('never happened within ${within.inMilliseconds} ms: $what (${state()})');
  }

  Future<void> start({Duration startDeadline = const Duration(seconds: 5), Duration stopDeadline = const Duration(seconds: 5)}) async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_recording_state_notification_session_test');
    platform = _PreviewFake(tempDir: dir);
    CameraPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
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
    await Hive.openBox(HiveBoxNames.appSettings);
    preferences = DashcamPreferences();
    await preferences.setEnabled(true);
    recorder = DrivingSessionRecorder(snapshots.stream);
    service = DashcamService(
      config: DashcamConfig(
        cameraSelection: CameraSelection.rear,
        storageQuotaMb: 1024,
        audioEnabled: false,
        resolution: VideoResolution.hd720,
        frameRate: 30,
        enabled: true,
      ),
      // Rotations are driven by hand (ticks), never by a real 10 min timer.
      segmentDuration: const Duration(minutes: 10),
      startVideoRecordingTimeout: startDeadline,
      stopVideoRecordingTimeout: stopDeadline,
    );
    service.segmentTimerArmedHookForTest = ticks.add;
    controller = DashcamSessionController(
      dashcamService: service,
      dashcamPreferences: preferences,
      sessionRecorder: recorder,
      snapshotStream: snapshots.stream,
      eventStream: events.stream,
    );
    controller.addListener(() => notified.add((status: controller.status, session: recorder.activeSession?.id, camera: cameraRecording)));
    controller.startSession();
    await until(() => controller.status == DashcamStatus.recording && cameraRecording, 'the session recording');
  }

  /// A tick stops the segment; the restart START is held on the returned gate
  /// (created here, in the real zone, so completing it needs no pump).
  Future<Completer<void>> rotateAndHoldTheRestart() async {
    final startsBefore = count('startVideoCapturing');
    final stopsBefore = count('stopVideoRecording');
    final gate = Completer<void>();
    held.add(gate);
    platform.pendingStartVideoCapturing = gate;
    ticks.last();
    await until(
      () => count('stopVideoRecording') == stopsBefore + 1 && !service.hasPendingNativeStop && count('startVideoCapturing') == startsBefore + 1,
      'the rotation stopping its segment and issuing the restart START',
    );
    platform.pendingStartVideoCapturing = null;
    return gate;
  }

  Future<void> waitForTheDeadline() => until(() => controller.status == DashcamStatus.cameraUnavailable, 'the deadline making the camera unavailable');

  Future<void> close() async {
    for (final gate in [...held, platform.pendingStartVideoCapturing, platform.pendingStopVideoRecording]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    platform.pendingStartVideoCapturing = null;
    platform.pendingStopVideoRecording = null;
    try {
      await controller.stopSession().timeout(const Duration(seconds: 15));
    } catch (_) {}
    controller.dispose();
    await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown', within: const Duration(seconds: 15));
    // Fase 16.2-R4.4-R2.1.1-F1-R (test isolation): every camera is released, so
    // no late STOP pass can still queue; the index turns this test left (a test
    // that does not read the index does not wait for them) settle here, against
    // this test's boxes and directory — never inside the next test's FIFO.
    await indexQueueSettledForTest();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await snapshots.close();
    await events.close();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<void> _mount(WidgetTester tester, _Rig rig) async {
  // Tall enough for every state of the three, the error state of the preview included.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [KeyedSubtree(key: _recKey, child: DashcamRecIndicator(controller: rig.controller, onTap: () {}))]),
        body: Column(
          children: [
            SizedBox(height: 480, child: KeyedSubtree(key: _previewKey, child: DashcamPreviewView(controller: rig.controller))),
            Expanded(
              child: KeyedSubtree(
                key: _sessionKey,
                child: UnitPreferencesScope(preferences: UnitPreferences(), child: SessionRecordingScreen(recorder: rig.recorder, dashcamController: rig.controller)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

_Shown _shown(WidgetTester tester) {
  final button = tester.widget<IconButton>(find.descendant(of: find.byKey(_recKey), matching: find.byType(IconButton)));
  final icon = (button.icon as Icon).icon;
  final tooltip = button.tooltip?.split('\n').first ?? '';
  final rec = icon == Icons.fiber_manual_record
      ? 'REC $tooltip'
      : icon == Icons.videocam_off
      ? 'error'
      : (tooltip == 'Câmera indisponível' ? 'unavailable' : 'other $tooltip');
  bool inPreview(Finder finder) => find.descendant(of: find.byKey(_previewKey), matching: finder).evaluate().isNotEmpty;
  final preview = inPreview(find.byKey(const Key('x21-camera-surface'))) && inPreview(find.textContaining('REC'))
      ? 'REC'
      : inPreview(find.text('Câmera temporariamente indisponível'))
      ? 'unavailable'
      : inPreview(find.text('Tentar novamente'))
      ? 'error'
      : 'other';
  var session = 'none';
  for (final label in ['Gravando', 'Câmera indisponível', 'Erro', 'Pronto', 'Iniciando…', 'Finalizando…']) {
    if (find.descendant(of: find.byKey(_sessionKey), matching: find.text(label)).evaluate().isNotEmpty) session = label;
  }
  return (rec: rec, preview: preview, session: session);
}

/// What renders after a frame that only builds what was marked dirty.
Future<_Shown> _afterANotificationOnlyFrame(WidgetTester tester) async {
  await tester.pump();
  return _shown(tester);
}

void _expectUnavailableShown(_Shown shown, String when) {
  expect(shown.rec, 'unavailable', reason: 'REC indicator $when');
  expect(shown.preview, 'unavailable', reason: 'preview $when');
  expect(shown.session, 'Câmera indisponível', reason: 'session screen $when');
}

void _expectRecordingShown(_Shown shown, String when) {
  expect(shown.rec, startsWith('REC Gravando'), reason: 'REC indicator $when');
  expect(shown.preview, 'REC', reason: 'preview $when');
  expect(shown.session, 'Gravando', reason: 'session screen $when');
}

void main() {
  testWidgets(
    'X400 — the product\'s own numbers: a rotation whose restart START takes 6.95 s against the 5 s deadline. AT the deadline '
    'the controller notifies "câmera indisponível" and the REC indicator, the preview and the session screen show it in the '
    'next frame; when the START returns the controller notifies "gravando" and all three show recording again, by themselves',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start());
      try {
        await _mount(tester, rig);
        _expectRecordingShown(_shown(tester), 'while recording (test setup)');
        late Completer<void> gate;
        final clock = Stopwatch();
        late int mark;
        await tester.runAsync(() async {
          gate = await rig.rotateAndHoldTheRestart();
          clock.start();
          mark = rig.notified.length;
          await rig.waitForTheDeadline();
        });
        expect(clock.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)), reason: 'test setup: the product\'s 5 s deadline');
        expect(rig.statusesNotifiedSince(mark), isNotEmpty, reason: 'the deadline is notified');
        expect(rig.statusesNotifiedSince(mark), everyElement(DashcamStatus.cameraUnavailable), reason: 'with the status it changed to');
        expect(rig.cameraRecording, isFalse, reason: 'and it is the truth: nothing is being recorded');
        _expectUnavailableShown(await _afterANotificationOnlyFrame(tester), 'in the first frame after the deadline');
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        _expectUnavailableShown(_shown(tester), 'three seconds of the widgets\' own tickers later');

        await tester.runAsync(() async {
          final remaining = const Duration(milliseconds: 6950) - clock.elapsed;
          if (!remaining.isNegative) await Future<void>.delayed(remaining);
          mark = rig.notified.length;
          gate.complete();
          await rig.until(() => rig.cameraRecording && rig.service.queuedRotationCountForTest == 0, 'the late START settling');
        });
        expect(rig.statusesNotifiedSince(mark), isNotEmpty, reason: 'the late success is notified');
        expect(rig.statusesNotifiedSince(mark), everyElement(DashcamStatus.recording));
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'in the first frame after the late START returned');
        expect(rig.ticks, hasLength(2), reason: 'R2.6.20, unchanged: the run\'s timer re-armed at the settlement');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X401 — the restart START never returns: after the deadline all three show "câmera indisponível" and keep showing it — '
    'through 60 s of the widgets\' own tickers nothing brings REC back, no notification says "gravando", and nothing retries: '
    'no second START, no second camera, no initialize',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline));
      try {
        await _mount(tester, rig);
        late int mark;
        await tester.runAsync(() async {
          mark = rig.notified.length;
          await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
        });
        _expectUnavailableShown(await _afterANotificationOnlyFrame(tester), 'after the deadline');
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
        await tester.pump();
        _expectUnavailableShown(_shown(tester), 'after 60 s of the widgets\' tickers and 1 s more of the service\'s');
        expect(rig.statusesNotifiedSince(mark), isNot(contains(DashcamStatus.recording)));
        expect(rig.controller.status, DashcamStatus.cameraUnavailable);
        expect(rig.count('startVideoCapturing'), 2, reason: 'the first segment and the restart still in flight');
        expect(rig.count('createCameraWithSettings'), 1, reason: 'no second camera');
        expect(rig.count('initializeCamera'), 1, reason: 'no re-initialize');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X402 — the restart START outlives the deadline and then FAILS: from the deadline on nothing notifies "gravando"; the '
    'failure ends in the existing error state — REC indicator and preview show the error, the preview offers "Tentar novamente"',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline));
      try {
        await _mount(tester, rig);
        late Completer<void> gate;
        late int mark;
        await tester.runAsync(() async {
          gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          mark = rig.notified.length;
        });
        _expectUnavailableShown(await _afterANotificationOnlyFrame(tester), 'after the deadline');
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          gate.completeError(CameraException('start_failed', 'the restart START failed, late'));
          await rig.until(() => rig.controller.status == DashcamStatus.error && rig.service.queuedRotationCountForTest == 0, 'the late failure settling');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        expect(rig.statusesNotifiedSince(mark), isNot(contains(DashcamStatus.recording)), reason: 'the late failure is no success');
        final shown = await _afterANotificationOnlyFrame(tester);
        expect(shown.rec, 'error');
        expect(shown.preview, 'error', reason: 'with its "Tentar novamente"');
        expect(shown.session, 'Erro');
        expect(rig.cameraRecording, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X403 — the session is stopped while the restart is overdue and the START returns WHILE that stop is still in progress: '
    'the late Recording is not adopted (R2.6.20) and the status never goes back to "gravando" — not in any notification, not '
    'in any reading during the stop, not in any frame. The session ends "Pronto"',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline));
      try {
        await _mount(tester, rig);
        late Completer<void> gate;
        late int mark;
        late Future<void> stopping;
        var stopReturned = false;
        await tester.runAsync(() async {
          gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          mark = rig.notified.length;
          stopping = rig.controller.stopSession().whenComplete(() => stopReturned = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        expect(stopReturned, isFalse, reason: 'test setup: the stop waits for the rotation, whose START is in flight');
        // The recorder ends the session at once (the session screen leaves its live view); the camera side is what is still stopping.
        final stopRequested = await _afterANotificationOnlyFrame(tester);
        expect(stopRequested.rec, 'unavailable', reason: 'REC indicator once the stop was requested');
        expect(stopRequested.preview, 'unavailable', reason: 'preview once the stop was requested');

        final readDuringTheStop = <DashcamStatus>[];
        final readAtTheLateClip = <DashcamStatus>[];
        await tester.runAsync(() async {
          void read() {
            if (!stopReturned) readDuringTheStop.add(rig.controller.status);
          }

          final sampler = Timer.periodic(const Duration(milliseconds: 1), (_) => read());
          // A reading at a fixed point inside the window, too (the sampler alone
          // can miss a window a few ms wide): the late Recording's clip is
          // published by the session's own stop, while the controller still
          // awaits that stop.
          rig.service.afterClipPublishedHookForTest = (_) async {
            if (!stopReturned) readAtTheLateClip.add(rig.controller.status);
          };
          gate.complete();
          read();
          final clock = Stopwatch()..start();
          while (!stopReturned && clock.elapsed < _patience) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            read();
          }
          sampler.cancel();
          await stopping.timeout(_patience);
        });
        expect(rig.statusesNotifiedSince(mark), isNot(contains(DashcamStatus.recording)), reason: 'no notification says "gravando" for a Recording the stop made stale');
        expect(readAtTheLateClip, isNotEmpty, reason: 'test setup: the late clip was published during the stop');
        expect(readAtTheLateClip, isNot(contains(DashcamStatus.recording)), reason: 'nor does the status, read as the late clip is published inside the stop');
        expect(readDuringTheStop, isNotEmpty);
        expect(readDuringTheStop, isNot(contains(DashcamStatus.recording)), reason: 'nor does the status, read during the stop');
        expect(rig.statusesNotifiedSince(mark).last, DashcamStatus.idle);
        final shown = await _afterANotificationOnlyFrame(tester);
        expect(shown.rec, 'other Dashcam');
        expect(rig.count('stopVideoRecording'), 2, reason: 'segment 1 by the rotation, the late Recording by the session\'s stop');
        expect(rig.cameraRecording, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X412 — the session is stopped while the restart START is in flight but still WITHIN its deadline; the deadline passes '
    'during the stop and the START then returns, still during the stop: from the deadline on the UI shows "câmera '
    'indisponível" and nothing brings "gravando" back before the session ends "Pronto"',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline));
      try {
        await _mount(tester, rig);
        late Completer<void> gate;
        late int mark;
        late Future<void> stopping;
        var stopReturned = false;
        await tester.runAsync(() async {
          gate = await rig.rotateAndHoldTheRestart();
          stopping = rig.controller.stopSession().whenComplete(() => stopReturned = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(rig.service.cameraKnownUnavailable, isFalse, reason: 'test setup: the stop was requested within the restart\'s deadline');
          await rig.waitForTheDeadline();
          mark = rig.notified.length;
        });
        expect(stopReturned, isFalse, reason: 'test setup: the deadline passed during the stop');
        final atTheDeadline = await _afterANotificationOnlyFrame(tester);
        expect(atTheDeadline.rec, 'unavailable', reason: 'REC indicator after the deadline, during the stop');
        expect(atTheDeadline.preview, 'unavailable', reason: 'preview after the deadline, during the stop');

        final readDuringTheStop = <DashcamStatus>[];
        final readAtTheLateClip = <DashcamStatus>[];
        await tester.runAsync(() async {
          void read() {
            if (!stopReturned) readDuringTheStop.add(rig.controller.status);
          }

          final sampler = Timer.periodic(const Duration(milliseconds: 1), (_) => read());
          await Future<void>.delayed(const Duration(milliseconds: 200));
          // A reading at a fixed point inside the window too — see X403.
          rig.service.afterClipPublishedHookForTest = (_) async {
            if (!stopReturned) readAtTheLateClip.add(rig.controller.status);
          };
          gate.complete();
          read();
          final clock = Stopwatch()..start();
          while (!stopReturned && clock.elapsed < _patience) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            read();
          }
          sampler.cancel();
          await stopping.timeout(_patience);
        });
        expect(rig.statusesNotifiedSince(mark), isNot(contains(DashcamStatus.recording)), reason: 'no notification says "gravando" for a Recording the stop made stale');
        expect(readAtTheLateClip, isNotEmpty, reason: 'test setup: the late clip was published during the stop');
        expect(readAtTheLateClip, isNot(contains(DashcamStatus.recording)), reason: 'nor does the status, read as the late clip is published inside the stop');
        expect(readDuringTheStop, isNotEmpty);
        expect(readDuringTheStop, isNot(contains(DashcamStatus.recording)), reason: 'nor does the status, read during the stop');
        expect(rig.controller.status, DashcamStatus.idle);
        expect(rig.count('stopVideoRecording'), 2, reason: 'segment 1 by the rotation, the late Recording by the session\'s stop');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X404 — the session\'s stop returns while the restart START is still in flight; the START returns afterwards: the status '
    'stays "Pronto" — the late success notifies nothing that says "gravando" and REC does not come back',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline, stopDeadline: const Duration(milliseconds: 150)));
      try {
        await _mount(tester, rig);
        late Completer<void> gate;
        late int mark;
        await tester.runAsync(() async {
          gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          await rig.controller.stopSession().timeout(const Duration(seconds: 3));
          expect(rig.count('startVideoCapturing'), 2, reason: 'test setup: the START is still in flight when the stop has returned');
          expect(rig.cameraRecording, isFalse);
          mark = rig.notified.length;
          gate.complete();
          await rig.until(() => rig.count('stopVideoRecording') == 2 && !rig.cameraRecording && rig.service.queuedRotationCountForTest == 0, 'the late Recording being stopped');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        expect(rig.statusesNotifiedSince(mark), isNot(contains(DashcamStatus.recording)));
        expect(rig.controller.status, DashcamStatus.idle);
        final shown = await _afterANotificationOnlyFrame(tester);
        expect(shown.rec, 'other Dashcam');
        expect(shown.preview, isNot('REC'));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X405 — session A ends while its restart is overdue and session B is requested: A\'s late settlement never makes REC '
    'appear for B — the first "gravando" notified after A\'s stop is B\'s own, with B\'s camera recording, and B keeps '
    'recording afterwards',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline, stopDeadline: const Duration(milliseconds: 150)));
      try {
        await _mount(tester, rig);
        late int mark;
        late String bId;
        await tester.runAsync(() async {
          final gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          mark = rig.notified.length;
          await rig.controller.stopSession().timeout(const Duration(seconds: 3));
          bId = rig.controller.startSession().id;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(rig.count('startVideoCapturing'), 2, reason: 'test setup: B is held back while A\'s START is in flight');
          gate.complete();
          await rig.until(() => rig.controller.status == DashcamStatus.recording && rig.cameraRecording && rig.count('startVideoCapturing') == 3, 'session B recording');
        });
        final recordingNotified = rig.notified.skip(mark).where((n) => n.status == DashcamStatus.recording).toList();
        expect(recordingNotified, isNotEmpty);
        expect(recordingNotified.first.session, bId, reason: 'the first "gravando" after A\'s stop is B\'s');
        expect(recordingNotified.first.camera, isTrue, reason: 'and B\'s camera is recording when it is notified');
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'once B records');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        expect(rig.controller.status, DashcamStatus.recording, reason: 'nothing of A flips B afterwards');
        await tester.pump(const Duration(seconds: 1));
        _expectRecordingShown(_shown(tester), 'a second later');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X413 — after a session that ended with its camera unavailable, the next session\'s first START fails and "Tentar '
    'novamente" brings it to recording: the status says "gravando" and the UI shows REC — what the previous session\'s '
    'stop decided is not carried over',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline, stopDeadline: const Duration(milliseconds: 150)));
      try {
        await _mount(tester, rig);
        late int mark;
        await tester.runAsync(() async {
          final gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          await rig.controller.stopSession().timeout(const Duration(seconds: 3));
          gate.complete();
          await rig.until(() => rig.count('stopVideoRecording') == 2 && !rig.cameraRecording && rig.service.queuedRotationCountForTest == 0, 'A\'s late Recording being stopped');
          await rig.until(() => rig.controller.canStartSession, 'A being over');
          rig.platform.failStartVideoCapturingWith = CameraException('start_failed', 'the first START of B failed');
          rig.controller.startSession();
          await rig.until(() => rig.controller.status == DashcamStatus.error, 'B\'s first START failing');
          rig.platform.failStartVideoCapturingWith = null;
          mark = rig.notified.length;
          await rig.controller.retryCamera();
          await rig.until(() => rig.cameraRecording && !rig.service.startAttemptSettling, 'the retry recording');
        });
        expect(rig.controller.status, DashcamStatus.recording, reason: 'the camera records, and the status says so');
        expect(rig.statusesNotifiedSince(mark), contains(DashcamStatus.recording));
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'after the retry');
      } finally {
        rig.platform.failStartVideoCapturingWith = null;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X406 — the app goes to the background while the restart is overdue and the START returns there: nothing notifies '
    '"gravando" while in the background and the UI keeps "câmera indisponível"; back in the foreground the existing recovery '
    'brings the same session back to recording, and the UI follows',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline));
      try {
        await _mount(tester, rig);
        late int mark;
        await tester.runAsync(() async {
          final gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          mark = rig.notified.length;
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          gate.complete();
          await rig.until(
            () => rig.count('stopVideoRecording') == 2 && !rig.cameraRecording && rig.service.queuedRotationCountForTest == 0,
            'the late Recording being stopped by the rotation (R2.6.20, background)',
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        expect(rig.statusesNotifiedSince(mark), isNot(contains(DashcamStatus.recording)), reason: 'nothing notifies recording in the background');
        expect(rig.controller.status, DashcamStatus.cameraUnavailable);
        _expectUnavailableShown(await _afterANotificationOnlyFrame(tester), 'in the background, after the late START returned');

        await tester.runAsync(() async {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await rig.until(() => rig.controller.status == DashcamStatus.recording && rig.cameraRecording && rig.count('startVideoCapturing') == 3, 'foreground recovery reaching recording');
        });
        expect(rig.count('createCameraWithSettings'), 2, reason: 'recovery\'s own new camera');
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'after the foreground recovery');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X407 — the app goes to the background during an ordinary recording: the camera becomes unavailable and that is '
    'notified at once (it used to change silently, leaving REC drawn); back in the foreground the recovery records again',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start());
      try {
        await _mount(tester, rig);
        late int mark;
        await tester.runAsync(() async {
          mark = rig.notified.length;
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        expect(rig.statusesNotifiedSince(mark), contains(DashcamStatus.cameraUnavailable));
        _expectUnavailableShown(await _afterANotificationOnlyFrame(tester), 'in the background');
        await tester.runAsync(() async {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await rig.until(() => rig.controller.status == DashcamStatus.recording && rig.cameraRecording && rig.count('startVideoCapturing') == 2, 'foreground recovery reaching recording');
        });
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'after the foreground recovery');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X408 — the controller is disposed while the restart is overdue; the START returns afterwards: the disposed controller '
    'notifies nothing and nothing throws',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(startDeadline: _shortDeadline));
      var closed = false;
      try {
        await _mount(tester, rig);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          final gate = await rig.rotateAndHoldTheRestart();
          await rig.waitForTheDeadline();
          final mark = rig.notified.length;
          rig.controller.dispose();
          gate.complete();
          await rig.until(() => rig.service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown after dispose');
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(rig.notified.length, mark, reason: 'a disposed controller notifies nothing');
          // Fase 16.2-R4.4-R2.1.1-F1-R (test isolation): see _Rig.close().
          await indexQueueSettledForTest();
          rig.held.clear();
          await rig.snapshots.close();
          await rig.events.close();
          await Hive.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_Rig.channel, null);
          try {
            rig.dir.deleteSync(recursive: true);
          } catch (_) {}
          closed = true;
        });
        expect(tester.takeException(), isNull);
      } finally {
        if (!closed) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(rig.close);
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X409 — a rotation\'s STOP outlives its deadline (R2.6.14) and then succeeds: AT the stop\'s deadline the UI shows '
    '"câmera indisponível"; when the stop returns and the next segment starts it shows recording again, by itself',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start(stopDeadline: _shortDeadline));
      try {
        await _mount(tester, rig);
        late Completer<void> stopGate;
        late int mark;
        await tester.runAsync(() async {
          stopGate = Completer<void>();
          rig.held.add(stopGate);
          rig.platform.pendingStopVideoRecording = stopGate;
          mark = rig.notified.length;
          rig.ticks.last();
          await rig.until(() => rig.count('stopVideoRecording') == 1, 'the rotation\'s STOP being issued and held');
          rig.platform.pendingStopVideoRecording = null;
          await rig.waitForTheDeadline();
        });
        expect(rig.statusesNotifiedSince(mark), everyElement(DashcamStatus.cameraUnavailable));
        expect(rig.statusesNotifiedSince(mark), isNotEmpty);
        _expectUnavailableShown(await _afterANotificationOnlyFrame(tester), 'after the stop\'s deadline');
        await tester.runAsync(() async {
          mark = rig.notified.length;
          stopGate.complete();
          await rig.until(() => rig.cameraRecording && rig.count('startVideoCapturing') == 2 && rig.service.queuedRotationCountForTest == 0, 'the late stop and the restart');
        });
        expect(rig.statusesNotifiedSince(mark), isNotEmpty);
        expect(rig.statusesNotifiedSince(mark), everyElement(DashcamStatus.recording));
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'after the late stop and the restart');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X410 — characterization of the window BEFORE the deadline (historical contract, unchanged by this round): while the '
    'restart START is in flight and within its deadline the status still says "gravando", REC is drawn and nothing is '
    'notified; a restart that returns in time notifies nothing either',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start());
      try {
        await _mount(tester, rig);
        late Completer<void> gate;
        late int mark;
        await tester.runAsync(() async {
          mark = rig.notified.length;
          gate = await rig.rotateAndHoldTheRestart();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        expect(rig.cameraRecording, isFalse, reason: 'nothing is being recorded while the restart START is in flight');
        expect(rig.controller.status, DashcamStatus.recording, reason: 'and the status says recording: the pre-deadline contract');
        expect(rig.statusesNotifiedSince(mark), isEmpty);
        _expectRecordingShown(await _afterANotificationOnlyFrame(tester), 'within the deadline');
        await tester.runAsync(() async {
          gate.complete();
          await rig.until(() => rig.cameraRecording && rig.service.queuedRotationCountForTest == 0, 'the restart returning in time');
        });
        expect(rig.statusesNotifiedSince(mark), isEmpty, reason: 'a rotation that met its deadline notifies nothing');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  testWidgets(
    'X411 — ordinary rotations notify nothing (no notification per segment): three rotations in a row, zero '
    'notifications, and REC keeps counting on its own ticker',
    (tester) async {
      final rig = _Rig();
      await tester.runAsync(() => rig.start());
      try {
        await _mount(tester, rig);
        late int mark;
        await tester.runAsync(() async {
          mark = rig.notified.length;
          for (var i = 0; i < 3; i++) {
            final startsBefore = rig.count('startVideoCapturing');
            rig.ticks.last();
            await rig.until(() => rig.count('startVideoCapturing') == startsBefore + 1 && rig.cameraRecording && rig.service.queuedRotationCountForTest == 0, 'rotation ${i + 1}');
          }
        });
        expect(rig.statusesNotifiedSince(mark), isEmpty);
        await tester.pump(const Duration(seconds: 1));
        _expectRecordingShown(_shown(tester), 'after three rotations');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(rig.close);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
