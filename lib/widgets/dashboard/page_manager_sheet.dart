import 'package:flutter/material.dart';

import '../../models/sensor_widget_config.dart';
import '../../services/dashboard_layout_engine.dart';

/// A page's sensor plus its grid footprint — enough to draw a proportional
/// mini-layout thumbnail, unlike a bare [SensorType] list.
typedef PageManagerEntry = ({SensorType type, CellRect rect});

/// Opens the dashboard's page manager — an Android-home-screen-style
/// overview of every page, reached by long-pressing empty dashboard space.
/// Lets the user jump to a page, add a new one (up to [maxPages]), or delete
/// any page but the last one remaining — deleting a page that still has
/// widgets asks for confirmation first, since that discards them.
Future<void> showPageManagerSheet({
  required BuildContext context,
  required List<List<PageManagerEntry>> pages,
  required GridDimensions grid,
  required int currentPage,
  required int maxPages,
  required Future<void> Function() onAddPage,
  required Future<void> Function(int page) onDeletePage,
  required ValueChanged<int> onNavigateToPage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // See the identical comment in dashboard_tile_context_menu.dart: without
    // this, the sheet is capped at 9/16 of the available height by the
    // framework's own default, regardless of actual content — this sheet's
    // content is normally well under that, but a large system font size on
    // the header row is enough to push it over on a short/landscape screen.
    isScrollControlled: true,
    builder: (_) => PageManagerSheet(
      pages: pages,
      grid: grid,
      currentPage: currentPage,
      maxPages: maxPages,
      onAddPage: onAddPage,
      onDeletePage: onDeletePage,
      onNavigateToPage: onNavigateToPage,
    ),
  );
}

/// See [showPageManagerSheet]. [pages] is a snapshot (index = page number,
/// value = the sensors placed on it, with their rects for the thumbnail)
/// taken when the sheet opens; it's kept as local state so add/delete can
/// update the list in place without closing the sheet, letting the user
/// manage several pages in one visit. Tapping a page to navigate to it is
/// the one action that closes the sheet.
class PageManagerSheet extends StatefulWidget {
  const PageManagerSheet({
    super.key,
    required this.pages,
    required this.grid,
    required this.currentPage,
    required this.maxPages,
    required this.onAddPage,
    required this.onDeletePage,
    required this.onNavigateToPage,
  });

  final List<List<PageManagerEntry>> pages;
  final GridDimensions grid;
  final int currentPage;
  final int maxPages;
  final Future<void> Function() onAddPage;
  final Future<void> Function(int page) onDeletePage;
  final ValueChanged<int> onNavigateToPage;

  @override
  State<PageManagerSheet> createState() => _PageManagerSheetState();
}

class _PageManagerSheetState extends State<PageManagerSheet> {
  late List<List<PageManagerEntry>> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [for (final page in widget.pages) [...page]];
  }

  Future<void> _addPage() async {
    await widget.onAddPage();
    if (!mounted) return;
    setState(() => _pages.add(const []));
  }

  Future<void> _deletePage(int page) async {
    final entries = _pages[page];
    if (entries.isNotEmpty) {
      final confirmed = await _confirmDeleteNonEmptyPage(context, page: page, widgetCount: entries.length);
      if (confirmed != true) return;
    }
    if (!mounted) return;
    await widget.onDeletePage(page);
    if (!mounted) return;
    setState(() => _pages.removeAt(page));
  }

  void _navigateTo(int page) {
    Navigator.of(context).pop();
    widget.onNavigateToPage(page);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Páginas do painel'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Concluir',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: _pages.length + (_pages.length < widget.maxPages ? 1 : 0),
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  if (i == _pages.length) {
                    return _AddPageCard(onTap: _addPage);
                  }
                  return _PageCard(
                    index: i,
                    entries: _pages[i],
                    grid: widget.grid,
                    isCurrent: i == widget.currentPage,
                    canDelete: _pages.length > 1,
                    onTap: () => _navigateTo(i),
                    onDelete: () => _deletePage(i),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Confirms deleting a non-empty page — an empty one is removed outright,
/// but losing [widgetCount] placed sensor widgets is destructive enough to
/// require an explicit yes.
Future<bool?> _confirmDeleteNonEmptyPage(BuildContext context, {required int page, required int widgetCount}) {
  final colorScheme = Theme.of(context).colorScheme;
  final noun = widgetCount == 1 ? 'ferramenta' : 'ferramentas';
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Excluir Página ${page + 1}?'),
      content: Text(
        'Esta página tem $widgetCount $noun. Elas serão removidas permanentemente junto com a página.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancelar')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Excluir', style: TextStyle(color: colorScheme.error)),
        ),
      ],
    ),
  );
}

