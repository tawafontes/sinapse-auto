// "Gravações" — every indexed clip of every session, newest first, grouped by day; a tap opens the
// same DashcamPlaybackScreen the session's "Vídeo" tab opens. Real Hive in a temporary directory.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/screens/sessions/dashcam_playback_screen.dart';
import 'package:synapse_auto/screens/sessions/dashcam_recordings_screen.dart';
import 'package:synapse_auto/services/dashcam_gallery_exporter.dart';
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

  testWidgets('the delete button asks first, then deletes that clip and refreshes the list', (tester) async {
    late File kept;
    late File doomed;
    await tester.runAsync(() async {
      Hive.registerAdapter(DrivingSessionAdapter(), override: true);
      await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
      await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).put('A', DrivingSession(id: 'A', startTime: DateTime(2026, 11, 11, 7), endTime: DateTime(2026, 11, 11, 9)));
      kept = await File('${dir.path}/dashcam_clips/kept.mp4').create(recursive: true);
      doomed = await File('${dir.path}/dashcam_clips/doomed.mp4').create(recursive: true);
      await Hive.box(HiveBoxNames.dashcamSessionVideos).put('A', [
        DashcamClipRecord(filePath: kept.path, recordedAt: DateTime(2026, 11, 11, 8, 0, 0), durationSeconds: 75, sizeBytes: 3 * 1024 * 1024),
        DashcamClipRecord(filePath: doomed.path, recordedAt: DateTime(2026, 11, 11, 8, 10, 0), durationSeconds: 75, sizeBytes: 3 * 1024 * 1024),
      ]);
    });
    await tester.pumpWidget(const MaterialApp(home: DashcamRecordingsScreen()));
    expect(find.byTooltip('Excluir vídeo'), findsNWidgets(2));

    // The newest clip (08:10:00) is listed first. Its button's callback runs in
    // the real zone, so the deletion's Hive and file I/O can progress.
    final button = tester.widgetList<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline)).first;
    await tester.runAsync(() async {
      button.onPressed!(); // a block: an arrow would wait for the dialog's answer
    });
    await tester.pumpAndSettle();
    expect(find.text('Excluir este vídeo?'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(doomed.existsSync(), isTrue, reason: 'cancelled: nothing deleted');

    await tester.runAsync(() async {
      button.onPressed!(); // a block: an arrow would wait for the dialog's answer
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluir'));
    for (var i = 0; i < 400 && find.text('Vídeo excluído.').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.text('Vídeo excluído.'), findsOneWidget);
    expect(doomed.existsSync(), isFalse);
    expect(kept.existsSync(), isTrue);
    expect(find.text('08:10:00'), findsNothing);
    expect(find.text('08:00:00'), findsOneWidget);
  });

  group('with a gallery (owner decisions, 2026-11-14)', () {
    late _FakeGallery gallery;
    late List<File> files;

    Future<void> seed(WidgetTester tester, int count) async {
      await tester.runAsync(() async {
        Hive.registerAdapter(DrivingSessionAdapter(), override: true);
        await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
        await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).put('A', DrivingSession(id: 'A', startTime: DateTime(2026, 11, 11, 7), endTime: DateTime(2026, 11, 11, 9)));
        files = [for (var i = 0; i < count; i++) await File('${dir.path}/dashcam_clips/c$i.mp4').create(recursive: true)];
        await Hive.box(HiveBoxNames.dashcamSessionVideos).put('A', [
          for (var i = 0; i < count; i++)
            DashcamClipRecord(filePath: files[i].path, recordedAt: DateTime(2026, 11, 11, 8, i, 0), durationSeconds: 60, sizeBytes: 1024 * 1024),
        ]);
      });
      gallery = _FakeGallery();
      await tester.pumpWidget(MaterialApp(home: DashcamRecordingsScreen(galleryExporter: gallery)));
    }

    Future<void> runInRealZone(WidgetTester tester, VoidCallback action) async {
      await tester.runAsync(() async {
        action(); // a block: an arrow would wait for the dialog's answer
      });
      await tester.pumpAndSettle();
    }

    Future<void> waitFor(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      expect(finder, findsOneWidget);
    }

    VoidCallback deleteButtonOf(WidgetTester tester, String time) => tester
        .widget<IconButton>(find.descendant(of: find.widgetWithText(ListTile, time), matching: find.widgetWithIcon(IconButton, Icons.delete_outline)))
        .onPressed!;

    testWidgets('deleting one video asks whether its gallery copy goes too', (tester) async {
      await seed(tester, 2);
      await runInRealZone(tester, deleteButtonOf(tester, '08:01:00'));
      expect(find.text('Excluir este vídeo?'), findsOneWidget);
      expect(find.textContaining('Apagar também a cópia na galeria'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recordingsDelete_confirm')));
      await waitFor(tester, find.textContaining('Galeria: 1 cópia apagada.'));
      expect(gallery.deleted, ['SynapseAuto_20261111_080100.mp4']);
      expect(files[1].existsSync(), isFalse);
      expect(files[0].existsSync(), isTrue);
    });

    testWidgets('"Só do app" leaves the gallery alone', (tester) async {
      await seed(tester, 1);
      await runInRealZone(tester, deleteButtonOf(tester, '08:00:00'));
      await tester.tap(find.byKey(const ValueKey('recordingsDelete_appOnly')));
      await waitFor(tester, find.text('Vídeo excluído.'));
      expect(gallery.deleted, isEmpty);
      expect(files[0].existsSync(), isFalse);
    });

    testWidgets('several at once: long press, select all, delete the selection', (tester) async {
      await seed(tester, 3);
      await tester.longPress(find.text('08:02:00'));
      await tester.pump();
      expect(find.text('1 selecionado'), findsOneWidget);
      await tester.tap(find.text('08:00:00'));
      await tester.pump();
      expect(find.text('2 selecionados'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recordings_selectAll')));
      await tester.pump();
      expect(find.text('3 selecionados'), findsOneWidget);
      await tester.tap(find.text('08:01:00'));
      await tester.pump();
      expect(find.text('2 selecionados'), findsOneWidget, reason: 'a tap unselects');

      await runInRealZone(tester, tester.widget<IconButton>(find.byKey(const ValueKey('recordings_deleteSelected'))).onPressed!);
      expect(find.text('Excluir 2 vídeos?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recordingsDelete_confirm')));
      await waitFor(tester, find.textContaining('2 vídeos excluídos.'));
      expect([for (final f in files) f.existsSync()], [false, true, false]);
      expect(gallery.deleted, hasLength(2));
      expect(find.text('Gravações'), findsOneWidget, reason: 'the selection ends');
    });

    testWidgets('"Excluir todos" in the menu', (tester) async {
      await seed(tester, 3);
      // The menu offers it…
      await tester.tap(find.byKey(const ValueKey('recordings_menu')));
      await tester.pumpAndSettle();
      expect(find.text('Excluir todos'), findsOneWidget);
      await tester.tapAt(Offset.zero); // close the menu
      await tester.pumpAndSettle();
      // …and its choice runs in the real zone, where the deletion's I/O progresses.
      final menu = tester.widget<PopupMenuButton<String>>(find.byKey(const ValueKey('recordings_menu')));
      await runInRealZone(tester, () => menu.onSelected!('deleteAll'));
      expect(find.text('Excluir 3 vídeos?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recordingsDelete_appOnly')));
      await waitFor(tester, find.textContaining('3 vídeos excluídos.'));
      expect(files.every((f) => !f.existsSync()), isTrue);
      expect(find.textContaining('Nenhuma gravação ainda.'), findsOneWidget);
    });
  });
}

class _FakeGallery implements DashcamGalleryExporter {
  final deleted = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> saveVideo({required String path, required String displayName, required DateTime recordedAt}) async {}

  @override
  Future<GalleryDeletion> deleteVideos(List<String> displayNames) async {
    deleted.addAll(displayNames);
    return (deleted: displayNames.length, notFound: 0, denied: 0);
  }
}
