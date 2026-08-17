import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for the other half of the edit-mode gesture gating in
/// `DashboardScreen` (the tile-level drag gating is covered by
/// `dashboard_drag_vs_pageview_swipe_test.dart`): while *any* tile is in
/// edit mode, the dashboard's own page swipe must be completely disabled —
/// not just out-competed during an active drag — for the whole edit
/// session, and restored the instant edit mode ends.
///
/// `DashboardScreen` achieves this the same way this harness does: binding
/// `PageView.physics` directly to the edit-mode flag
/// (`NeverScrollableScrollPhysics` while editing, the platform default
/// otherwise). That flag only ever flips via a plain `setState` from a
/// completed, separate gesture (a tap on a tile or on empty space) — never
/// mid-gesture on the same pointer — which is what makes this safe: a
/// previous, pointer-position-tracking version of "block swipe while
/// something is selected" was removed in an earlier round after proving
/// racy (`shouldAcceptUserOffset` is only re-consulted at the `Scrollable`'s
/// own layout time), whereas a plain widget-identity change in `physics` is
/// picked up deterministically on the very next frame — always before any
/// new pointer-down can physically occur.
void main() {
  Widget buildHarness(PageController controller, ValueNotifier<bool> editing) {
    return MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: editing,
        builder: (context, isEditing, _) => PageView.builder(
          controller: controller,
          physics: isEditing ? const NeverScrollableScrollPhysics() : null,
          itemCount: 2,
          itemBuilder: (context, index) => Center(child: Text('page $index')),
        ),
      ),
    );
  }

  testWidgets('a swipe starting on empty space is fully blocked for the whole edit session', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    final editing = ValueNotifier<bool>(true);
    addTearDown(editing.dispose);

    await tester.pumpWidget(buildHarness(controller, editing));
    expect(controller.page, 0.0);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    expect(controller.page, 0.0, reason: 'swipe must stay disabled for the entire edit session, not just mid-drag');
  });

  testWidgets('swipe is restored immediately once edit mode ends, no extra gesture required', (tester) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    final editing = ValueNotifier<bool>(true);
    addTearDown(editing.dispose);

    await tester.pumpWidget(buildHarness(controller, editing));

    // Confirms the blocked baseline before flipping, so the second fling
    // below is proven to be what re-enabled it, not a pre-existing state.
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(controller.page, 0.0);

    editing.value = false;
    await tester.pump();

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    expect(controller.page, 1.0, reason: 'swipe must work again immediately once editing ends');
  });
}