const _cardWidth = 120.0;

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.index,
    required this.entries,
    required this.grid,
    required this.isCurrent,
    required this.canDelete,
    required this.onTap,
    required this.onDelete,
  });

  final int index;
  final List<PageManagerEntry> entries;
  final GridDimensions grid;
  final bool isCurrent;
  final bool canDelete;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _cardWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCurrent ? colorScheme.primary : colorScheme.outlineVariant,
                  width: isCurrent ? 2.5 : 1,
                ),
                boxShadow: isCurrent
                    ? [BoxShadow(color: colorScheme.primary.withValues(alpha: 0.25), blurRadius: 8)]
                    : null,
              ),
              child: Column(
                children: [
                  Expanded(child: _PageThumbnail(entries: entries, grid: grid, isCurrent: isCurrent)),
                  const SizedBox(height: 6),
                  Text(
                    'Página ${index + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                      color: isCurrent ? colorScheme.primary : colorScheme.onSurface,
                    ),
                  ),
                  if (entries.isEmpty)
                    Text('Vazia', style: TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          if (canDelete)
            Positioned(
              right: -6,
              top: -6,
              child: _DeleteBadge(onTap: onDelete),
            ),
        ],
      ),
    );
  }
}

/// Small proportional preview of a page's layout — plain rectangles at each
/// widget's [PageManagerEntry.rect], scaled to the card, not real sensor
/// content (cheap, and never risks mock/real data leaking into the picker).
class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({required this.entries, required this.grid, required this.isCurrent});

  final List<PageManagerEntry> entries;
  final GridDimensions grid;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: grid.columns / grid.rows,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cellWidth = constraints.maxWidth / grid.columns;
          final cellHeight = constraints.maxHeight / grid.rows;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Stack(
              children: [
                for (final entry in entries)
                  Positioned(
                    left: entry.rect.x * cellWidth,
                    top: entry.rect.y * cellHeight,
                    width: entry.rect.width * cellWidth,
                    height: entry.rect.height * cellHeight,
                    child: Container(
                      key: ValueKey('pageThumbnailRect_${entry.type.name}'),
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: (isCurrent ? colorScheme.primary : colorScheme.onSurfaceVariant)
                            .withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DeleteBadge extends StatelessWidget {
  const _DeleteBadge({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Excluir página',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: colorScheme.error,
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface, width: 2),
          ),
          child: Icon(Icons.delete_outline, size: 14, color: colorScheme.onError),
        ),
      ),
    );
  }
}

class _AddPageCard extends StatelessWidget {
  const _AddPageCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _cardWidth,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: DottedBorderBox(
          color: colorScheme.outlineVariant,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline, size: 32, color: colorScheme.primary),
              const SizedBox(height: 8),
              Text(
                'Adicionar página',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A simple dashed-look rounded box (drawn as a thin dashed border via
/// [CustomPaint], not a real dashed-border package) for the "add page"
/// affordance — deliberately understated/original rather than mimicking any
/// specific platform's own add-page graphic.
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color),
      child: Padding(padding: const EdgeInsets.all(8), child: child),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(14));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dashWidth = 6.0;
    const gapWidth = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dashWidth + gapWidth;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => oldDelegate.color != color;
}
