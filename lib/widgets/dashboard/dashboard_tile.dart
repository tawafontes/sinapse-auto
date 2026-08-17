import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../models/widget_size_bounds.dart';
import '../../services/dashboard_layout_engine.dart';

/// Governs how a *displaced* tile settles into its new position when
/// something else is dragged onto it (see
/// [_DashboardTileState._startReflowAnimation]) — never the tile actively
/// being dragged itself, which must keep tracking the finger directly, with
/// zero lag (a hard requirement carried across every earlier round of this
/// feature). A gentle, slightly underdamped spring: quick, with just a touch
/// of natural give, closer to how the Android launcher's own displaced icons
/// settle than a plain, mechanical ease-out. `stiffness` mostly governs
/// overall speed; `ratio` (a damping *ratio* — 1.0 is critically damped, no
/// overshoot; lower values overshoot slightly before settling) governs how
/// much of that natural "give" is visible — raise it toward 1.0 for a
/// calmer, more "serious" feel, or lower it for a springier one.
final SpringDescription kReflowSpring = SpringDescription.withDampingRatio(mass: 1, stiffness: 500, ratio: 0.82);

/// One dashboard tile, Android-home-screen style with cleanly independent
/// gestures (no gesture ever triggers another's action):
///  * Long-press enters edit mode ([onLongPress]) — [isEditing] then shows
///    resize handles on every edge/corner *and* arms the tile's drag
///    recognizer (see below). A tap anywhere at all — this tile, a
///    different one, or empty space (all handled by the parent) — ends edit
///    mode again; see [onTap]. Movement during the long-press hold is
///    impossible by construction: `LongPressGestureRecognizer` only wins
///    the gesture arena if the pointer stays within touch-slop for the full
///    hold, at which point the competing drag recognizer is already
///    rejected, so no post-accept movement can do anything — entering edit
///    mode itself never moves or resizes the tile.
///  * Tap ([onTap]) opens the tile's context menu — but only while nothing
///    dashboard-wide is being edited. While any tile is in edit mode, a tap
///    on this tile instead ends that edit session (the parent decides which
///    behavior [onTap] means; this widget has no opinion either way).
///  * Double-tap is recognized but intentionally does nothing (reserved).
///  * Drag moves the tile — but *only* while [isEditing] is true, matching
///    the Android home-screen model (select first via long-press, then
///    move, as a separate, subsequent gesture). When
///    [isEditing] is false, the tile's [ImmediateMultiDragGestureRecognizer]
///    (see [_DashboardTileState._onMoveDragStart]) is left out of the
///    [RawGestureDetector.gestures] map entirely in [build] — not merely
///    made to return null from `onStart` — because
///    `ImmediateMultiDragGestureRecognizer` claims its win in the gesture
///    arena purely from touch-slop displacement, *before* `onStart` is ever
///    called (see `_ImmediatePointerState.checkForResolutionAfterMove` in
///    the Flutter SDK); a registered-but-declining recognizer would still
///    steal the gesture from the dashboard's own page swipe even while
///    contributing no movement. Omitting the recognizer outright is what
///    makes "drag blocked outside edit mode" and "swipe works normally
///    outside edit mode" both true by construction. While editing, the drag
///    reliably wins over the dashboard's own page swipe even on a fast,
///    mostly-horizontal move, using the same recognizer `Draggable` uses
///    internally rather than a plain pan recognizer. Live-snaps to each
///    valid cell as it's dragged (the local [_liveRect]), consulting
///    [onMoveCandidate] (parent-computed reflow feasibility, see
///    `DashboardScreen`) instead of a local overlap check — dragging onto an
///    occupied cell relocates whatever's there rather than being rejected.
///    Dragging near either screen edge auto-switches pages, letting a widget
///    move across pages in one continuous gesture (see `DashboardScreen`'s
///    edge-hover handling). Committed once, on release ([onMoved]). For the
///    entire duration of a move (not resize), the tile's real visuals are
///    promoted into the app's [Overlay] — see
///    [_DashboardTileState._dragOverlayEntry] — completely decoupled from
///    whatever the Dashboard/PageView/Grid underneath is doing (reflowing
///    other tiles, switching pages, creating a brand new one mid-drag), so
///    none of that can ever move, flicker, or interrupt it.
///
/// This is a *controlled* widget: its displayed rect always comes from
/// [rect] (the parent's source of truth) except transiently mid-gesture.
/// Resize is different from move: dragging a handle only updates a separate
/// preview rect, reported upward via [onResizePreviewChanged] for the parent
/// to render as a ghost outline (a shrink/grow from a top/left handle can
/// extend outside this tile's own clipped box, so the parent — not this
/// widget — owns that overlay) — the tile's real rect, and [onResized], only
/// change once, on release. Resize keeps its own reject-on-overlap check
/// against [otherRects] (unlike move, resize does not reflow).
///
/// [alertColor] drives a card-wide blinking risk alert (border + translucent
/// overlay over the whole tile, header included) whenever non-null — set by
/// a sensor whose reading entered a risk zone (currently only the
/// artificial horizon). Null (the default) means no alert.
class DashboardTile extends StatefulWidget {
  const DashboardTile({
    super.key,
    required this.rect,
    required this.cellSize,
    required this.grid,
    required this.otherRects,
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.content,
    required this.onMoved,
    required this.onMoveStarted,
    required this.onMoveCandidate,
    required this.onMoveCancelled,
    required this.onDragPositionUpdate,
    required this.onResized,
    required this.isEditing,
    required this.onTap,
    required this.onLongPress,
    required this.onResizePreviewChanged,
    this.alertColor,
  });

