import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/dashboard/dashboard_screen.dart'
    show
        kDashboardPageTransitionCurve,
        kDashboardPageTransitionDuration,
        kDragEdgeHoverDelayMax,
        kPageCreationCooldown;

/// Regression coverage for auto-creating a new page when a drag is held past
/// the right edge of the last existing page — see
/// `DashboardScreen._hoverPageSwitch`, `_createNewPage`, and the
/// `_EdgePagingPhase` state machine that governs when a creation is (and,
/// critically, is *not*) allowed to happen.
///
/// `DashboardScreen` itself can't be pumped in a widget test (its
/// `SensorService` touches real platform channels on construction), so this
/// mirrors that state machine's exact logic in a small harness — but, unlike
/// other harnesses in this suite, deliberately does *not* talk to the real
/// `AppSettings`/Hive: `AppSettings.setDashboardPageCount`'s own persistence
/// is already covered by app_settings_test.dart, and firing a real Hive
/// write from inside a fake-clock-triggered `Timer` (which is what
/// `tester.pump(duration)` does) leaves a write in flight that `Hive.close()`
/// then deadlocks waiting on in `tearDown`. This test instead verifies the
/// page-index/cap/once-per-approach *logic* via an injected callback, which
/// is exactly what a real restart-persistence check on a physical device
/// complements (see the delivery report).
void main() {
  testWidgets('dragging past an existing next page just navigates, without creating anything', (tester) async {
    final key = GlobalKey<HoverPageCreationHarnessState>();
    final createdPages = <int>[];
    await tester.pumpWidget(HoverPageCreationHarness(key: key, initialPageCount: 2, onPageCreated: createdPages.add));

    key.currentState!.startDrag();
    key.currentState!.holdAtEdge(1);
    await tester.pump(kDragEdgeHoverDelayMax);

    expect(key.currentState!.currentPage, 1);
    expect(createdPages, isEmpty, reason: 'no new page — it already existed');

    key.currentState!.endDrag();
    await tester.pump(kDragEdgeHoverDelayMax);
  });

  testWidgets("dragging past the last page's right edge creates a new page and navigates to it", (tester) async {
    final key = GlobalKey<HoverPageCreationHarnessState>();
    final createdPages = <int>[];
    await tester.pumpWidget(HoverPageCreationHarness(key: key, onPageCreated: createdPages.add));

    key.currentState!.startDrag();
    key.currentState!.holdAtEdge(1);
    await tester.pump(kDragEdgeHoverDelayMax);

    expect(createdPages, [1], reason: 'exactly one new page, at index 1');
    expect(key.currentState!.currentPage, 1, reason: 'and navigated to right away');
    expect(key.currentState!.pageCount, 2);

    key.currentState!.endDrag();
    await tester.pump(kDragEdgeHoverDelayMax);
  });

  testWidgets(
    'creating a new page clears a stale reflow preview from the old page (regression)',
    (tester) async {
      final key = GlobalKey<HoverPageCreationHarnessState>();
      final createdPages = <int>[];
      await tester.pumpWidget(HoverPageCreationHarness(key: key, onPageCreated: createdPages.add));

      key.currentState!.startDrag();
      // Simulates a candidate already accepted on the old page from pointer
      // movement before the finger went still and held at the edge — the
      // real bug this guards against: this must not survive the page switch
      // below, since it was computed against the page being left behind.
      key.currentState!.setReflowPreview('stale candidate from the old page');
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax);

      expect(createdPages, [1]);
      expect(
        key.currentState!.reflowPreview,
        isNull,
        reason: 'a candidate accepted on the old page must not be mistaken for one valid on the new page',
      );

      key.currentState!.endDrag();
      await tester.pump(kDragEdgeHoverDelayMax);
    },
  );

  testWidgets(
    'switching to an existing next page also clears a stale reflow preview (regression)',
    (tester) async {
      final key = GlobalKey<HoverPageCreationHarnessState>();
      final createdPages = <int>[];
      await tester.pumpWidget(HoverPageCreationHarness(key: key, initialPageCount: 2, onPageCreated: createdPages.add));

      key.currentState!.startDrag();
      key.currentState!.setReflowPreview('stale candidate from the old page');
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax);

      expect(createdPages, isEmpty, reason: 'page 1 already existed');
      expect(key.currentState!.currentPage, 1);
      expect(key.currentState!.reflowPreview, isNull);

      key.currentState!.endDrag();
      await tester.pump(kDragEdgeHoverDelayMax);
    },
  );

  testWidgets('only one page is created per hover period, not one per re-check', (tester) async {
    final key = GlobalKey<HoverPageCreationHarnessState>();
    final createdPages = <int>[];
    await tester.pumpWidget(HoverPageCreationHarness(key: key, onPageCreated: createdPages.add));

    key.currentState!.startDrag();
    key.currentState!.holdAtEdge(1);
    await tester.pump(kDragEdgeHoverDelayMax);
    expect(createdPages, [1]);

    // Still within the *next* hover window (re-armed after the first
    // creation) — must not have created a second page yet.
    await tester.pump(kDragEdgeHoverDelayMax ~/ 2);
    expect(createdPages, [1], reason: 'a second creation must wait its own full hover delay');

    key.currentState!.endDrag();
    await tester.pump(kDragEdgeHoverDelayMax);
  });

  testWidgets(
    'holding continuously at the edge after a creation never creates a second page '
    '(Android-launcher-style, not a repeating timer)',
    (tester) async {
      final key = GlobalKey<HoverPageCreationHarnessState>();
      final createdPages = <int>[];
      await tester.pumpWidget(HoverPageCreationHarness(key: key, maxPages: 4, onPageCreated: createdPages.add));

      key.currentState!.startDrag();
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax); // page 0 -> new page 1
      expect(createdPages, [1]);

      // The pointer never left the edge (never called holdAtEdge(null)) —
      // keep the fake clock running well past both the cooldown and several
      // more hover-delay-equivalents. A pre-fix implementation (a single
      // self-re-arming timer) would create a second, third, fourth page
      // here; the state machine must not.
      await tester.pump(kPageCreationCooldown);
      await tester.pump(kDragEdgeHoverDelayMax);
      await tester.pump(kDragEdgeHoverDelayMax);
      await tester.pump(kDragEdgeHoverDelayMax);
      expect(createdPages, [1], reason: 'a stationary hold must never create more than one page');
      expect(key.currentState!.currentPage, 1);

      key.currentState!.endDrag();
      await tester.pump(kDragEdgeHoverDelayMax);
    },
  );

  testWidgets(
    'leaving the edge zone and deliberately returning to it allows exactly one more creation',
    (tester) async {
      final key = GlobalKey<HoverPageCreationHarnessState>();
      final createdPages = <int>[];
      await tester.pumpWidget(HoverPageCreationHarness(key: key, maxPages: 4, onPageCreated: createdPages.add));

      key.currentState!.startDrag();
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax); // page 0 -> new page 1
      expect(createdPages, [1]);

      // Cooldown alone (without ever actually leaving the zone) must not be
      // enough — the widget stays right at the edge here.
      await tester.pump(kPageCreationCooldown);
      expect(createdPages, [1], reason: 'cooldown elapsing alone must not be enough without a real exit');

      // Now genuinely move away from the edge, then deliberately come back —
      // the real gesture this is meant to require.
      key.currentState!.holdAtEdge(null);
      await tester.pump(const Duration(milliseconds: 16));
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax);

      expect(createdPages, [1, 2], reason: 'a deliberate new approach must be allowed to create again');
      expect(key.currentState!.currentPage, 2);

      key.currentState!.endDrag();
      await tester.pump(kDragEdgeHoverDelayMax);
    },
  );

  testWidgets(
    'returning to the edge before the cooldown elapses does not shortcut a new creation',
    (tester) async {
      final key = GlobalKey<HoverPageCreationHarnessState>();
      final createdPages = <int>[];
      await tester.pumpWidget(HoverPageCreationHarness(key: key, maxPages: 4, onPageCreated: createdPages.add));

      key.currentState!.startDrag();
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax); // page 0 -> new page 1
      expect(createdPages, [1]);

      // Leaves and returns *immediately*, well before kPageCreationCooldown
      // has had a chance to elapse — the cooldown floor must still apply.
      key.currentState!.holdAtEdge(null);
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax);
      expect(createdPages, [1], reason: 'the timed cooldown floor must still be respected');

      key.currentState!.endDrag();
      await tester.pump(kDragEdgeHoverDelayMax + kPageCreationCooldown);
    },
  );

  testWidgets('several deliberate approaches in a row each create exactly one page', (tester) async {
    final key = GlobalKey<HoverPageCreationHarnessState>();
    final createdPages = <int>[];
    await tester.pumpWidget(HoverPageCreationHarness(key: key, maxPages: 5, onPageCreated: createdPages.add));

    key.currentState!.startDrag();
    for (var i = 0; i < 3; i++) {
      key.currentState!.holdAtEdge(1);
      await tester.pump(kDragEdgeHoverDelayMax);
      await tester.pump(kPageCreationCooldown);
      key.currentState!.holdAtEdge(null);
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(createdPages, [1, 2, 3], reason: 'three deliberate approaches — exactly three new pages');
    expect(key.currentState!.currentPage, 3);

    key.currentState!.endDrag();
    await tester.pump(kDragEdgeHoverDelayMax);
  });

  testWidgets('dragging past the first page never creates anything (no page-before-first concept)', (tester) async {
    final key = GlobalKey<HoverPageCreationHarnessState>();
    final createdPages = <int>[];
    await tester.pumpWidget(HoverPageCreationHarness(key: key, onPageCreated: createdPages.add));

    key.currentState!.startDrag();
    key.currentState!.holdAtEdge(-1);
    await tester.pump(kDragEdgeHoverDelayMax);

    expect(key.currentState!.currentPage, 0);
    expect(createdPages, isEmpty);

    key.currentState!.endDrag();
    await tester.pump(kDragEdgeHoverDelayMax);
  });

  testWidgets('page creation stops once maxPages is reached', (tester) async {
    final key = GlobalKey<HoverPageCreationHarnessState>();
    final createdPages = <int>[];
    await tester.pumpWidget(
      HoverPageCreationHarness(key: key, initialPageCount: 3, maxPages: 3, onPageCreated: createdPages.add),
    );
    key.currentState!.jumpTo(2); // the last page, already at the cap.

    key.currentState!.startDrag();
    key.currentState!.holdAtEdge(1);
    await tester.pump(kDragEdgeHoverDelayMax);

    expect(key.currentState!.currentPage, 2, reason: 'nothing to navigate to past the cap');
    expect(createdPages, isEmpty, reason: 'the cap must not be exceeded');

    key.currentState!.endDrag();
    await tester.pump(kDragEdgeHoverDelayMax);
  });
}

