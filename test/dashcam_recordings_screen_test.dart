// "Gravações" — every indexed clip of every session, newest first, grouped by day; a tap opens the
// same DashcamPlaybackScreen the session's "Vídeo" tab opens. Real Hive in a temporary directory.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/screens/sessions/dashcam_playback_screen.dart';
import 'package:synapse_auto/screens/sessions/dashcam_recordings_screen.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

DashcamClipRecord _clip(DateTime at, {bool protected = false}) => DashcamClipRecord(
  filePath: '/nowhere/clip_${at.millisecondsSinceEpoch}.mp4',
  recordedAt: at,
  durationSeconds: 75,
  sizeBytes: 3 * 1024 * 1024,
  isProtected: protected,
  resolution: VideoResolution.hd720,
  audioEnabled: false,
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dashcam_recordings_screen_test');
    if (!Hive.isAdapterRegistered(DashcamClipRecordAdapter().typeId)) Hive.registerAdapter(DashcamClipRecordAdapter());
    if (!Hive.isAdapterRegistered(VideoResolutionAdapter().typeId)) Hive.registerAdapter(VideoResolutionAdapter());
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
  });

  tearDown(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('every clip of every session, newest first', () async {
    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    await box.put('A', [_clip(DateTime(2026, 11, 10, 9)), _clip(DateTime(2026, 11, 11, 8))]);
    await box.put('B', [_clip(DateTime(2026, 11, 11, 17))]);

    final entries = loadDashcamRecordings();
    expect([for (final e in entries) (e.sessionId, e.clip.recordedAt.hour)], [('B', 17), ('A', 8), ('A', 9)]);
  });

  testWidgets('lists the clips under their day, and a tap opens the player for that clip', (tester) async {
    await tester.runAsync(() async {
      final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
      await box.put('A', [_clip(DateTime(2026, 11, 10, 9, 5, 7)), _clip(DateTime(2026, 11, 11, 8, 0, 1), protected: true)]);
      await box.put('B', [_clip(DateTime(2026, 11, 11, 17, 30, 0))]);
    });
    await tester.pumpWidget(const MaterialApp(home: DashcamRecordingsScreen()));

    expect(find.text('11/11/2026'), findsOneWidget);
    expect(find.text('10/11/2026'), findsOneWidget);
    final times = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).where((d) => d != null && RegExp(r'^\d\d:\d\d:\d\d$').hasMatch(d)).toList();
    expect(times, ['17:30:00', '08:00:01', '09:05:07']);
    expect(find.text('01:15 · 3.0 MB'), findsNWidgets(3));
    expect(find.byIcon(Icons.shield), findsOneWidget, reason: 'the protected clip is marked');

    await tester.tap(find.text('08:00:01'));
    // Not pumpAndSettle: the player shows a spinning progress indicator while
    // it looks for the file. The route transition is over well within this.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final player = tester.widget<DashcamPlaybackScreen>(find.byType(DashcamPlaybackScreen));
    expect(player.sessionId, 'A');
    expect(player.clip.recordedAt, DateTime(2026, 11, 11, 8, 0, 1));
  });

  testWidgets('with no clip it says there is nothing yet', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DashcamRecordingsScreen()));
    expect(find.textContaining('Nenhuma gravação ainda.'), findsOneWidget);
  });
}
