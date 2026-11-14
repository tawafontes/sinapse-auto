import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/detected_event.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/dashboard_alerts.dart';
import '../../services/obd/obd_consumption.dart';
import '../../services/obd/obd_service.dart';
import '../../services/vehicle_repository.dart';
import 'obd_widgets.dart';

/// One line of an OBD panel: a label, the value as text (or `null`: no
/// value) and whether that value is the last one of a failing link.
typedef ObdPanelLine = ({String label, String? value, String unit, bool stale});

String _pt(double v, int decimals) => v.toStringAsFixed(decimals).replaceAll('.', ',');

/// The OBD-II panels (owner request, 2026-11-14): several values in one card,
/// with more of them when the card is maximized ([fullscreen]):
///
/// * Nível do tanque — the tank's %, and its litres with the tank capacity of
///   "Meu veículo"; maximized, also the ethanol share of the blend;
/// * Temperaturas — intake air, ambient and catalyst; maximized, also the
///   intake manifold pressure;
/// * Acelerador — the throttle and the accelerator pedal;
/// * Consumo instantâneo — km/L moving (L/h stopped), estimated from the MAF
///   or, without one, from the manifold pressure and the displacement of
///   "Meu veículo" ([estimateConsumption]); calibrated against the refuels in
///   phase 2.
///
/// The same rules as every OBD card ([ObdSignalView]): live values; the link's
/// state when there are none; after a drop, the last values with the card's
/// border in red, steady (owner decisions) — through [onAlertColorChanged].
class ObdPanelView extends StatefulWidget {
  const ObdPanelView({super.key, required this.sensorType, required this.service, this.fullscreen = false, this.onAlertColorChanged})
      : preview = false;

  /// A static look for the style picker.
  const ObdPanelView.preview({super.key, required this.sensorType})
      : service = null,
        fullscreen = false,
        onAlertColorChanged = null,
        preview = true;

  final SensorType sensorType;
  final ObdService? service;
  final bool fullscreen;
  final ValueChanged<Color?>? onAlertColorChanged;
  final bool preview;

  @override
  State<ObdPanelView> createState() => _ObdPanelViewState();
}

