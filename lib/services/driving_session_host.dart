import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/detected_event.dart';
import 'alert_engine.dart';
import 'alert_preferences.dart';
import 'dashboard_sensor_streams.dart';
import 'dashcam_preferences.dart';
import 'dashcam_service.dart';
import 'dashcam_session_controller.dart';
import 'driving_session_recorder.dart';
import 'event_detection_engine.dart';
import 'obd/obd_bridge.dart';
import 'obd/obd_preferences.dart';
import 'obd/obd_service.dart';
import 'power_profile_preferences.dart';
import 'sensor_service.dart';

/// Fase 16.2-R4.3-R2.6.8: "Redefinir configuração" refused because the driving
/// session still has an open obligation — [blocker] says which. Thrown before
/// anything is reset. A distinct type, like [SessionAdmissionRejected], so the
/// UI can explain this EXPECTED refusal without silencing real errors.
class ConfigurationResetRejected extends StateError {
  ConfigurationResetRejected(this.blocker)
    : super(
        'Configuration reset rejected: the driving session is still ${blocker.name}; '
        'it must be stopped and durably finalized first. Nothing was reset.',
      );

  final DrivingSessionRecorderState blocker;
}

/// Fase 16.2-R4.3-R2.6.8 (R4.3-D2, Alternative A): owns everything whose
/// lifetime is the driving session's rather than a screen's. Before this,
/// `DashboardScreen` built all of it, and three normal flows replace that
/// screen (Tema → Concluir, "+" → Continuar, Redefinir). Reproduced through the
/// real UI: the new screen's reclaim closed the live session, its pending
/// samples were lost, the old screen's dispose stopped the camera and left the
/// clip unindexed, and a session whose finalization had failed lost both its
/// retry and its deletion protection while a new session was admitted.
///
/// What lives here, and why each one cannot live in a screen:
///  * [sensorService] → [streams]: the single sensor/telemetry pipeline
///    (CLAUDE.md §4). The recorder and both detectors consume
///    [DashboardSensorStreams.snapshot], so the pipeline must live at least as
///    long as they do — and a second one per screen is what CLAUDE.md forbids;
///  * [recorder]: THE logical session — active session, pending samples,
///    finalization in flight or failed, and its retry;
///  * [eventEngine]: the single event detector; it feeds the session's event
///    log and the dashcam. Forwarding its events into [recorder] is done here,
///    once: while two dashboards coexist during a recreation, forwarding from
///    each of them would record every event twice;
///  * [alertEngine]: hysteresis/cooldown state over the same snapshot — one
///    per dashboard meant two independent fire decisions while two dashboards
///    coexist, and a cooldown bypassed at every recreation;
///  * [dashcamController] (and the [DashcamService] it disposes): the
///    session's persistence obligations (clip → session index, telemetry
///    writer, STOP protocol) and the lifecycle-generation authority, whose
///    counter restarted at 0 with every recreated screen. Owning it here does
///    NOT keep the camera on: the camera is still acquired by a START, released
///    by a STOP, suspended and recovered with the app lifecycle — the
///    controller's own contracts, unchanged.
///
/// Owned by the app's root `State` — created in its `initState`, disposed in
/// its `dispose` — and reached through [DrivingSessionScope]; deliberately not
/// a singleton or a static. Screens observe it, render, and forward user
/// intents; none of them builds, owns or disposes anything here.
///
/// Construction subscribes to nothing: listening to the snapshot is what
/// starts GPS and the sensors (and asks for location permission, which
/// onboarding must do first). The pipeline runs while something listens — a
/// mounted dashboard, a recording session — and stops when nothing does.
class DrivingSessionHost {
  factory DrivingSessionHost({
    required PowerProfilePreferences powerProfile,
    required AlertPreferences alertPreferences,
    required DashcamPreferences dashcamPreferences,
    ObdPreferences? obdPreferences,
    ObdBridge? obdBridge,
  }) {
    final sensorService = SensorService();
    // OBD-II phase 1: the second physical source, only where there is an
    // adapter to talk to (the native bridge is Android only) and the app gave
    // its preferences — tests that do not care get none.
    final bridge = obdBridge ??
        debugObdBridgeOverride ??
        (MethodChannelObdBridge.isSupported ? const MethodChannelObdBridge() : null);
    final obd = obdPreferences == null || bridge == null ? null : ObdService(bridge: bridge, preferences: obdPreferences);
    final streams = DashboardSensorStreams(sensorService, powerProfile: powerProfile, obd: obd);
    final recorder = DrivingSessionRecorder(streams.snapshot);
    final eventEngine = EventDetectionEngine(streams.snapshot, alertPreferences);
    return DrivingSessionHost._(
      dashcamPreferences,
      obd: obd,
      sensorService: sensorService,
      streams: streams,
      recorder: recorder,
      alertEngine: AlertEngine(streams.snapshot, alertPreferences),
      eventEngine: eventEngine,
      dashcamController: DashcamSessionController(
        dashcamService: DashcamService(config: dashcamPreferences.config),
        dashcamPreferences: dashcamPreferences,
        sessionRecorder: recorder,
        snapshotStream: streams.snapshot,
        eventStream: eventEngine.events,
      ),
    );
  }

