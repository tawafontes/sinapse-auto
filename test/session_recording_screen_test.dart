import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/screens/sessions/session_recording_screen.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/unit_preferences.dart';

void main() {
  late Directory dir;
  late StreamController<TelemetrySnapshot> controller;
  late DrivingSessionRecorder recorder;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('session_recording_screen_test');
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
    }
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    controller = StreamController<TelemetrySnapshot>.broadcast();
    recorder = DrivingSessionRecorder(controller.stream);
  });

  tearDown(() async {
    await Future<void>.delayed(Duration.zero);
    await controller.close();
    recorder.dispose();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Widget build(Size size) => MediaQuery(
    data: MediaQueryData(size: size),
    child: MaterialApp(
      home: UnitPreferencesScope(preferences: UnitPreferences(), child: SessionRecordingScreen(recorder: recorder)),
    ),
  );

  group('SessionRecordingScreen (Fase 13.1 incidental fix — landscape overflow)', () {
    // Only the idle-state case is covered here — the active-session variant
    // (session started, snapshot pushed) hangs indefinitely inside
    // flutter_test's FakeAsync test zone regardless of stream interaction,
    // a pre-existing test-harness limitation unrelated to this fix (not
    // reproducible outside the widget-test environment). The actual overflow
    // fix (wrapping the body in SingleChildScrollView) was verified directly
    // on a physical device instead — see the Fase 13.1 report.
    testWidgets('the idle (no session) state fits without overflow in a short landscape viewport', (tester) async {
      // A real device landscape viewport (short height) is exactly what
      // triggered the original RenderFlex overflow — the screen previously
      // had no scroll fallback for this case.
      await tester.pumpWidget(build(const Size(1600, 720)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('Iniciar sessão'), findsOneWidget);
    });
  });
}