class _ObdPanelViewState extends State<ObdPanelView> {
  StreamSubscription<ObdReadings>? _readings;
  Timer? _freshness;
  Color? _reportedAlert;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(ObdPanelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      _detach(oldWidget.service);
      _attach();
    }
  }

  void _attach() {
    final service = widget.service;
    if (service == null) return;
    service.addListener(_changed);
    _readings = service.readingsStream.listen((_) => _changed());
    _freshness = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
  }

  void _detach(ObdService? service) {
    service?.removeListener(_changed);
    unawaited(_readings?.cancel());
    _readings = null;
    _freshness?.cancel();
    _freshness = null;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _detach(widget.service);
    super.dispose();
  }

  void _reportAlert(Color? color) {
    if (color == _reportedAlert) return;
    _reportedAlert = color;
    final callback = widget.onAlertColorChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(color);
    });
  }

  /// A value to show and whether it is stale: live, or the last one while
  /// the link is failing (the red-border rule); otherwise none.
  ({double? value, bool stale}) _read(ObdSignal signal) {
    final service = widget.service;
    if (service == null) return (value: null, stale: false);
    final last = service.readings[signal]?.value;
    if (service.isFresh(signal)) return (value: last, stale: false);
    if (service.state == ObdLinkState.reconnecting) return (value: last, stale: last != null);
    return (value: null, stale: false);
  }

  List<ObdPanelLine> _lines() {
    if (widget.preview) return _previewLines(widget.sensorType);
    ObdPanelLine line(String label, ObdSignal signal, String unit, String Function(double) format) {
      final r = _read(signal);
      return (label: label, value: r.value == null ? null : format(r.value!), unit: unit, stale: r.stale);
    }

    String whole(double v) => v.round().toString();
    final full = widget.fullscreen;
    switch (widget.sensorType) {
      case SensorType.fuelLevel:
        final level = _read(ObdSignal.fuelLevel);
        final tank = VehicleRepository.profile?.tankCapacityLiters;
        return [
          line('Tanque', ObdSignal.fuelLevel, '%', whole),
          if (tank != null && tank > 0)
            (label: 'Litros', value: level.value == null ? null : '≈ ${whole(level.value! * tank / 100)}', unit: 'L', stale: level.stale),
          if (full) line('Etanol na mistura', ObdSignal.ethanol, '%', whole),
        ];
      case SensorType.engineTemperatures:
        return [
          line('Admissão', ObdSignal.intakeTemp, '°C', whole),
          line('Ambiente', ObdSignal.ambientTemp, '°C', whole),
          line('Catalisador', ObdSignal.catalystTemp, '°C', whole),
          if (full) line('Coletor de admissão', ObdSignal.manifoldPressure, 'kPa', whole),
        ];
      case SensorType.accelerator:
        return [
          line('Acelerador', ObdSignal.throttle, '%', whole),
          line('Pedal', ObdSignal.pedal, '%', whole),
        ];
      case SensorType.fuelConsumption:
        final maf = _read(ObdSignal.maf);
        final map = _read(ObdSignal.manifoldPressure);
        final rpm = _read(ObdSignal.rpm);
        final iat = _read(ObdSignal.intakeTemp);
        final speed = _read(ObdSignal.speed);
        final ethanol = _read(ObdSignal.ethanol);
        final estimate = estimateConsumption(
          mafGramsPerSecond: maf.value,
          manifoldPressureKpa: map.value,
          rpm: rpm.value,
          intakeTempC: iat.value,
          engineDisplacementLiters: VehicleRepository.profile?.engineDisplacementLiters,
          speedKmh: speed.value,
          ethanolPercent: ethanol.value,
        );
        final stale = maf.stale || map.stale || rpm.stale;
        return [
          (label: 'Consumo', value: estimate?.kmPerLiter == null ? null : _pt(estimate!.kmPerLiter!, 1), unit: 'km/L', stale: stale),
          (label: 'Vazão', value: estimate == null ? null : _pt(estimate.litersPerHour, 1), unit: 'L/h', stale: stale),
          if (full)
            (
              label: 'Base',
              value: estimate == null ? null : (estimate.fromMaf ? 'sensor MAF' : 'pressão do coletor'),
              unit: '',
              stale: false,
            ),
        ];
      default:
        return const [];
    }
  }

  static List<ObdPanelLine> _previewLines(SensorType type) => switch (type) {
        SensorType.fuelLevel => const [(label: 'Tanque', value: '62', unit: '%', stale: false), (label: 'Litros', value: '≈ 32', unit: 'L', stale: false)],
        SensorType.engineTemperatures => const [
            (label: 'Admissão', value: '34', unit: '°C', stale: false),
            (label: 'Ambiente', value: '27', unit: '°C', stale: false),
            (label: 'Catalisador', value: '512', unit: '°C', stale: false),
          ],
        SensorType.accelerator => const [(label: 'Acelerador', value: '18', unit: '%', stale: false), (label: 'Pedal', value: '22', unit: '%', stale: false)],
        SensorType.fuelConsumption => const [(label: 'Consumo', value: '14,2', unit: 'km/L', stale: false), (label: 'Vazão', value: '4,1', unit: 'L/h', stale: false)],
        _ => const [],
      };

  /// What the card says with no value at all.
  String _emptyText() {
    final service = widget.service;
    final signal = obdSignalForSensor[widget.sensorType] ?? ObdSignal.rpm;
    if (widget.sensorType == SensorType.fuelConsumption &&
        service?.state == ObdLinkState.receiving &&
        service?.supports(ObdSignal.maf) != true &&
        VehicleRepository.profile?.engineDisplacementLiters == null) {
      return 'Informe a cilindrada em Meu veículo';
    }
    return obdStatusText(service, signal);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _lines();
    final stale = lines.any((l) => l.value != null && l.stale);
    _reportAlert(stale ? dashboardAlertColor(EventSeverity.critical, theme.brightness) : null);

    // Consumption stopped: no km/L, but the flow means something.
    final shown = widget.sensorType == SensorType.fuelConsumption && lines.first.value == null && lines.length > 1 && lines[1].value != null
        ? [lines[1], ...lines.skip(2)]
        : lines;

    if (shown.every((l) => l.value == null)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _emptyText(),
            key: const ValueKey('obdStatusText'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final valueColor = stale ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface;
    final first = shown.first;
    final rest = shown.skip(1).toList();
    final showBars = widget.sensorType == SensorType.accelerator;
    Widget valueText(ObdPanelLine l, TextStyle? style) => Text.rich(
          TextSpan(children: [
            TextSpan(text: l.value ?? '—', style: style?.copyWith(color: valueColor, fontWeight: FontWeight.w600)),
            if (l.unit.isNotEmpty) TextSpan(text: ' ${l.unit}', style: theme.textTheme.labelLarge?.copyWith(color: valueColor)),
          ]),
          key: ValueKey('obdPanel_${l.label}'),
          maxLines: 1,
        );
    Widget bar(ObdPanelLine l) {
      final v = double.tryParse(l.value ?? '') ?? 0;
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: LinearProgressIndicator(value: (v / 100).clamp(0, 1), minHeight: widget.fullscreen ? 10 : 5, borderRadius: BorderRadius.circular(4)),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 140, maxWidth: 260),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(first.label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              valueText(first, theme.textTheme.displaySmall),
              if (showBars) bar(first),
              for (final l in rest) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(l.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    const SizedBox(width: 8),
                    // A long value ("pressão do coletor") shrinks instead of
                    // overflowing the card (found by the panel test).
                    Flexible(
                      flex: 2,
                      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: valueText(l, theme.textTheme.titleMedium)),
                    ),
                  ],
                ),
                if (showBars) bar(l),
              ],
              if (widget.fullscreen && widget.sensorType == SensorType.fuelConsumption)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Estimativa: será calibrada com os seus abastecimentos.',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              if (stale)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(obdStatusText(widget.service, obdSignalForSensor[widget.sensorType] ?? ObdSignal.rpm),
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