class HoverPageCreationHarness extends StatefulWidget {
  const HoverPageCreationHarness({
    super.key,
    this.initialPageCount = 1,
    this.maxPages = 5,
    required this.onPageCreated,
  });

  final int initialPageCount;
  final int maxPages;

  /// Fired with the new page's index whenever the harness creates one —
  /// stands in for `DashboardScreen._createNewPage`'s real
  /// `AppSettings.setDashboardPageCount` call.
  final ValueChanged<int> onPageCreated;

  @override
  State<HoverPageCreationHarness> createState() => HoverPageCreationHarnessState();
}

/// Mirrors `DashboardScreen`'s private `_EdgePagingPhase` — see that enum's
/// own doc for the full state machine.
enum _HarnessEdgePagingPhase { idle, hoveringEdge, creatingPage, creationCooldown, waitingEdgeExit }

class HoverPageCreationHarnessState extends State<HoverPageCreationHarness> {
  late final PageController _pageController;
  late int _pageCount;
  int _currentPage = 0;
  bool _dragging = false;
  Timer? _edgeHoverTimer;
  int? _edgeHoverDirection;
  _HarnessEdgePagingPhase _phase = _HarnessEdgePagingPhase.idle;

  /// Stands in for `DashboardScreen._dragReflowPreview` — a real value here
  /// (any non-null placeholder) means "the last pointer-movement-triggered
  /// candidate was accepted", mirroring how it's only ever recomputed in
  /// response to movement, never to a page switch on its own.
  Object? _reflowPreview;

