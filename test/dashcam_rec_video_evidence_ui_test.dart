// Fase 16.2-R4.4-HW-MIG-5-SIG-2 — what the REC indicator, the preview bar and the session screen
// show through a rotation, driven by a real DashcamSessionController + DashcamService over the fake
// camera platform: one authority (DashcamSessionController.segmentPresentation) for all of them,
// with the preview kept mounted. autoVideoEvidence is off: video is released by the test.
//
// `tester.pump()` with no time builds only what a notification marked dirty; a longer pump also runs
// the widgets' 1 s tickers, which must never authorize REC.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart' show CameraPlatform;
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

class _PreviewFake extends FakeCameraPlatform {
  _PreviewFake({required super.tempDir});

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand(key: Key('surface'));
}

const _recKey = Key('rec');
const _previewKey = Key('preview');
const _sessionKey = Key('session');

class _Rig {
  static const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;
  late _PreviewFake platform;
  late DashcamService service;
  late DashcamSessionController controller;
  late DrivingSessionRecorder recorder;
  final snapshots = StreamController<TelemetrySnapshot>.broadcast();
  final events = StreamController<DetectedEvent>.broadcast();
  final ticks = <void Function()>[];
  final held = <Completer<void>>[];

  int count(String call) => platform.calls.where((c) => c == call).length;

