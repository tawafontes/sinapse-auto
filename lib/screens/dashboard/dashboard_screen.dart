import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../models/alert_event.dart';
import '../../models/alert_type.dart';
import '../../models/color_palette_metadata.dart';
import '../../models/detected_event.dart';
import '../../models/display_style_metadata.dart';
import '../../models/sensor_type_metadata.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/alert_preferences.dart';
import '../../services/app_settings.dart';
import '../../services/dashboard_layout_engine.dart';
import '../../services/dashboard_maintenance_service.dart';
import '../../services/driving_session_host.dart';
import '../../services/sensor_widget_repository.dart';
import '../../services/theme_controller.dart';
import '../../widgets/dashboard/dashboard_tile.dart';
import '../../widgets/dashboard/dashboard_tile_context_menu.dart';
import '../../widgets/dashboard/page_indicator_dots.dart';
import '../../widgets/dashboard/page_manager_sheet.dart';
import '../../widgets/dashboard/resize_ghost_overlay.dart';
import '../../widgets/dashcam/dashcam_preview_view.dart';
import '../../widgets/dashcam/dashcam_rec_indicator.dart';
import '../../widgets/sensors/sensor_widget_factory.dart';
import '../onboarding/sensor_selection_screen.dart';
import '../settings/settings_menu_screen.dart';
import 'sensor_fullscreen_screen.dart';
import 'single_sensor_style_screen.dart';

/// How close to a screen edge (logical pixels) a dragged tile's pointer must
/// be for [_DashboardScreenState._handleDragGlobalPosition] to start the
/// hover-to-switch-page timer — tune to make the edge zone wider/narrower.
const double kDragEdgeHoverZoneWidth = 56.0;

/// The auto-scroll delay's range — [_DashboardScreenState._hoverDelayFor]
/// interpolates between the two based on [dragEdgeHoverProximity], so
/// holding right at the physical screen edge switches pages far sooner than
/// merely grazing the outer boundary of [kDragEdgeHoverZoneWidth], instead of
/// a single fixed wait regardless of exactly where in the zone the pointer
/// sits — matching the Android launcher's own graduated auto-scroll speed.
/// [kDragEdgeHoverDelayMax] intentionally matches the previous single fixed
/// delay, so a pointer that's only just entered the zone feels unchanged.
const Duration kDragEdgeHoverDelayMax = Duration(milliseconds: 600);
const Duration kDragEdgeHoverDelayMin = Duration(milliseconds: 200);

/// The minimum time [_EdgePagingPhase.creationCooldown] blocks a further
/// page creation for, after one just happened — a floor, not the primary
/// gate: returning to [_EdgePagingPhase.idle] (where a *new* creation
/// becomes possible again) additionally always requires the pointer to have
/// actually left [kDragEdgeHoverZoneWidth] at least once — see that enum's
/// own doc for why both together are what reproduces the Android launcher's
/// "one creation per deliberate approach" behavior.
const Duration kPageCreationCooldown = Duration(milliseconds: 700);

/// How far, as a fraction of the viewport, the next/previous page is allowed
/// to peek into view while a drag hovers near a screen edge (see
/// [_DashboardScreenState._updatePagePeek]) — purely a visual hint that
/// there's continuity beyond the edge, never large enough to cross
/// `PageView`'s own page-rounding threshold (0.5) and risk firing a spurious
/// `onPageChanged`.
const double kPagePeekMaxFraction = 0.10;

/// Motion spec for [_DashboardScreenState._updatePagePeek] snapping back to
/// the current page's resting position once a hover ends without completing
/// a page switch (a real switch instead uses [kDashboardPageTransitionCurve]
/// / [kDashboardPageTransitionDuration], picking up smoothly from wherever
/// the peek left off).
const Duration kPagePeekReleaseDuration = Duration(milliseconds: 220);
const Curve kPagePeekReleaseCurve = Curves.easeOutCubic;

/// Opacity multiplier applied to the grid lines' normal color while a tile is
/// actively being dragged (see [_GridLinesPainter]) — a deliberately subtle
/// lift, just enough to read as "these are the valid drop positions" without
/// competing visually with the tiles themselves.
const double kDragActiveGridOpacityBoost = 2.2;
const Duration kDragActiveGridFadeDuration = Duration(milliseconds: 180);

/// Curve and duration shared by every programmatic page transition —
/// edge-hover auto-switch (including past-the-last-page auto-creation, see
/// [_DashboardScreenState._hoverPageSwitch]) and manual navigation from the
/// page manager (see [_DashboardScreenState._navigateToPage]) — one motion
/// spec so a page glides the same way no matter what triggered it.
/// `fastOutSlowIn` is Flutter's name for Material's "standard" easing
/// (accelerate quickly, decelerate gently into place) — the same curve
/// Android's own system UI uses for this kind of page-settle motion, chosen
/// over the previous plain [Curves.easeInOut], whose symmetric ease-in/out
/// read as slightly mechanical by comparison.
const Curve kDashboardPageTransitionCurve = Curves.fastOutSlowIn;
const Duration kDashboardPageTransitionDuration = Duration(milliseconds: 250);

/// The real dashboard: up to 5 swipeable pages, each a fixed-cell grid (6x4
/// landscape, 4x6 portrait), autosaved to Hive on every change. Values are
/// shown post-smoothing (see `DashboardSensorStreams`). The "+" button opens
/// [SensorSelectionScreen] to add tools; the gear icon opens
/// [SettingsMenuScreen] for theme.
///
/// Long-pressing a tile enters edit mode (resize handles) — Android
/// home-screen style: hold to select, then act. Tapping a tile opens its
/// context menu ([_showContextMenu]) — but only when nothing is being
/// edited; while any tile is in edit mode, a tap anywhere at all (this tile,
/// a different one, or empty space) instead ends the edit session
/// immediately ([_exitEditMode]), same as tapping empty space already did.
/// Double-tap does nothing (reserved). Drag only moves a tile *while it's
/// the one in edit mode* — select first (long-press), then move — within a page
/// (relocating/reflowing whatever it's dragged onto rather than being
/// blocked by it) or across pages (holding the tile near a screen edge
/// auto-switches pages, see [_handleDragGlobalPosition]) — holding it past
/// the right edge of the *last* page instead creates a brand new one and
/// switches to it, Android-home-screen style, up to [_maxPages] (see
/// [_hoverPageSwitch] and [_createNewPage]). See [DashboardTile] and
/// [resolveDragReflow]. At most one tile is ever in edit
/// mode at a time, tracked here as [_editingConfig]; while it's non-null,
/// the page's own swipe is completely disabled (`PageView.physics` below) —
/// the only way to change pages during an edit session is the drag's own
/// edge-hover auto-navigation. A drag that starts on the edited tile always
/// wins over the page's own swipe, even on a fast, mostly-horizontal move —
/// by construction, via [DashboardTile]'s own
/// `ImmediateMultiDragGestureRecognizer`-based move handling, which is only
/// even registered while editing (see that class's doc). Swipe is restored
/// the instant edit mode ends. Long-pressing empty dashboard space instead
/// opens the page manager (add/delete/navigate pages) — see
/// [showPageManagerSheet]. For the entire duration of a move, the dragged
/// tile is rendered once, as a page-independent sibling of the `PageView`
/// itself (see [_draggingConfig] and [_buildDashboardTile]) rather than as
/// part of whichever page's grid — combined with [DashboardTile] promoting
/// its own visuals into the app's `Overlay` for that same span, this is what
/// keeps it completely unaffected by any rebuild happening underneath
/// (reflow, a page switch, even a brand new page being created mid-drag).
///
/// Fase 16.2-R4.3-R2.6.8: this screen owns no session object. The sensor
/// pipeline, the driving session, the event/alert engines and the dashcam
/// belong to the app's [DrivingSessionHost] (read from [DrivingSessionScope]);
/// this screen renders them and forwards the user's intents. It is replaced
/// by a new instance in normal use (Tema → Concluir, "+" → Continuar), and the
/// new one is mounted while the old one is still on screen (~30 frames) — so
/// nothing a session depends on may start or end with it.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.preferredPage});

  /// Which page a newly-added tool should try to land on first, and which
  /// page the view opens to — set when this screen is reached from the
  /// dashboard's own "+" button (which knows what page was on screen).
  /// Null when reached any other way (app boot, Settings), which just opens
  /// on page 0 and scans placement from there.
  final int? preferredPage;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

