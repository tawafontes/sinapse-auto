// deleteDashcamClipByUser — the user's "Excluir" on one recorded clip: file first, then its index
// entry, in a turn of the index FIFO; a protected clip goes too; a clip of a session a recorder still
// controls is refused before anything is touched. Real Hive and real files in a temporary directory.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/dashcam_clip_files.dart';
import 'package:synapse_auto/services/dashcam_storage_quota.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

/// Leaves every file in place: a delete that "succeeds" without removing anything.
class _StuckFileOps extends DashcamClipFileOps {
  const _StuckFileOps();

  @override
  Future<void> delete(String path) async {}
}

void main() {
  late Directory dir;
  Box<DrivingSession> sessions() => Hive.box<DrivingSession>(HiveBoxNames.drivingSessions);
  Box videos() => Hive.box(HiveBoxNames.dashcamSessionVideos);

  Future<DashcamClipRecord> clipOf(String sessionId, String name, {bool protected = false}) async {
    final file = File('${dir.path}/dashcam_clips/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(64, 7));
    return DashcamClipRecord(filePath: file.path, recordedAt: DateTime(2026, 11, 11), sizeBytes: 64, isProtected: protected);
  }

  Future<void> finishedSession(String id, List<DashcamClipRecord> clips) async {
    await sessions().put(id, DrivingSession(id: id, startTime: DateTime(2026, 11, 11, 9), endTime: DateTime(2026, 11, 11, 10)));
    await videos().put(id, clips);
  }

  List<String> namesIndexed(String id) => [for (final c in (videos().get(id) as List? ?? const [])) dashcamClipBasename((c as DashcamClipRecord).filePath)];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dashcam_clip_user_deletion_test');
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
    }
    if (!Hive.isAdapterRegistered(DashcamClipRecordAdapter().typeId)) Hive.registerAdapter(DashcamClipRecordAdapter());
    if (!Hive.isAdapterRegistered(VideoResolutionAdapter().typeId)) Hive.registerAdapter(VideoResolutionAdapter());
    Hive.init(dir.path);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
  });

  tearDown(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('deletes the file and only its own entry; the session and its other clips stay', () async {
    final one = await clipOf('S', 'one.mp4');
    final two = await clipOf('S', 'two.mp4');
    await finishedSession('S', [one, two]);

    expect(await deleteDashcamClipByUser(sessionId: 'S', filePath: one.filePath), DashcamClipDeletionOutcome.deleted);

    expect(File(one.filePath).existsSync(), isFalse);
    expect(File(two.filePath).existsSync(), isTrue);
    expect(namesIndexed('S'), ['two.mp4']);
    expect(sessions().containsKey('S'), isTrue);
  });

  test('the last clip of a session removes its key (the History then shows no video), and a protected one goes too', () async {
    final only = await clipOf('S', 'only.mp4', protected: true);
    await finishedSession('S', [only]);

    expect(await deleteDashcamClipByUser(sessionId: 'S', filePath: only.filePath), DashcamClipDeletionOutcome.deleted);
    expect(File(only.filePath).existsSync(), isFalse);
    expect(videos().containsKey('S'), isFalse);
  });

  test('a clip no longer indexed is left alone: nothing deleted', () async {
    final kept = await clipOf('S', 'kept.mp4');
    final stray = await clipOf('S', 'stray.mp4');
    await finishedSession('S', [kept]);

    expect(await deleteDashcamClipByUser(sessionId: 'S', filePath: stray.filePath), DashcamClipDeletionOutcome.notIndexed);
    expect(File(stray.filePath).existsSync(), isTrue, reason: 'not the index\'s to delete');
    expect(namesIndexed('S'), ['kept.mp4']);
  });

  test('a file that stays on disk keeps its entry (fileFailed)', () async {
    final clip = await clipOf('S', 'stuck.mp4');
    await finishedSession('S', [clip]);

    expect(await deleteDashcamClipByUser(sessionId: 'S', filePath: clip.filePath, fileOps: const _StuckFileOps()), DashcamClipDeletionOutcome.fileFailed);
    expect(File(clip.filePath).existsSync(), isTrue);
    expect(namesIndexed('S'), ['stuck.mp4']);
  });

  test('a clip of a session a recorder still controls is refused before anything is touched', () async {
    final snapshots = StreamController<TelemetrySnapshot>.broadcast();
    final recorder = DrivingSessionRecorder(snapshots.stream);
    final live = recorder.startSession();
    final clip = await clipOf(live.id, 'live.mp4');
    await videos().put(live.id, [clip]);

    expect(() => deleteDashcamClipByUser(sessionId: live.id, filePath: clip.filePath), throwsA(isA<DashcamClipDeletionRejected>()));
    expect(File(clip.filePath).existsSync(), isTrue);
    expect(namesIndexed(live.id), ['live.mp4']);

    await recorder.stopSession();
    recorder.dispose();
    await snapshots.close();
    expect(await deleteDashcamClipByUser(sessionId: live.id, filePath: clip.filePath), DashcamClipDeletionOutcome.deleted,
        reason: 'once finalized, the same clip can be deleted');
  });
}
