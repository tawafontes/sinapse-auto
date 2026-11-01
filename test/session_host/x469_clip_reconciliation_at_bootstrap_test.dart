// Fase 16.2-R4.4-R1 — X469.
//
// The canonical clips a previous run published and did not index are indexed by
// the app's bootstrap, in the order the design closure fixed: pending deletions
// are completed first, active sessions reclaimed next, the clip reconciliation
// runs only then — before the UI exists.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_descriptor.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';
import 'package:synapse_auto/services/dashcam_clip_index.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets(
    'X469 the bootstrap reconciles canonical clips after the pending deletions and the reclaim: a finished session\'s clip '
    'and a reclaimed active session\'s clip are indexed once; a session marked for deletion is deleted with its canonical '
    'file before the reconciliation runs; an orphan\'s file is kept and indexed nowhere',
    (tester) async {
      final app = AppHarness(tester);
      const finished = 'X469-finished';
      const marked = 'X469-marked';
      const active = 'X469-active';
      const orphan = 'X469-orphan';
      final t0 = DateTime(2026, 10, 24, 8);
      late String finishedClip;
      late String markedClip;
      late String activeClip;
      late String orphanClip;
      final atReconciliation = <String>[];
      afterReconciledClipHookForTest = (path, outcome) async {
        if (atReconciliation.isNotEmpty) return;
        final sessions = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
        atReconciliation.add('marked record present: ${sessions.containsKey(marked)}');
        atReconciliation.add('marked clip present: ${File(markedClip).existsSync()}');
        atReconciliation.add('active reclaimed: ${sessions.get(active)?.endTime != null}');
      };
      try {
        await app.run(() async {
          await app.boot(
            beforeBootstrap: () async {
              final clips = Directory('${app.dir.path}/$dashcamClipsDirectoryName')..createSync(recursive: true);
              String publish(String sessionId, int recordingId) {
                final d = DashcamClipDescriptor.tryCreate(
                  sessionId: sessionId,
                  recordedAt: t0.add(Duration(seconds: recordingId)),
                  namespace: '0469cafe0469cafe0469cafe0469cafe',
                  recordingId: recordingId,
                  durationSeconds: 3,
                  isProtected: false,
                  resolution: VideoResolution.hd720,
                  audioEnabled: false,
                )!;
                return (File('${clips.path}/${d.basename}')..writeAsBytesSync(List<int>.filled(64, 1))).path;
              }

              final sessions = Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
              await sessions.put(finished, DrivingSession(id: finished, startTime: t0, endTime: t0.add(const Duration(minutes: 3))));
              finishedClip = publish(finished, 1);
              await sessions.put(marked, DrivingSession(id: marked, startTime: t0, endTime: t0.add(const Duration(minutes: 3)), deletionPending: true));
              markedClip = publish(marked, 2);
              await sessions.put(active, DrivingSession(id: active, startTime: t0));
              await Hive.lazyBox(HiveBoxNames.drivingSessionSamples).put(active, [DrivingSessionSample(timestamp: t0.add(const Duration(seconds: 9)), speedKmh: 30)]);
              activeClip = publish(active, 3);
              orphanClip = publish(orphan, 4);
            },
          );

          List<String> indexed(String id) => [
            for (final r in List<DashcamClipRecord>.from(app.videosBox.get(id) as List? ?? const [])) dashcamClipBasename(r.filePath),
          ];
          expect(atReconciliation, ['marked record present: false', 'marked clip present: false', 'active reclaimed: true'],
              reason: 'the deletion and the reclaim ran before the reconciliation');
          expect(indexed(finished), [dashcamClipBasename(finishedClip)]);
          expect(indexed(active), [dashcamClipBasename(activeClip)]);
          expect(app.sessionsBox.get(active)!.isActive, isFalse, reason: 'reclaimed as before; the index did not touch the record');
          expect(app.sessionsBox.containsKey(marked) || app.videosBox.containsKey(marked) || File(markedClip).existsSync(), isFalse);
          expect(File(orphanClip).existsSync(), isTrue);
          expect(app.videosBox.containsKey(orphan) || app.sessionsBox.containsKey(orphan), isFalse);
          expect(app.unindexedClipFiles(), [dashcamClipBasename(orphanClip)]);
        });
      } finally {
        afterReconciledClipHookForTest = null;
        await app.teardown();
      }
    },
  );
}
