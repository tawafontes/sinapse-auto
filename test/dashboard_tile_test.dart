import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/dashboard_layout_engine.dart';
import 'package:synapse_auto/widgets/dashboard/dashboard_tile.dart';

void main() {
  const defaultRect = (x: 0, y: 0, width: 2, height: 2);
  const grid = (columns: 4, rows: 4);
  const cellSize = Size(100, 100);

  Widget buildTile({
    CellRect? rect,
    Color? alertColor,
    bool isEditing = false,
    List<CellRect>? otherRects,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    VoidCallback? onMoveStarted,
    bool Function(CellRect)? onMoveCandidate,
    VoidCallback? onMoveCancelled,
    ValueChanged<Offset>? onDragPositionUpdate,
    ValueChanged<CellRect?>? onResizePreviewChanged,
    ValueChanged<CellRect>? onResized,
    ValueChanged<CellRect>? onMoved,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            DashboardTile(
              rect: rect ?? defaultRect,
              cellSize: cellSize,
              grid: grid,
              otherRects: otherRects ?? const [],
              label: 'Inclinação',
              icon: Icons.architecture,
              accentColor: Colors.blue,
              content: const SizedBox(),
              onMoved: onMoved ?? (_) {},
              onMoveStarted: onMoveStarted ?? () {},
              onMoveCandidate: onMoveCandidate ?? (_) => true,
              onMoveCancelled: onMoveCancelled ?? () {},
              onDragPositionUpdate: onDragPositionUpdate ?? (_) {},
              onResized: onResized ?? (_) {},
              alertColor: alertColor,
              isEditing: isEditing,
              onTap: onTap ?? () {},
              onLongPress: onLongPress ?? () {},
              onResizePreviewChanged: onResizePreviewChanged ?? (_) {},
            ),
          ],
        ),
      ),
    );
  }

  // Searches the whole tree, not just DashboardTile's own descendants: while
  // a move drag is in progress, the tile's real visual body — the Container
  // this reads — is promoted into the app's Overlay instead (see that
  // class's doc), which is a sibling of DashboardTile, not a descendant of
  // it. The harness only ever has one tile, so this stays unambiguous
  // either way.
  BoxDecoration cardDecoration(WidgetTester tester) {
    final container = tester.widget<Container>(find.byKey(const ValueKey('dashboardTileVisualBody')));
    return container.decoration! as BoxDecoration;
  }

  bool hasOverlay(WidgetTester tester) =>
      find.byKey(const ValueKey('dashboardTileAlertOverlay')).evaluate().isNotEmpty;

  testWidgets('with no alertColor, the border stays at the normal accent style and there is no overlay', (
    tester,
  ) async {
    await tester.pumpWidget(buildTile());

    final decoration = cardDecoration(tester);
    expect(decoration.border, Border.all(color: Colors.blue.withValues(alpha: 0.7), width: 1.5));
    expect(hasOverlay(tester), isFalse);
  });

  testWidgets('with an alertColor, the border and the overlay blink together', (tester) async {
    await tester.pumpWidget(buildTile(alertColor: Colors.red));

    // Blink starts "on": highlighted border + overlay both present together.
    var decoration = cardDecoration(tester);
    expect(decoration.border, Border.all(color: Colors.red, width: 3.0));
    expect(hasOverlay(tester), isTrue);

    // Half a blink cycle later: both should disappear together, not just one.
    await tester.pump(const Duration(milliseconds: 500));
    decoration = cardDecoration(tester);
    expect(decoration.border, Border.all(color: Colors.blue.withValues(alpha: 0.7), width: 1.5));
    expect(hasOverlay(tester), isFalse);

    // Another half cycle: both come back together.
    await tester.pump(const Duration(milliseconds: 500));
    decoration = cardDecoration(tester);
    expect(decoration.border, Border.all(color: Colors.red, width: 3.0));
    expect(hasOverlay(tester), isTrue);
  });

  testWidgets('clearing alertColor stops the blink and restores the normal border', (tester) async {
    await tester.pumpWidget(buildTile(alertColor: Colors.red));
    expect(hasOverlay(tester), isTrue);

    await tester.pumpWidget(buildTile());
    final decoration = cardDecoration(tester);
    expect(decoration.border, Border.all(color: Colors.blue.withValues(alpha: 0.7), width: 1.5));
    expect(hasOverlay(tester), isFalse);

    // No more blinking scheduled — pumping further stays quiet (also
    // guards against a leaked Timer keeping the test from settling).
    await tester.pump(const Duration(milliseconds: 500));
    expect(hasOverlay(tester), isFalse);
  });

  testWidgets('resize handles only appear while editing', (tester) async {
    await tester.pumpWidget(buildTile());
    expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsNothing);

    await tester.pumpWidget(buildTile(isEditing: true));
    expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsOneWidget);
  });

  testWidgets(
    'a rect change while not being dragged (e.g. reflow displacing this tile) settles in '
    'gradually instead of teleporting',
    (tester) async {
      Positioned positioned() => tester.widget<Positioned>(
        find.descendant(of: find.byType(DashboardTile), matching: find.byType(Positioned)),
      );

      await tester.pumpWidget(buildTile());
      await tester.pump();
      expect(positioned().left, 0);
      expect(positioned().top, 0);

      const target = (x: 2, y: 1, width: 2, height: 2);
      await tester.pumpWidget(buildTile(rect: target));
      // A single short frame in: the spring has barely had time to move —
      // proof this isn't an instant jump to the new rect.
      await tester.pump(const Duration(milliseconds: 16));
      expect(positioned().left, greaterThan(0));
      expect(positioned().left, lessThan(200));

      // Long enough for the spring to fully settle.
      await tester.pump(const Duration(seconds: 2));
      expect(positioned().left, closeTo(200, 0.5));
      expect(positioned().top, closeTo(100, 0.5));
    },
  );

  testWidgets('double-tapping the tile does not call onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTile(onTap: () => tapped = true));

    await tester.tap(find.byType(DashboardTile));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(DashboardTile));
    await tester.pump();

    expect(tapped, isFalse);

    // Flush the gesture recognizer's own internal timer bookkeeping so it
    // doesn't outlive the widget tree and trip the test harness's pending-
    // timer check.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a single tap on the tile calls onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildTile(onTap: () => tapped = true));

    await tester.tap(find.byType(DashboardTile));
    // The detector also listens for a double tap, so a lone tap only fires
    // onTap once Flutter is sure a second tap isn't coming.
    await tester.pump(const Duration(milliseconds: 400));

    expect(tapped, isTrue);
  });

  testWidgets('long-pressing the tile calls onLongPress while still held, before release', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(buildTile(onLongPress: () => longPressed = true));

    final gesture = await tester.startGesture(const Offset(100, 100));
    await tester.pump(kLongPressTimeout + kPressTimeout);

    expect(longPressed, isTrue); // fired already — the finger hasn't lifted yet.

    await gesture.up();
    await tester.pump();
  });

  testWidgets('movement past touch slop before the long-press deadline starts a drag, not a long press', (
    tester,
  ) async {
    var longPressed = false;
    CellRect? committed;
    await tester.pumpWidget(
      buildTile(isEditing: true, onLongPress: () => longPressed = true, onMoved: (r) => committed = r),
    );

    // tester.drag() completes its whole down/move/up sequence without
    // advancing the test clock by anything close to kLongPressTimeout, so
    // this alone proves the long press never gets a chance to win.
    await tester.drag(find.byType(DashboardTile), const Offset(100, 0));
    await tester.pump();

    expect(longPressed, isFalse);
    expect(committed, (x: 1, y: 0, width: 2, height: 2));

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('holding still past the deadline then releasing fires onLongPress without moving', (tester) async {
    var longPressed = false;
    CellRect? committed;
    await tester.pumpWidget(buildTile(onLongPress: () => longPressed = true, onMoved: (r) => committed = r));

    final gesture = await tester.startGesture(const Offset(100, 100));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.up();
    await tester.pump();

    expect(longPressed, isTrue);
    expect(committed, isNull);
  });

  testWidgets('a candidate onMoveCandidate rejects leaves the tile at its last accepted position', (tester) async {
    CellRect? committed;
    await tester.pumpWidget(
      buildTile(
        isEditing: true,
        // Simulates the parent finding reflow impossible for any rightward move.
        onMoveCandidate: (candidate) => candidate.x <= 0,
        onMoved: (r) => committed = r,
      ),
    );

    await tester.drag(find.byType(DashboardTile), const Offset(100, 0));
    await tester.pump();

    // onMoved still fires on release (same as a no-op drag always did before
    // reflow existed) — but with the tile's unchanged starting rect, since
    // every rightward candidate was rejected.
    expect(committed, defaultRect);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('onMoveStarted fires even when every candidate for the whole drag is rejected', (tester) async {
    // Regression test: a tile already pinned at its page's own edge (e.g.
    // rightmost column) can have every single candidate rejected for an
    // entire drag — onMoveCandidate then never fires at all. The parent
    // still needs to know a drag started (for edge-hover page-switching),
    // which onMoveStarted alone guarantees, decoupled from candidate
    // validity.
    var started = false;
    await tester.pumpWidget(
      buildTile(isEditing: true, onMoveStarted: () => started = true, onMoveCandidate: (_) => false),
    );

    await tester.drag(find.byType(DashboardTile), const Offset(100, 0));
    await tester.pump();

    expect(started, isTrue);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the border highlights while dragging via pan, while editing', (tester) async {
    await tester.pumpWidget(buildTile(isEditing: true));
    // isEditing alone already highlights the border (see the resize-handle
    // scenario below), so this only proves _isDragging keeps it highlighted
    // through the drag itself, not that dragging is what turns it on.
    expect(cardDecoration(tester).border!.top.width, 2.5);

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();

    expect(cardDecoration(tester).border!.top.width, 2.5);

    await gesture.up();
    await tester.pump();
    expect(cardDecoration(tester).border!.top.width, 2.5); // isEditing itself still holds it up.

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('dragging the tile while editing moves it and commits only on release', (tester) async {
    CellRect? committed;
    await tester.pumpWidget(buildTile(isEditing: true, onMoved: (r) => committed = r));

    await tester.drag(find.byType(DashboardTile), const Offset(100, 0));
    await tester.pump();

    expect(committed, (x: 1, y: 0, width: 2, height: 2));

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('dragging the tile while NOT editing does nothing — drag requires edit mode first', (tester) async {
    // Regression test for the Android-home-screen-style gating: outside edit
    // mode, DashboardTile leaves ImmediateMultiDragGestureRecognizer out of
    // its gestures map entirely (see build()), so a drag never starts at
    // all — no movement, no onMoved, no highlight — rather than starting
    // and simply being declined.
    CellRect? committed;
    await tester.pumpWidget(buildTile(onMoved: (r) => committed = r));
    expect(cardDecoration(tester).border!.top.width, 1.5);

    await tester.drag(find.byType(DashboardTile), const Offset(100, 0));
    await tester.pump();

    expect(committed, isNull);
    expect(cardDecoration(tester).border!.top.width, 1.5);

    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('dragging reports the live raw global position via onDragPositionUpdate', (tester) async {
    final positions = <Offset>[];
    await tester.pumpWidget(buildTile(isEditing: true, onDragPositionUpdate: positions.add));

    final gesture = await tester.startGesture(const Offset(100, 100));
    // The first move past the recognizer's own slop is what starts the
    // drag — ImmediateMultiDragGestureRecognizer reports that very first
    // update with the *initial* down position (its own delta is correct,
    // just not yet reflected in globalPosition; see
    // MultiDragPointerState._startDrag in the Flutter SDK, same as
    // Draggable). A second move is a normal update and reports the true
    // current position.
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();

    expect(positions, isNotEmpty);
    expect(positions.last, const Offset(250, 100));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('isEditing turning off mid-drag cancels the in-flight move instead of leaving it stuck', (
    tester,
  ) async {
    // Regression test for the didUpdateWidget guard in _DashboardTileState:
    // exiting edit mode removes ImmediateMultiDragGestureRecognizer from the
    // gestures map outright (see build()), which disposes the recognizer's
    // per-pointer state without ever calling the in-flight Drag's own
    // cancel()/end() (confirmed directly against the Flutter SDK source).
    // Without the guard, _isDragging (and the parent's onMoveCancelled)
    // would never fire, leaving the tile stuck looking mid-drag.
    var cancelled = false;
    CellRect? committed;
    await tester.pumpWidget(
      buildTile(isEditing: true, onMoveCancelled: () => cancelled = true, onMoved: (r) => committed = r),
    );

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(cardDecoration(tester).border!.top.width, 2.5); // dragging, highlighted.

    // Same pointer stays down (as it would with a second finger tapping
    // empty space elsewhere) while the parent flips isEditing off.
    await tester.pumpWidget(
      buildTile(isEditing: false, onMoveCancelled: () => cancelled = true, onMoved: (r) => committed = r),
    );
    // _cancelMove's OverlayEntry.remove() runs mid-build here (from inside
    // didUpdateWidget) — Overlay defers the rebuild that actually drops the
    // entry's widget to a post-frame callback in that case, so the avatar's
    // Container is still around for one more frame alongside the freshly
    // un-hidden in-place one, until this settles.
    await tester.pump();

    expect(cancelled, isTrue);
    expect(committed, isNull);
    expect(cardDecoration(tester).border!.top.width, 1.5);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('dragging a resize handle reports a live preview and commits only on release', (tester) async {
    final previews = <CellRect?>[];
    CellRect? resized;
    CellRect? moved;
    await tester.pumpWidget(
      buildTile(
        isEditing: true,
        onResizePreviewChanged: previews.add,
        onResized: (r) => resized = r,
        onMoved: (r) => moved = r,
      ),
    );

    // The bottom-right handle straddles the tile's own corner (200, 200) —
    // dragFrom a point safely inside its tap target instead of relying on
    // a finder-based hit-test check against that exact boundary corner,
    // and zero touch slop so the full requested delta is delivered as one
    // clean update (matching what _candidateRect expects).
    final gesture = await tester.startGesture(const Offset(195, 195));
    await tester.pump();
    await gesture.moveBy(const Offset(100, 100));
    await tester.pump();

    expect(previews, isNotEmpty);
    expect(previews.contains((x: 0, y: 0, width: 3, height: 3)), isTrue);
    expect(resized, isNull); // not yet — only on release.

    await gesture.up();
    await tester.pump();

    expect(resized, (x: 0, y: 0, width: 3, height: 3));
    expect(previews.last, isNull); // cleared once the gesture ends.
    expect(moved, isNull); // a handle drag resizes, never moves.
  });

  group('press, hold and drag in one gesture (2026-11-11)', () {
    /// Like the dashboard: the long press itself enters edit mode.
    Widget editOnLongPress({required ValueChanged<CellRect> onMoved, VoidCallback? onMoveStarted}) {
      var editing = false;
      return StatefulBuilder(
        builder: (context, setState) => buildTile(
          isEditing: editing,
          onLongPress: () => setState(() => editing = true),
          onMoved: onMoved,
          onMoveStarted: onMoveStarted,
        ),
      );
    }

    testWidgets('holding the tile and dragging without lifting moves it, committed on release', (tester) async {
      CellRect? committed;
      var started = 0;
      await tester.pumpWidget(editOnLongPress(onMoved: (r) => committed = r, onMoveStarted: () => started++));

      final gesture = await tester.startGesture(const Offset(100, 100));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsOneWidget, reason: 'edit mode entered by the hold');

      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      expect(started, 1);
      expect(committed, isNull, reason: 'not before release');

      await gesture.up();
      await tester.pump();
      expect(committed, (x: 1, y: 0, width: 2, height: 2));
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('a hold that only wobbles within touch slop stays "enter edit mode" — no move', (tester) async {
      CellRect? committed;
      var started = 0;
      await tester.pumpWidget(editOnLongPress(onMoved: (r) => committed = r, onMoveStarted: () => started++));

      final gesture = await tester.startGesture(const Offset(100, 100));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.moveBy(const Offset(5, 3));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(started, 0);
      expect(committed, isNull);
      expect(find.byKey(const ValueKey('resizeHandle_bottomRight')), findsOneWidget, reason: 'still editing, handles shown');
    });

    testWidgets('the two-gesture way (hold, lift, then drag) still works', (tester) async {
      CellRect? committed;
      await tester.pumpWidget(editOnLongPress(onMoved: (r) => committed = r));

      final hold = await tester.startGesture(const Offset(100, 100));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await hold.up();
      await tester.pump();

      await tester.drag(find.byType(DashboardTile), const Offset(100, 0));
      await tester.pump();
      expect(committed, (x: 1, y: 0, width: 2, height: 2));
      await tester.pump(const Duration(milliseconds: 400));
    });
  });
}
