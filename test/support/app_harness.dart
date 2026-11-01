// Mounts the REAL app (SynapseAutoApp after the real bootstrapApp(): Hive,
// startup recovery, root State, DrivingSessionHost, DashboardScreen and every
// screen reached through the UI) over fake PLATFORM interfaces only — camera
// (fake_camera_platform.dart), GPS/motion sensors/wakelock
// (fake_sensor_platforms.dart) and path_provider. No app class is mocked.
//
// One test per file: HiveBoxes.init() runs once per isolate, and the camera's
// process owner is static — a failed test must not leak either into another.
//
// Driving: FakeAsync frames alternated with real time (Hive and file I/O are
// real). The recorder decimates on real DateTime.now() timestamps (1 sample/s),
// so GPS fixes are emitted on real time while [AppHarness.emitting]. Every wait
// is a condition with a timeout, never a fixed sleep that assumes a speed.
import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive/hive.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:synapse_auto/main.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/screens/dashboard/dashboard_screen.dart';
import 'package:synapse_auto/services/dashcam_session_controller.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';
import 'package:synapse_auto/services/theme_controller.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_rec_indicator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'fake_camera_platform.dart';
import 'fake_sensor_platforms.dart';

/// Every periodic [Timer] the app creates while [run]'s body executes,
/// attributed to the lib/ file whose frame is closest to the creation. The
/// GNSS stale-check timer of `telemetry_engine.dart` exists once per LIVE
/// snapshot pipeline, so it counts live pipelines.
class TimerCensus {
  final Set<_CensusTimer> _timers = {};

  Future<T> run<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        final timer = _CensusTimer(parent.createPeriodicTimer(zone, period, callback), _origin(StackTrace.current));
        _timers.add(timer);
        return timer;
      },
    ),
  );

  /// Live periodic timers per lib/ file.
  Map<String, int> get live {
    final m = <String, int>{};
    for (final t in _timers) {
      if (!t.isActive) continue;
      m[t.origin] = (m[t.origin] ?? 0) + 1;
    }
    return m;
  }

  int liveOf(String file) => live.entries.where((e) => e.key.endsWith(file)).fold(0, (a, e) => a + e.value);

  int get liveTotal => live.values.fold(0, (a, b) => a + b);

  static String _origin(StackTrace st) {
    for (final line in st.toString().split('\n')) {
      final m = RegExp(r'package:synapse_auto/(\S+?\.dart)').firstMatch(line);
      if (m != null) return m.group(1)!;
    }
    return 'other';
  }
}

class _CensusTimer implements Timer {
  _CensusTimer(this._inner, this.origin);
  final Timer _inner;
  final String origin;

  @override
  void cancel() => _inner.cancel();

  @override
  bool get isActive => _inner.isActive;

  @override
  int get tick => _inner.tick;
}

const gnssTimerFile = 'services/telemetry_engine.dart';

class AppHarness {
  AppHarness(this.tester);

  final WidgetTester tester;
  final census = TimerCensus();
  late Directory dir;
  late FakeCameraPlatform camera;
  late FakeGeolocatorPlatform gps;
  late FakeSensorsPlatform sensors;
  bool emitting = false;
  final _emitClock = Stopwatch();

  static const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  Box<DrivingSession> get sessionsBox => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  Box get videosBox => Hive.box(HiveBoxNames.dashcamSessionVideos);

  /// The app's host, as the widget tree exposes it.
  DrivingSessionHost get host => tester.widget<DrivingSessionScope>(find.byType(DrivingSessionScope)).host;

  /// The dashcam controller the (newest) dashboard actually renders and
  /// forwards intents to — observed from the UI, so a regression that gives
  /// the dashboard its own objects again is seen by its consequences.
  DashcamSessionController get uiController =>
      tester.widget<DashcamRecIndicator>(find.byType(DashcamRecIndicator, skipOffstage: false).last).controller;

  /// Runs [body] inside the [census].
  Future<void> run(Future<void> Function() body) => census.run(body);