  final CellRect rect;
  final Size cellSize;
  final GridDimensions grid;
  final List<CellRect> otherRects;
  final String label;
  final IconData icon;
  final Color accentColor;
  final Widget content;
  final ValueChanged<CellRect> onMoved;
  final ValueChanged<CellRect> onResized;
  final Color? alertColor;

  /// Whether this specific tile is the one currently in edit mode — at most
  /// one tile dashboard-wide at a time (owned by the parent).
  final bool isEditing;

  /// Fired on tap. What it should do is entirely up to the parent — see
  /// class doc: normally opens this tile's context menu, but while *any*
  /// tile dashboard-wide is being edited, the parent instead uses this to
  /// end that edit session, regardless of [isEditing] for this particular
  /// tile.
  final VoidCallback onTap;

  /// Fired when a long press is held — should enter edit mode (show resize
  /// handles) for this tile. Movement during the hold is impossible by
  /// construction (see class doc), so this never competes with a drag.
  final VoidCallback onLongPress;

  /// Fired once, the moment a move drag begins — before any candidate rect
  /// is ever proposed. Needed *in addition to* [onMoveCandidate]: a tile
  /// already sitting at its page's own edge can have every single candidate
  /// for an entire drag rejected before it ever fits the grid (e.g.
  /// dragging a rightmost-column tile further right, exactly the gesture
  /// that should push it onto the next page), in which case
  /// [onMoveCandidate] never fires at all — the parent still needs to know
  /// a drag is under way so edge-hover page-switching keeps working.
  final VoidCallback onMoveStarted;

  /// Queried on every drag update with a candidate rect (already validated
  /// to fit the grid) — the parent computes whether this position is
  /// achievable (relocating whatever it would overlap) and returns whether
  /// to accept it, caching the reflow preview as a side effect for
  /// rendering. Returning false leaves the tile at its last accepted
  /// position, exactly like a rejected candidate did before reflow existed.
  final bool Function(CellRect candidate) onMoveCandidate;

  /// Fired if an in-progress move drag is cancelled by the framework rather
  /// than released normally (see [Drag.cancel]) — e.g. the tile is removed
  /// from the tree mid-drag. Mirrors [onMoved] but abandons the gesture
  /// instead of committing a final rect.
  final VoidCallback onMoveCancelled;

  /// Fired on every move-drag update with the pointer's raw global position
  /// — unlike [onMoveCandidate] (a grid-cell candidate, which can stop
  /// changing once the tile is pinned against its page's own edge), this
  /// always reports where the finger actually is, so the parent can detect
  /// "held near the screen edge" and auto-switch pages while the drag
  /// continues.
  final ValueChanged<Offset> onDragPositionUpdate;

  /// Fired with the live proposed rect while dragging a resize handle, and
  /// with `null` once the gesture ends — the parent renders the ghost
  /// outline from this, since it can extend beyond this tile's own bounds.
  final ValueChanged<CellRect?> onResizePreviewChanged;

  @override
  State<DashboardTile> createState() => _DashboardTileState();
}

/// Which edge/corner of the tile a resize handle sits on and drags from —
/// each anchors the *opposite* corner/edge, so e.g. dragging `topLeft` keeps
/// the bottom-right corner fixed while `x`/`y`/`width`/`height` all move.
enum _ResizeHandlePosition { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

class _DashboardTileState extends State<DashboardTile> with SingleTickerProviderStateMixin {
  static const _alertBlinkInterval = Duration(milliseconds: 500);
  static const _handleSize = 16.0;

  static const _handleTapTarget = kResizeHandleOverhang * 2;

  CellRect? _liveRect;
  CellRect? _resizePreviewRect;
  Offset? _gestureStartFocal;
  CellRect? _gestureStartRect;
  Timer? _alertBlinkTimer;
  bool _alertBlinkOn = true;