  int get currentPage => _currentPage;
  int get pageCount => _pageCount;
  Object? get reflowPreview => _reflowPreview;

  void setReflowPreview(Object? value) => setState(() => _reflowPreview = value);

  @override
  void initState() {
    super.initState();
    _pageCount = widget.initialPageCount;
    _pageController = PageController(initialPage: _currentPage);
  }

  @override
  void dispose() {
    _edgeHoverTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _createNewPage() {
    setState(() => _pageCount += 1);
    widget.onPageCreated(_pageCount - 1);
  }

  void startDrag() => setState(() => _dragging = true);

  void jumpTo(int page) => setState(() => _currentPage = page);

  void endDrag() {
    setState(() => _dragging = false);
    _resetToIdle();
  }

  void _resetToIdle() {
    _edgeHoverTimer?.cancel();
    _edgeHoverTimer = null;
    _edgeHoverDirection = null;
    _phase = _HarnessEdgePagingPhase.idle;
  }

  /// Mirrors `DashboardScreen._handleDragGlobalPosition`'s state-machine
  /// dispatch, simplified to a direct direction input (`null` meaning the
  /// pointer isn't near either edge) rather than raw pointer geometry — the
  /// geometry itself (`dragEdgeHoverDirection`) already has its own
  /// dedicated tests in dashboard_layout_engine_test.dart.
  void holdAtEdge(int? direction) {
    switch (_phase) {
      case _HarnessEdgePagingPhase.idle:
        if (direction != null) _startHovering(direction);
      case _HarnessEdgePagingPhase.hoveringEdge:
        if (direction == null) {
          _resetToIdle();
        } else if (direction != _edgeHoverDirection) {
          _startHovering(direction);
        }
      case _HarnessEdgePagingPhase.creatingPage:
      case _HarnessEdgePagingPhase.creationCooldown:
        break; // Flatly ignored — see _EdgePagingPhase's own doc.
      case _HarnessEdgePagingPhase.waitingEdgeExit:
        if (direction == null) _resetToIdle();
    }
  }

  void _startHovering(int direction) {
    _edgeHoverTimer?.cancel();
    _edgeHoverDirection = direction;
    _phase = _HarnessEdgePagingPhase.hoveringEdge;
    _edgeHoverTimer = Timer(kDragEdgeHoverDelayMax, () => _hoverPageSwitch(direction));
  }

  /// Mirrors `DashboardScreen._hoverPageSwitch` exactly, except persistence
  /// (`AppSettings.setDashboardPageCount`/`setDashboardLastViewedPage`) is
  /// replaced by local state + [HoverPageCreationHarness.onPageCreated] —
  /// see the file doc for why. As in the real version, a freshly-created
  /// page only grows [_pageCount] here; the actual switch is deferred one
  /// frame via [_applyPageSwitch] so the new (empty) page gets a settled
  /// frame to build, and — critically — creating a page leaves the
  /// `hoveringEdge` cycle for [_enterCreationCooldown]'s lockout instead of
  /// re-arming, which is what stops a stationary hold from creating more
  /// than one page.
  void _hoverPageSwitch(int direction) {
    _edgeHoverTimer = null;
    if (!mounted || !_dragging || _phase != _HarnessEdgePagingPhase.hoveringEdge || _edgeHoverDirection != direction) {
      return;
    }
    var target = _currentPage + direction;
    if (target < 0) {
      _resetToIdle();
      return;
    }
    if (target >= _pageCount) {
      if (direction != 1 || _pageCount >= widget.maxPages) {
        _resetToIdle();
        return;
      }
      _phase = _HarnessEdgePagingPhase.creatingPage;
      target = _pageCount;
      _createNewPage();
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyPageSwitch(target, direction));
      _enterCreationCooldown();
      return;
    }
    _applyPageSwitch(target, direction);
    _edgeHoverTimer = Timer(kDragEdgeHoverDelayMax, () => _hoverPageSwitch(direction));
  }

