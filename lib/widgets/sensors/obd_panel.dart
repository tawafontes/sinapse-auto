import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/detected_event.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/dashboard_alerts.dart';
import '../../services/obd/obd_consumption.dart';
import '../../services/obd/obd_service.dart';
import '../../services/vehicle_repository.dart';
import 'obd_gauges.dart';
import 'obd_widgets.dart';

String _pt(double v, int decimals) => v.toStringAsFixed(decimals).replaceAll('.', ',');
String _whole(double v) => v.round().toString();

/// A value to show and whether it is the last one of a failing link.
typedef _Read = ({double? value, bool stale});

/// The recent consumption of one [ObdService], kept outside the card so a
/// page swipe (which rebuilds the card) does not wipe the chart.
class _ConsumptionTrace {
  final samples = <({DateTime at, double litersPerHour, double speedKmh})>[];
}

final _traces = Expando<_ConsumptionTrace>('obdConsumption');

/// The OBD-II panels (owner requests, 2026-11-14 and -15): several values in
/// one card, drawn rather than listed, with more when maximized ([fullscreen]):
///
/// * Nível do tanque — an arc gauge from red (empty) through orange to green
///   (full), the % and the litres (tank of "Meu veículo"); maximized, the
///   ethanol share of the blend;
/// * Temperaturas — engine (coolant; it replaced the engine temperature card
///   on 2026-11-15), intake, ambient and catalyst, each on its own colour
///   scale; maximized, the intake manifold pressure too;
/// * Acelerador — the throttle and the pedal as two vertical bars (the
///   throttle alone on a car that does not report the pedal);
/// * Consumo instantâneo — km/L moving (L/h stopped) in big figures and a
///   chart of the last minutes ([estimateConsumption]); maximized, the
///   window's average and the basis of the estimate.
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
  bool _reportedOnce = false;

  static const _previewValues = {
    ObdSignal.fuelLevel: 62.0,
    ObdSignal.ethanol: 27.0,
    ObdSignal.intakeTemp: 34.0,
    ObdSignal.ambientTemp: 27.0,
    ObdSignal.catalystTemp: 512.0,
    ObdSignal.manifoldPressure: 38.0,
    ObdSignal.throttle: 18.0,
    ObdSignal.pedal: 22.0,
  };

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
    _readings = service.readingsStream.listen((_) {
      if (widget.sensorType == SensorType.fuelConsumption) _recordConsumption();
      _changed();
    });
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

  /// Reports the card's alert colour. The first report always goes out: a
  /// card rebuilt (page swipe, maximize) must clear a red the dashboard still
  /// holds from the card it replaced — the "all cards red" on the phone.
  void _reportAlert(Color? color) {
    if (_reportedOnce && color == _reportedAlert) return;
    _reportedOnce = true;
    _reportedAlert = color;
    final callback = widget.onAlertColorChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(color);
    });
  }

  _Read _read(ObdSignal signal) {
    if (widget.preview) return (value: _previewValues[signal], stale: false);
    final service = widget.service;
    if (service == null) return (value: null, stale: false);
    final last = service.readings[signal]?.value;
    if (service.isFresh(signal)) return (value: last, stale: false);
    if (service.state == ObdLinkState.reconnecting) return (value: last, stale: last != null);
    return (value: null, stale: false);
  }

  // ───────────────────────── consumption ─────────────────────────

  ({ObdConsumption? estimate, bool stale}) _consumption() {
    final maf = _read(ObdSignal.maf);
    final map = _read(ObdSignal.manifoldPressure);
    final rpm = _read(ObdSignal.rpm);
    final speed = _read(ObdSignal.speed);
    final estimate = estimateConsumption(
      mafGramsPerSecond: maf.value,
      manifoldPressureKpa: map.value,
      rpm: rpm.value,
      intakeTempC: _read(ObdSignal.intakeTemp).value,
      engineDisplacementLiters: VehicleRepository.profile?.engineDisplacementLiters,
      speedKmh: speed.value,
      ethanolPercent: _read(ObdSignal.ethanol).value,
    );
    return (estimate: estimate, stale: maf.stale || map.stale || rpm.stale);
  }

  _ConsumptionTrace? get _trace {
    final service = widget.service;
    if (service == null) return null;
    return _traces[service] ??= _ConsumptionTrace();
  }

  static const _keep = Duration(minutes: 5);

  void _recordConsumption() {
    final service = widget.service;
    final trace = _trace;
    if (service == null || trace == null) return;
    final c = _consumption();
    final at = service.readings[ObdSignal.rpm]?.at;
    if (c.estimate == null || c.stale || at == null) return;
    final samples = trace.samples;
    if (samples.isNotEmpty && !at.isAfter(samples.last.at)) return;
    samples.add((at: at, litersPerHour: c.estimate!.litersPerHour, speedKmh: _read(ObdSignal.speed).value ?? 0));
    while (samples.isNotEmpty && at.difference(samples.first.at) > _keep) {
      samples.removeAt(0);
    }
  }

  // ───────────────────────── build ─────────────────────────

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
    final reads = switch (widget.sensorType) {
      SensorType.fuelLevel => [_read(ObdSignal.fuelLevel)],
      SensorType.engineTemperatures => [_read(ObdSignal.coolant), _read(ObdSignal.intakeTemp), _read(ObdSignal.ambientTemp), _read(ObdSignal.catalystTemp)],
      SensorType.accelerator => [_read(ObdSignal.throttle), _read(ObdSignal.pedal)],
      _ => <_Read>[],
    };
    final consumption = widget.sensorType == SensorType.fuelConsumption && !widget.preview ? _consumption() : null;
    final stale = reads.any((r) => r.value != null && r.stale) || (consumption?.estimate != null && consumption!.stale);
    _reportAlert(stale ? dashboardAlertColor(EventSeverity.critical, theme.brightness) : null);

    final hasValue = widget.preview || reads.any((r) => r.value != null) || consumption?.estimate != null;
    if (!hasValue) {
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

    final body = switch (widget.sensorType) {
      SensorType.fuelLevel => _fuel(theme, stale),
      SensorType.engineTemperatures => _temperatures(theme, stale),
      SensorType.accelerator => _accelerator(theme, stale),
      SensorType.fuelConsumption => _consumptionBody(theme, stale),
      _ => const SizedBox.shrink(),
    };

    // Laid out on a canvas of at least 170×150 and scaled down into smaller
    // cards; larger cards give the drawing the room (no tiny text in a big
    // card, the owner's complaint).
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 200.0;
      final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 180.0;
      // Maximized panels carry more rows, so they need a taller canvas.
      final minHeight = switch (widget.sensorType) {
        SensorType.accelerator => 150.0,
        SensorType.engineTemperatures => widget.fullscreen ? 270.0 : 210.0,
        _ => widget.fullscreen ? 240.0 : 150.0,
      };
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: math.max(w, 170),
          height: math.max(h, minHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: body),
                if (stale)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      obdStatusText(widget.service, obdSignalForSensor[widget.sensorType] ?? ObdSignal.rpm),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Color _valueColor(ThemeData theme, bool stale) => stale ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface;

  /// A value as "value unit", keyed `obdPanel_<label>` (tests read it).
  Widget _value(ThemeData theme, String label, String? value, String unit, TextStyle? style, bool stale, {Color? color}) {
    final c = color ?? _valueColor(theme, stale);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: value ?? '—', style: style?.copyWith(color: c, fontWeight: FontWeight.w700)),
        if (unit.isNotEmpty) TextSpan(text: ' $unit', style: (style ?? theme.textTheme.bodyMedium)?.copyWith(color: c, fontSize: (style?.fontSize ?? 14) * 0.5)),
      ]),
      key: ValueKey('obdPanel_$label'),
      maxLines: 1,
    );
  }

  /// A label on the left and its value on the right; a long value shrinks
  /// instead of overflowing the card.
  Widget _pair(ThemeData theme, String label, Widget value) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: _label(theme, label)),
          const SizedBox(width: 8),
          Flexible(flex: 2, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: value)),
        ],
      );

  Text _label(ThemeData theme, String text) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant));

  Widget _fuel(ThemeData theme, bool stale) {
    final level = _read(ObdSignal.fuelLevel);
    final tank = VehicleRepository.profile?.tankCapacityLiters ?? (widget.preview ? 52 : null);
    final ethanol = _read(ObdSignal.ethanol);
    final style = theme.textTheme.displayLarge;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ObdArcGauge(
              value: level.value,
              min: 0,
              max: 100,
              stops: ObdScales.fuel,
              startLabel: '0',
              endLabel: '1/1',
              dimmed: stale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_gas_station_rounded, size: 40, color: level.value == null ? theme.colorScheme.outline : obdColorAt(ObdScales.fuel, level.value!)),
                  _value(theme, 'Tanque', level.value == null ? null : _whole(level.value!), '%', style, stale),
                  if (tank != null && tank > 0)
                    _value(theme, 'Litros', level.value == null ? null : '≈ ${_whole(level.value! * tank / 100)}', 'L', theme.textTheme.headlineMedium, stale),
                ],
              ),
            ),
          ),
        ),
        if (widget.fullscreen) ...[
          const SizedBox(height: 12),
          _pair(theme, 'Etanol na mistura',
              _value(theme, 'Etanol na mistura', ethanol.value == null ? null : _whole(ethanol.value!), '%', theme.textTheme.headlineSmall, ethanol.stale)),
          const SizedBox(height: 6),
          ObdScaleBar(value: ethanol.value, min: 0, max: 100, stops: const [(0, Color(0xFFFFB300)), (100, obdGreen)], thickness: 12, dimmed: ethanol.stale),
          const SizedBox(height: 2),
          Row(children: [
            Expanded(child: Text('Gasolina', maxLines: 1, overflow: TextOverflow.clip, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
            Expanded(
              child: Text('Etanol',
                  maxLines: 1, overflow: TextOverflow.clip, textAlign: TextAlign.right, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _scaleRow(ThemeData theme, String label, _Read r, String unit, double min, double max, List<ObdColorStop> stops) {
    final color = r.value == null ? null : obdColorAt(stops, r.value!);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pair(
          theme,
          label,
          _value(theme, label, r.value == null ? null : _whole(r.value!), unit, theme.textTheme.headlineSmall, r.stale,
              color: r.stale || color == null ? null : Color.lerp(color, theme.colorScheme.onSurface, 0.35)),
        ),
        const SizedBox(height: 4),
        ObdScaleBar(value: r.value, min: min, max: max, stops: stops, thickness: 10, dimmed: r.stale),
      ],
    );
  }

  Widget _temperatures(ThemeData theme, bool stale) {
    final rows = [
      _scaleRow(theme, 'Motor', _read(ObdSignal.coolant), '°C', 40, 130, ObdScales.coolant),
      _scaleRow(theme, 'Admissão', _read(ObdSignal.intakeTemp), '°C', -10, 80, ObdScales.intake),
      _scaleRow(theme, 'Ambiente', _read(ObdSignal.ambientTemp), '°C', -10, 50, ObdScales.ambient),
      _scaleRow(theme, 'Catalisador', _read(ObdSignal.catalystTemp), '°C', 0, 1000, ObdScales.catalyst),
      if (widget.fullscreen) _scaleRow(theme, 'Coletor de admissão', _read(ObdSignal.manifoldPressure), 'kPa', 10, 250, ObdScales.manifold),
    ];
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _accelerator(ThemeData theme, bool stale) {
    Widget pedal(String label, _Read r) => Expanded(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ObdScaleBar(value: r.value, min: 0, max: 100, stops: ObdScales.load, vertical: true, thickness: 30, dimmed: r.stale),
                ),
              ),
              const SizedBox(height: 6),
              FittedBox(child: _value(theme, label, r.value == null ? null : _whole(r.value!), '%', theme.textTheme.headlineMedium, r.stale)),
              _label(theme, label),
            ],
          ),
        );
    // A car that does not report the pedal (the Haval H6 PHEV) gets the
    // throttle alone, not an empty bar that reads as zero.
    final noPedal = !widget.preview && widget.service?.supports(ObdSignal.pedal) == false;
    return Row(children: [
      pedal('Acelerador', _read(ObdSignal.throttle)),
      if (!noPedal) pedal('Pedal', _read(ObdSignal.pedal)),
    ]);
  }

  Widget _consumptionBody(ThemeData theme, bool stale) {
    final window = widget.fullscreen ? 300.0 : 120.0;
    final ObdConsumption? estimate;
    final List<(double, double)> points;
    double? averageKmL;
    if (widget.preview) {
      estimate = (litersPerHour: 4.1, kmPerLiter: 14.2, fromMaf: false);
      points = [for (var i = 0; i <= 24; i++) (120.0 - i * 5, 3 + 1.6 * math.sin(i / 3) + (i % 4) * 0.2)];
    } else {
      estimate = _consumption().estimate;
      final samples = _trace?.samples ?? const [];
      final now = samples.isEmpty ? null : samples.last.at;
      final inWindow = [for (final s in samples) if (now!.difference(s.at).inMilliseconds / 1000 <= window) s];
      points = [for (final s in inWindow) (now!.difference(s.at).inMilliseconds / 1000, s.litersPerHour)];
      // Distance over fuel across the window: steadier than any instant.
      var km = 0.0, liters = 0.0;
      for (var i = 1; i < inWindow.length; i++) {
        final hours = inWindow[i].at.difference(inWindow[i - 1].at).inMilliseconds / 3.6e6;
        if (hours > 10 / 3600) continue; // a gap in the readings
        km += inWindow[i].speedKmh * hours;
        liters += inWindow[i].litersPerHour * hours;
      }
      if (km > 0.05 && liters > 0) averageKmL = km / liters;
    }
    final moving = estimate?.kmPerLiter != null;
    final big = theme.textTheme.displayLarge;
    final main = moving
        ? _value(theme, 'Consumo', _pt(estimate!.kmPerLiter!, 1), 'km/L', big, stale)
        : _value(theme, 'Vazão', estimate == null ? null : _pt(estimate.litersPerHour, 1), 'L/h', big, stale);
    final label = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Row(
            children: [
              Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: main)),
              if (moving) ...[
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _value(theme, 'Vazão', _pt(estimate!.litersPerHour, 1), 'L/h', theme.textTheme.titleLarge, stale),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ObdSparkline(points: points, window: window, minTop: 4, color: stale ? theme.colorScheme.outline : theme.colorScheme.primary),
          ),
        ),
        const SizedBox(height: 2),
        Text('L/h · últimos ${window ~/ 60} min', style: label, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (widget.fullscreen) ...[
          const SizedBox(height: 8),
          _pair(theme, 'Média no período', _value(theme, 'Média', averageKmL == null ? null : _pt(averageKmL, 1), 'km/L', theme.textTheme.headlineSmall, stale)),
          _pair(
            theme,
            'Base',
            Text(
              estimate == null ? '—' : (estimate.fromMaf ? 'sensor MAF' : 'pressão do coletor'),
              key: const ValueKey('obdPanel_Base'),
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          Text('Estimativa: será calibrada com os seus abastecimentos.', style: label),
        ],
      ],
    );
  }
}
