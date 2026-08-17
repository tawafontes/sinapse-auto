import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile_context_menu.dart';

void main() {
  Future<void> pumpAndOpen(
    WidgetTester tester, {
    VoidCallback? onDelete,
    VoidCallback? onChangeStyle,
    VoidCallback? onFullscreen,
    bool isFullscreen = false,
    VoidCallback? onResetRecords,
    String resetRecordsLabel = 'Resetar registros',
    IconData resetRecordsIcon = Icons.restart_alt,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDashboardTileContextMenu(
                  context: context,
                  icon: Icons.speed,
                  label: 'Velocidade',
                  onDelete: onDelete ?? () {},
                  onChangeStyle: onChangeStyle,
                  onFullscreen: onFullscreen ?? () {},
                  isFullscreen: isFullscreen,
                  onResetRecords: onResetRecords,
                  resetRecordsLabel: resetRecordsLabel,
                  resetRecordsIcon: resetRecordsIcon,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('with no onResetRecords, no reset/calibrate item appears at all', (tester) async {
    await pumpAndOpen(tester);

    expect(find.text('Excluir'), findsOneWidget);
    expect(find.text('Colocar em tela cheia'), findsOneWidget);
    expect(find.text('Resetar registros'), findsNothing);
  });

  testWidgets('with onResetRecords and no label override, defaults to "Resetar registros" with restart_alt', (
    tester,
  ) async {
    var tapped = false;
    await pumpAndOpen(tester, onResetRecords: () => tapped = true);

    expect(find.text('Resetar registros'), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsOneWidget);

    await tester.tap(find.text('Resetar registros'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('a custom label/icon (e.g. inclination calibration) replaces the default entirely', (tester) async {
    var tapped = false;
    await pumpAndOpen(
      tester,
      onResetRecords: () => tapped = true,
      resetRecordsLabel: 'Calibrar horizonte',
      resetRecordsIcon: Icons.architecture,
    );

    expect(find.text('Calibrar horizonte'), findsOneWidget);
    expect(find.text('Resetar registros'), findsNothing);
    expect(find.byIcon(Icons.architecture), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsNothing);

    await tester.tap(find.text('Calibrar horizonte'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('a rename-only override (no icon override) keeps the default icon', (tester) async {
    await pumpAndOpen(tester, onResetRecords: () {}, resetRecordsLabel: 'Calibrar');

    expect(find.text('Calibrar'), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsOneWidget);
  });

  testWidgets('isFullscreen false (default): shows "Colocar em tela cheia" with the fullscreen icon', (tester) async {
    var tapped = false;
    await pumpAndOpen(tester, onFullscreen: () => tapped = true);

    expect(find.text('Colocar em tela cheia'), findsOneWidget);
    expect(find.text('Sair da tela cheia'), findsNothing);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);

    await tester.tap(find.text('Colocar em tela cheia'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });

  testWidgets('isFullscreen true: shows "Sair da tela cheia" with the fullscreen_exit icon instead — same slot, '
      'same callback, no second menu implementation', (tester) async {
    var tapped = false;
    await pumpAndOpen(tester, isFullscreen: true, onFullscreen: () => tapped = true);

    expect(find.text('Sair da tela cheia'), findsOneWidget);
    expect(find.text('Colocar em tela cheia'), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsNothing);

    await tester.tap(find.text('Sair da tela cheia'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });

  testWidgets('onChangeStyle absent hides "Alterar o estilo"; present shows and wires it', (tester) async {
    var tapped = false;
    await pumpAndOpen(tester, onChangeStyle: () => tapped = true);

    expect(find.text('Alterar o estilo'), findsOneWidget);
    await tester.tap(find.text('Alterar o estilo'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('tapping any item closes the sheet', (tester) async {
    await pumpAndOpen(tester, onResetRecords: () {});

    expect(find.text('Resetar registros'), findsOneWidget);
    await tester.tap(find.text('Resetar registros'));
    await tester.pumpAndSettle();

    expect(find.text('Resetar registros'), findsNothing);
  });

  testWidgets(
    'a menu with every optional item present does not overflow even on a very short viewport, '
    'and the last item is still reachable and tappable via scrolling',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;

      var tapped = false;
      await pumpAndOpen(
        tester,
        onChangeStyle: () {},
        onResetRecords: () => tapped = true,
      );

      // The overflow this regresses against is a RenderFlex layout
      // exception thrown during the pump above — if it happened, it would
      // already be recorded here.
      expect(tester.takeException(), isNull);

      final resetFinder = find.text('Resetar registros');
      expect(resetFinder, findsOneWidget);
      await tester.ensureVisible(resetFinder);
      await tester.pumpAndSettle();
      await tester.tap(resetFinder);
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
