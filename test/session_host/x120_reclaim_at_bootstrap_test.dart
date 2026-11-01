// Fase 16.2-R4.3-R2.6.8 — X120.
//
// reclaimOrphanedSessions() closes every session left active. That is only
// right once, at startup, before any recorder of this process exists. It used
// to run in every DashboardScreen.initState — and a replacement dashboard is
// mounted while the old one still records, so it closed the live session
// (R4.3-D2 F10, 3/3).
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X120 orphans are reclaimed exactly once, by the app bootstrap: one left by a "previous run" is closed '
    'at startup; one appearing later, and the live session, are never touched by dashboard recreations',
    (tester) async {
      final app = AppHarness(tester);
      const beforeStart = 'X120-orphan-of-previous-run';
      const afterStart = 'X120-orphan-appearing-after-startup';
      final t0 = DateTime.utc(2026, 9, 1, 8);
      try {
        await app.run(() async {
          await app.boot(
            beforeBootstrap: () async {
              await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).put(beforeStart, DrivingSession(id: beforeStart, startTime: t0)..sampleCount = 7);
              await Hive.lazyBox(HiveBoxNames.drivingSessionSamples).put(beforeStart, [
                for (var i = 1; i <= 3; i++) DrivingSessionSample(timestamp: t0.add(Duration(seconds: i)), speedKmh: 30),
              ]);
            },
          );

          // Reclaimed by the bootstrap, from what it had stored.
          final reclaimed = app.sessionsBox.get(beforeStart)!;
          expect(reclaimed.endTime, isNotNull, reason: 'closed by the startup reclaim');
          expect(reclaimed.endTime!.isAtSameMomentAs(t0.add(const Duration(seconds: 3))), isTrue, reason: 'at its last stored sample');
          expect(reclaimed.sampleCount, 3);

          // An active record that shows up after startup (standing in for any
          // orphan the bootstrap did not see) and the live session A.
          await app.driveFuture(app.sessionsBox.put(afterStart, DrivingSession(id: afterStart, startTime: t0)));
          final recorder = app.host.recorder;
          final a = await app.startSessionViaUi();
          await app.waitSamples(2);

          await app.tapThemeConclude();
          await app.settleDashboardTransition();
          app.pushReplacingDashboard();
          await app.settleDashboardTransition();
          await app.drive(const Duration(seconds: 1));

          expect(app.sessionsBox.get(afterStart)!.endTime, isNull, reason: 'no reclaim ran after the bootstrap');
          expect(app.sessionsBox.get(afterStart)!.isActive, isTrue);
          expect(recorder.state, DrivingSessionRecorderState.recording);
          expect(recorder.activeSession!.id, a);
          expect(app.sessionsBox.get(a)!.endTime, isNull, reason: 'the live session was not closed');
          expect(app.sessionsBox.get(beforeStart)!.sampleCount, 3, reason: 'the reclaimed one was not rewritten');

          await app.stopSessionViaUi();
          expect(app.sessionsBox.get(afterStart)!.isActive, isTrue);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
