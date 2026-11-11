import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/screens/sessions/session_history_screen.dart';
import 'package:synapse_auto/services/altitude_trend.dart';
import 'package:synapse_auto/services/driving_session_recorder.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/unit_preferences.dart';

// Widget-level coverage for SessionHistoryScreen (ValueListenableBuilder
// over a live Hive Box.listenable()) is validated on the physical device
// instead of here — the pure filtering/sorting logic below is unit-tested
// directly (which is the actual risk worth guarding), matching this
// codebase's established convention for other Hive/hardware-backed screens
// (SensorService, DashboardSensorStreams) that likewise have no dedicated
// widget-pump test.
//
// Exception, Fase 16.2-R4.3-R2.6.6: the deletion flow (D1 — a session whose
// finalization was pending could be deleted from this screen) is covered with
// the real screen, the real recorder and real Hive — see [_drive] for the
// harness technique that keeps Hive's close from hanging after a deletion the
// widget itself started.
void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('visibleSessionsSortedByRecency', () {
    test('excludes an active (not-yet-finished) session', () {
      final active = DrivingSession(id: 'a', startTime: t0);
      final finished = DrivingSession(id: 'b', startTime: t0, endTime: t0.add(const Duration(minutes: 5)));
      expect(visibleSessionsSortedByRecency([active, finished]), [finished]);
    });

    test('sorts most-recent start time first', () {
      final older = DrivingSession(id: 'a', startTime: t0, endTime: t0.add(const Duration(minutes: 1)));
      final newer = DrivingSession(
        id: 'b',
        startTime: t0.add(const Duration(days: 1)),
        endTime: t0.add(const Duration(days: 1, minutes: 1)),
      );
      expect(visibleSessionsSortedByRecency([older, newer]), [newer, older]);
    });

    test('an empty input yields an empty list', () {
      expect(visibleSessionsSortedByRecency([]), isEmpty);
    });

    test('multiple finished sessions all sort correctly, active ones filtered throughout', () {
      final s1 = DrivingSession(id: '1', startTime: t0, endTime: t0.add(const Duration(minutes: 1)));
      final s2 = DrivingSession(
        id: '2',
        startTime: t0.add(const Duration(hours: 2)),
        endTime: t0.add(const Duration(hours: 2, minutes: 1)),
      );
      final activeMidway = DrivingSession(id: '3', startTime: t0.add(const Duration(hours: 1)));
      final s4 = DrivingSession(
        id: '4',
        startTime: t0.add(const Duration(hours: 3)),
        endTime: t0.add(const Duration(hours: 3, minutes: 1)),
      );
      expect(visibleSessionsSortedByRecency([s1, s2, activeMidway, s4]), [s4, s2, s1]);
    });
  });

  // Fase 16.2-R4.3-R2.6.6 (D1 of the R2.6.5 pre-audit, reproduced before the fix
  // through this very screen: scratchpad/fase16_2_r4_3_r2_6_6/01_prefix_repro).
  // The recorder-level contract lives in driving_session_recorder_test.dart
  // (X80–X88), the controller-level STOP/retry in
  // dashcam_session_controller_test.dart (X92).
  group('Fase 16.2-R4.3-R2.6.6 — deletion from the real history', () {
    const refusal = 'Esta sessão ainda está sendo finalizada e não pode ser excluída agora.';

    // Scoped to the list: a SnackBar is itself wrapped in a Dismissible.
    final tileFinder = find.descendant(of: find.byType(ListView), matching: find.byType(Dismissible));
    Dismissible tile(WidgetTester tester) => tester.widget<Dismissible>(tileFinder);

    /// A session with 10 checkpointed samples and 3 pending, whose final
    /// sample write failed: finalizationFailed. It also has a dashcam index
    /// entry and a telemetry file, so the deletion's last steps are observable.
    Future<DrivingSession> failedSession(WidgetTester tester, _Env env) async {
      final a = (await tester.runAsync(() async {
        final a = env.recorder.startSession();
        await env.feed(13);
        await env.waitUntil(() => env.recorder.pendingSampleCountForTest == 3, 'the incremental checkpoint landed');
        await Hive.box(HiveBoxNames.dashcamSessionVideos).put(a.id, <dynamic>[]);
        await env.telemetryFile(a.id).create(recursive: true);
        env.failing.armed = true;
        try {
          await env.recorder.stopSession();
        } catch (_) {}
        env.failing.armed = false;
        return a;
      }))!;
      expect(env.recorder.state, DrivingSessionRecorderState.finalizationFailed, reason: 'setup');
      return a;
    }

    testWidgets(
      'X89 (D1, the real history flow) — a session whose finalization failed is listed but its deletion is unavailable '
      'and says why; a swipe opens nothing and removes nothing. Pre-fix it was offered, and deleting it made every retry '
      'fail and START stay refused until the app restarted. After the retry succeeds, the same tile becomes deletable and '
      'swipe + "Excluir" removes the record, the samples and the dashcam data',
      (tester) async {
        await _withEnv(tester, (env) async {
          final a = await failedSession(tester, env);
          await tester.pumpWidget(_app());
          await tester.pump();
          expect(tileFinder, findsOneWidget, reason: 'the pending session is listed (its cached instance has an endTime)');
          expect(tile(tester).direction, DismissDirection.none, reason: 'pre-fix: endToStart — offered for deletion');
          expect(find.textContaining('Finalização pendente — exclusão indisponível'), findsOneWidget, reason: 'and says why');

          await tester.drag(tileFinder, const Offset(-600, 0));
          await tester.pumpAndSettle();
          expect(find.text('Excluir'), findsNothing, reason: 'no confirmation: the swipe is disabled');
          expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(a.id), same(a), reason: 'nothing removed');
          expect(await _drive(tester, () => _storedCount(a.id)), 10);

          // The retry — what SessionRecordingScreen's "Tentar finalizar novamente" does.
          await _drive(tester, () => env.recorder.stopSession());
          await tester.pump();
          expect(env.recorder.state, DrivingSessionRecorderState.idle);
          expect(await _drive(tester, () => _storedCount(a.id)), 13, reason: 'the same session, every sample once');
          expect(tile(tester).direction, DismissDirection.endToStart, reason: 'deletable once durably closed');
          expect(find.textContaining('exclusão indisponível'), findsNothing);

          await tester.drag(tileFinder, const Offset(-600, 0));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await _pumpUntil(tester, () => !env.telemetryFile(a.id).existsSync() && tileFinder.evaluate().isEmpty, 'the deletion ran to its last step');
          expect(tester.takeException(), isNull);
          expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).containsKey(a.id), isFalse);
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(a.id), isFalse);
          expect(await _drive(tester, () => _storedCount(a.id)), isNull);
          expect(find.text('Nenhuma sessão registrada ainda.'), findsOneWidget);
        });
      },
    );

    testWidgets(
      'X90 (D1, the persistence layer is the authority) — the tile\'s own delete action, invoked directly whatever the '
      'swipe shows (standing for any action rendered before the refusal became true; the visual guard is X89\'s '
      'subject), is refused by deleteDrivingSession: the refusal is shown, the action reports "not dismissed", nothing '
      'is removed and the retry still works. Any OTHER failure of the deletion is not turned into that refusal: it '
      'reaches the caller',
      (tester) async {
        await _withEnv(tester, (env) async {
          final a = await failedSession(tester, env);
          await tester.pumpWidget(_app());
          await tester.pump();

          bool? dismissed;
          Object? failure;
          tile(tester).confirmDismiss!(DismissDirection.endToStart).then<void>((v) => dismissed = v, onError: (Object e) => failure = e);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pump();
          await tester.pump();
          expect(failure, isNull);
          expect(dismissed, isFalse, reason: 'refused: the tile stays (pre-fix: deleted)');
          expect(find.text(refusal), findsOneWidget, reason: 'the refusal is shown');
          expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get(a.id), same(a), reason: 'nothing removed');
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey(a.id), isTrue);
          expect(env.telemetryFile(a.id).existsSync(), isTrue);
          expect(await _drive(tester, () => _storedCount(a.id)), 10);

          await _drive(tester, () => env.recorder.stopSession());
          expect(env.recorder.state, DrivingSessionRecorderState.idle, reason: 'the retry still works');
          expect(await _drive(tester, () => _storedCount(a.id)), 13);
          // The snackbar goes away: its show animation, its 4 s, its hide animation.
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          expect(find.text(refusal), findsNothing, reason: 'setup');

          // Deletable now, but the samples box is unavailable: a real failure.
          await _drive(tester, () => Hive.lazyBox(HiveBoxNames.drivingSessionSamples).close());
          dismissed = null;
          tile(tester).confirmDismiss!(DismissDirection.endToStart).then<void>((v) => dismissed = v, onError: (Object e) => failure = e);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pump();
          await tester.pump();
          expect(dismissed, isNull);
          expect(failure, isA<HiveError>(), reason: 'propagated as it was, not handled as the expected refusal');
          expect(find.text(refusal), findsNothing);
          expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).containsKey(a.id), isTrue, reason: 'it failed before removing anything');
          await _drive(tester, () => Hive.openLazyBox(HiveBoxNames.drivingSessionSamples));
        });
      },
    );

    testWidgets(
      'X91 (D1, the list stays current) — transitions that write nothing to the sessions box still update the history: a '
      'STOP held before any write makes the ended session appear, as "Finalizando" and not deletable; its failed samples '
      'checkpoint turns it into "Finalização pendente"',
      (tester) async {
        await _withEnv(tester, (env) async {
          await tester.runAsync(() async {
            env.recorder.startSession();
            await env.feed(3);
            // The per-sample record writes have landed (and been announced).
            await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pumpWidget(_app());
          await tester.pump();
          expect(tileFinder, findsNothing, reason: 'setup: a session being recorded is not listed');

          late Future<Object?> stop;
          await tester.runAsync(() async {
            env.cancelGate = Completer<void>();
            stop = _errorOf(env.recorder.stopSession());
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          expect(env.recorder.state, DrivingSessionRecorderState.finalizing, reason: 'setup: held inside the finalization, nothing written');
          await tester.pump();
          expect(tileFinder, findsOneWidget, reason: 'the STOP wrote nothing; only the control notification rebuilds the list');
          expect(tile(tester).direction, DismissDirection.none);
          expect(find.textContaining('Finalizando — exclusão indisponível'), findsOneWidget);

          await tester.runAsync(() async {
            env.failing.armed = true;
            env.cancelGate!.complete();
            expect(await stop, isNotNull, reason: 'setup: the samples checkpoint failed');
            env.failing.armed = false;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          expect(env.recorder.state, DrivingSessionRecorderState.finalizationFailed);
          await tester.pump();
          expect(find.textContaining('Finalização pendente — exclusão indisponível'), findsOneWidget, reason: 'nothing was written to the sessions box');

          await _drive(tester, () => env.recorder.stopSession());
          await tester.pump();
          expect(tile(tester).direction, DismissDirection.endToStart);
        });
      },
    );
  });

  // Fase 16.2-R4.3-R2.6.7 — a deletion that did not finish, in the real history.
  // The protocol itself is covered in session_deletion_protocol_test.dart
  // (X100–X107).
  group('Fase 16.2-R4.3-R2.6.7 — interrupted deletion in the real history', () {
    testWidgets(
      'X109 — sessions whose deletion did not finish (their records still carry the deletion marker: the durable state '
      'a run killed, or failing, after that marker leaves) are listed as pending and stay deletable; swipe + "Excluir" '
      'finishes one; the recovery main() runs at the next start finishes the other; the finished session next to them '
      'is untouched',
      (tester) async {
        await _withEnv(tester, (env) async {
          final start = DateTime(2026, 2, 1, 9);
          DrivingSession session(String id, int hour, {bool marked = false}) => DrivingSession(
                id: id,
                startTime: start.add(Duration(hours: hour)),
                endTime: start.add(Duration(hours: hour, minutes: 30)),
                deletionPending: marked,
              );
          await tester.runAsync(() async {
            await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).putAll({
              'kept': session('kept', 0),
              'pending-1': session('pending-1', 1, marked: true),
              'pending-2': session('pending-2', 2, marked: true),
            });
            for (final id in ['kept', 'pending-1', 'pending-2']) {
              await Hive.lazyBox(HiveBoxNames.drivingSessionSamples).put(id, [DrivingSessionSample(timestamp: start)]);
              await Hive.box(HiveBoxNames.dashcamSessionVideos).put(id, <dynamic>[]);
              await env.telemetryFile(id).create(recursive: true);
            }
          });
          await tester.pumpWidget(_app());
          await tester.pump();
          final tiles = find.descendant(of: find.byType(ListView), matching: find.byType(Dismissible));
          final pendingTiles = find.ancestor(of: find.textContaining('Exclusão pendente — deslize para concluir'), matching: find.byType(Dismissible));
          expect(tiles, findsNWidgets(3));
          expect(pendingTiles, findsNWidgets(2), reason: 'listed, and said to be pending');
          for (final pending in tester.widgetList<Dismissible>(pendingTiles)) {
            expect(pending.direction, DismissDirection.endToStart, reason: 'the swipe runs the deletion again');
          }

          // The most recent one (pending-2) is listed first.
          await tester.drag(pendingTiles.first, const Offset(-600, 0));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await _pumpUntil(tester, () => !Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).containsKey('pending-2'), 'the swiped deletion finished');
          expect(tester.takeException(), isNull);
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey('pending-2'), isFalse);
          expect(env.telemetryFile('pending-2').existsSync(), isFalse);
          expect(await _drive(tester, () => _storedCount('pending-2')), isNull);

          await _drive(tester, completePendingSessionDeletions);
          await tester.pump();
          expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).containsKey('pending-1'), isFalse);
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey('pending-1'), isFalse);
          expect(env.telemetryFile('pending-1').existsSync(), isFalse);
          expect(await _drive(tester, () => _storedCount('pending-1')), isNull);
          expect(find.textContaining('Exclusão pendente'), findsNothing);
          expect(tiles, findsOneWidget);

          expect(Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).get('kept')?.deletionPending, isFalse);
          expect(Hive.box(HiveBoxNames.dashcamSessionVideos).containsKey('kept'), isTrue);
          expect(env.telemetryFile('kept').existsSync(), isTrue);
          expect(await _drive(tester, () => _storedCount('kept')), 1);
        });
      },
    );
  });

  // Fase 16.2-R4.3-R2.6.11 — what the History says about a session's dashcam
  // telemetry, from the outcome stored on that session. How the outcome gets
  // there is covered in session_telemetry_outcome_test.dart (X160–X169, X180)
  // and dashcam_telemetry_outcome_session_test.dart (X170–X177, X181); the
  // whole flow through the real app in session_host/x178.
  group('Fase 16.2-R4.3-R2.6.11 — telemetry outcome in the real history', () {
    DrivingSession session(String id, int hour, {bool marked = false}) => DrivingSession(
          id: id,
          startTime: t0.add(Duration(hours: hour)),
          endTime: t0.add(Duration(hours: hour, minutes: 30)),
          deletionPending: marked,
        );

    test('X179-text — the summary is built from the stored outcome and counts only: nothing for an unknown outcome, the '
        'written count for a success, and for a failure what was lost — or that nothing was ever written, or that only '
        'closing the file failed', () {
      String? summary(DashcamTelemetryOutcome outcome, int accepted, int persisted, int refused) =>
          dashcamTelemetryOutcomeSummary(session('s', 0)..applyDashcamTelemetryOutcome(outcome, accepted: accepted, persisted: persisted, refused: refused));

      expect(dashcamTelemetryOutcomeSummary(session('legacy', 0)), isNull, reason: 'no outcome recorded: nothing to say');
      expect(summary(DashcamTelemetryOutcome.success, 19, 19, 0), 'completa: 19 amostras gravadas');
      expect(summary(DashcamTelemetryOutcome.failed, 19, 0, 0), 'incompleta: 0 de 19 amostras gravadas');
      expect(summary(DashcamTelemetryOutcome.failed, 50, 25, 3), 'incompleta: 25 de 50 amostras gravadas, 3 recusadas após a falha');
      expect(summary(DashcamTelemetryOutcome.failed, 25, 25, 4), 'incompleta: 25 de 25 amostras gravadas, 4 recusadas após a falha',
          reason: 'samples refused after the failure are a loss too');
      expect(summary(DashcamTelemetryOutcome.failed, 0, 0, 0), 'não gravada');
      expect(summary(DashcamTelemetryOutcome.failed, 28, 28, 0), 'com erro ao finalizar o arquivo: 28 de 28 amostras gravadas',
          reason: 'not "incompleta: 28 de 28"');
      for (final text in [summary(DashcamTelemetryOutcome.failed, 19, 0, 0)!, summary(DashcamTelemetryOutcome.failed, 0, 0, 0)!]) {
        expect(text, isNot(anyOf(contains('Exception'), contains('errno'), contains('OS Error'))), reason: 'no operating-system detail');
      }
    });

    testWidgets(
      'X179 — a session whose telemetry FAILED says so on its own tile, with what was written and lost; a complete one, '
      'and one with no recorded outcome (every session stored before R2.6.11), are listed exactly as before — never as a '
      'failure; a pending deletion keeps its own note next to it; no action is offered; and a result recorded while the '
      'list is open appears on that session\'s tile',
      (tester) async {
        // Tall enough for the lazily built list to build all seven tiles.
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await _withEnv(tester, (env) async {
          await tester.runAsync(() async {
            await Hive.box<DrivingSession>(HiveBoxNames.drivingSessions).putAll({
              'legacy': session('legacy', 0),
              'late': session('late', 1),
              'success': session('success', 2)..applyDashcamTelemetryOutcome(DashcamTelemetryOutcome.success, accepted: 19, persisted: 19, refused: 0),
              'total': session('total', 3)..applyDashcamTelemetryOutcome(DashcamTelemetryOutcome.failed, accepted: 19, persisted: 0, refused: 0),
              'partial': session('partial', 4)..applyDashcamTelemetryOutcome(DashcamTelemetryOutcome.failed, accepted: 50, persisted: 25, refused: 3),
              'unopened': session('unopened', 5)..applyDashcamTelemetryOutcome(DashcamTelemetryOutcome.failed, accepted: 0, persisted: 0, refused: 0),
              'marked': session('marked', 6, marked: true)..applyDashcamTelemetryOutcome(DashcamTelemetryOutcome.failed, accepted: 7, persisted: 2, refused: 0),
            });
          });
          await tester.pumpWidget(_app());
          await tester.pump();

          String subtitle(String id) =>
              (tester.widget<ListTile>(find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(ListTile))).subtitle! as Text).data!;
          const plain = '30min · 0.0 km';

          expect(subtitle('legacy'), plain, reason: 'no outcome recorded: listed as before — not as a failure');
          expect(subtitle('late'), plain);
          expect(subtitle('success'), plain, reason: 'a complete telemetry adds no note to the list');
          expect(subtitle('total'), '$plain\nTelemetria da dashcam incompleta: 0 de 19 amostras gravadas');
          expect(subtitle('partial'), '$plain\nTelemetria da dashcam incompleta: 25 de 50 amostras gravadas, 3 recusadas após a falha');
          expect(subtitle('unopened'), '$plain\nTelemetria da dashcam não gravada');
          expect(subtitle('marked'), '$plain\nExclusão pendente — deslize para concluir\nTelemetria da dashcam incompleta: 2 de 7 amostras gravadas',
              reason: 'the pending deletion keeps its own note');
          expect(find.textContaining('Tentar novamente'), findsNothing, reason: 'no retry: nothing can bring a telemetry file back');
          expect(find.byType(TextButton), findsNothing, reason: 'no action of any kind on the tiles');

          // A result recorded while the list is open — as a session's late
          // telemetry failure is — appears on that session, and only there.
          expect(
            await _drive(tester, () => persistSessionTelemetryOutcome('late', outcome: DashcamTelemetryOutcome.failed, accepted: 27, persisted: 0, refused: 0)),
            SessionTelemetryOutcomeWrite.recorded,
          );
          await tester.pump();
          expect(subtitle('late'), '$plain\nTelemetria da dashcam incompleta: 0 de 27 amostras gravadas');
          expect(subtitle('legacy'), plain);
          expect(subtitle('success'), plain);
        });
      },
    );
  });

  group('visible delete actions (2026-11-11)', () {
    final box = Hive.box<DrivingSession>;

    Future<String> finishedSession(WidgetTester tester, _Env env) async => (await tester.runAsync(() async {
      final s = env.recorder.startSession();
      await env.feed(2);
      await env.recorder.stopSession();
      return s.id;
    }))!;

    testWidgets('each finished session has a delete button: confirmed, it deletes the session like the swipe does', (tester) async {
      await _withEnv(tester, (env) async {
        final a = await finishedSession(tester, env);
        await tester.pumpWidget(_app());
        await tester.pump();

        await tester.tap(find.byTooltip('Excluir sessão'));
        await tester.pumpAndSettle();
        expect(find.textContaining('vídeos gravados no app, será apagada permanentemente'), findsOneWidget);
        await tester.tap(find.text('Excluir'));
        await _pumpUntil(tester, () => !box(HiveBoxNames.drivingSessions).containsKey(a), 'the session deleted');
        await tester.pump();
        expect(find.text('Nenhuma sessão registrada ainda.'), findsOneWidget);
      });
    });

    testWidgets('"Limpar histórico" deletes every finished session and never the one still recording', (tester) async {
      await _withEnv(tester, (env) async {
        final a = await finishedSession(tester, env);
        final b = await finishedSession(tester, env);
        final live = (await tester.runAsync(() async {
          final s = env.recorder.startSession();
          await env.feed(2);
          return s.id;
        }))!;
        await tester.pumpWidget(_app());
        await tester.pump();

        await tester.tap(find.byTooltip('Limpar histórico'));
        await tester.pumpAndSettle();
        expect(find.textContaining('As 2 sessões finalizadas serão apagadas'), findsOneWidget);
        await tester.tap(find.text('Excluir tudo'));
        await _pumpUntil(tester, () => find.text('Histórico limpo.').evaluate().isNotEmpty, 'the result shown');

        expect(box(HiveBoxNames.drivingSessions).containsKey(a), isFalse);
        expect(box(HiveBoxNames.drivingSessions).containsKey(b), isFalse);
        expect(box(HiveBoxNames.drivingSessions).containsKey(live), isTrue, reason: 'the recording session is untouched');
        expect(env.recorder.state, DrivingSessionRecorderState.recording);
        expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the progress dialog closed');
      });
    });

    testWidgets('"Limpar histórico" with nothing finished says so and asks nothing', (tester) async {
      await _withEnv(tester, (env) async {
        await tester.pumpWidget(_app());
        await tester.pump();
        await tester.tap(find.byTooltip('Limpar histórico'));
        await tester.pump();
        expect(find.text('Limpar histórico?'), findsNothing);
        expect(find.text('Não há sessões finalizadas para excluir.'), findsOneWidget);
      });
    });
  });
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

