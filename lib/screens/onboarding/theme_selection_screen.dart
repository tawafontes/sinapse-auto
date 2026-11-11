import 'package:flutter/material.dart';

import '../../models/color_palette_metadata.dart';
import '../../models/font_family_metadata.dart';
import '../../models/theme_config.dart';
import '../../services/sensor_widget_repository.dart';
import '../../services/theme_controller.dart';
import '../dashboard/dashboard_screen.dart';

/// Lets the user pick screen mode, color palette and typography. Every tap
/// updates [ThemeController] immediately so the whole app re-skins live —
/// "Concluir" just persists whatever is currently previewed; leaving any
/// other way reverts to the last saved theme.
class ThemeSelectionScreen extends StatefulWidget {
  const ThemeSelectionScreen({super.key});

  @override
  State<ThemeSelectionScreen> createState() => _ThemeSelectionScreenState();
}

class _ThemeSelectionScreenState extends State<ThemeSelectionScreen> {
  bool _confirmed = false;

  @override
  void dispose() {
    if (!_confirmed) {
      ThemeControllerScope.of(context).revertToPersisted();
    }
    super.dispose();
  }

  Future<void> _finish(BuildContext context) async {
    final controller = ThemeControllerScope.of(context);
    // The first "Concluir" ends the onboarding (a persisted theme is what marks
    // it done, see main.dart): the dashboard then opens with every widget
    // instead of empty. Seeded BEFORE the commit, so a process death in
    // between repeats the onboarding (and finds the widgets already there)
    // rather than leaving an empty dashboard. Revisiting "Tema" later never
    // re-adds a widget the user deleted.
    if (!controller.isPersisted && SensorWidgetRepository.all.isEmpty) {
      await SensorWidgetRepository.addDefaultWidgets();
    }
    await controller.commit();
    _confirmed = true;
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const DashboardScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ThemeControllerScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Tema')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Modo de tela', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _ScreenModeOption(
              icon: Icons.dark_mode,
              label: 'Escuro fixo',
              selected: controller.screenMode == ScreenMode.dark,
              onTap: () => controller.previewScreenMode(ScreenMode.dark),
            ),
            _ScreenModeOption(
              icon: Icons.light_mode,
              label: 'Claro fixo',
              selected: controller.screenMode == ScreenMode.light,
              onTap: () => controller.previewScreenMode(ScreenMode.light),
            ),
            _ScreenModeOption(
              icon: Icons.brightness_auto,
              label: 'Automático (por horário)',
              description:
                  'Alterna entre claro e escuro conforme o horário do dia '
                  '(escuro das 18h às 6h), sem depender de sensor de luz.',
              selected: controller.screenMode == ScreenMode.auto,
              onTap: () => controller.previewScreenMode(ScreenMode.auto),
            ),
            const SizedBox(height: 24),
            Text('Paleta de cores', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...colorPalettes.values.map(
              (palette) => _PaletteOption(
                palette: palette,
                selected: controller.colorPaletteId == palette.id,
                onTap: () => controller.previewColorPalette(palette.id),
              ),
            ),
            const SizedBox(height: 24),
            Text('Tipografia', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: fontFamilyLabels.entries.map((entry) {
                final isSelected = controller.fontFamilyId == entry.key;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _FontFamilyOptionCard(
                      fontId: entry.key,
                      label: entry.value,
                      selected: isSelected,
                      onTap: () => controller.previewFontFamily(entry.key),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => _finish(context),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Concluir'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScreenModeOption extends StatelessWidget {
  const _ScreenModeOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.description,
  });

  final IconData icon;
  final String label;
  final String? description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: description == null ? null : Text(description!),
        trailing: selected ? Icon(Icons.check_circle, color: colorScheme.primary) : null,
        onTap: onTap,
      ),
    );
  }
}

class _PaletteOption extends StatelessWidget {
  const _PaletteOption({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final ColorPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: selected ? colorScheme.primaryContainer : null,
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: palette.swatchColors
              .take(4)
              .map(
                (color) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: CircleAvatar(radius: 10, backgroundColor: color),
                ),
              )
              .toList(),
        ),
        title: Text(palette.label),
        trailing: selected ? Icon(Icons.check_circle, color: colorScheme.primary) : null,
        onTap: onTap,
      ),
    );
  }
}

class _FontFamilyOptionCard extends StatelessWidget {
  const _FontFamilyOptionCard({
    required this.fontId,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String fontId;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(
              'Aa 123',
              style: TextStyle(fontSize: 24, fontFamily: resolveFontFamily(fontId)),
            ),
            const SizedBox(height: 8),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
