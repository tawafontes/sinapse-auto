import 'package:flutter/material.dart';

import '../../services/dashboard_layout_engine.dart';

/// The dashed/bordered outline shown while dragging one of a
/// [DashboardTile]'s resize handles — tracks the grid-snapped candidate
/// [rect] the tile would resize to on release. Rendered by the dashboard
/// page (not the tile itself) since a shrink/grow from a top or left handle
/// can extend beyond the tile's own clipped box.
class ResizeGhostOverlay extends StatelessWidget {
  const ResizeGhostOverlay({super.key, required this.rect, required this.cellSize, required this.color});

  final CellRect rect;
  final Size cellSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: rect.x * cellSize.width,
      top: rect.y * cellSize.height,
      width: rect.width * cellSize.width,
      height: rect.height * cellSize.height,
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2.5),
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