/// The state machine governing edge-hover auto-paging while a tile is being
/// dragged (see [_DashboardScreenState._edgePagingPhase]) — specifically,
/// what stops a *page creation* from repeating indefinitely while the
/// pointer simply sits still at the edge of the last page, which a single
/// self-re-arming timer (the previous implementation) cannot: after each
/// hover delay, that page is *still* the last one, satisfying "create
/// another" all over again, every delay, until [DashboardScreen]'s page cap.
///
///        ┌──────────────────────────────────────────────────────┐
///        │                                                      │
///        ▼                                                      │
///      [idle] ──(enters edge zone)──▶ [hoveringEdge] ─────┐      │
///        ▲                                 │              │      │
///        │                    (delay elapses, an existing │      │
///        │                     page is next — loops back  │      │
///        │                     to hoveringEdge on its own, │      │
///        │                     see _applyPageSwitch)       │      │
///        │                                 │              │      │
///        │                    (delay elapses, this *is*    │      │
///        │                     the last page)              │      │
///        │                                 ▼              │      │
///        │                          [creatingPage]         │      │
///        │                                 │              │      │
///        │                                 ▼              │      │
///        │                       [creationCooldown] ◀──────┘      │
///        │                                 │                     │
///        │                    (kPageCreationCooldown elapses)     │
///        │                                 ▼                     │
///        └───────────────────────[waitingEdgeExit]────────────────┘
///                       (pointer observed outside the edge zone)
///
/// Only [hoveringEdge] ever starts (or re-arms) the hover-delay timer, and
/// only [idle] ever lets a *new* [hoveringEdge] begin — [creationCooldown]
/// and [waitingEdgeExit] both flatly ignore the pointer's position for the
/// purpose of starting anything new, which is what makes "hold still at the
/// edge" produce exactly one new page, full stop, no matter how long the
/// hold continues. Switching to an *already-existing* next/previous page
/// never leaves [hoveringEdge] at all — holding at the edge still traverses
/// several existing pages in one continuous hold, unchanged from before;
/// this whole state machine only ever engages once an actual *creation*
/// happens.
enum _EdgePagingPhase {
  idle,
  hoveringEdge,
  creatingPage,
  creationCooldown,
  waitingEdgeExit,
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _maxPages = 5;

  /// The app's session host — read once from [DrivingSessionScope] in
  /// [didChangeDependencies]; never built, owned or disposed here.
  DrivingSessionHost? _host;
  DrivingSessionHost get _session => _host!;

  /// This view's own banner subscriptions to the host's engines.
  StreamSubscription<AlertEvent>? _alertSub;
  StreamSubscription<DetectedEvent>? _eventSub;
  late final PageController _pageController;
  late List<SensorWidgetConfig> _configs;
  late int _currentPage;
  GridDimensions? _lastGrid;

  /// Per-sensor card alert color (see [DashboardTile.alertColor]), fed by
  /// whichever sensor widget reports one (currently only the artificial
  /// horizon, via [buildDashboardSensorWidget]'s `onAlertColorChanged`).
  final Map<SensorType, Color?> _alertColors = {};

  /// Per-sensor "reset records" trigger, captured once each sensor widget
  /// registers itself via `onResetRequested` — only present for the three
  /// styles with a resettable record (line chart, G-force meter, artificial
  /// horizon). Feeds the tile's context menu's "Resetar registros".
  final Map<SensorType, VoidCallback> _resetTriggers = {};

  /// Same idea as [_resetTriggers], but the bare (dialog-free) trigger each
  /// widget registers via `onImmediateResetRequested` — feeds the AppBar's
  /// global "Resetar e calibrar sistema" button via
  /// [DashboardMaintenanceService], which shows exactly one confirmation of
  /// its own before running every currently-built tile's trigger. Any
  /// future sensor style that registers one is automatically included here,
  /// with no changes needed to the button or the service.
  final Map<SensorType, VoidCallback> _immediateResetTriggers = {};

  /// The one tile currently in edit mode (move/resize enabled), dashboard
  /// wide — null when nothing is being edited.
  SensorWidgetConfig? _editingConfig;

  /// Live ghost-outline rect while a resize handle is being dragged, for
  /// whichever tile is in [_editingConfig] — reported by [DashboardTile]
  /// since a shrink/grow from a top/left handle can extend past the tile's
  /// own clipped box.
  CellRect? _resizeGhostRect;

  /// The config currently being drag-moved (not resized), if any — while
  /// non-null, excluded from every page's own grid entirely (see
  /// [_buildPageGrid]) and instead rendered exactly once, as a permanent
  /// sibling of the `PageView` (see [build]), since it tracks the finger via
  /// its own local, zero-lag state ([DashboardTile._liveRect], visually
  /// promoted into the app's `Overlay` for the duration — see that class's
  /// doc) rather than anything fed down from here. Only the *other*,
  /// displaced tiles need a rect fed down live, via [_dragReflowPreview].
  SensorWidgetConfig? _draggingConfig;

  /// Live reflow preview while [_draggingConfig] is being dragged — the
  /// dragged tile's own candidate rect plus the tentative new rect of any
  /// other tile it currently overlaps (see [resolveDragReflow]), or null
  /// when nothing's being dragged or the current candidate isn't achievable
  /// (some displaced tile has nowhere to go).
  Map<SensorType, CellRect>? _dragReflowPreview;

  /// One stable [GlobalKey] per sensor, reused across rebuilds — lets a
  /// tile's [DashboardTile] `State` (its live rect, its in-flight `Drag`,
  /// its `Overlay` avatar) survive being reparented between its normal
  /// page's `Stack` and the permanent, page-independent slot it moves to for
  /// the duration of a drag (see [_draggingConfig] and [build]), instead of
  /// being torn down and rebuilt from scratch, which would drop the gesture.
  final Map<SensorType, GlobalKey> _tileKeys = {};

  GlobalKey _keyFor(SensorType type) => _tileKeys.putIfAbsent(type, GlobalKey.new);

  /// Pending auto page-switch while [_draggingConfig] is held near a screen
  /// edge — see [_handleDragGlobalPosition] / [_hoverPageSwitch].
  Timer? _edgeHoverTimer;

  /// Which edge [_edgeHoverTimer] is currently counting down for (-1
  /// previous / 1 next), so a repeated call with the same direction doesn't
  /// keep resetting an already-running timer, and so [_hoverPageSwitch] can
  /// tell the pointer hasn't since moved away from the edge.
  int? _edgeHoverDirection;

  /// See [_EdgePagingPhase]'s own doc for the full state machine this
  /// drives — [_edgeHoverTimer] is reused as *both* the hover-delay timer
  /// (while [_EdgePagingPhase.hoveringEdge]) and the cooldown timer (while
  /// [_EdgePagingPhase.creationCooldown]), deliberately never two separate
  /// timer fields, so there's exactly one place tracking "what happens
  /// next."
  _EdgePagingPhase _edgePagingPhase = _EdgePagingPhase.idle;

