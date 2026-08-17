import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for the mechanism [DashboardTile] relies on to make a
/// tile drag reliably win over the dashboard's own page swipe (see that
/// file's class doc): a bare `PanGestureRecognizer` needs [kPanSlop] (36px)
/// to self-accept, while a `PageView`'s own `HorizontalDragGestureRecognizer`
/// only needs [kTouchSlop] (18px) — on a mostly-horizontal move, the page
/// can win the gesture arena before the tile ever gets a chance. Using
/// [ImmediateMultiDragGestureRecognizer] instead (same recognizer
/// `Draggable` uses) puts the tile on equal footing and, per its own
/// documentation, lets the more specific (deeper) widget reliably win.
///
/// This reproduces [DashboardTile]'s actual gesture setup — the same four
/// recognizer types on one `RawGestureDetector`, nested inside
/// `Positioned`/`Stack`, inside a `PageView.builder` wrapped in an outer
/// `Listener` — rather than testing `DashboardTile` itself, since the
/// interaction under test is specifically with an *ancestor* `PageView`,
/// which `DashboardTile`'s own widget tests (pumped standalone, with no
/// enclosing `PageView`) can't exercise.
///
/// [DashboardTile] only ever registers the drag recognizer while its tile is
/// the one in edit mode (Android-home-screen style: select first, then
/// move) — see that class's doc for why merely declining via a null
/// `onStart` isn't enough. The two tests below cover both sides of that
/// gate: recognizer present (editing) vs. absent (not editing).
Widget _buildHarness({
  required PageController controller,
  required bool includeDragRecognizer,
  required VoidCallback onDragStart,
}) {
  return MaterialApp(
    home: Listener(
      onPointerDown: (_) {},
      child: PageView.builder(
        controller: controller,
        itemCount: 2,
        itemBuilder: (context, index) {
          if (index == 1) return const Center(child: Text('page 2'));
          return Stack(
            children: [
              Positioned(
                left: 50,
                top: 50,
                width: 200,
                height: 200,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.opaque,
                  gestures: {
                    TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                      TapGestureRecognizer.new,
                      (instance) => instance.onTap = () {},
                    ),
                    DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                      DoubleTapGestureRecognizer.new,
                      (instance) => instance.onDoubleTap = () {},
                    ),
                    LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                      LongPressGestureRecognizer.new,
                      (instance) => instance.onLongPress = () {},
                    ),
                    if (includeDragRecognizer)
                      ImmediateMultiDragGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
                            ImmediateMultiDragGestureRecognizer.new,
                            (instance) => instance.onStart = (position) {
                              onDragStart();
                              return _NoopDrag();
                            },
                          ),
                  },
                  child: Container(color: Colors.blue),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

void main() {
  testWidgets('a horizontal drag starting on the tile is claimed by the tile, not the page swipe, while editing', (
    tester,
  ) async {
    var dragStarted = false;
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _buildHarness(controller: controller, includeDragRecognizer: true, onDragStart: () => dragStarted = true),
    );

    expect(controller.page, 0.0);

    final gesture = await tester.startGesture(const Offset(150, 150));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(dragStarted, isTrue, reason: 'the tile drag should have started, not the page swipe');
    expect(controller.page, 0.0, reason: 'the page should not have changed while dragging the tile');

    // Flushes DoubleTapGestureRecognizer's own internal timer bookkeeping so
    // it doesn't outlive the widget tree and trip the test harness's
    // pending-timer check (same pattern used in dashboard_tile_test.dart).
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
    'a horizontal drag starting on the tile changes pages instead, when the tile has no drag recognizer '
    '(not editing)',
    (tester) async {
      var dragStarted = false;
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _buildHarness(controller: controller, includeDragRecognizer: false, onDragStart: () => dragStarted = true),
      );

      expect(controller.page, 0.0);

      // A real fling (with release velocity), unlike the "claimed by the
      // tile" test above, where the exact motion doesn't matter — the arena
      // there resolves to the tile's own recognizer before the page ever
      // sees a single scroll update. This test specifically needs the swipe
      // to actually complete a page transition on release, to prove it's
      // really the page swipe doing the work, not just an absence of
      // movement. Starts on the tile's own Container (center (150, 150),
      // matching the tile's `Positioned(left: 50, top: 50, width: 200,
      // height: 200)` box) so this is still a drag that *starts on the
      // tile*, same as the sibling test above.
      await tester.fling(find.byType(Container), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();

      expect(dragStarted, isFalse, reason: 'no drag recognizer is registered outside edit mode');
      expect(controller.page, 1.0, reason: 'with no competing drag recognizer, the page swipe should win instead');

      await tester.pump(const Duration(milliseconds: 400));
    },
  );
}

class _NoopDrag extends Drag {}