  DrivingSessionHost._(
    this._dashcamPreferences, {
    this.obd,
    required this.sensorService,
    required this.streams,
    required this.recorder,
    required this.alertEngine,
    required this.eventEngine,
    required this.dashcamController,
  }) {
    recorder.addListener(_syncEventForwarding);
    _dashcamPreferences.addListener(_onDashcamPreferencesChanged);
    final obd = this.obd;
    if (obd != null) {
      recorder.addListener(_syncObdWithRecorder);
      _obdReadings = obd.readingsStream.listen((_) => _maybeAutoStartSession());
      // The app is opening: connect silently, if the owner wants it automatic.
      obd.resume();
    }
  }

  final DashcamPreferences _dashcamPreferences;

  /// The adapter bridge the real app's host uses in a test (the app mounts
  /// its own host, and the test host is not Android) — a scripted car.
  @visibleForTesting
  static ObdBridge? debugObdBridgeOverride;

  /// The single owner of the OBD-II link (phase 1); `null` when the app has
  /// no adapter bridge (see the factory).
  final ObdService? obd;
  StreamSubscription<ObdReadings>? _obdReadings;
  bool _inForeground = true;

  /// Whether the next "car answering and moving" may start a session — once
  /// per time the car comes on, so stopping a session by hand while the
  /// engine runs does not start another one right away.
  bool _autoStartArmed = true;
  final SensorService sensorService;
  final DashboardSensorStreams streams;
  final DrivingSessionRecorder recorder;
  final AlertEngine alertEngine;
  final EventDetectionEngine eventEngine;
  final DashcamSessionController dashcamController;

  StreamSubscription<DetectedEvent>? _eventForwarding;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  @visibleForTesting
  bool get isForwardingEventsForTest => _eventForwarding != null;

  /// Records every confirmed event into the active session, exactly once —
  /// subscribed only while the recorder is recording (the only state in which
  /// [DrivingSessionRecorder.recordDetectedEvent] records anything), so the
  /// host never keeps the pipeline running on its own outside a session.
  void _syncEventForwarding() {
    if (recorder.state == DrivingSessionRecorderState.recording) {
      _eventForwarding ??= eventEngine.events.listen(recorder.recordDetectedEvent);
    } else {
      final forwarding = _eventForwarding;
      _eventForwarding = null;
      unawaited(forwarding?.cancel());
    }
  }