  Future<void> until(bool Function() condition, String what) async {
    final clock = Stopwatch()..start();
    while (!condition()) {
      if (clock.elapsed > const Duration(seconds: 10)) fail('never happened: $what (calls=${platform.calls.join(',')})');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Completer<void> gate() {
    final completer = Completer<void>();
    held.add(completer);
    return completer;
  }

  Future<void> start() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    dir = Directory.systemTemp.createTempSync('dashcam_rec_video_evidence_ui_test');
    platform = _PreviewFake(tempDir: dir)..autoVideoEvidence = false;
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
    final preferences = DashcamPreferences();
    await preferences.setEnabled(true);
    recorder = DrivingSessionRecorder(snapshots.stream);
    service = DashcamService(
      config: DashcamConfig(cameraSelection: CameraSelection.rear, storageQuotaMb: 1024, audioEnabled: false, resolution: VideoResolution.hd720, frameRate: 30, enabled: true),
      segmentDuration: const Duration(minutes: 10),
    );
    service.segmentTimerArmedHookForTest = ticks.add;
    controller = DashcamSessionController(dashcamService: service, dashcamPreferences: preferences, sessionRecorder: recorder, snapshotStream: snapshots.stream, eventStream: events.stream);
    controller.startSession();
    await until(() => controller.status == DashcamStatus.recording, 'the session recording');
  }

  Future<void> close() async {
    for (final completer in held) {
      if (!completer.isCompleted) completer.complete();
    }
    platform.pendingStartVideoCapturing = null;
    platform.pendingStopVideoRecording = null;
    try {
      await controller.stopSession().timeout(const Duration(seconds: 15));
    } catch (_) {}
    controller.dispose();
    await until(() => service.previewController == null && DashcamService.processOwnerCurrentForTest == null, 'the teardown');
    await indexQueueSettledForTest();
    await snapshots.close();
    await events.close();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<void> _mount(WidgetTester tester, _Rig rig) async {
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

IconButton _indicator(WidgetTester tester) => tester.widget<IconButton>(find.descendant(of: find.byKey(_recKey), matching: find.byType(IconButton)));
bool _indicatorRed(WidgetTester tester) => (_indicator(tester).icon as Icon).icon == Icons.fiber_manual_record;
bool _previewRed(WidgetTester tester) => find.descendant(of: find.byKey(_previewKey), matching: find.byIcon(Icons.fiber_manual_record)).evaluate().isNotEmpty;
bool _previewSays(String text) => find.descendant(of: find.byKey(_previewKey), matching: find.textContaining(text)).evaluate().isNotEmpty;
bool _sessionSays(String text) => find.descendant(of: find.byKey(_sessionKey), matching: find.text(text)).evaluate().isNotEmpty;

void _expectRed(WidgetTester tester, String when) {
  expect(_indicatorRed(tester), isTrue, reason: 'REC indicator $when');
  expect(_previewRed(tester), isTrue, reason: 'preview $when');
  expect(_previewSays('REC'), isTrue, reason: 'preview $when');
  expect(_sessionSays('Gravando'), isTrue, reason: 'session screen $when');
}

void _expectNeutral(WidgetTester tester, String label, String when) {
  expect(_indicatorRed(tester), isFalse, reason: 'REC indicator $when');
  expect(_indicator(tester).tooltip, startsWith(label), reason: 'REC indicator $when');
  expect(_previewRed(tester), isFalse, reason: 'preview $when');
  expect(_previewSays('REC'), isFalse, reason: 'preview $when');
  expect(_previewSays(label), isTrue, reason: 'preview $when');
  expect(_sessionSays(label), isTrue, reason: 'session screen $when');
  expect(_sessionSays('Gravando'), isFalse, reason: 'session screen $when');
}

void main() {
  testWidgets('X559 — two REC widgets and the session line agree through a whole rotation; the same preview stays mounted and no camera call comes from showing it', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await _mount(tester, rig);
      await tester.pump();
      _expectNeutral(tester, 'Iniciando segmento…', 'before any video');

      rig.platform.emitVideoProgress();
      await tester.pump();
      _expectRed(tester, 'with video confirmed');
      final previewElement = tester.element(find.byType(DashcamCameraSurface));
      final surfaceElement = tester.element(find.byKey(const Key('surface')));
      final callsAtFirstFrame = rig.platform.calls.length;

      final stop = rig.gate();
      rig.platform.pendingStopVideoRecording = stop;
      await tester.runAsync(() async {
        rig.ticks.last();
        await rig.until(() => rig.count('stopVideoRecording') == 1, 'the STOP');
      });
      await tester.pump();
      _expectNeutral(tester, 'Trocando segmento…', 'with the STOP held');
      expect(rig.controller.status, DashcamStatus.recording, reason: 'the session is not touched');

      final start = rig.gate();
      rig.platform.pendingStartVideoCapturing = start;
      await tester.runAsync(() async {
        stop.complete();
        await rig.until(() => rig.count('startVideoCapturing') == 2, 'the restart');
      });
      await tester.pump();
      _expectNeutral(tester, 'Iniciando segmento…', 'with the START held');

      await tester.runAsync(() async {
        start.complete();
        await rig.until(() => rig.service.queuedRotationCountForTest == 0, 'the rotation settling');
      });
      await tester.pump();
      _expectNeutral(tester, 'Iniciando segmento…', 'N1: after Start, without video');

      // The tickers run: a timer has no way to authorize REC.
      await tester.pump(const Duration(seconds: 30));
      _expectNeutral(tester, 'Iniciando segmento…', 'after 30 s of the widgets\' own tickers');

      rig.platform.emitVideoProgress();
      await tester.pump();
      _expectRed(tester, 'with the new segment confirmed');

      expect(identical(tester.element(find.byType(DashcamCameraSurface)), previewElement), isTrue, reason: 'the same preview, never remounted');
      expect(identical(tester.element(find.byKey(const Key('surface'))), surfaceElement), isTrue);
      expect(rig.platform.calls.skip(callsAtFirstFrame).where((c) => c != 'stopVideoRecording' && c != 'startVideoCapturing' && c != 'prepareForVideoRecording'), isEmpty, reason: 'nothing but the rotation\'s own calls');
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  testWidgets('X560 — manual STOP: both REC neutral in the next frame, with the native STOP still held; later evidence does not relight', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await _mount(tester, rig);
      rig.platform.emitVideoProgress();
      await tester.pump();
      _expectRed(tester, 'test setup');

      final stop = rig.gate();
      rig.platform.pendingStopVideoRecording = stop;
      late Future<void> stopping;
      await tester.runAsync(() async {
        stopping = rig.controller.stopSession();
        await rig.until(() => rig.count('stopVideoRecording') == 1, 'the STOP');
      });
      await tester.pump();
      expect(_indicatorRed(tester), isFalse);
      expect(_previewRed(tester), isFalse);
      expect(rig.controller.segmentPresentation, DashcamSegmentPresentation.inactive);

      rig.platform.emitVideoProgress();
      await tester.pump();
      expect(_indicatorRed(tester), isFalse);
      expect(_previewRed(tester), isFalse);

      await tester.runAsync(() async {
        stop.complete();
        await stopping;
      });
      await tester.pump();
      expect(_indicatorRed(tester), isFalse);
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  testWidgets('X561 — N4 on screen: a spontaneous Finalize shows the failure, not only a neutral icon, and the session stays', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await _mount(tester, rig);
      rig.platform.emitVideoProgress();
      await tester.pump();
      _expectRed(tester, 'test setup');

      rig.platform.emitRecordingEnded(error: 3);
      await tester.pump();
      _expectNeutral(tester, 'Segmento encerrado inesperadamente', 'after the spontaneous end');
      expect(rig.controller.status, DashcamStatus.recording, reason: 'recovery is not this round\'s');
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  testWidgets('X562 — HOME and return: the old evidence does not relight; the return needs its own', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await _mount(tester, rig);
      rig.platform.emitVideoProgress();
      await tester.pump();
      _expectRed(tester, 'test setup');

      // In the real zone: the recovery's own async work must run without pumps.
      await tester.runAsync(() async => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused));
      // The binding draws no frames while paused: what the next frame would show is read at its source.
      expect(rig.controller.segmentPresentation, DashcamSegmentPresentation.inactive);

      final startsBefore = rig.count('startVideoCapturing');
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await rig.until(() => rig.count('startVideoCapturing') > startsBefore && rig.controller.status == DashcamStatus.recording, 'the recovery START');
      });
      await tester.pump();
      expect(_indicatorRed(tester), isFalse, reason: 'recovered, but no video of the new recording yet');
      expect(_previewRed(tester), isFalse);

      rig.platform.emitVideoProgress();
      await tester.pump();
      _expectRed(tester, 'with evidence of the new recording');
    } finally {
      await tester.runAsync(rig.close);
    }
  });

  testWidgets('X563 — a rebuilt UI reads the same state: no flash, no camera call', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.start);
    try {
      await _mount(tester, rig);
      rig.platform.emitVideoProgress();
      await tester.pump();
      final calls = rig.platform.calls.length;
      await tester.pumpWidget(const SizedBox());
      await _mount(tester, rig);
      await tester.pump();
      _expectRed(tester, 'after the UI was rebuilt');
      expect(rig.platform.calls.length, calls);
    } finally {
      await tester.runAsync(rig.close);
    }
  });
}