  /// Mirrors `DashboardScreen._enterCreationCooldown`.
  void _enterCreationCooldown() {
    _phase = _HarnessEdgePagingPhase.creationCooldown;
    _edgeHoverTimer?.cancel();
    _edgeHoverTimer = Timer(kPageCreationCooldown, () {
      _edgeHoverTimer = null;
      if (!mounted || _phase != _HarnessEdgePagingPhase.creationCooldown) return;
      // The real DashboardScreen re-derives the pointer's *current* edge
      // direction fresh here (from _lastDragGlobalPosition, updated on
      // every call regardless of phase). The harness's equivalent is
      // _edgeHoverDirection — deliberately *not* cleared while
      // creationCooldown/waitingEdgeExit are busy ignoring holdAtEdge(null)
      // calls (see the switch above), so it still faithfully reflects
      // whatever the most recent holdAtEdge call reported, exactly like the
      // real implementation's independent position tracking does.
      if (_edgeHoverDirection == null) {
        _resetToIdle();
      } else {
        _phase = _HarnessEdgePagingPhase.waitingEdgeExit;
      }
    });
  }

  /// Mirrors `DashboardScreen._applyPageSwitch`.
  void _applyPageSwitch(int target, int direction) {
    if (!mounted || !_dragging || _edgeHoverDirection != direction) return;
    setState(() {
      _currentPage = target;
      // Regression coverage for a real bug found while building this
      // feature: left stale, a reflow preview accepted on the *old* page
      // would be wrongly treated as validated for the new one on release,
      // misplacing the dragged tile (and relocating unrelated widgets from
      // the old page onto the new one) instead of correctly falling back to
      // firstFit placement — see DashboardScreen._hoverPageSwitch.
      _reflowPreview = null;
    });
    _pageController.animateToPage(target, duration: kDashboardPageTransitionDuration, curve: kDashboardPageTransitionCurve);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: PageView.builder(
          controller: _pageController,
          allowImplicitScrolling: _dragging,
          itemCount: _pageCount,
          itemBuilder: (context, i) => Center(child: Text('page $i')),
        ),
      ),
    );
  }
}
