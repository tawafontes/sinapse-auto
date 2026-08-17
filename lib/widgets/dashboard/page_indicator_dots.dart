import 'package:flutter/material.dart';

/// Row of small dots below the dashboard's page view, one per page, with the
/// current page highlighted. Purely presentational — [DashboardScreen] owns
/// which page is current and how many pages exist.
class PageIndicatorDots extends StatelessWidget {
  const PageIndicatorDots({super.key, required this.count, required this.currentPage});

  final int count;
  final int currentPage;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == currentPage ? 10 : 7,
              height: i == currentPage ? 10 : 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == currentPage ? colorScheme.primary : colorScheme.outlineVariant,
              ),
            ),
        ],
      ),
    );
  }
}
