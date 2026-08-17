import 'package:flutter/material.dart';

/// The dashboard tile long-press menu: delete, change style (if the sensor
/// has more than one valid style), fullscreen, and a trailing reset/
/// calibrate action (only for sensors that offer one — speed, G-force,
/// altitude, inclination). Each option pops the sheet, then invokes its
/// callback.
///
/// [onResetRecords]'s label and icon are configurable ([resetRecordsLabel]/
/// [resetRecordsIcon]) rather than fixed, since the same slot covers two
/// different kinds of action across callers — a destructive "erase my
/// stats" (speed, defaults to "Resetar registros") and a non-destructive
/// "recalibrate" (inclination) — without needing two parallel optional
/// menu items for what's, structurally, the exact same thing: one trailing
/// action.
///
/// [isFullscreen] is the same idea applied to the fullscreen item itself:
/// this one menu serves both the Dashboard tile's own long-press ("Colocar
/// em tela cheia", pushes the fullscreen route) and the fullscreen screen's
/// reused options menu ("Sair da tela cheia", pops back to the Dashboard)
/// — [onFullscreen] is whichever of those two actions the caller wants,
/// this flag only swaps the label/icon so the option always reads correctly
/// for the widget's *current* state instead of needing a second, separate
/// menu implementation for the fullscreen case.
Future<void> showDashboardTileContextMenu({
  required BuildContext context,
  required IconData icon,
  required String label,
  // Nullable so a live camera preview (which has no "delete" concept, Fase
  // 15) can reuse this same menu — every dashboard-tile/fullscreen call
  // site still passes a real callback.
  VoidCallback? onDelete,
  VoidCallback? onChangeStyle,
  required VoidCallback onFullscreen,
  bool isFullscreen = false,
  VoidCallback? onResetRecords,
  String resetRecordsLabel = 'Resetar registros',
  IconData resetRecordsIcon = Icons.restart_alt,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Without this, showModalBottomSheet's default (isScrollControlled:
    // false) caps the sheet's content at 9/16 of the available height
    // (Flutter's own _ModalBottomSheetLayout) regardless of how many items
    // this menu actually has — a menu with every optional item present
    // (onChangeStyle + onResetRecords) could exceed that fraction and
    // overflow. true lets the sheet size itself to the full available
    // height instead (still computed by the framework from MediaQuery, not
    // a value picked here), and the SingleChildScrollView below is the
    // fallback for the rare case where even that isn't enough.
    isScrollControlled: true,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      void run(VoidCallback action) {
        Navigator.of(sheetContext).pop();
        action();
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(icon, color: colorScheme.primary),
                title: Text(label, style: Theme.of(sheetContext).textTheme.titleMedium),
                enabled: false,
              ),
              const Divider(height: 1),
              if (onDelete != null)
                ListTile(
                  leading: Icon(Icons.delete_outline, color: colorScheme.error),
                  title: Text('Excluir', style: TextStyle(color: colorScheme.error)),
                  onTap: () => run(onDelete),
                ),
              if (onChangeStyle != null)
                ListTile(
                  leading: const Icon(Icons.style_outlined),
                  title: const Text('Alterar o estilo'),
                  onTap: () => run(onChangeStyle),
                ),
              ListTile(
                leading: Icon(isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                title: Text(isFullscreen ? 'Sair da tela cheia' : 'Colocar em tela cheia'),
                onTap: () => run(onFullscreen),
              ),
              if (onResetRecords != null)
                ListTile(
                  leading: Icon(resetRecordsIcon),
                  title: Text(resetRecordsLabel),
                  onTap: () => run(onResetRecords),
                ),
            ],
          ),
        ),
      );
    },
  );
}