  /// The pointer's raw global position as of the last
  /// [_handleDragGlobalPosition] call — kept around so [_hoverPageSwitch] can
  /// re-derive *today's* auto-scroll delay when it re-arms itself (see
  /// [_hoverDelayFor]), rather than reusing whatever delay was computed when
  /// the timer first started, which could be stale if the pointer has since
  /// drifted closer to (or further from) the true edge without leaving the
  /// zone entirely.
  Offset? _lastDragGlobalPosition;

  @override
  void initState() {
    super.initState();
    _configs = SensorWidgetRepository.all;
    _currentPage = _clampPage(widget.preferredPage ?? AppSettings.dashboardLastViewedPage);
    _pageController = PageController(initialPage: _currentPage);
  }

  // DrivingSessionScope (per its own InheritedWidget contract) isn't safe to
  // read from initState — resolved exactly once, on the first dependency pass.
  // Only this screen's banners are subscribed here; recording events into the
  // session is the host's job, done once however many dashboards are mounted.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_host == null) {
      final host = DrivingSessionScope.of(context);
      _host = host;
      _alertSub = host.alertEngine.events.listen(_handleAlertEvent);
      _eventSub = host.eventEngine.events.listen(_handleDetectedEvent);
    }
  }

  /// The one place any alert is actually shown — a brief [SnackBar], the
  /// same mechanism regardless of which [AlertType] fired, so no widget or
  /// screen needs its own alert-display logic. Only a *new* fire shows
  /// anything; a clear is silent (a disappearing banner reads as more
  /// alarming than informative for something like "speed dropped back
  /// below the threshold"). Covers only the two types [AlertEngine] itself
  /// still detects (`highInclination`/`weakGnss`) — see that class's doc.
  void _handleAlertEvent(AlertEvent event) {
    if (!event.active || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alertTypeLabel(event.type)),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Every confirmed [DetectedEvent] always gets persisted to the active
  /// session, unconditionally — an event belongs in driving history
  /// regardless of whether the user currently wants a live interruption for
  /// it. Since Fase 16.2-R4.3-R2.6.8 that persistence is
  /// [DrivingSessionHost]'s, not this screen's (two dashboards mounted during
  /// a recreation would otherwise record it twice). Here, if this event's
  /// type has a live-banner equivalent (see [alertTypeForDetectedEvent]) and
  /// the user hasn't disabled it, the same [SnackBar] mechanism
  /// [_handleAlertEvent] uses shows it — one confirmed event, at most one
  /// visible effect, never two independently-timed decisions about the same
  /// real-world moment (Fase 13.1 §1/§2).
  void _handleDetectedEvent(DetectedEvent event) {
    final alertType = alertTypeForDetectedEvent(event.type);
    if (alertType == null || !mounted) return;
    // Level-based delegated types (acceleration/braking/cornering/
    // resultantG/speed) already gate on `isEnabled` inside
    // EventDetectionEngine's own tracker before ever emitting — this check
    // is what's actually load-bearing for `gnssLost`, whose tracker is
    // unconditional by design (a GNSS-loss session record should always be
    // recorded; only the live banner should honor the user's toggle).
    if (!AlertPreferencesScope.of(context).isEnabled(alertType)) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alertTypeLabel(alertType)),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  int _clampPage(int page) => page < 0 ? 0 : (page > _maxPages - 1 ? _maxPages - 1 : page);

  /// The larger of two things: how many pages actually have widgets on them
  /// (so an overflowing "+" that auto-creates a page shows it immediately),
  /// and how many pages the user explicitly reserved via the page manager
  /// (so an intentionally-added blank page stays visible even before
  /// anything lands on it) — see [AppSettings.dashboardPageCount].
  int get _pageCount {
    final derived = _configs.isEmpty ? 1 : (_configs.map((c) => c.page).reduce((a, b) => a > b ? a : b) + 1);
    final persisted = AppSettings.dashboardPageCount;
    return (derived > persisted ? derived : persisted).clamp(1, _maxPages);
  }

  void _setAlertColor(SensorType type, Color? color) {
    if (_alertColors[type] == color) return;
    setState(() => _alertColors[type] = color);
  }

  /// Only this view's own resources: the session, its pipeline and the camera
  /// belong to [DrivingSessionHost] and outlive this screen.
  @override
  void dispose() {
    _edgeHoverTimer?.cancel();
    _pageController.dispose();
    _alertSub?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }

  /// Re-fits every already-placed widget on every page against [grid] (an
  /// orientation change may have shrunk it), then places any sentinel
  /// (brand new / newly-added) widget across pages, creating a page beyond
  /// the current highest one automatically when needed — see
  /// [placeAcrossPages]. A no-op when everything already fits.
  void _reconcileAndPlace(GridDimensions grid) {
    var changed = false;

    for (var page = 0; page < _pageCount; page++) {
      final pageConfigs = _configs.where((c) => c.page == page && c.position.x >= 0).toList();
      final resolved = reconcileLayout(configs: pageConfigs, grid: grid);
      for (final config in pageConfigs) {
        final rect = resolved[config.sensorType]!;
        final current = _rectOf(config);
        if (rect != current) {
          changed = true;
          SensorWidgetRepository.updateLayout(
            config,
            position: WidgetPosition(x: rect.x.toDouble(), y: rect.y.toDouble()),
            size: WidgetSize(width: rect.width.toDouble(), height: rect.height.toDouble()),
          );
        }
      }
    }

    final result = placeAcrossPages(
      allConfigs: _configs,
      grid: grid,
      maxPages: _maxPages,
      preferredPage: widget.preferredPage,
    );
    for (final entry in result.placed.entries) {
      final config = _configs.firstWhere((c) => c.sensorType == entry.key);
      final placement = entry.value;
      changed = true;
      SensorWidgetRepository.updateLayout(
        config,
        position: WidgetPosition(x: placement.rect.x.toDouble(), y: placement.rect.y.toDouble()),
        size: WidgetSize(width: placement.rect.width.toDouble(), height: placement.rect.height.toDouble()),
        page: placement.page,
      );
    }
    if (result.unplaced.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não há mais espaço no painel — remova algo ou tente em outra página.')),
      );
    }

    if (changed && mounted) setState(() {});
  }

  /// Fired once as soon as a move drag begins (see [DashboardTile.onMoveStarted])
  /// — sets [_draggingConfig] unconditionally, *before* any candidate rect
  /// is proposed. Necessary in addition to [_handleMoveCandidate]: a tile
  /// already at its page's own edge can have every candidate for an entire
  /// drag rejected before [_handleMoveCandidate] ever runs (e.g. dragging a
  /// rightmost-column tile further right — exactly the gesture meant to
  /// push it onto the next page), and edge-hover page-switching needs to
  /// know a drag is under way regardless.
  void _handleMoveStarted(SensorWidgetConfig config) {
    setState(() => _draggingConfig = config);
  }

  /// Queried by [DashboardTile.onMoveCandidate] on every drag update —
  /// computes whether [candidate] is achievable via reflow (relocating
  /// whatever it currently overlaps, see [resolveDragReflow]) and caches
  /// the result for [_buildPageGrid] to render the live preview of any
  /// displaced tile. Returns whether the tile should accept the candidate.
  ///
  /// Deliberately reflows against [_currentPage] rather than [config]'s own
  /// (still-persisted, not-yet-committed) page: once a drag has crossed onto
  /// a different page via [_handleDragGlobalPosition]'s edge-hover, this is
  /// what makes every subsequent candidate reflow against the *new* page's
  /// widgets instead of the one the drag started on.
  bool _handleMoveCandidate(SensorWidgetConfig config, CellRect candidate) {
    final others = _configs.where((c) => c.page == _currentPage && c != config).toList();
    final grid = _lastGrid ?? gridDimensionsFor(MediaQuery.orientationOf(context));
    final result = resolveDragReflow(
      draggedRect: candidate,
      draggedType: config.sensorType,
      others: others,
      grid: grid,
    );
    setState(() {
      _draggingConfig = config;
      _dragReflowPreview = result;
    });
    return result != null;
  }

  /// Called on every drag update with the pointer's raw global position —
  /// drives [_edgePagingPhase] (see that enum's own doc for the complete
  /// state machine) and, only while [_EdgePagingPhase.hoveringEdge] (the
  /// sole phase where a page switch is actually still a live possibility),
  /// keeps [_updatePagePeek] in sync.
  void _handleDragGlobalPosition(Offset globalPosition) {
    _lastDragGlobalPosition = globalPosition;
    final direction = _currentHoverDirection();
    final proximity = _currentHoverProximity();

    switch (_edgePagingPhase) {
      case _EdgePagingPhase.idle:
        if (direction != null) _startHoveringEdge(direction, proximity);
      case _EdgePagingPhase.hoveringEdge:
        if (direction == null) {
          _resetToIdle();
        } else if (direction != _edgeHoverDirection) {
          // Jumped straight from one edge's zone to the other's without an
          // in-between update reporting null — vanishingly rare (would need
          // a single pointer-move event to cross the entire viewport), but
          // this is what a fresh, correctly-armed hover for the *new* edge
          // needs regardless.
          _startHoveringEdge(direction, proximity);
        }
      case _EdgePagingPhase.creatingPage:
      case _EdgePagingPhase.creationCooldown:
        // Flatly ignored — see _EdgePagingPhase's own doc. Only its own
        // cooldown timer (armed by _enterCreationCooldown) ever moves this
        // phase forward, never the pointer's position.
        break;
      case _EdgePagingPhase.waitingEdgeExit:
        if (direction == null) _resetToIdle();
    }

    final peekArmed = _edgePagingPhase == _EdgePagingPhase.hoveringEdge;
    _updatePagePeek(peekArmed ? direction : null, peekArmed ? proximity : 0);
  }

  /// The edge direction (-1 previous / 1 next), if any, [_lastDragGlobalPosition]
  /// currently reports — recomputed on demand (from the *latest* known
  /// pointer position, not whatever was true when some earlier timer was
  /// armed) by every part of [_EdgePagingPhase]'s machinery that needs it
  /// outside of [_handleDragGlobalPosition] itself (which already has a
  /// fresh reading it can use directly).
  int? _currentHoverDirection() {
    final position = _lastDragGlobalPosition;
    if (position == null) return null;
    return dragEdgeHoverDirection(
      globalX: position.dx,
      viewportWidth: MediaQuery.sizeOf(context).width,
      zoneWidth: kDragEdgeHoverZoneWidth,
    );
  }

  /// Companion to [_currentHoverDirection] — see [_hoverDelayFor].
  double _currentHoverProximity() {
    final position = _lastDragGlobalPosition;
    if (position == null) return 0.0;
    return dragEdgeHoverProximity(
          globalX: position.dx,
          viewportWidth: MediaQuery.sizeOf(context).width,
          zoneWidth: kDragEdgeHoverZoneWidth,
        ) ??
        0.0;
  }

  /// Enters [_EdgePagingPhase.hoveringEdge] for [direction] and (re)arms the
  /// hover-delay timer — the *only* place that ever does either, so a page
  /// switch is only ever attempted after a deliberate, fresh entry into the
  /// edge zone while nothing else is already in flight.
  void _startHoveringEdge(int direction, double proximity) {
    _edgeHoverTimer?.cancel();
    _edgeHoverDirection = direction;
    _edgePagingPhase = _EdgePagingPhase.hoveringEdge;
    _edgeHoverTimer = Timer(_hoverDelayFor(proximity), () => _hoverPageSwitch(direction));
  }

  /// Resets the whole edge-paging state machine back to
  /// [_EdgePagingPhase.idle] — cancels whatever timer [_edgeHoverTimer] is
  /// currently holding (hover-delay or cooldown, whichever applies) and
  /// forgets which edge/direction was in play, so the very next zone entry
  /// starts a fully fresh cycle.
  void _resetToIdle() {
    _edgeHoverTimer?.cancel();
    _edgeHoverTimer = null;
    _edgeHoverDirection = null;
    _edgePagingPhase = _EdgePagingPhase.idle;
  }

  /// Auto-scroll delay for the current hold, interpolated between
  /// [kDragEdgeHoverDelayMax] (pointer just barely inside the edge zone) and
  /// [kDragEdgeHoverDelayMin] (pointer right at the physical screen edge) —
  /// replaces a single fixed wait with one that's proportional to exactly how
  /// close to the edge the pointer actually is, matching the Android
  /// launcher's own graduated auto-scroll speed instead of a uniform
  /// timer-driven feel. [_hoverPageSwitch] calls this again on every re-arm,
  /// so holding closer to the edge partway through a multi-page hold speeds
  /// the *remaining* switches up too, not just the first one.
  Duration _hoverDelayFor(double proximity) {
    final maxMs = kDragEdgeHoverDelayMax.inMilliseconds;
    final minMs = kDragEdgeHoverDelayMin.inMilliseconds;
    return Duration(milliseconds: (maxMs - (maxMs - minMs) * proximity.clamp(0.0, 1.0)).round());
  }

  /// Nudges the [PageController] to reveal a discreet sliver of the
  /// neighboring page while a drag hovers near a screen edge — proportional
  /// to [proximity], capped at [kPagePeekMaxFraction] of the viewport (always
  /// comfortably under the 0.5 a page rounds over at, so this can never fire
  /// a spurious [PageView.onPageChanged]) — and eases smoothly back to the
  /// current page's exact resting position the moment the hold ends without
  /// completing a real page switch. A real switch ([_applyPageSwitch]) just
  /// calls `animateToPage` as usual, which animates from wherever the peek
  /// left the scroll position — already partway there — so the peek blends
  /// directly into the real transition instead of resetting first.
  void _updatePagePeek(int? direction, double proximity) {
    if (!_pageController.hasClients) return;
    final position = _pageController.position;
    final viewportWidth = position.viewportDimension;
    final restingPixels = _currentPage * viewportWidth;
    if (direction == null || proximity <= 0) {
      if ((position.pixels - restingPixels).abs() > 0.5) {
        _pageController.animateTo(restingPixels, duration: kPagePeekReleaseDuration, curve: kPagePeekReleaseCurve);
      }
      return;
    }
    final peekPixels = proximity.clamp(0.0, 1.0) * kPagePeekMaxFraction * viewportWidth;
    _pageController.jumpTo(restingPixels + direction * peekPixels);
  }

  /// Fires once [_EdgePagingPhase.hoveringEdge]'s delay elapses. Two
  /// entirely different outcomes, depending on what [direction] leads to:
  ///
  ///  * An *existing* page — switches to it and, as long as the pointer is
  ///    still there once the delay elapses again, re-arms the same
  ///    [_EdgePagingPhase.hoveringEdge] timer, so holding at the edge keeps
  ///    continuously paging through however many existing pages there are —
  ///    unchanged from every earlier round of this feature.
  ///  * Past the *last* page, in the forward direction only — creates a
  ///    brand new one instead (Android-home-screen style), then *leaves*
  ///    [_EdgePagingPhase.hoveringEdge] for [_enterCreationCooldown]'s
  ///    lockout instead of re-arming — this, not a fixed delay, is what
  ///    stops a stationary hold from creating page after page: see
  ///    [_EdgePagingPhase]'s own doc.
  ///
  /// Guards on [_edgePagingPhase] itself, not just [_edgeHoverDirection]:
  /// only fires anything while genuinely still [_EdgePagingPhase.hoveringEdge]
  /// — defensive, since nothing should be able to leave a stale copy of this
  /// timer armed against a phase that's since moved on, but a phase
  /// mismatch is a cheap, unambiguous way to detect and ignore one if it
  /// ever happened. A no-op past the first page ([direction] == -1 with
  /// nothing before page 0) — there's no "page before the first" concept
  /// here — or once the pointer has moved away from the edge (including
  /// because the drag itself ended).
  void _hoverPageSwitch(int direction) {
    _edgeHoverTimer = null;
    if (!mounted ||
        _draggingConfig == null ||
        _edgePagingPhase != _EdgePagingPhase.hoveringEdge ||
        _edgeHoverDirection != direction) {
      return;
    }
    var target = _currentPage + direction;
    if (target < 0) {
      _resetToIdle();
      return;
    }
    if (target >= _pageCount) {
      if (direction != 1 || _pageCount >= _maxPages) {
        _resetToIdle();
        return;
      }
      _edgePagingPhase = _EdgePagingPhase.creatingPage;
      target = _pageCount;
      _createNewPage();
      // A creation — not just a switch to an already-existing page —
      // deserves its own, slightly more present cue, the same way it gets
      // its own moment in the Android launcher: a fresh page just came into
      // existence, not merely into view.
      HapticFeedback.mediumImpact();
      setState(() {});
      // See _hoverPageSwitch's own doc for why this waits one settled frame
      // before actually switching: it lets the new page's widget subtree
      // mount while the screen is still completely still.
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyPageSwitch(target, direction));
      _enterCreationCooldown();
      return;
    }
    _applyPageSwitch(target, direction);
    // Still hovering — an existing page, not a creation — so the ordinary
    // hoveringEdge cycle just keeps going, re-armed with *today's*
    // proximity (not whatever delay was in effect when this timer was
    // first started — see _hoverDelayFor).
    _edgeHoverTimer = Timer(_hoverDelayFor(_currentHoverProximity()), () => _hoverPageSwitch(direction));
  }

  /// Enters the post-creation lockout (see [_EdgePagingPhase]'s own doc) —
  /// [kPageCreationCooldown] is a timed floor; actually reaching
  /// [_EdgePagingPhase.idle] (where a *new* creation becomes possible again)
  /// additionally always requires the pointer to have been observed outside
  /// the edge zone at least once, checked fresh (not from some earlier,
  /// possibly-stale reading) the moment this timer fires — either right here
  /// if it's already outside by then, or later, whenever
  /// [_handleDragGlobalPosition] next observes it leaving while
  /// [_EdgePagingPhase.waitingEdgeExit].
  void _enterCreationCooldown() {
    _edgePagingPhase = _EdgePagingPhase.creationCooldown;
    _edgeHoverTimer?.cancel();
    _edgeHoverTimer = Timer(kPageCreationCooldown, () {
      _edgeHoverTimer = null;
      if (!mounted || _edgePagingPhase != _EdgePagingPhase.creationCooldown) return;
      if (_currentHoverDirection() == null) {
        _resetToIdle();
      } else {
        _edgePagingPhase = _EdgePagingPhase.waitingEdgeExit;
      }
    });
  }

  /// The actual page switch — [_currentPage], persisting the last-viewed
  /// page, and starting the [PageController]'s animation — shared by both
  /// branches of [_hoverPageSwitch]. Re-validates the drag is still where
  /// [_hoverPageSwitch] left it, since the newly-created-page branch's
  /// one-frame deferral leaves a (vanishingly small) window for the pointer
  /// to have moved away from the edge, or the drag to have ended, meanwhile.
  void _applyPageSwitch(int target, int direction) {
    if (!mounted || _draggingConfig == null || _edgeHoverDirection != direction) return;
    setState(() {
      _currentPage = target;
      // Whatever reflow candidate was last accepted (see
      // _handleMoveCandidate) was computed against the *old* page's other
      // widgets — it's now meaningless on this one, and never gets
      // recomputed on its own, since that only happens in response to
      // pointer *movement*, not to this timer-driven page switch. Left
      // stale, _handleMoveCommitted would wrongly treat it as a validated
      // candidate for the new page on release (misplacing the dragged tile,
      // and relocating unrelated widgets from the old page onto the new one)
      // instead of correctly falling back to firstFit placement. Clearing it
      // here — whether or not the pointer ever moves again before release —
      // is what makes that fallback trigger correctly.
      _dragReflowPreview = null;
    });
    AppSettings.setDashboardLastViewedPage(target);
    _pageController.animateToPage(target, duration: kDashboardPageTransitionDuration, curve: kDashboardPageTransitionCurve);
  }

  void _cancelEdgeHover() {
    _resetToIdle();
    // In case a peek (see _updatePagePeek) was mid-flight when the drag
    // ended (e.g. released right as it reached the edge, before the hover
    // delay ever elapsed) — the PageView must never be left visually
    // offset from a page's exact resting position once nothing is dragging.
    _updatePagePeek(null, 0);
  }

  /// Commits the drag: persists [config]'s own final position *and page* —
  /// [_currentPage] at release time, which is the page the drag started on
  /// unless an edge-hover moved it — plus every other config the live
  /// reflow preview relocated (already on [_currentPage] themselves, since
  /// [_handleMoveCandidate] only ever reflows against that page).
  ///
  /// A null preview means [_handleMoveCandidate] never accepted a single
  /// candidate *for the page the drag ends on* — not just "shouldn't
  /// happen": either a tile already flush against its page's edge (in the
  /// direction it's dragged) had every candidate for a whole gesture
  /// rejected as out-of-bounds before reflow was ever consulted (e.g. a
  /// 2-wide tile already touching the right edge, dragged further right —
  /// exactly the gesture meant to push it onto the next page), or
  /// [_hoverPageSwitch] deliberately cleared a stale one when the page
  /// changed without the pointer moving again afterward (holding still at
  /// the edge while auto-navigation — or auto page-creation — does its
  /// thing). If the page never changed either, the tile is simply still
  /// exactly where it validly already was, so this is a correct no-op. If
  /// an edge-hover *did* cross it onto a new page (whether pre-existing or
  /// just auto-created), that page move is real and must not be silently
  /// discarded just because the live candidate math never caught up (or was
  /// invalidated) — fall back to auto-placing it on the new page instead.
  void _handleMoveCommitted(SensorWidgetConfig config, CellRect finalRect) {
    final preview = _dragReflowPreview;
    final finalPage = _currentPage;
    final crossedPages = finalPage != config.page;
    setState(() {
      _draggingConfig = null;
      _dragReflowPreview = null;
    });
    _cancelEdgeHover();
    if (preview == null) {
      if (!crossedPages) return;
      final grid = _lastGrid ?? gridDimensionsFor(MediaQuery.orientationOf(context));
      final others = _configs.where((c) => c.page == finalPage && c != config).map(_rectOf);
      final fallback = firstFit(
        occupied: others,
        grid: grid,
        width: config.size.width.round(),
        height: config.size.height.round(),
      );
      if (fallback == null) return;
      SensorWidgetRepository.updateLayout(
        config,
        position: WidgetPosition(x: fallback.x.toDouble(), y: fallback.y.toDouble()),
        size: config.size,
        page: finalPage,
      );
      setState(() {});
      return;
    }
    SensorWidgetRepository.updateLayout(
      config,
      position: WidgetPosition(x: finalRect.x.toDouble(), y: finalRect.y.toDouble()),
      size: config.size,
      page: finalPage,
    );
    for (final entry in preview.entries) {
      if (entry.key == config.sensorType) continue;
      final other = _configs.firstWhere((c) => c.sensorType == entry.key);
      SensorWidgetRepository.updateLayout(
        other,
        position: WidgetPosition(x: entry.value.x.toDouble(), y: entry.value.y.toDouble()),
        size: other.size,
        page: finalPage,
      );
    }
    setState(() {});
  }

  /// A move drag abandoned rather than released (see [Drag.cancel]) — drops
  /// the live preview without persisting anything.
  void _handleMoveCancelled() {
    setState(() {
      _draggingConfig = null;
      _dragReflowPreview = null;
    });
    _cancelEdgeHover();
  }

  void _handleResized(SensorWidgetConfig config, CellRect rect) {
    SensorWidgetRepository.updateLayout(
      config,
      position: config.position,
      size: WidgetSize(width: rect.width.toDouble(), height: rect.height.toDouble()),
    );
    setState(() {});
  }

  void _enterEditMode(SensorWidgetConfig config) {
    // Selection-weight feedback — the lightest tick Flutter offers, matching
    // how discreetly the Android launcher confirms an icon has been picked
    // up (never a sustained buzz).
    HapticFeedback.selectionClick();
    setState(() => _editingConfig = config);
  }

  void _exitEditMode() {
    if (_editingConfig != null) setState(() => _editingConfig = null);
  }

  void _setResizeGhost(CellRect? rect) => setState(() => _resizeGhostRect = rect);

  Future<void> _handleDelete(SensorWidgetConfig config) async {
    await SensorWidgetRepository.deleteConfig(config);
    if (!mounted) return;
    setState(() {
      _configs.remove(config);
      _resetTriggers.remove(config.sensorType);
      _immediateResetTriggers.remove(config.sensorType);
      _alertColors.remove(config.sensorType);
      _tileKeys.remove(config.sensorType);
      if (_editingConfig == config) _editingConfig = null;
    });
    _reconcileAndPlace(gridDimensionsFor(MediaQuery.orientationOf(context)));
  }

  Future<void> _openSingleStyleEditor(SensorWidgetConfig config) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SingleSensorStyleScreen(sensorType: config.sensorType, initialStyle: config.displayStyle),
      ),
    );
    if (changed == true && mounted) setState(() {});
  }

  /// Label/icon for the context menu's trailing reset/calibrate action, per
  /// sensor — the underlying menu slot is shared (see
  /// [showDashboardTileContextMenu]'s own doc), only the wording/icon differ
  /// per sensor so each reads correctly for what it actually does.
  static const Map<SensorType, (String, IconData)> _resetRecordsPresentation = {
    SensorType.inclination: ('Calibrar', Icons.center_focus_strong),
  };

  /// Every value [_showContextMenu] (the Dashboard tile's own long-press
  /// menu) and [_openFullscreen] (which hands the same options through to
  /// [SensorFullscreenScreen]'s own reused menu) both need — computed once
  /// here so neither call site re-derives it independently. This is what
  /// lets the fullscreen screen's "Excluir"/"Alterar o estilo"/reset-or-
  /// calibrate options run the exact same callbacks the Dashboard's own
  /// menu already uses, with no second implementation.
  ({
    IconData icon,
    String label,
    VoidCallback onDelete,
    VoidCallback? onChangeStyle,
    VoidCallback? onResetRecords,
    String resetRecordsLabel,
    IconData resetRecordsIcon,
  })
  _contextMenuParamsFor(SensorWidgetConfig config) {
    final validStyles = validDisplayStylesForSensor[config.sensorType]!;
    final (resetLabel, resetIcon) =
        _resetRecordsPresentation[config.sensorType] ?? ('Resetar registros', Icons.restart_alt);
    return (
      icon: sensorTypeMetadata[config.sensorType]!.icon,
      label: sensorTypeMetadata[config.sensorType]!.label,
      onDelete: () => _handleDelete(config),
      onChangeStyle: validStyles.length > 1 ? () => _openSingleStyleEditor(config) : null,
      onResetRecords:
          _resetTriggers.containsKey(config.sensorType) ? () => _resetTriggers[config.sensorType]!() : null,
      resetRecordsLabel: resetLabel,
      resetRecordsIcon: resetIcon,
    );
  }

  void _openFullscreen(SensorWidgetConfig config) {
    final params = _contextMenuParamsFor(config);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SensorFullscreenScreen(
          label: params.label,
          icon: params.icon,
          content: buildDashboardSensorWidget(config.sensorType, config.displayStyle, _session.streams),
          onDelete: params.onDelete,
          onChangeStyle: params.onChangeStyle,
          onResetRecords: params.onResetRecords,
          resetRecordsLabel: params.resetRecordsLabel,
          resetRecordsIcon: params.resetRecordsIcon,
        ),
      ),
    );
  }

  /// Fase 15 — pushes the exact same [SensorFullscreenScreen] every other
  /// instrument uses, not a second fullscreen mechanism. No `onDelete` (a
  /// live camera preview has no "delete" concept); `onResetRecords` reuses
  /// that slot for "Proteger este clipe" instead, matching how inclination
  /// already reuses it for "Calibrar".
  void _openDashcamFullscreen() {
    final controller = _session.dashcamController;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SensorFullscreenScreen(
          label: 'Dashcam',
          icon: Icons.videocam,
          content: DashcamPreviewView(controller: controller),
          onResetRecords: controller.protectCurrentClip,
          resetRecordsLabel: 'Proteger este clipe',
          resetRecordsIcon: Icons.shield_outlined,
        ),
      ),
    );
  }

  Future<void> _showContextMenu(SensorWidgetConfig config) {
    final params = _contextMenuParamsFor(config);
    return showDashboardTileContextMenu(
      context: context,
      icon: params.icon,
      label: params.label,
      onDelete: params.onDelete,
      onChangeStyle: params.onChangeStyle,
      onFullscreen: () => _openFullscreen(config),
      onResetRecords: params.onResetRecords,
      resetRecordsLabel: params.resetRecordsLabel,
      resetRecordsIcon: params.resetRecordsIcon,
    );
  }

  void _addTool() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SensorSelectionScreen(isEditMode: true, preferredPage: _currentPage),
      ),
    );
  }

  static const _resetAndCalibrateMessage =
      'Esta operação irá:\n'
      '\n'
      '• Resetar todos os registros dos Widgets.\n'
      '• Resetar velocidades máximas.\n'
      '• Resetar velocidades médias.\n'
      '• Resetar altitude máxima.\n'
      '• Resetar altitude mínima.\n'
      '• Resetar aceleração máxima.\n'
      '• Resetar quaisquer outros registros armazenados pelos Widgets.\n'
      '• Recalibrar automaticamente todos os sensores que possuem função de calibração.\n'
      '\n'
      'Esta operação não excluirá Widgets nem alterará a organização do Dashboard.\n'
      '\n'
      'Deseja continuar?';

  /// The AppBar's global "Resetar e calibrar sistema" button: a single
  /// confirmation, then [DashboardMaintenanceService] runs every currently
  /// registered tile's own bare reset/calibration trigger (see
  /// [_immediateResetTriggers]) — the exact same routines each widget
  /// already uses for its own per-tile "Resetar registros"/"Calibrar" menu
  /// item, just without popping up one dialog per widget. `setState` inside
  /// each trigger updates every tile immediately; no navigation or rebuild
  /// of this screen is needed for that.
  Future<void> _confirmResetAndCalibrateAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resetar e calibrar sistema'),
        content: const SingleChildScrollView(child: Text(_resetAndCalibrateMessage)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirmar')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await const DashboardMaintenanceService().resetAndCalibrateAll(_immediateResetTriggers.values);
    } catch (error, stackTrace) {
      debugPrint('Falha ao resetar e calibrar o sistema: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível resetar e calibrar o sistema. Tente novamente.')),
      );
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sistema resetado e sensores calibrados com sucesso.')),
    );
  }

  /// Reserves one more page, persisting immediately via the exact same
  /// mechanism used everywhere else page count is read/written — the single
  /// source for both manual creation (the page-manager sheet's "+", see
  /// [_addPageFromSheet]) and automatic creation while dragging a tile past
  /// the last page's edge (see [_hoverPageSwitch]). Callers are responsible
  /// for the [_maxPages] check: the sheet already hides its own "+" at the
  /// cap, and [_hoverPageSwitch] checks explicitly since dragging has no
  /// equivalent UI affordance to hide.
  Future<void> _createNewPage() => AppSettings.setDashboardPageCount(_pageCount + 1);

  Future<void> _addPageFromSheet() async {
    await _createNewPage();
    if (mounted) setState(() {});
  }

  /// Deletes every widget still on [page] (the page manager has already
  /// confirmed this with the user if it wasn't empty), reindexes every
  /// config past it down by one, and shrinks the persisted page count to
  /// match — then corrects [_currentPage]/[_pageController] if the deleted
  /// page was at or before the one being viewed, persisting that too so a
  /// restart reopens on the same page.
  Future<void> _deletePage(int page) async {
    final deletedTypes = await SensorWidgetRepository.deleteConfigsOnPage(page);
    await SensorWidgetRepository.shiftPagesAfterDelete(page);
    await AppSettings.setDashboardPageCount((AppSettings.dashboardPageCount - 1).clamp(1, _maxPages));
    if (!mounted) return;
    setState(() {
      _configs.removeWhere((c) => deletedTypes.contains(c.sensorType));
      for (final type in deletedTypes) {
        _resetTriggers.remove(type);
        _immediateResetTriggers.remove(type);
        _alertColors.remove(type);
        _tileKeys.remove(type);
      }
      if (deletedTypes.contains(_editingConfig?.sensorType)) _editingConfig = null;
      if (deletedTypes.contains(_draggingConfig?.sensorType)) {
        _draggingConfig = null;
        _dragReflowPreview = null;
        _cancelEdgeHover();
      }
    });
    final newCount = _pageCount;
    final newCurrentPage = (_currentPage > page ? _currentPage - 1 : _currentPage).clamp(0, newCount - 1);
    setState(() => _currentPage = newCurrentPage);
    await AppSettings.setDashboardLastViewedPage(newCurrentPage);
    _pageController.jumpToPage(newCurrentPage);
  }

  void _navigateToPage(int page) {
    setState(() => _currentPage = page);
    AppSettings.setDashboardLastViewedPage(page);
    _pageController.animateToPage(page, duration: kDashboardPageTransitionDuration, curve: kDashboardPageTransitionCurve);
  }

  Future<void> _showPageManager() {
    final pages = [
      for (var page = 0; page < _pageCount; page++)
        [
          for (final config in _configs)
            if (config.page == page) (type: config.sensorType, rect: _rectOf(config)),
        ],
    ];
    return showPageManagerSheet(
      context: context,
      pages: pages,
      grid: _lastGrid ?? gridDimensionsFor(MediaQuery.orientationOf(context)),
      currentPage: _currentPage,
      maxPages: _maxPages,
      onAddPage: _addPageFromSheet,
      onDeletePage: _deletePage,
      onNavigateToPage: _navigateToPage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.orientationOf(context);
    final grid = gridDimensionsFor(orientation);
    if (_lastGrid != grid) {
      _lastGrid = grid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reconcileAndPlace(grid);
      });
    }

    final themeController = ThemeControllerScope.of(context);
    final isColorfulPerWidget = themeController.colorPaletteId == 'colorful_per_widget';
    final colorScheme = Theme.of(context).colorScheme;
    final pageCount = _pageCount;

    final appBar = AppBar(
      title: const Text('Synapse Auto'),
      actions: [
        IconButton(icon: const Icon(Icons.add), tooltip: 'Adicionar ferramenta', onPressed: _addTool),
        DashcamRecIndicator(controller: _session.dashcamController, onTap: _openDashcamFullscreen),
        IconButton(
          icon: const Icon(Icons.settings_backup_restore),
          tooltip: 'Resetar e calibrar sistema',
          onPressed: _confirmResetAndCalibrateAll,
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          tooltip: 'Configurações',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SettingsMenuScreen(
                streams: _session.streams,
                sessionRecorder: _session.recorder,
                dashcamController: _session.dashcamController,
              ),
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      // The AppBar (title, "+", gear, and any future action) sits outside
      // the body's own subtree, so none of the edit-mode-exit machinery
      // below (the background GestureDetector, each tile's own onTap) ever
      // sees a tap here — this Listener is what closes that gap. onPointerDown
      // fires for any touch anywhere under it, buttons included, without
      // ever joining the gesture arena, so it can't steal or delay a
      // button's own tap recognition (ripple, onPressed keep working
      // exactly as before) — it only piggybacks _exitEditMode as a side
      // effect, and reliably runs before onPressed since down always
      // precedes the up that triggers it. Deliberately scoped to just the
      // AppBar, not the whole Scaffold: the body already has its own
      // correct, tap-time (not touch-down-time) rule for whether a tap on a
      // tile should end editing or open that tile's context menu (see
      // _buildPageGrid's onTap wiring) — wrapping the body here too would
      // race with it and reopen a bug an earlier round already fixed.
      appBar: PreferredSize(
        preferredSize: appBar.preferredSize,
        child: Listener(onPointerDown: (_) => _exitEditMode(), child: appBar),
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cellSize = Size(
                  constraints.maxWidth / grid.columns,
                  constraints.maxHeight / grid.rows,
                );
                return Stack(
                  children: [
                    PageView.builder(
                      controller: _pageController,
                      // Swipe is fully disabled for the entire edit-mode session
                      // (not just while a drag is actively in flight) — matches
                      // the Android home-screen model, where the only way to
                      // change pages while something is selected/being edited is
                      // the drag's own edge-hover auto-navigation (see
                      // _hoverPageSwitch, which pages programmatically via
                      // PageController and so is unaffected by this physics
                      // override). _editingConfig flips via a plain setState
                      // from a completed, separate gesture (a tap), never mid-
                      // drag on the same pointer, so there's no risk of the
                      // layout-timing race a previous, pointer-tracking-based
                      // version of this idea (removed in an earlier round) had.
                      physics: _editingConfig != null ? const NeverScrollableScrollPhysics() : null,
                      // Off (the default) the rest of the time, since it forces
                      // Flutter to keep the current page's immediate neighbors
                      // built and laid out at all times, not just while they're
                      // actually visible — a real, if modest, ongoing CPU/memory
                      // cost (their sensor widgets, live gauges included, keep
                      // rendering). Scoped to exactly the window a drag is in
                      // progress — the only time a page transition is ever
                      // programmatic (edge-hover, see _hoverPageSwitch) rather
                      // than paced 1:1 by the user's own finger — so the
                      // dashboard's usual live-gauge screens never pay it.
                      allowImplicitScrolling: _draggingConfig != null,
                      itemCount: pageCount,
                      onPageChanged: (i) {
                        setState(() => _currentPage = i);
                        AppSettings.setDashboardLastViewedPage(i);
                      },
                      itemBuilder: (context, pageIndex) => _buildPageGrid(
                        pageIndex,
                        grid,
                        cellSize,
                        colorScheme,
                        isColorfulPerWidget,
                      ),
                    ),
                    // The tile currently being drag-moved, if any — rendered
                    // here instead of as part of whichever page's grid is
                    // current (see _buildPageGrid, which now always excludes
                    // it), as a permanent, page-independent sibling of the
                    // PageView for the tile's *entire* drag. It stays mounted
                    // in this exact spot regardless of which page is on
                    // screen, so it never needs reparenting across pages'
                    // Stacks the way it used to — completely decoupled from
                    // the PageView itself, not just from a specific page's
                    // grid. DashboardTile promotes its own real visuals into
                    // the app-level Overlay for the actual duration of the
                    // move (see that class's doc); what's built here mainly
                    // exists to keep the gesture's own State alive throughout
                    // — see _buildDashboardTile.
                    if (_draggingConfig != null)
                      _buildDashboardTile(
                        _draggingConfig!,
                        _rectOf(_draggingConfig!),
                        cellSize,
                        grid,
                        const [],
                        colorScheme,
                        isColorfulPerWidget,
                      ),
                  ],
                );
              },
            ),
          ),
          PageIndicatorDots(count: pageCount, currentPage: _currentPage),
        ],
      ),
    );
  }

  Widget _buildPageGrid(
    int pageIndex,
    GridDimensions grid,
    Size cellSize,
    ColorScheme colorScheme,
    bool isColorfulPerWidget,
  ) {
    // The tile currently being drag-moved (if any) is never part of any
    // page's own grid — it's rendered exactly once, as a permanent sibling
    // of the whole PageView (see build) — so every page here only ever shows
    // its *other*, non-dragged widgets.
    final pageConfigs = [
      for (final config in _configs)
        if (config.page == pageIndex && config != _draggingConfig) config,
    ];
    // Prefers the live reflow preview, so a displaced tile visibly scoots to
    // its tentative new spot while the drag is still in progress.
    final rects = <SensorType, CellRect>{
      for (final config in pageConfigs) config.sensorType: _dragReflowPreview?[config.sensorType] ?? _rectOf(config),
    };

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _exitEditMode,
            onLongPress: () {
              _exitEditMode();
              _showPageManager();
            },
            behavior: HitTestBehavior.opaque,
          ),
        ),
        // Grid lines fade to a subtly more visible opacity for exactly the
        // span of an active drag — a discreet hint of the positions
        // available for the tile, matching the Android launcher's own faint
        // grid highlight, without introducing a second painted layer or any
        // per-cell bookkeeping: same painter, same lines, just a livelier
        // color while it's actually relevant.
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.0, end: _draggingConfig != null ? kDragActiveGridOpacityBoost : 1.0),
            duration: kDragActiveGridFadeDuration,
            curve: Curves.easeOut,
            builder: (context, boost, child) => CustomPaint(
              painter: _GridLinesPainter(
                grid: grid,
                cellSize: cellSize,
                color: colorScheme.outlineVariant.withValues(alpha: (0.25 * boost).clamp(0.0, 1.0)),
              ),
            ),
          ),
        ),
        for (final config in pageConfigs)
          _buildDashboardTile(
            config,
            rects[config.sensorType]!,
            cellSize,
            grid,
            [for (final entry in rects.entries) if (entry.key != config.sensorType) entry.value],
            colorScheme,
            isColorfulPerWidget,
          ),
        if (_resizeGhostRect != null && _editingConfig?.page == pageIndex)
          ResizeGhostOverlay(rect: _resizeGhostRect!, cellSize: cellSize, color: colorScheme.secondary),
      ],
    );
  }

  /// Builds one [DashboardTile], wiring every callback exactly the same way
  /// regardless of whether [config] is being rendered normally as part of
  /// its page's grid (from [_buildPageGrid]) or, while it's the one being
  /// drag-moved, as the permanent PageView-sibling avatar-host (from
  /// [build]) — the single place all of that wiring lives, so the two call
  /// sites can never drift apart from each other.
  DashboardTile _buildDashboardTile(
    SensorWidgetConfig config,
    CellRect rect,
    Size cellSize,
    GridDimensions grid,
    List<CellRect> otherRects,
    ColorScheme colorScheme,
    bool isColorfulPerWidget,
  ) {
    return DashboardTile(
      key: _keyFor(config.sensorType),
      rect: rect,
      cellSize: cellSize,
      grid: grid,
      otherRects: otherRects,
      label: sensorTypeMetadata[config.sensorType]!.label,
      icon: sensorTypeMetadata[config.sensorType]!.icon,
      accentColor: isColorfulPerWidget
          ? (perWidgetAccentColors[config.sensorType] ?? colorScheme.primary)
          : colorScheme.primary,
      content: buildDashboardSensorWidget(
        config.sensorType,
        config.displayStyle,
        _session.streams,
        onAlertColorChanged: (color) => _setAlertColor(config.sensorType, color),
        onResetRequested: (type, trigger) => _resetTriggers[type] = trigger,
        onImmediateResetRequested: (type, trigger) => _immediateResetTriggers[type] = trigger,
      ),
      onMoved: (rect) => _handleMoveCommitted(config, rect),
      onMoveStarted: () => _handleMoveStarted(config),
      onMoveCandidate: (candidate) => _handleMoveCandidate(config, candidate),
      onMoveCancelled: _handleMoveCancelled,
      onDragPositionUpdate: _handleDragGlobalPosition,
      onResized: (rect) => _handleResized(config, rect),
      alertColor: _alertColors[config.sensorType],
      isEditing: _editingConfig == config,
      // While any tile is being edited, a tap anywhere — this same tile, a
      // different one, or empty space (see _buildPageGrid's background
      // GestureDetector, which already calls _exitEditMode unconditionally)
      // — has exactly one job: end the edit session. Only once nothing is
      // being edited does tapping a tile fall back to its normal job of
      // opening the context menu.
      onTap: () => _editingConfig != null ? _exitEditMode() : _showContextMenu(config),
      onLongPress: () => _enterEditMode(config),
      // Same rule as onTap: while anything is being edited, a touch on a tile
      // ends that edit session first — it never opens something on top of it.
      onDoubleTap: () => _editingConfig != null ? _exitEditMode() : _openFullscreen(config),
      onResizePreviewChanged: _setResizeGhost,
    );
  }
}

CellRect _rectOf(SensorWidgetConfig config) => (
  x: config.position.x.round(),
  y: config.position.y.round(),
  width: config.size.width.round(),
  height: config.size.height.round(),
);

class _GridLinesPainter extends CustomPainter {
  _GridLinesPainter({required this.grid, required this.cellSize, required this.color});

  final GridDimensions grid;
  final Size cellSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0; x <= grid.columns; x++) {
      final dx = x * cellSize.width;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
    }
    for (var y = 0; y <= grid.rows; y++) {
      final dy = y * cellSize.height;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridLinesPainter oldDelegate) =>
      oldDelegate.grid != grid || oldDelegate.cellSize != cellSize || oldDelegate.color != color;

  // CustomPainter.hitTest defaults to null, which RenderCustomPaint treats
  // as "hit" (opaque) — without this override, these purely decorative grid
  // lines silently absorb every pointer that lands on empty space before it
  // can reach the background gesture layer beneath them in the Stack.
  @override
  bool? hitTest(Offset position) => false;
}
