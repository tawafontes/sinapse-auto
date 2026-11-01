// Fase 16.2-R4.3-R2.6.8 — X118.
//
// R4.3-D2 (F20-F22, 3/3): after a failed finalization, recreating the
// dashboard disposed the recorder holding A — A became deletable, admission
// reopened (START B accepted), the retry became impossible (stopSession on the
// disposed recorder is refused) and A's pending samples were lost.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_status.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X118 A in finalizationFailed, dashboard recreated 3 times: same session and recorder, retry still '
    'offered, START B refused, deletion refused, no sample dropped, nothing written to disk; the retry then '
    'stores every sample',
    (tester) async {
      final app = AppHarness(tester);
      try {
        await app.run(() async {
          await app.boot();
          final host = app.host;
          final recorder = host.recorder;
          final controller = host.dashcamController;
          final a = await app.startSessionViaUi();
          await app.waitSamples(4);

          // A transient storage failure during the STOP (session screen is on top).
          await app.driveFuture(Hive.lazyBox(HiveBoxNames.drivingSessionSamples).close());
          app.emitting = false;
          await app.tapText('Finalizar sessão', settle: const Duration(milliseconds: 50));
          await app.driveUntil(() => recorder.state == DrivingSessionRecorderState.finalizationFailed, label: 'finalizationFailed');
          await app.driveUntil(() => controller.status == DashcamStatus.idle && !controller.dashcamService.hasPendingNativeStop, label: 'camera side settled');
          await app.driveFuture(Hive.openLazyBox(HiveBoxNames.drivingSessionSamples));
          final accepted = recorder.activeSession!.sampleCount;
          final pending = recorder.pendingSampleCountForTest;
          expect(pending, greaterThan(0), reason: 'setup: A still holds samples that are not stored');
          final storedBefore = await app.storedSamples(a);
          List<int> bytes(String box) => File('${app.dir.path}/$box.hive').readAsBytesSync();
          final sessionsFileBefore = bytes(HiveBoxNames.drivingSessions);
          final samplesFileBefore = bytes(HiveBoxNames.drivingSessionSamples);
          final sessionKeysBefore = app.sessionsBox.keys.toSet();

          for (var round = 1; round <= 3; round++) {
            final oldDashboard = app.dashboardStates().single;
            await app.tapThemeConclude();
            await app.settleDashboardTransition();
            expect(oldDashboard.mounted, isFalse, reason: 'setup: round $round replaced the dashboard');
            final why = 'after recreation $round';

            expect(app.host, same(host), reason: why);
            expect(host.recorder, same(recorder), reason: why);
            expect(recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: why);
            expect(recorder.activeSession!.id, a, reason: why);
            expect(recorder.activeSession!.sampleCount, accepted, reason: why);
            expect(recorder.pendingSampleCountForTest, pending, reason: '$why: no pending sample dropped');
            expect(DrivingSessionRecorder.controllingState(a), DrivingSessionRecorderState.finalizationFailed, reason: why);

            // START B refused, before anything is created.
            expect(controller.canStartSession, isFalse, reason: why);
            expect(() => controller.startSession(), throwsA(isA<SessionAdmissionRejected>()), reason: why);
            expect(app.sessionsBox.keys.toSet(), sessionKeysBefore, reason: '$why: no session B created');

            // Deletion refused.
            Object? deletion;
            try {
              await app.driveFuture(deleteDrivingSession(a));
            } catch (e) {
              deletion = e;
            }
            expect(deletion, isA<SessionDeletionRejected>(), reason: why);

            // Nothing about A was written by the recreation.
            expect(await app.storedSamples(a), storedBefore, reason: why);
            expect(listEquals(bytes(HiveBoxNames.drivingSessions), sessionsFileBefore), isTrue, reason: '$why: sessions box file unchanged');
            expect(listEquals(bytes(HiveBoxNames.drivingSessionSamples), samplesFileBefore), isTrue, reason: '$why: samples box file unchanged');
          }

          // The retry is still offered, and it completes A durably.
          await app.openSessionScreen();
          expect(app.shows('Tentar finalizar novamente'), isTrue);
          expect(app.shows('Iniciar sessão'), isFalse);
          await app.stopSessionViaUi();
          final record = app.sessionsBox.get(a)!;
          expect(record.endTime, isNotNull);
          expect(record.sampleCount, accepted);
          expect(await app.storedSamples(a), accepted, reason: 'every accepted sample stored by the retry');
          expect(DrivingSessionRecorder.controllingState(a), isNull);
          expect(controller.canStartSession, isTrue);
          expect(app.indexedClips(a), greaterThanOrEqualTo(1));
          expect(app.unindexedClipFiles(), isEmpty);
        });
      } finally {
        await app.teardown();
      }
    },
  );
}
