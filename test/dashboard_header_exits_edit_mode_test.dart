import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

/// Regression coverage for the fix that made the AppBar (and every button in
/// it) participate in the same edit-mode-exit flow the Dashboard's body
/// already had — see `DashboardScreen.build`'s
/// `appBar: PreferredSize(..., child: Listener(onPointerDown: ..., child:
/// appBar))`. DashboardScreen itself can't be pumped in a widget test (its
/// SensorService touches real platform channels on construction), so this
/// reproduces the exact Scaffold/AppBar/Listener wiring with one tile and
/// one header button.
void main() {
  testWidgets('tapping a header button while a tile is being edited ends the edit session first', (tester) async {
    var buttonPressed = 0;
    await tester.pumpWidget(_Harness(onButtonPressed: () => buttonPressed++));

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('tile0'))));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsOneWidget, reason: 'sanity: editing started');

    await tester.tap(find.byKey(const ValueKey('headerButton')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('resizeHandle_bottomRight')),
      findsNothing,
      reason: 'the header tap must have ended the edit session',
    );
    expect(buttonPressed, 1, reason: "the button's own action must still run normally");
  });

  testWidgets('tapping a header button while nothing is being edited just runs its own action', (tester) async {
    var buttonPressed = 0;
    await tester.pumpWidget(_Harness(onButtonPressed: () => buttonPressed++));

    await tester.tap(find.byKey(const ValueKey('headerButton')));
    await tester.pump();

    expect(buttonPressed, 1);
    expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsNothing);
  });

  testWidgets('tapping empty header space (not a button) while editing also ends the session', (tester) async {
    var buttonPressed = 0;
    await tester.pumpWidget(_Harness(onButtonPressed: () => buttonPressed++));

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('tile0'))));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsOneWidget);

    await tester.tap(find.text('Test'));
    await tester.pump();

    expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsNothing);
    expect(buttonPressed, 0, reason: 'the header title is not the button, so it must not fire the button action');
  });
}

class _Harness extends StatefulWidget {
  const _Harness({required this.onButtonPressed});

  final VoidCallback onButtonPressed;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool _editing = false;

  void _exitEditMode() {
    if (_editing) setState(() => _editing = false);
  }

  void _enterEditMode() => setState(() => _editing = true);

  @override
  Widget build(BuildContext context) {
    // Mirrors DashboardScreen.build exactly: build the AppBar first, then
    // wrap it in Listener + PreferredSize for the Scaffold's appBar slot.
    final appBar = AppBar(
      title: const Text('Test'),
      actions: [
        IconButton(key: const ValueKey('headerButton'), icon: const Icon(Icons.settings), onPressed: widget.onButtonPressed),
      ],
    );
    return MaterialApp(
      home: Scaffold(
        appBar: PreferredSize(
          preferredSize: appBar.preferredSize,
          child: Listener(onPointerDown: (_) => _exitEditMode(), child: appBar),
        ),
        body: Stack(
          children: [
            DashboardTile(
              key: const ValueKey('tile0'),
              rect: (x: 0, y: 0, width: 2, height: 2),
              cellSize: const Size(100, 100),
              grid: const (columns: 4, rows: 2),
              otherRects: const [],
              label: 'Tile',
              icon: Icons.widgets,
              accentColor: Colors.blue,
              content: const SizedBox(),
              onMoved: (_) {},
              onMoveStarted: () {},
              onMoveCandidate: (_) => true,
              onMoveCancelled: () {},
              onDragPositionUpdate: (_) {},
              onResized: (_) {},
              isEditing: _editing,
              onTap: () {
                if (_editing) _exitEditMode();
              },
              onLongPress: _enterEditMode,
              onResizePreviewChanged: (_) {},
            ),
          ],
        ),
      ),
    );
  }
}