  /// Whether a move drag is currently in progress — drives the same
  /// highlight [isEditing] gets. Can now only ever be true while [isEditing]
  /// is also true (drag is gated on it, see [build]), but is kept as its own
  /// flag rather than collapsed into `widget.isEditing` since it specifically
  /// marks the sub-interval of an edit session where the finger is actually
  /// down and moving the tile. Also gates which of [build] / [_buildDragOverlay]
  /// renders the tile's real visual body — see [_insertDragOverlay].
  bool _isDragging = false;

  /// The floating avatar shown in the app's [Overlay] for the entire
  /// duration of a move drag — present iff [_isDragging]. Promoting the
  /// dragged tile's actual visuals here, completely outside the
  /// Dashboard/PageView/Grid subtree, is what makes it immune to *any*
  /// rebuild happening underneath (a displaced tile reflowing, a page
  /// switch, a brand new page being created mid-drag): none of those can
  /// ever move, flicker, or rebuild something that isn't their descendant.
  /// [build] keeps rendering the [RawGestureDetector] that actually owns the
  /// gesture in its usual place the entire time (a `Drag` object's
  /// `update`/`end`/`cancel` calls are routed directly to whichever
  /// recognizer's `State` claimed the pointer, independent of hit-testing or
  /// layout — moving/hiding it doesn't drop the gesture) — it just paints
  /// nothing of its own while this is up.
  OverlayEntry? _dragOverlayEntry;

  /// The tile's on-screen top-left, in the [Overlay]'s own coordinate space,
  /// captured once at drag-start (see [_insertDragOverlay]) — combined with
  /// the cell delta between [_gestureStartRect] and [_currentRect] on every
  /// update, this is what positions [_dragOverlayEntry] without ever needing
  /// to know (or care) which page is technically underneath.
  Offset? _dragOverlayOrigin;

  /// The tile's on-screen size, captured once at drag-start alongside
  /// [_dragOverlayOrigin] — stays constant for the rest of the drag (a move,
  /// unlike a resize, never changes the tile's width/height).
  Size? _dragOverlaySize;

  /// Stable identity for [_buildVisualBody]'s subtree — which, crucially,
  /// contains [widget.content] (the live sensor widget, with its own Stream
  /// subscriptions) — shared by [build] and [_buildDragOverlay], which never
  /// render it at the same time (gated by [_isDragging] either way) but do
  /// so from two entirely different parents (in place vs. inside the
  /// [Overlay]). Without this, moving from one to the other would look to
  /// Flutter like "an old, key-less subtree gone, an unrelated new one
  /// appeared" rather than "the same subtree, relocated" — silently
  /// disposing [widget.content]'s State (dropping any Stream subscription it
  /// held, and any history it accumulated, e.g. the g-force meter's trail)
  /// while an *independent* new instance mounts alongside it and attempts
  /// its own subscription — a real, confirmed double-listen on whatever
  /// Stream [widget.content] happens to hold, since the two builds can run
  /// before [DashboardTile] itself has been reconciled with fresh props.
  /// Wrapping it in a [KeyedSubtree] keyed by this instead makes Flutter
  /// *reparent* the one, already-live Element — same technique already used
  /// to keep this tile's own gesture alive across its own reparenting.
  final GlobalKey _visualBodyKey = GlobalKey(debugLabel: 'DashboardTile visual body');

  /// Drives the spring-physics settle whenever this tile is *displaced* by
  /// someone else's drag (never by its own — see [_startReflowAnimation]).
  /// [_reflowFromRect]/[_reflowToRect] are the two rects it's currently
  /// interpolating between (in cell units — the actual pixel interpolation
  /// happens in [_displayPixelRect]); both null whenever nothing is settling,
  /// which is also what [_displayPixelRect] uses to know to fall back to
  /// [_currentRect] directly.
  late final AnimationController _reflowController;
  CellRect? _reflowFromRect;
  CellRect? _reflowToRect;

  /// Set for exactly one [didUpdateWidget] call, right after [_commitMove]/
  /// [_cancelMove] flips [_isDragging] back off — see that guard's own doc
  /// for why the very next `widget.rect` change must *not* trigger
  /// [_startReflowAnimation] even though it looks, superficially, like any
  /// other reposition.
  bool _justFinishedDragging = false;

  @override
  void initState() {
    super.initState();
    _reflowController = AnimationController(vsync: this)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _syncAlertBlinkTimer();
  }