  /// Platform fakes, then the real [bootstrapApp], then [SynapseAutoApp].
  /// [beforeBootstrap] runs with the boxes open, before the startup recovery.
  Future<void> boot({
    Map<SensorType, DisplayStyle> seedTiles = const {},
    Future<void> Function()? beforeBootstrap,
    bool onboardingDone = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('session_host_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _pathProvider,
        (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
      );
      camera = FakeCameraPlatform(tempDir: dir);
      CameraPlatform.instance = camera;
      gps = FakeGeolocatorPlatform();
      GeolocatorPlatform.instance = gps;
      sensors = FakeSensorsPlatform();
      SensorsPlatform.instance = sensors;
      wakelockPlusPlatformInstance = FakeWakelockPlatform();
      if (beforeBootstrap != null) {
        await HiveBoxes.init();
        await beforeBootstrap();
      }
      await bootstrapApp();
      if (onboardingDone) await ThemeController().commit();
      await Hive.box<DashcamConfig>(HiveBoxNames.dashcamConfig).put(
        'config',
        DashcamConfig(
          cameraSelection: CameraSelection.rear,
          storageQuotaMb: 1024,
          audioEnabled: false,
          resolution: VideoResolution.hd720,
          frameRate: 30,
          enabled: true,
        ),
      );
      for (final e in seedTiles.entries) {
        await SensorWidgetRepository.upsertStyle(e.key, e.value);
      }
    });
    await tester.pumpWidget(const SynapseAutoApp());
    await drive(const Duration(milliseconds: 300));
    if (onboardingDone) await driveUntil(() => dashboardCount() == 1, label: 'dashboard mounted');
  }