Widget _app() => MaterialApp(home: UnitPreferencesScope(preferences: UnitPreferences(), child: const SessionHistoryScreen()));

/// Harness (Fase 16.2-R4.3-R2.6.6): a Hive operation the WIDGET started (a
/// deletion from confirmDismiss runs in the test's FakeAsync zone) leaves the
/// box's internal ReadWriteSync tail as a future owned by that zone; any later
/// `.then` on it — a close, a write, even one issued from runAsync — is
/// scheduled on the FakeAsync microtask queue and runs only on pump(). Found
/// while reproducing D1: a plain `runAsync(() => box.close())` hung forever
/// (scratchpad/fase16_2_r4_3_r2_6_6/01_prefix_repro/harness_bisect). So Hive
/// work in these tests is started inside runAsync and driven by alternating
/// pump() and a short real delay until it settles.
Future<T> _drive<T>(WidgetTester tester, Future<T> Function() op) async {
  var done = false;
  T? value;
  Object? error;
  await tester.runAsync(() async {
    op().then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
  });
  for (var i = 0; i < 2000 && !done; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  if (!done) fail('_drive: the operation never settled');
  if (error != null) throw error!;
  return value as T;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition, String label) async {
  for (var i = 0; i < 2000; i++) {
    if (condition()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  fail('_pumpUntil: "$label" never became true');
}

Future<Object?> _errorOf(Future<void> f) async {
  try {
    await f.timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  }
}

Future<int?> _storedCount(String id) async => ((await Hive.lazyBox(HiveBoxNames.drivingSessionSamples).get(id)) as List?)?.length;

/// Everything is created inside runAsync and torn down through [_drive], after
/// the screen is unmounted, whatever the test's outcome.
Future<void> _withEnv(WidgetTester tester, Future<void> Function(_Env env) body) async {
  final env = (await tester.runAsync(_Env.open))!;
  try {
    await body(env);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await _drive(tester, env.close);
  }
}

/// Real Hive in a temporary directory (adapter-registration guard, only the
/// boxes this screen and the deletion need), path_provider mocked to it, and a
/// real recorder over a snapshot source whose subscription cancel() waits for
/// [cancelGate] when one is set — that holds a stopSession() inside its
/// finalization before anything is written.
class _Env {
  _Env._(this.dir, this.snapshots, this.recorder, this.failing);

  final Directory dir;
  final StreamController<TelemetrySnapshot> snapshots;
  final DrivingSessionRecorder recorder;
  final _WriteFailingSampleAdapter failing;
  Completer<void>? cancelGate;
  var _clock = DateTime(2026, 1, 1, 12);

  static Future<_Env> open() async {
    final dir = Directory.systemTemp.createTempSync('session_history_screen_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, (call) async => dir.path);
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) {
      Hive.registerAdapter(DrivingSessionAdapter());
      Hive.registerAdapter(DrivingSessionSampleAdapter());
      Hive.registerAdapter(DrivingSessionEventTypeAdapter());
      Hive.registerAdapter(EventSeverityAdapter());
      Hive.registerAdapter(DrivingSessionEventAdapter());
    }
    final failing = _WriteFailingSampleAdapter();
    Hive.registerAdapter<DrivingSessionSample>(failing, override: true);
    Hive.init(dir.path);
    await Hive.openBox<DrivingSession>(HiveBoxNames.drivingSessions);
    await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    await Hive.openBox(HiveBoxNames.dashcamSessionVideos);
    await Hive.openBox(HiveBoxNames.appSettings);
    final snapshots = StreamController<TelemetrySnapshot>.broadcast();
    late final _Env env;
    final source = Stream<TelemetrySnapshot>.multi((c) {
      final sub = snapshots.stream.listen(c.add);
      c.onCancel = () async {
        await sub.cancel();
        final gate = env.cancelGate;
        if (gate != null) await gate.future;
      };
    });
    env = _Env._(dir, snapshots, DrivingSessionRecorder(source), failing);
    return env;
  }

  File telemetryFile(String id) => File('${dir.path}/dashcam_telemetry/$id.jsonl');

  Future<void> feed(int n) async {
    for (var i = 0; i < n; i++) {
      _clock = _clock.add(const Duration(seconds: 2));
      snapshots.add(TelemetrySnapshot(timestamp: _clock, speedKmh: 40.0 + i, gnssQuality: GnssQuality.good, altitudeTrend: AltitudeTrend.stable));
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> waitUntil(bool Function() condition, String label) async {
    for (var i = 0; i < 500; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('waitUntil: "$label" never became true');
  }

  Future<void> close() async {
    final gate = cancelGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    failing.armed = false;
    if (!Hive.isBoxOpen(HiveBoxNames.drivingSessionSamples)) await Hive.openLazyBox(HiveBoxNames.drivingSessionSamples);
    for (var i = 0; i < 3 && recorder.hasPendingFinalization; i++) {
      await _errorOf(recorder.stopSession());
    }
    recorder.dispose();
    Hive.registerAdapter<DrivingSessionSample>(DrivingSessionSampleAdapter(), override: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_pathProviderChannel, null);
    await snapshots.close();
    await Hive.close();
    dir.deleteSync(recursive: true);
  }
}

/// A sample adapter that, while [armed], fails while serializing — a put that
/// fails before its write takes effect (same technique as the recorder tests).
class _WriteFailingSampleAdapter extends DrivingSessionSampleAdapter {
  // TypeAdapter is @immutable: the switch is a final reference to mutable state.
  final _Armed _armed = _Armed();

  bool get armed => _armed.value;
  set armed(bool value) => _armed.value = value;

  @override
  void write(BinaryWriter writer, DrivingSessionSample obj) {
    if (armed) throw StateError('injected failure while serializing a sample');
    super.write(writer, obj);
  }
}

class _Armed {
  bool value = false;
}
