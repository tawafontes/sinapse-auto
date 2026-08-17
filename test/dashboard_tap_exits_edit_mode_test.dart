import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

/// Regression coverage for the DashboardScreen-level rule that
/// [DashboardTile] itself has no opinion on (see that class's doc): while
/// *any* tile dashboard-wide is being edited, tapping a tile — the one
/// being edited, or a different one — must end the edit session instead of
/// opening that tile's own context menu.
///
/// DashboardScreen itself can't be pumped in a widget test (its
/// SensorService touches real platform channels on construction), so this
/// reproduces its exact wiring pattern —
/// `onTap: () => editing != null ? exitEdit() : openMenu(tile)` — with two
/// tiles managed by a tiny local harness, the same approach already used for
/// the drag-vs-swipe arena priority and the edit-mode swipe lock.
void main() {
  bool hasAnyResizeHandle(WidgetTester tester) =>
      find.byKey(const ValueKey('resizeHandle_bottomRight')).evaluate().isNotEmpty;

  testWidgets('tapping a tile while nothing is being edited opens its context menu', (tester) async {
    final opened = <int>[];
    await tester.pumpWidget(_Harness(onMenuOpened: opened.add));

    await tester.tap(find.byKey(const ValueKey('tile0')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(opened, [0]);
    expect(hasAnyResizeHandle(tester), isFalse);
  });

  testWidgets('tapping the tile currently being edited ends the edit session instead of opening its menu', (
    tester,
  ) async {
    final opened = <int>[];
    await tester.pumpWidget(_Harness(onMenuOpened: opened.add));

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('tile0'))));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.up();
    await tester.pump();
    expect(hasAnyResizeHandle(tester), isTrue, reason: 'long-press should have entered edit mode');

    await tester.tap(find.byKey(const ValueKey('tile0')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(opened, isEmpty, reason: 'tapping while editing must never open a context menu');
    expect(hasAnyResizeHandle(tester), isFalse, reason: 'the tap should have ended the edit session');
  });

  testWidgets(
    'tapping a different tile while one is being edited ends the edit session '
    'instead of opening the other tile\'s menu or starting to edit it',
    (tester) async {
      final opened = <int>[];
      await tester.pumpWidget(_Harness(onMenuOpened: opened.add));

      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('tile0'))));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.up();
      await tester.pump();
      expect(hasAnyResizeHandle(tester), isTrue);

      await tester.tap(find.byKey(const ValueKey('tile1')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(opened, isEmpty, reason: 'tile1\'s menu must not open');
      expect(hasAnyResizeHandle(tester), isFalse, reason: 'edit mode must be over, not switched to tile1');
    },
  );
}

class _Harness extends StatefulWidget {
  const _Harness({required this.onMenuOpened});

  final ValueChanged<int> onMenuOpened;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  static const _grid = (columns: 4, rows: 2);
  static const _cellSize = Size(100, 100);

  int? _editing;

  void _exitEdit() {
    if (_editing != null) setState(() => _editing = null);
  }

  void _enterEdit(int index) => setState(() => _editing = index);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            for (var i = 0; i < 2; i++)
              DashboardTile(
                key: ValueKey('tile$i'),
                rect: (x: i * 2, y: 0, width: 2, height: 2),
                cellSize: _cellSize,
                grid: _grid,
                otherRects: const [],
                label: 'Tile $i',
                icon: Icons.widgets,
                accentColor: Colors.blue,
                content: const SizedBox(),
                onMoved: (_) {},
                onMoveStarted: () {},
                onMoveCandidate: (_) => true,
                onMoveCancelled: () {},
                onDragPositionUpdate: (_) {},
                onResized: (_) {},
                isEditing: _editing == i,
                // Exactly DashboardScreen's own wiring pattern (see
                // dashboard_screen.dart's _buildPageGrid).
                onTap: () => _editing != null ? _exitEdit() : widget.onMenuOpened(i),
                onLongPress: () => _enterEdit(i),
                onResizePreviewChanged: (_) {},
              ),
          ],
        ),
      ),
    );
  }
}