  /// Pumps FakeAsync frames interleaved with real time for [real] (or until
  /// [until]); emits a GPS fix every 250 ms of real time while [emitting].
  Future<void> drive(Duration real, {bool Function()? until, Duration frame = const Duration(milliseconds: 20)}) async {
    final sw = Stopwatch()..start();
    if (!_emitClock.isRunning) _emitClock.start();
    while (sw.elapsed < real) {
      if (until != null && until()) return;
      emitIfDue();
      await tester.pump(frame);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
  }

  void emitIfDue() {
    if (emitting && _emitClock.elapsedMilliseconds >= 250) {
      _emitClock.reset();
      gps.emit();
    }
  }

  Future<void> driveUntil(bool Function() condition, {Duration timeout = const Duration(seconds: 30), required String label}) async {
    await drive(timeout, until: condition);
    if (!condition()) fail('harness: timed out waiting for "$label"');
  }

  Future<T> driveFuture<T>(Future<T> future, {Duration timeout = const Duration(seconds: 30)}) async {
    var done = false;
    T? value;
    Object? error;
    StackTrace? stack;
    future.then<void>(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    );
    await drive(timeout, until: () => done);
    if (!done) fail('harness: future did not complete');
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value as T;
  }

  bool shows(String text) => find.text(text).hitTestable().evaluate().isNotEmpty;

  Future<void> tapText(String text, {Duration settle = const Duration(milliseconds: 200)}) async {
    await driveUntil(() => shows(text), label: 'shown: $text');
    await tester.tap(find.text(text).hitTestable().last);
    await drive(settle);
  }

  int dashboardCount() => find.byType(DashboardScreen, skipOffstage: false).evaluate().length;

  List<State> dashboardStates() => [
    for (final e in find.byType(DashboardScreen, skipOffstage: false).evaluate()) (e as StatefulElement).state,
  ];

  /// Back to the root route, waiting until nothing remains above it.
  Future<void> backToDashboard() async {
    tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((route) => route.isFirst);
    await driveUntil(
      () => find.byTooltip('Configurações').hitTestable().evaluate().length == 1 && find.byType(BackButton).evaluate().isEmpty,
      label: 'back on the dashboard',
    );
  }

  Future<void> openSettings() async {
    await backToDashboard();
    await tester.tap(find.byTooltip('Configurações'));
    await driveUntil(() => shows('Sessão de condução'), label: 'settings');
  }

  Future<void> openSessionScreen() async {
    await openSettings();
    await tapText('Sessão de condução');
    await driveUntil(
      () => shows('Iniciar sessão') || shows('Finalizar sessão') || shows('Tentar finalizar novamente') || shows('Finalizando…'),
      label: 'session screen',
    );
  }

  /// START through the UI; returns once the session records and the camera
  /// records it.
  Future<String> startSessionViaUi() async {
    emitting = true;
    await openSessionScreen();
    await tapText('Iniciar sessão', settle: const Duration(milliseconds: 50));
    final controller = uiController;
    final recorder = controller.sessionRecorder;
    await driveUntil(
      () => recorder.state == DrivingSessionRecorderState.recording && controller.status == DashcamStatus.recording,
      label: 'session recording with camera',
    );
    return recorder.activeSession!.id;
  }

  /// STOP (or the finalization retry) through the UI; returns once the
  /// recorder is idle and the camera side has settled.
  Future<void> stopSessionViaUi() async {
    await openSessionScreen();
    final controller = uiController;
    await tapText(shows('Tentar finalizar novamente') ? 'Tentar finalizar novamente' : 'Finalizar sessão', settle: const Duration(milliseconds: 50));
    await driveUntil(
      () =>
          controller.sessionRecorder.state == DrivingSessionRecorderState.idle &&
          controller.status == DashcamStatus.idle &&
          !controller.dashcamService.hasPendingNativeStop,
      label: 'session stopped',
    );
    await drive(const Duration(milliseconds: 500));
  }

  Future<void> waitSamples(int count) {
    final recorder = uiController.sessionRecorder;
    return driveUntil(() => (recorder.activeSession?.sampleCount ?? 0) >= count, timeout: const Duration(seconds: 60), label: '$count samples');
  }

  /// Settings → Tema → "Claro fixo" → "Concluir": ThemeSelectionScreen._finish
  /// replaces the dashboard with pushAndRemoveUntil.
  Future<void> tapThemeConclude() async {
    await openSettings();
    await tapText('Tema');
    await tapText('Claro fixo');
    await driveUntil(() => shows('Concluir'), label: 'Concluir');
    await tester.tap(find.text('Concluir').hitTestable().last);
  }

  /// "+" → "Continuar": StyleSelectionScreen._finish (edit mode) replaces the
  /// dashboard with pushAndRemoveUntil. Needs a dashboard tile whose sensor has
  /// a single style, so the style step finishes on its own.
  Future<void> tapAddToolContinue() async {
    await backToDashboard();
    await tester.tap(find.byTooltip('Adicionar ferramenta'));
    await driveUntil(() => shows('Continuar'), label: 'Continuar');
    await tester.tap(find.text('Continuar').hitTestable().last);
  }

  /// The same pushAndRemoveUntil(DashboardScreen) the theme/edit flows issue.
  void pushReplacingDashboard() {
    tester.state<NavigatorState>(find.byType(Navigator).first).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const DashboardScreen()),
      (route) => false,
    );
  }

  /// Frames until exactly one dashboard is left; [onFrame] runs after each.
  Future<int> settleDashboardTransition({void Function(int frame)? onFrame, int maxFrames = 600}) async {
    for (var i = 0; i < maxFrames; i++) {
      emitIfDue();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
      onFrame?.call(i);
      if (i > 2 && dashboardCount() == 1 && find.byType(BackButton).evaluate().isEmpty) return i;
    }
    fail('harness: dashboard transition did not settle');
  }

  Future<int?> storedSamples(String id) async {
    final raw = await driveFuture(Hive.lazyBox(HiveBoxNames.drivingSessionSamples).get(id));
    return raw == null ? null : (raw as List).length;
  }

  int indexedClips(String id) => (videosBox.get(id) as List?)?.length ?? 0;

  List<String> clipFiles() {
    final d = Directory('${dir.path}/dashcam_clips');
    if (!d.existsSync()) return [];
    return d.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
  }

  /// Clip files that no session's index names.
  List<String> unindexedClipFiles() {
    final indexed = <String>{};
    for (final key in videosBox.keys) {
      for (final r in (videosBox.get(key) as List?) ?? const []) {
        indexed.add(File((r as dynamic).filePath as String).uri.pathSegments.last);
      }
    }
    return clipFiles().where((f) => !indexed.contains(f)).toList();
  }

  int telemetryLines(String id) {
    final f = File('${dir.path}/dashcam_telemetry/$id.jsonl');
    return f.existsSync() ? f.readAsLinesSync().length : 0;
  }

  Map<String, int> cameraCalls() {
    final m = <String, int>{};
    for (final c in camera.calls) {
      m[c] = (m[c] ?? 0) + 1;
    }
    return m;
  }

  /// Unmounts the app (the root State and its host are disposed) and lets
  /// every asynchronous teardown and timeout settle, so flutter_test's own
  /// "no pending timers" invariant judges what is really left. Then closes
  /// Hive and removes the temporary directory.
  Future<void> teardown() async {
    emitting = false;
    await tester.pumpWidget(const SizedBox());
    await drive(const Duration(seconds: 1));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await driveFuture(Hive.close());
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 20 && dir.existsSync(); attempt++) {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    tester.view.reset();
  }
}
