import 'package:flutter/widgets.dart' show Orientation;

import '../models/sensor_widget_config.dart';
import '../models/widget_size_bounds.dart';

/// Grid shape for the current orientation — 6x4 landscape, 4x6 portrait, per
/// the spec. A record, so it gets structural equality for free.
typedef GridDimensions = ({int columns, int rows});

GridDimensions gridDimensionsFor(Orientation orientation) {
  return orientation == Orientation.landscape
      ? (columns: 6, rows: 4)
      : (columns: 4, rows: 6);
}

/// How far a resize handle's tap target extends beyond its tile's own rect
/// (handles straddle the tile's edges/corners, half in and half out) — see
/// [DashboardTile]'s own handle layout.
const double kResizeHandleOverhang = 14.0;

/// Which neighboring page a dragged tile's pointer currently at [globalX]
/// (within a [viewportWidth]-wide dashboard) is hovering close enough to an
/// edge of to trigger an auto page-switch: -1 (previous), 1 (next), or null
/// (not near either edge). [zoneWidth] is how wide that edge zone is, in the
/// same pixel units as [globalX]/[viewportWidth]. Pure geometry — pulled out
/// of the dashboard screen (which pairs this with a hover-delay timer, see
/// `kDragEdgeHoverDelayMax`/`kDragEdgeHoverDelayMin`) so the zone math itself can be unit-tested without
/// a widget tree or platform channels.
int? dragEdgeHoverDirection({required double globalX, required double viewportWidth, required double zoneWidth}) {
  if (globalX < zoneWidth) return -1;
  if (globalX > viewportWidth - zoneWidth) return 1;
  return null;
}

/// How deep into the edge zone (from [dragEdgeHoverDirection]'s own
/// [zoneWidth]) a pointer currently at [globalX] is — `0.0` right at the
/// zone's *outer* boundary (just barely hovering), `1.0` right at the
/// physical screen edge — or `null` outside the zone entirely (mirrors
/// [dragEdgeHoverDirection]'s own null case). Pure geometry, same rationale
/// as that function: unit-testable without a widget tree. Callers use this
/// to make auto-scroll *progressive* — a page switch triggers sooner the
/// closer the pointer is to the true edge — instead of a single fixed delay
/// regardless of exactly where within the zone the pointer sits.
double? dragEdgeHoverProximity({required double globalX, required double viewportWidth, required double zoneWidth}) {
  if (zoneWidth <= 0) return null;
  if (globalX < zoneWidth) return ((zoneWidth - globalX) / zoneWidth).clamp(0.0, 1.0);
  final fromRightEdge = viewportWidth - globalX;
  if (fromRightEdge < zoneWidth) return ((zoneWidth - fromRightEdge) / zoneWidth).clamp(0.0, 1.0);
  return null;
}

/// A widget's footprint in grid cells. Also a record — value equality lets
/// callers cheaply check "did this actually change" with `!=`.
typedef CellRect = ({int x, int y, int width, int height});

extension CellRectGeometry on CellRect {
  bool overlaps(CellRect other) {
    return x < other.x + other.width &&
        other.x < x + width &&
        y < other.y + other.height &&
        other.y < y + height;
  }

  bool fitsWithin(GridDimensions grid) {
    return x >= 0 && y >= 0 && x + width <= grid.columns && y + height <= grid.rows;
  }
}

CellRect _rectOf(SensorWidgetConfig config) => (
  x: config.position.x.round(),
  y: config.position.y.round(),
  width: config.size.width.round(),
  height: config.size.height.round(),
);

/// Finds the first free top-left cell (row-major scan) that fits a
/// `width x height` footprint without overlapping any rect in [occupied].
/// Returns null if nothing fits anywhere in [grid].
CellRect? firstFit({
  required Iterable<CellRect> occupied,
  required GridDimensions grid,
  required int width,
  required int height,
}) {
  for (var y = 0; y <= grid.rows - height; y++) {
    for (var x = 0; x <= grid.columns - width; x++) {
      final candidate = (x: x, y: y, width: width, height: height);
      if (occupied.every((rect) => !rect.overlaps(candidate))) return candidate;
    }
  }
  return null;
}

/// Reconciles every [configs]' position/size against [grid]: widgets whose
/// stored rect already fits in-bounds and doesn't collide with another
/// already-accepted widget are left alone (preserving whatever the user
/// dragged/resized); everything else (brand new widgets using the unplaced
/// sentinel position, or widgets that no longer fit after an orientation
/// change) gets auto-placed via [firstFit], reusing their current size if it
/// still fits their style's category bounds for this grid, else the
/// category minimum.
///
/// Returns the resolved rect per sensor. Does not mutate or persist
/// anything — callers diff this against the configs' current values to know
/// what changed and needs saving.
Map<SensorType, CellRect> reconcileLayout({
  required List<SensorWidgetConfig> configs,
  required GridDimensions grid,
}) {
  final accepted = <SensorType, CellRect>{};
  final needsPlacement = <SensorWidgetConfig>[];

  for (final config in configs) {
    final rect = _rectOf(config);
    final isSentinel = config.position.x < 0 || config.position.y < 0;
    final fits = !isSentinel &&
        rect.fitsWithin(grid) &&
        accepted.values.every((other) => !other.overlaps(rect));
    if (fits) {
      accepted[config.sensorType] = rect;
    } else {
      needsPlacement.add(config);
    }
  }

  for (final config in needsPlacement) {
    final bounds = universalBounds(grid);
    var width = config.size.width.round();
    var height = config.size.height.round();
    final sizeUsable = width >= bounds.minWidth &&
        width <= bounds.maxWidth &&
        width <= grid.columns &&
        height >= bounds.minHeight &&
        height <= bounds.maxHeight &&
        height <= grid.rows;
    if (!sizeUsable) {
      width = bounds.minWidth.clamp(1, grid.columns);
      height = bounds.minHeight.clamp(1, grid.rows);
    }

    final placed = firstFit(
      occupied: accepted.values,
      grid: grid,
      width: width,
      height: height,
    );
    // No free footprint anywhere (only possible if many large widgets are
    // packed into one grid) — fall back to the origin rather than dropping
    // the widget; the user can drag it apart manually.
    accepted[config.sensorType] = placed ?? (x: 0, y: 0, width: width, height: height);
  }

  return accepted;
}

