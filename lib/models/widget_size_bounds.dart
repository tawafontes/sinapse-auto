import 'dart:math' as math;

import '../services/dashboard_layout_engine.dart' show GridDimensions;

/// Min/max footprint (in grid cells) a widget can be resized to. Bounds
/// apply independently per axis, so e.g. a 6x2 or 2x4 rectangle is as valid
/// as a 4x4 square.
class SizeBounds {
  const SizeBounds({
    required this.minWidth,
    required this.minHeight,
    required this.maxWidth,
    required this.maxHeight,
  });

  final int minWidth;
  final int minHeight;
  final int maxWidth;
  final int maxHeight;
}

const int kUniversalMinWidth = 2;
const int kUniversalMinHeight = 2;
const int kUniversalMaxWidth = 6;
const int kUniversalMaxHeight = 4;
const int kDefaultCreateWidth = 2;
const int kDefaultCreateHeight = 2;

/// One rule for every widget regardless of `DisplayStyle`: min 2x2, max 6x4,
/// clamped down to the grid's own column/row count so a tile can never be
/// proposed wider/taller than the grid itself. In portrait (4 columns) this
/// clamps max width to 4 even though the general rule allows 6; landscape
/// (6 columns, 4 rows) needs no clamping at all.
SizeBounds universalBounds(GridDimensions grid) => SizeBounds(
  minWidth: kUniversalMinWidth,
  minHeight: kUniversalMinHeight,
  maxWidth: math.min(kUniversalMaxWidth, grid.columns),
  maxHeight: math.min(kUniversalMaxHeight, grid.rows),
);