  /// Forwarded from the root `State`'s `WidgetsBindingObserver`. In the
  /// background the OBD link stays up only while a session records (owner
  /// decision); otherwise the adapter is let go, and picked up again on
  /// return.
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final obd = this.obd;
    if (obd == null || _disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _inForeground = true;
        obd.resume();
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _inForeground = false;
        _syncObdWithRecorder();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _syncObdWithRecorder() {
    final obd = this.obd;
    if (obd == null || _inForeground) return;
    if (recorder.state != DrivingSessionRecorderState.recording) unawaited(obd.pause());
  }

  /// "Iniciar sessão quando o carro ligar" (off by default): the car answering
  /// is not enough — on the Nivus the ECUs answer with the ignition on and the
  /// engine stopped — so the trigger is the engine turning (rpm > 0) or the
  /// car moving (OBD speed > 0, which also covers a plug-in hybrid driving
  /// electric with the engine at 0 rpm).
  void _maybeAutoStartSession() {
    final obd = this.obd;
    if (obd == null || _disposed) return;
    if (obd.state != ObdLinkState.receiving) {
      _autoStartArmed = true;
      return;
    }
    if (!_autoStartArmed || !_inForeground || !obd.preferences.autoStartSession) return;
    if (recorder.state != DrivingSessionRecorderState.idle) return;
    double live(ObdSignal signal) => obd.isFresh(signal) ? obd.readings[signal]?.value ?? 0 : 0;
    if (live(ObdSignal.rpm) <= 0 && live(ObdSignal.speed) <= 0) return;
    _autoStartArmed = false;
    try {
      dashcamController.startSession();
    } on SessionAdmissionRejected {
      // A session is still being finalized: nothing was touched.
    }
  }

  /// Keeps [DashcamService]'s config in sync with live changes made in
  /// `DashcamSettingsScreen` (e.g. a resolution change) — takes effect on the
  /// next camera `initialize()`, i.e. the next session start.
  void _onDashcamPreferencesChanged() {
    dashcamController.dashcamService.updateConfig(_dashcamPreferences.config);
  }

  /// Why "Redefinir configuração" must not run now, or `null` when the session
  /// side is free. The recorder is the authority: a session still recording
  /// (stop it first), being finalized (wait for it), or whose finalization
  /// failed (retry it first) — resetting then would leave that session with no
  /// screen to stop or retry it until onboarding ends. The camera side of an
  /// already-finalized session is not an obligation this blocks: its teardown
  /// and clip indexing belong to [dashcamController], which the reset's
  /// navigation does not touch.
  DrivingSessionRecorderState? get configurationResetBlocker {
    _ensureNotDisposed();
    final state = recorder.state;
    return state == DrivingSessionRecorderState.idle ? null : state;
  }

  /// Throws [ConfigurationResetRejected] unless [configurationResetBlocker] is
  /// `null`.
  void ensureConfigurationResetAllowed() {
    final blocker = configurationResetBlocker;
    if (blocker != null) throw ConfigurationResetRejected(blocker);
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('DrivingSessionHost used after dispose().');
  }

  /// App teardown only (the root `State`'s own dispose). Idempotent. Stops
  /// the consumers first, then the sensor source: a session still recording
  /// is left as the next start's reclaim finds it (as before), the camera is
  /// released by the controller's own teardown, and no subscription or timer
  /// of the pipeline survives.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    recorder.removeListener(_syncEventForwarding);
    recorder.removeListener(_syncObdWithRecorder);
    _dashcamPreferences.removeListener(_onDashcamPreferencesChanged);
    unawaited(_obdReadings?.cancel());
    final obd = this.obd;
    if (obd != null) {
      unawaited(obd.pause());
      obd.dispose();
    }
    final forwarding = _eventForwarding;
    _eventForwarding = null;
    unawaited(forwarding?.cancel());
    recorder.dispose();
    dashcamController.dispose();
    alertEngine.dispose();
    eventEngine.dispose();
    unawaited(sensorService.dispose());
  }
}

/// Makes the app's single [DrivingSessionHost] reachable from any descendant
/// via [DrivingSessionScope.of] — the `...Scope` pattern of CLAUDE.md §5. A
/// plain [InheritedWidget], not an `InheritedNotifier`: the host itself never
/// changes (screens listen to its recorder/controller directly).
class DrivingSessionScope extends InheritedWidget {
  const DrivingSessionScope({super.key, required this.host, required super.child});

  final DrivingSessionHost host;

  static DrivingSessionHost of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DrivingSessionScope>();
    assert(scope != null, 'No DrivingSessionScope found in context');
    return scope!.host;
  }

  @override
  bool updateShouldNotify(DrivingSessionScope oldWidget) => !identical(host, oldWidget.host);
}