/// Attempts to place [draggedRect] (the tile the user is actively dragging)
/// among a page's [others] by *relocating* — not rejecting — whichever of
/// [others] it would overlap: each displaced widget moves to the nearest
/// available free footprint via [firstFit], processed in a stable
/// top-to-bottom/left-to-right order (so the same drag position always
/// reflows identically, and so no relocation can ever collide with an
/// earlier one in the same pass — no cascades beyond the initially-
/// overlapped set). Widgets [draggedRect] doesn't overlap are left
/// completely untouched (minimal-disruption, not a full page re-pack).
///
/// Returns null if [draggedRect] itself doesn't fit [grid], or if any
/// displaced widget has nowhere left to go — callers treat that as "this
/// candidate isn't achievable," never a partial commit.
Map<SensorType, CellRect>? resolveDragReflow({
  required CellRect draggedRect,
  required SensorType draggedType,
  required List<SensorWidgetConfig> others,
  required GridDimensions grid,
}) {
  if (!draggedRect.fitsWithin(grid)) return null;

  final displaced = <SensorWidgetConfig>[];
  final settled = <CellRect>[draggedRect];
  for (final other in others) {
    final rect = _rectOf(other);
    if (rect.overlaps(draggedRect)) {
      displaced.add(other);
    } else {
      settled.add(rect);
    }
  }

  displaced.sort((a, b) {
    final ra = _rectOf(a);
    final rb = _rectOf(b);
    return ra.y != rb.y ? ra.y.compareTo(rb.y) : ra.x.compareTo(rb.x);
  });

  final result = <SensorType, CellRect>{draggedType: draggedRect};
  for (final config in displaced) {
    final rect = _rectOf(config);
    final placed = firstFit(occupied: settled, grid: grid, width: rect.width, height: rect.height);
    if (placed == null) return null;
    settled.add(placed);
    result[config.sensorType] = placed;
  }

  return result;
}

/// Result of trying to place every sentinel-position config in [allConfigs]
/// onto one of up to [maxPages] independent grids.
typedef PagePlacementResult = ({
  Map<SensorType, ({int page, CellRect rect})> placed,
  List<SensorType> unplaced,
});

/// Places every sentinel-position (brand new / newly-added) config in
/// [allConfigs] onto the first page with room, trying [preferredPage] first
/// (if given and in range) then scanning pages `0..maxPages-1` in order. An
/// empty or not-yet-used page naturally has no occupied rects, so [firstFit]
/// returning a result for it *is* "auto-create the next page" — no separate
/// branch needed. Already-placed (non-sentinel) configs in [allConfigs] are
/// read only, to seed per-page occupancy; use [reconcileLayout] separately
/// to re-fit those after an orientation change.
PagePlacementResult placeAcrossPages({
  required List<SensorWidgetConfig> allConfigs,
  required GridDimensions grid,
  required int maxPages,
  int? preferredPage,
}) {
  final occupiedByPage = <int, List<CellRect>>{
    for (var p = 0; p < maxPages; p++)
      p: [
        for (final c in allConfigs)
          if (c.page == p && c.position.x >= 0) _rectOf(c),
      ],
  };

  final bounds = universalBounds(grid);
  final pageOrder = [
    if (preferredPage != null && preferredPage >= 0 && preferredPage < maxPages) preferredPage,
    for (var p = 0; p < maxPages; p++)
      if (p != preferredPage) p,
  ];

  final placed = <SensorType, ({int page, CellRect rect})>{};
  final unplaced = <SensorType>[];

  for (final config in allConfigs) {
    if (config.position.x >= 0) continue; // already placed — not our concern.

    CellRect? result;
    int? resultPage;
    for (final page in pageOrder) {
      final candidate = firstFit(
        occupied: occupiedByPage[page]!,
        grid: grid,
        width: kDefaultCreateWidth.clamp(bounds.minWidth, bounds.maxWidth),
        height: kDefaultCreateHeight.clamp(bounds.minHeight, bounds.maxHeight),
      );
      if (candidate != null) {
        result = candidate;
        resultPage = page;
        break;
      }
    }

    if (result != null && resultPage != null) {
      occupiedByPage[resultPage]!.add(result);
      placed[config.sensorType] = (page: resultPage, rect: result);
    } else {
      unplaced.add(config.sensorType);
    }
  }

  return (placed: placed, unplaced: unplaced);
}
