import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/dashboard/sensor_fullscreen_screen.dart';

/// A single tap on the instrument. The screen also recognizes a double-tap
/// (back to the dashboard), so a single tap only counts once the double-tap
/// window has passed with no second tap — the same wait a real finger gets.
Future<void> tapContent(WidgetTester tester) async {
  await tester.tap(find.text('conteúdo do sensor'));
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
}

void main() {
  Future<void> pumpFullscreen(
    WidgetTester tester, {
    VoidCallback? onDelete,
    VoidCallback? onChangeStyle,
    VoidCallback? onResetRecords,
    Future<bool> Function(BuildContext context)? confirmExit,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (settings) => MaterialPageRoute(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SensorFullscreenScreen(
                        label: 'Aceleração G',
                        icon: Icons.bolt,
                        content: const Text('conteúdo do sensor'),
                        onDelete: onDelete ?? () {},
                        onChangeStyle: onChangeStyle,
                        onResetRecords: onResetRecords,
                        confirmExit: confirmExit,
                      ),
                    ),
                  ),
                  child: const Text('abrir tela cheia'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir tela cheia'));
    await tester.pumpAndSettle();
  }

  testWidgets('controls start hidden — only the instrument content is visible', (tester) async {
    await pumpFullscreen(tester);

    expect(find.text('conteúdo do sensor'), findsOneWidget);
    final topBarOpacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(topBarOpacity.opacity, 0);
  });

  testWidgets('a tap reveals the controls (label becomes visible)', (tester) async {
    await pumpFullscreen(tester);

    await tapContent(tester);
    await tester.pumpAndSettle();

    final topBarOpacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(topBarOpacity.opacity, 1);
    expect(find.text('Aceleração G'), findsOneWidget);
  });

  testWidgets('controls auto-hide after the timeout with no further interaction', (tester) async {
    await pumpFullscreen(tester);

    await tapContent(tester);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);

    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);
  });

  testWidgets('a tap while controls are visible hides them immediately, not waiting for the timeout', (
    tester,
  ) async {
    await pumpFullscreen(tester);

    await tapContent(tester);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);

    await tapContent(tester);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);
  });

  testWidgets('tapping again after the auto-hide restarts a fresh cycle (no stray timer left running)', (
    tester,
  ) async {
    await pumpFullscreen(tester);

    await tapContent(tester);
    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);

    await tapContent(tester);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);

    // No leftover timer from the first cycle firing early/late.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);
  });

  testWidgets('the options button opens the reused context menu, showing "Sair da tela cheia" (fullscreen-aware)', (
    tester,
  ) async {
    await pumpFullscreen(tester);
    await tapContent(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Sair da tela cheia'), findsOneWidget);
    expect(find.text('Colocar em tela cheia'), findsNothing);
  });

  testWidgets('selecting "Sair da tela cheia" pops back to the Dashboard', (tester) async {
    await pumpFullscreen(tester);
    await tapContent(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sair da tela cheia'));
    await tester.pumpAndSettle();

    expect(find.text('abrir tela cheia'), findsOneWidget); // back on the underlying screen.
    expect(find.text('conteúdo do sensor'), findsNothing);
  });

  testWidgets('the back button in the top bar also pops back to the Dashboard', (tester) async {
    await pumpFullscreen(tester);
    await tapContent(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text('abrir tela cheia'), findsOneWidget);
  });

  testWidgets('deleting from the fullscreen menu runs onDelete and pops back to the Dashboard', (tester) async {
    var deleted = false;
    await pumpFullscreen(tester, onDelete: () => deleted = true);
    await tapContent(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Excluir'));
    await tester.pumpAndSettle();

    expect(deleted, isTrue);
    expect(find.text('abrir tela cheia'), findsOneWidget);
  });

  testWidgets('resetting/calibrating from the fullscreen menu runs the callback WITHOUT leaving the screen', (
    tester,
  ) async {
    var reset = false;
    await pumpFullscreen(tester, onResetRecords: () => reset = true);
    await tapContent(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resetar registros'));
    await tester.pumpAndSettle();

    expect(reset, isTrue);
    expect(find.text('conteúdo do sensor'), findsOneWidget); // still in fullscreen — no navigation needed.
  });

  testWidgets('enters immersive system UI mode on open and restores edge-to-edge on close', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpFullscreen(tester);

    final enterCall = calls.singleWhere((c) => c.method == 'SystemChrome.setEnabledSystemUIMode');
    expect(enterCall.arguments, contains('SystemUiMode.immersiveSticky'));

    // Reveal the controls first — the back button is hidden (and
    // untappable, via IgnorePointer) until then.
    await tapContent(tester);
    await tester.pumpAndSettle();

    // Pop back to the Dashboard (via the back button) — dispose() must
    // restore normal system UI regardless of which exit path is taken.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    final restoreCall = calls.lastWhere((c) => c.method == 'SystemChrome.setEnabledSystemUIMode');
    expect(restoreCall.arguments, contains('SystemUiMode.edgeToEdge'));
  });

  testWidgets(
    'Fase 14 §3/§14 — 20 repeated open/close cycles leave no stray timer or system-UI-mode mismatch behind',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      // The custom back button carries a Portuguese tooltip ('Voltar'), not
      // the English 'Back' `WidgetTester.pageBack` looks for by default —
      // reveal the controls (tap the content) then tap the icon directly,
      // matching how this file's own earlier "back button" test already
      // does it.
      Future<void> backViaTopBar() async {
        await tapContent(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
      }

      await pumpFullscreen(tester);
      for (var i = 0; i < 19; i++) {
        await backViaTopBar();
        await tester.tap(find.text('abrir tela cheia'));
        await tester.pumpAndSettle();
      }
      await backViaTopBar();

      // 20 enters, 20 restores — every cycle's own SystemChrome call pair
      // fired exactly once, no accumulation and no missed teardown.
      final enterCalls = calls.where(
        (c) => c.method == 'SystemChrome.setEnabledSystemUIMode' && (c.arguments as String).contains('immersiveSticky'),
      );
      final restoreCalls = calls.where(
        (c) => c.method == 'SystemChrome.setEnabledSystemUIMode' && (c.arguments as String).contains('edgeToEdge'),
      );
      expect(enterCalls, hasLength(20));
      expect(restoreCalls, hasLength(20));

      // No pending timer left running (a leaked `_hideTimer` would fail
      // flutter_test's own "pending timer" check on tearDown) — asserted
      // implicitly by this test completing at all, plus explicitly here via
      // one more full settle with no further exception.
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> doubleTapContent(WidgetTester tester) async {
    await tester.tap(find.text('conteúdo do sensor'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('conteúdo do sensor'));
    await tester.pumpAndSettle();
  }

  testWidgets('a double-tap on the instrument returns to the dashboard (no controls shown first)', (tester) async {
    await pumpFullscreen(tester);
    await doubleTapContent(tester);

    expect(find.text('abrir tela cheia'), findsOneWidget);
    expect(find.text('conteúdo do sensor'), findsNothing);
  });

  testWidgets('a double-tap asks confirmExit first: false stays, true leaves', (tester) async {
    var answer = false;
    var asked = 0;
    await pumpFullscreen(
      tester,
      confirmExit: (context) async {
        asked++;
        return answer;
      },
    );

    await doubleTapContent(tester);
    expect(asked, 1);
    expect(find.text('conteúdo do sensor'), findsOneWidget, reason: 'refused: still in fullscreen');

    answer = true;
    await doubleTapContent(tester);
    expect(asked, 2);
    expect(find.text('abrir tela cheia'), findsOneWidget, reason: 'confirmed: back on the dashboard');
  });

  testWidgets('a long-press opens the calibrate/reset action only — no delete or style there', (tester) async {
    var resets = 0;
    await pumpFullscreen(tester, onResetRecords: () => resets++, onChangeStyle: () {});

    await tester.longPress(find.text('conteúdo do sensor'));
    await tester.pumpAndSettle();

    expect(find.text('Resetar registros'), findsOneWidget);
    expect(find.text('Sair da tela cheia'), findsOneWidget);
    expect(find.text('Excluir'), findsNothing);
    expect(find.text('Alterar o estilo'), findsNothing);

    await tester.tap(find.text('Resetar registros'));
    await tester.pumpAndSettle();
    expect(resets, 1);
    expect(find.text('conteúdo do sensor'), findsOneWidget, reason: 'resetting never leaves the screen');
  });

  testWidgets('the top bar buttons answer at once — the instrument\'s double-tap window never delays them', (tester) async {
    await pumpFullscreen(tester);
    await tapContent(tester);

    // No time advanced after the tap: a double-tap recognizer above the bar
    // would still be holding the arena here, and the pop would not start.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('abrir tela cheia'), findsOneWidget);
  });
}
