import 'package:flutter/material.dart';

/// Colors for a session's tracked extreme(s) — originally altitude-only
/// (hence the name), now also reused by the speed line chart (its MÁX badge
/// and, swapped, its MÉD badge — see `LineChart.highlightMaxInRed`) and the
/// G-force meter's vertical bar peak markers, so they all stay visually
/// consistent. Tuned per brightness: a fixed shade reads fine in light mode
/// but washes out toward muddy brown/olive over a near-black dark
/// background, so dark mode gets lighter, more saturated tones instead of
/// just a fixed hue.
typedef AltitudeExtremeStyle = ({Color min, Color max});

AltitudeExtremeStyle altitudeExtremeStyleFor(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return (min: const Color(0xFFE57373), max: const Color(0xFF64B5F6));
  }
  return (min: const Color(0xFFF44336), max: const Color(0xFF2196F3));
}

/// The reset-confirmation dialog shared by the line chart's two sensors
/// (altitude, speed). [title]/[confirmLabel] default to altitude's original
/// wording — unchanged for that caller — since speed's stats are no longer
/// "mínimo e máximo" (it shows máximo + média instead), its `LineChart`
/// instance overrides both to match. Returns true if the user confirmed;
/// callers reset their own local session-stat state.
Future<bool> confirmResetAltitudeExtremes(
  BuildContext context, {
  String title = 'Resetar mínimo e máximo de altitude?',
  String confirmLabel = 'Resetar mínimo e máximo',
}) async {
  final colorScheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: const Text(
        'Os valores registrados nesta sessão serão substituídos pela leitura atual.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