  @override
  void didUpdateWidget(covariant DashboardTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.alertColor != null) != (widget.alertColor != null)) {
      _syncAlertBlinkTimer();
    }
    // Edit mode can end (parent taps empty space) via a *second* pointer
    // while a first one is still mid-drag on this tile — rare, but physically
    // possible. When that happens, the rebuild below removes this tile's
    // ImmediateMultiDragGestureRecognizer from the gestures map entirely
    // (see build's isEditing-gated `gestures` map), which disposes the
    // recognizer's per-pointer state without ever calling the in-flight
    // Drag's own cancel()/end() — so without this, the tile and the parent
    // would be left stuck thinking a drag is still in progress. Reuses
    // _cancelMove exactly as a real Drag.cancel() would, so cleanup is
    // identical either way.
    if (oldWidget.isEditing && !widget.isEditing && _isDragging) {
      _cancelMove();
    }
    // A *displaced* tile's rect changing — reflow relocating it, or a
    // cancelled drag springing preview-displaced tiles back — settles with
    // real spring physics instead of teleporting; see kReflowSpring's own
    // doc for why this never applies to the tile actually being dragged
    // (_isDragging is checked, not just "isn't this widget's own drag" —
    // it's the literal precision-tracking guard the whole feature depends
    // on), and _justFinishedDragging's doc for the one specific case where
    // oldWidget.rect != widget.rect must *still* be skipped.
    if (_justFinishedDragging) {
      _justFinishedDragging = false;
    } else if (!_isDragging && oldWidget.rect != widget.rect) {
      _startReflowAnimation(from: oldWidget.rect, to: widget.rect);
    }
  }

  /// Kicks off (or redirects, if one was already under way) the spring
  /// settle from [from] to [to] — see [kReflowSpring] and [_displayPixelRect].
  void _startReflowAnimation({required CellRect from, required CellRect to}) {
    _reflowFromRect = from;
    _reflowToRect = to;
    _reflowController
      ..stop()
      ..value = 0
      ..animateWith(SpringSimulation(kReflowSpring, 0, 1, 0));
  }

  Rect _pixelRectFor(CellRect r) => Rect.fromLTWH(
    r.x * widget.cellSize.width,
    r.y * widget.cellSize.height,
    r.width * widget.cellSize.width,
    r.height * widget.cellSize.height,
  );

  /// The pixel rect actually painted by [build]'s `Positioned` — mid-spring
  /// interpolation between [_reflowFromRect] and [_reflowToRect] while
  /// [_reflowController] is running, otherwise just [_currentRect] converted
  /// to pixels directly. Never consulted for the drag avatar
  /// ([_buildDragOverlay]), which always tracks [_currentRect] with zero
  /// lag, spring or otherwise.
  Rect get _displayPixelRect {
    final from = _reflowFromRect;
    final to = _reflowToRect;
    if (from != null && to != null && _reflowController.isAnimating) {
      return Rect.lerp(_pixelRectFor(from), _pixelRectFor(to), _reflowController.value)!;
    }
    return _pixelRectFor(_currentRect);
  }

  void _syncAlertBlinkTimer() {
    final alerting = widget.alertColor != null;
    if (alerting && _alertBlinkTimer == null) {
      _alertBlinkOn = true;
      _alertBlinkTimer = Timer.periodic(_alertBlinkInterval, (_) {
        if (!mounted) return;
        setState(() => _alertBlinkOn = !_alertBlinkOn);
        // setState above only schedules *this* State's own subtree to
        // rebuild — the Overlay entry is a separate subtree the framework
        // won't touch on its own, so a tile that starts alerting mid-drag
        // needs telling explicitly, or its avatar would stop blinking.
        _dragOverlayEntry?.markNeedsBuild();
      });
    } else if (!alerting && _alertBlinkTimer != null) {
      _alertBlinkTimer!.cancel();
      _alertBlinkTimer = null;
      _alertBlinkOn = true;
    }
  }

  @override
  void dispose() {
    _alertBlinkTimer?.cancel();
    _dragOverlayEntry?.remove();
    _reflowController.dispose();
    super.dispose();
  }

  CellRect get _currentRect => _liveRect ?? widget.rect;

  SizeBounds get _bounds => universalBounds(widget.grid);

  bool _proposeIfValid(CellRect proposed) {
    if (proposed == _currentRect) return false;
    if (!proposed.fitsWithin(widget.grid)) return false;
    if (!widget.onMoveCandidate(proposed)) return false;
    setState(() => _liveRect = proposed);
    // Same reasoning as the blink timer above: the avatar is a separate
    // subtree from this State, so moving it needs its own explicit nudge.
    _dragOverlayEntry?.markNeedsBuild();
    // The magnetic snap into a new cell — the lightest tick Flutter offers,
    // since this can fire many times over a single drag and must never read
    // as a buzz.
    HapticFeedback.selectionClick();
    return true;
  }

  /// Starts a move drag — backed by [ImmediateMultiDragGestureRecognizer]
  /// rather than a plain `onPanStart`/pan recognizer (see the outer
  /// [RawGestureDetector] in [build]): a bare `PanGestureRecognizer` needs
  /// [kPanSlop] (36px, omnidirectional) of movement to self-accept, while
  /// [PageView]'s own horizontal-swipe recognizer only needs [kTouchSlop]
  /// (18px) — on a mostly-horizontal drag, the page's swipe can reach its
  /// threshold first and win the gesture arena before the tile ever gets a
  /// chance to move. `ImmediateMultiDragGestureRecognizer` uses the same
  /// 18px threshold as the page's own recognizer, and — per its own
  /// documentation — being the more specific (deeper) widget, reliably
  /// out-competes an ancestor `Scrollable` for the win. Returns a [Drag]
  /// whose `update`/`end`/`cancel` the framework calls for the rest of the
  /// gesture, exactly like `Draggable` does internally.
  Drag _onMoveDragStart(Offset position) {
    // Guarantees _currentRect (not a stale mid-spring position) drives this
    // tile from here on — relevant if it was itself still settling from
    // being displaced by a *different* drag when this one picked it up.
    _reflowController.stop();
    _reflowFromRect = null;
    _reflowToRect = null;
    _gestureStartFocal = position;
    _gestureStartRect = _currentRect;
    setState(() => _isDragging = true);
    widget.onMoveStarted();
    _insertDragOverlay();
    return _TileMoveDrag(onUpdate: _onMoveDragUpdate, onEnd: _commitMove, onCancel: _cancelMove);
  }

  /// Promotes the tile's visuals into the app's [Overlay] for the rest of
  /// the drag — see [_dragOverlayEntry]'s doc for why. Must run before
  /// anything else has a chance to rebuild in response to [widget.onMoveStarted]
  /// (already called by the time this runs): [context] still refers to this
  /// tile at its real, currently-on-screen position (nothing has moved or
  /// been reparented yet), which is exactly what's needed to capture
  /// [_dragOverlayOrigin] correctly.
  void _insertDragOverlay() {
    final overlayState = Overlay.of(context);
    final tileBox = context.findRenderObject()! as RenderBox;
    final overlayBox = overlayState.context.findRenderObject()! as RenderBox;
    _dragOverlayOrigin = overlayBox.globalToLocal(tileBox.localToGlobal(Offset.zero));
    _dragOverlaySize = tileBox.size;
    _dragOverlayEntry = OverlayEntry(builder: _buildDragOverlay);
    overlayState.insert(_dragOverlayEntry!);
  }

  /// Tears down [_dragOverlayEntry]. Usually synchronous — [OverlayEntry.remove]
  /// schedules the rebuild that actually drops its widget from the tree via
  /// a plain `setState`, same as any other, applying on the very next frame
  /// alongside [build] reverting to [_visualBodyKey]'s in-place
  /// `KeyedSubtree`. But when called *mid-build*
  /// (`SchedulerPhase.persistentCallbacks` — e.g. from [didUpdateWidget]'s
  /// guard below, itself invoked while an ancestor is rebuilding), the
  /// Flutter SDK's own `OverlayState._remove` defers that same rebuild to a
  /// post-frame callback instead — racing that against reverting to the
  /// in-place `KeyedSubtree` in the very same frame would leave *two*
  /// widgets bearing that GlobalKey alive at once (the avatar's stale,
  /// not-yet-actually-removed copy, and the freshly revealed in-place one),
  /// a hard Flutter assertion failure confirmed directly against this exact
  /// scenario. Mirroring that same conditional deferral here for our own
  /// local field is what keeps the two strictly sequenced instead of racing,
  /// only in the rare case that actually needs it — the overwhelmingly more
  /// common release-a-drag-normally path (never mid-build) stays fully
  /// synchronous, exactly as before.
  void _removeDragOverlay() {
    final entry = _dragOverlayEntry;
    if (entry == null) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        entry.remove();
        // Only clear the field if it's still *this* entry — guards the
        // (extremely tight, but not impossible) case of a brand new drag
        // starting, and inserting its own new entry, within the same single
        // frame this callback was waiting out.
        if (mounted && identical(_dragOverlayEntry, entry)) {
          setState(() => _dragOverlayEntry = null);
        }
      });
    } else {
      entry.remove();
      _dragOverlayEntry = null;
    }
    _dragOverlayOrigin = null;
    _dragOverlaySize = null;
  }

  /// The avatar's content — same border/header/live-content as the normal
  /// in-place tile (see [_buildVisualBody]), positioned by translating
  /// [_dragOverlayOrigin] by the cell delta travelled since the drag began.
  /// Cell-based (not raw-pixel) on purpose: it mirrors exactly how
  /// [_currentRect] itself already snaps to cells (see [_proposeIfValid]),
  /// so the avatar's motion matches what the tile would show if it were
  /// still rendering in place, just relocated. [IgnorePointer] keeps it from
  /// ever intercepting a touch — it's purely a visual stand-in; the real
  /// gesture is still owned by the [RawGestureDetector] in [build].
  Widget _buildDragOverlay(BuildContext context) {
    final origin = _dragOverlayOrigin!;
    final start = _gestureStartRect!;
    final current = _currentRect;
    final offset =
        origin +
        Offset(
          (current.x - start.x) * widget.cellSize.width,
          (current.y - start.y) * widget.cellSize.height,
        );
    final style = _borderStyle();
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      width: _dragOverlaySize!.width,
      height: _dragOverlaySize!.height,
      child: IgnorePointer(
        child: KeyedSubtree(key: _visualBodyKey, child: _buildVisualBody(style)),
      ),
    );
  }

  /// Proposes a new [_liveRect] one cell-delta away from [_gestureStartRect],
  /// toward [globalPosition] (see [_proposeIfValid] for acceptance rules —
  /// grid bounds + the parent's reflow feasibility check), and unconditionally
  /// reports the raw [globalPosition] upward — unlike the cell candidate,
  /// which can stop advancing once the tile is pinned against its page's own
  /// edge, this always reflects where the finger actually is, so the parent
  /// can detect a hold near the screen edge and auto-switch pages.
  void _onMoveDragUpdate(Offset globalPosition) {
    final start = _gestureStartFocal;
    final startRect = _gestureStartRect;
    if (start != null && startRect != null) {
      final delta = globalPosition - start;
      final cellDx = (delta.dx / widget.cellSize.width).round();
      final cellDy = (delta.dy / widget.cellSize.height).round();
      _proposeIfValid((
        x: startRect.x + cellDx,
        y: startRect.y + cellDy,
        width: startRect.width,
        height: startRect.height,
      ));
    }
    widget.onDragPositionUpdate(globalPosition);
  }

  /// Commits whatever [_liveRect] currently holds as the tile's real rect.
  void _commitMove() {
    setState(() => _isDragging = false);
    // The very next widget.rect this tile receives from its parent will just
    // be catching up to a position it was already visually showing the
    // whole time (tracked live via _liveRect / the Overlay avatar, never
    // through this prop) — see this flag's own doc for why that must not
    // read as a reposition to spring-animate.
    _justFinishedDragging = true;
    _gestureStartFocal = null;
    _gestureStartRect = null;
    final finalRect = _currentRect;
    setState(() => _liveRect = null);
    _removeDragOverlay();
    // A deliberately light confirmation that the move landed — distinct
    // from the per-cell snap tick during the drag itself, but still nowhere
    // near a sustained buzz.
    HapticFeedback.lightImpact();
    widget.onMoved(finalRect);
  }

  /// Abandons an in-progress move without committing — see [Drag.cancel] and
  /// [DashboardTile.onMoveCancelled].
  void _cancelMove() {
    setState(() {
      _isDragging = false;
      _liveRect = null;
    });
    _justFinishedDragging = true;
    _gestureStartFocal = null;
    _gestureStartRect = null;
    _removeDragOverlay();
    widget.onMoveCancelled();
  }

  /// Computes the candidate rect for dragging [handle] by ([cellDx], [cellDy])
  /// cells from [start] — clamps width/height to [_bounds] *before* deriving
  /// x/y, so the anchored corner/edge doesn't drift once a limit is hit.
  CellRect _candidateRect(_ResizeHandlePosition handle, CellRect start, int cellDx, int cellDy) {
    const left = {_ResizeHandlePosition.topLeft, _ResizeHandlePosition.left, _ResizeHandlePosition.bottomLeft};
    const right = {_ResizeHandlePosition.topRight, _ResizeHandlePosition.right, _ResizeHandlePosition.bottomRight};
    const top = {_ResizeHandlePosition.topLeft, _ResizeHandlePosition.top, _ResizeHandlePosition.topRight};
    const bottom = {_ResizeHandlePosition.bottomLeft, _ResizeHandlePosition.bottom, _ResizeHandlePosition.bottomRight};

    var width = start.width;
    if (left.contains(handle)) width -= cellDx;
    if (right.contains(handle)) width += cellDx;
    var height = start.height;
    if (top.contains(handle)) height -= cellDy;
    if (bottom.contains(handle)) height += cellDy;

    final bounds = _bounds;
    width = width.clamp(bounds.minWidth, bounds.maxWidth);
    height = height.clamp(bounds.minHeight, bounds.maxHeight);

    final x = left.contains(handle) ? (start.x + start.width) - width : start.x;
    final y = top.contains(handle) ? (start.y + start.height) - height : start.y;

    return (x: x, y: y, width: width, height: height);
  }

  void _proposeResizePreview(CellRect candidate) {
    if (candidate == _resizePreviewRect) return;
    if (!candidate.fitsWithin(widget.grid)) return;
    if (widget.otherRects.any((r) => r.overlaps(candidate))) return;
    setState(() => _resizePreviewRect = candidate);
    widget.onResizePreviewChanged(candidate);
  }

  void _onHandlePanStart(_ResizeHandlePosition handle, DragStartDetails details) {
    _gestureStartFocal = details.globalPosition;
    _gestureStartRect = widget.rect;
    setState(() => _resizePreviewRect = widget.rect);
  }

  void _onHandlePanUpdate(_ResizeHandlePosition handle, DragUpdateDetails details) {
    final start = _gestureStartFocal;
    final startRect = _gestureStartRect;
    if (start == null || startRect == null) return;

    final delta = details.globalPosition - start;
    final cellDx = (delta.dx / widget.cellSize.width).round();
    final cellDy = (delta.dy / widget.cellSize.height).round();
    _proposeResizePreview(_candidateRect(handle, startRect, cellDx, cellDy));
  }

  void _onHandlePanEnd(DragEndDetails details) {
    _gestureStartFocal = null;
    _gestureStartRect = null;
    final preview = _resizePreviewRect;
    setState(() => _resizePreviewRect = null);
    widget.onResizePreviewChanged(null);
    if (preview != null && preview != widget.rect) {
      widget.onResized(preview);
    }
  }

  /// Border color/width/alert-overlay-visibility — the only parts of
  /// [_buildVisualBody] that vary by state — computed once here so [build]
  /// and [_buildDragOverlay] (the in-place tile and the drag avatar, which
  /// are never both on screen at once, but are built from two entirely
  /// separate call sites) stay identical without duplicating the logic.
  ({Color color, double width, bool showAlert}) _borderStyle() {
    final colorScheme = Theme.of(context).colorScheme;
    final alertColor = widget.alertColor;
    final showAlert = alertColor != null && _alertBlinkOn;
    final highlighted = widget.isEditing || _isDragging;
    final color = showAlert
        ? alertColor
        : (highlighted ? colorScheme.secondary : widget.accentColor.withValues(alpha: 0.7));
    final width = showAlert ? 3.0 : (highlighted ? 2.5 : 1.5);
    return (color: color, width: width, showAlert: showAlert);
  }

  /// The tile's actual visuals — border, header (icon + label), live sensor
  /// [widget.content], and the blinking alert overlay — shared verbatim by
  /// [build] (rendered in place, whenever this tile isn't being drag-moved)
  /// and [_buildDragOverlay] (rendered in the [Overlay] instead, for exactly
  /// the duration it is).
  Widget _buildVisualBody(({Color color, double width, bool showAlert}) style) {
    return Container(
      key: const ValueKey('dashboardTileVisualBody'),
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: style.color, width: style.width),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                color: widget.accentColor.withValues(alpha: 0.12),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 14, color: widget.accentColor),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.label,
                        style: Theme.of(context).textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: Padding(padding: const EdgeInsets.all(4), child: widget.content)),
            ],
          ),
          // Card-wide risk alert overlay: covers header + content (the
          // border above already handles the card's edge), toggled by
          // _alertBlinkOn so it blinks in sync with the border.
          if (style.showAlert)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  key: const ValueKey('dashboardTileAlertOverlay'),
                  color: widget.alertColor!.withValues(alpha: 0.18),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // _displayPixelRect (not _currentRect directly) is what lets a
    // *displaced* tile slide into place via kReflowSpring instead of
    // teleporting — see that getter's doc. Never affects the actively
    // dragged tile itself, which _startReflowAnimation is never triggered
    // for in the first place.
    final displayRect = _displayPixelRect;
    final colorScheme = Theme.of(context).colorScheme;
    // True for the drag itself, and for the one extra settled frame after it
    // ends while _removeDragOverlay's deferred teardown is still pending
    // (see that method's doc) — not just _isDragging alone: revealing
    // _visualBodyKey's KeyedSubtree here before the avatar's own copy has
    // actually been detached from the Overlay would briefly leave two
    // widgets bearing the same GlobalKey alive at once.
    final visualBodySuppressed = _isDragging || _dragOverlayEntry != null;

    return Positioned(
      left: displayRect.left,
      top: displayRect.top,
      width: displayRect.width,
      height: displayRect.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          RawGestureDetector(
            // Transparent — instead of the normal opaque hit-test footprint
            // — for exactly the span of a move drag (plus the same trailing
            // settled frame [visualBodySuppressed] covers): this tile's
            // on-screen rect here is a stale, no-longer-meaningful position
            // (the real one lives in the Overlay, see _buildDragOverlay), so
            // it must not shadow whatever's actually visible underneath from
            // a second, unrelated touch. Doesn't affect the drag already in
            // progress either way — a Drag object's update/end/cancel calls
            // are routed directly to whichever recognizer claimed the
            // pointer, never by re-hit-testing.
            behavior: visualBodySuppressed ? HitTestBehavior.deferToChild : HitTestBehavior.opaque,
            gestures: {
              TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (instance) => instance.onTap = widget.onTap,
              ),
              DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                DoubleTapGestureRecognizer.new,
                // Recognized so a double-tap doesn't also fire onTap; intentionally inert (reserved).
                (instance) => instance.onDoubleTap = () {},
              ),
              LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                LongPressGestureRecognizer.new,
                (instance) => instance.onLongPress = widget.onLongPress,
              ),
              // Only present while editing — see the class doc for why this
              // must be an *absent* map entry (not a recognizer that's
              // present but declines via a null onStart): a registered
              // ImmediateMultiDragGestureRecognizer claims the gesture arena
              // win from touch-slop displacement alone, before onStart is
              // ever consulted, which would still steal the gesture from the
              // dashboard's own page swipe even while doing nothing with it.
              if (widget.isEditing)
                ImmediateMultiDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
                      ImmediateMultiDragGestureRecognizer.new,
                      (instance) => instance.onStart = _onMoveDragStart,
                    ),
            },
            // While a move drag is in progress, the real visuals live in the
            // Overlay instead (see _dragOverlayEntry's doc) — this stays
            // mounted with nothing to paint of its own, purely to keep the
            // gesture (and its State) alive right where it's always been.
            // _visualBodyKey is what lets that visual body's own Element —
            // widget.content (the live sensor widget) included — move to and
            // from the Overlay without ever being disposed and recreated.
            child: visualBodySuppressed
                ? const SizedBox.shrink()
                : KeyedSubtree(key: _visualBodyKey, child: _buildVisualBody(_borderStyle())),
          ),
          if (widget.isEditing && !_isDragging) ..._buildResizeHandles(colorScheme),
        ],
      ),
    );
  }

  List<Widget> _buildResizeHandles(ColorScheme colorScheme) {
    Widget dot() => Container(
      width: _handleSize,
      height: _handleSize,
      decoration: BoxDecoration(
        color: colorScheme.secondary,
        shape: BoxShape.circle,
        border: Border.all(color: colorScheme.onSecondary, width: 1.5),
      ),
    );

    Widget handle(_ResizeHandlePosition position) => GestureDetector(
      key: ValueKey('resizeHandle_${position.name}'),
      onPanStart: (d) => _onHandlePanStart(position, d),
      onPanUpdate: (d) => _onHandlePanUpdate(position, d),
      onPanEnd: _onHandlePanEnd,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(width: _handleTapTarget, height: _handleTapTarget, child: Center(child: dot())),
    );

    const half = _handleTapTarget / 2;
    return [
      Positioned(left: -half, top: -half, child: handle(_ResizeHandlePosition.topLeft)),
      Positioned(top: -half, left: 0, right: 0, child: Center(child: handle(_ResizeHandlePosition.top))),
      Positioned(right: -half, top: -half, child: handle(_ResizeHandlePosition.topRight)),
      Positioned(right: -half, top: 0, bottom: 0, child: Center(child: handle(_ResizeHandlePosition.right))),
      Positioned(right: -half, bottom: -half, child: handle(_ResizeHandlePosition.bottomRight)),
      Positioned(bottom: -half, left: 0, right: 0, child: Center(child: handle(_ResizeHandlePosition.bottom))),
      Positioned(left: -half, bottom: -half, child: handle(_ResizeHandlePosition.bottomLeft)),
      Positioned(left: -half, top: 0, bottom: 0, child: Center(child: handle(_ResizeHandlePosition.left))),
    ];
  }
}

/// The [Drag] returned by [_DashboardTileState._onMoveDragStart] — plain
/// callback forwarding, the same shape `Draggable` uses internally to bridge
/// [ImmediateMultiDragGestureRecognizer]'s callback-object API to ordinary
/// instance methods.
class _TileMoveDrag extends Drag {
  _TileMoveDrag({required this.onUpdate, required this.onEnd, required this.onCancel});

  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;

  @override
  void update(DragUpdateDetails details) => onUpdate(details.globalPosition);

  @override
  void end(DragEndDetails details) => onEnd();

  @override
  void cancel() => onCancel();
}
