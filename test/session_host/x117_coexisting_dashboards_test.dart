// Fase 16.2-R4.3-R2.6.8 — X117.
//
// R4.3-D2 measured ~30 frames during which the replaced DashboardScreen and its
// replacement are both mounted (the Navigator keeps a removed route until the
// new one finishes pushing). Here the window is held open — 1 ms fake frames
// while real time passes — and a GNSS loss and recovery happen inside it. With
// one host, both dashboards observe the same authorities, and the single event
// forwarding records each event once; forwarding from each dashboard would
// record it twice.
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/services/driving_session_host.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X117 two DashboardScreens mounted at once observe one host; an event inside the window is recorded '
    'into session A exactly once, and unmounting the old dashboard changes nothing in A',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          final host = app.host;
          final recorder = host.recorder;
          final controller = host.dashcamController;
          final a = await app.startSessionViaUi();
          await app.waitSamples(3);
          await app.backToDashboard();
          final oldDashboard = app.dashboardStates().single;
          int count(DrivingSessionEventType type) => recorder.activeSession!.events.where((e) => e.type == type).length;
          final lostBefore = count(DrivingSessionEventType.gnssLost);
          final recoveredBefore = count(DrivingSessionEventType.gnssRecovered);

          app.emitting = false;
          app.pushReplacingDashboard();
          await tester.pump(const Duration(milliseconds: 1));
          expect(app.dashboardCount(), 2, reason: 'setup: both dashboards are mounted');

          Future<void> holdWindow({required bool Function() until, Duration extra = Duration.zero, required String label}) async {
            final sw = Stopwatch()..start();
            Duration? reachedAt;
            while (true) {
              if (reachedAt == null && until()) reachedAt = sw.elapsed;
              if (reachedAt != null && sw.elapsed - reachedAt >= extra) return;
              if (sw.elapsed > const Duration(seconds: 30)) fail('window: timed out waiting for $label');
              app.gps.emit();
              await tester.pump(const Duration(milliseconds: 1));
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
              expect(app.dashboardCount(), 2, reason: 'setup: the window stays open while $label');
            }
          }

          // Both dashboards resolve the same host, the same recorder authority.
          final states = app.dashboardStates();
          expect(states, contains(same(oldDashboard)));
          for (final state in states) {
            expect(state.context.getInheritedWidgetOfExactType<DrivingSessionScope>()!.host, same(host));
          }

          app.gps.accuracy = 100; // > 50 m ⇒ GnssQuality.unavailable ⇒ gnssLost
          await holdWindow(until: () => count(DrivingSessionEventType.gnssLost) > lostBefore, extra: const Duration(milliseconds: 800), label: 'gnssLost');
          app.gps.accuracy = 4;
          await holdWindow(until: () => count(DrivingSessionEventType.gnssRecovered) > recoveredBefore, extra: const Duration(milliseconds: 800), label: 'gnssRecovered');

          expect(count(DrivingSessionEventType.gnssLost), lostBefore + 1, reason: 'recorded once, not once per mounted dashboard');
          expect(count(DrivingSessionEventType.gnssRecovered), recoveredBefore + 1);
          expect(host.isForwardingEventsForTest, isTrue, reason: 'the host is the one forwarding');
          expect(recorder.activeSession!.id, a);
          expect(recorder.state, DrivingSessionRecorderState.recording);
          expect(DrivingSessionRecorder.controllingState(a), DrivingSessionRecorderState.recording);

          // The old dashboard goes away: nothing in A changes.
          app.emitting = true;
          final samples = recorder.activeSession!.sampleCount;
          final callsBefore = app.cameraCalls();
          await app.settleDashboardTransition();
          expect(oldDashboard.mounted, isFalse);
          expect(app.host, same(host));
          expect(recorder.activeSession!.id, a);
          expect(recorder.activeSession!.endTime, isNull);
          expect(app.sessionsBox.get(a)!.endTime, isNull);
          expect(controller.status, DashcamStatus.recording);
          expect(app.cameraCalls(), callsBefore, reason: 'no camera call caused by the old dashboard going away');
          expect(host.isForwardingEventsForTest, isTrue);
          await app.driveUntil(() => recorder.activeSession!.sampleCount > samples, label: 'A keeps collecting');

          await app.stopSessionViaUi();
          final record = app.sessionsBox.get(a)!;
          expect(record.events.where((e) => e.type == DrivingSessionEventType.gnssLost).length, lostBefore + 1);
          expect(record.events.where((e) => e.type == DrivingSessionEventType.gnssRecovered).length, recoveredBefore + 1);
          expect(await app.storedSamples(a), record.sampleCount);
          expect(app.unindexedClipFiles(), isEmpty);
          expect(host.isForwardingEventsForTest, isFalse, reason: 'no forwarding outside a recording');
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
