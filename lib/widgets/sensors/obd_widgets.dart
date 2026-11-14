import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/detected_event.dart';
import '../../models/sensor_widget_config.dart';
import '../../services/dashboard_alerts.dart';
import '../../services/obd/obd_service.dart';

/// Which OBD value a dashboard sensor shows.
const Map<SensorType, ObdSignal> obdSignalForSensor = {
  SensorType.engineRpm: ObdSignal.rpm,
  SensorType.engineCoolant: ObdSignal.coolant,
  SensorType.batteryVoltage: ObdSignal.adapterVoltage,
  SensorType.engineLoad: ObdSignal.engineLoad,
};

/// What an OBD widget says instead of a value (owner decision, 2026-11-11:
/// the widgets stay on the dashboard and show the link's state).
String obdStatusText(ObdService? service, ObdSignal signal) {
  if (service == null) return 'OBD indisponível';
  return switch (service.state) {
    ObdLinkState.noAdapter => 'Configurar adaptador',
    ObdLinkState.off => 'OBD desligado',
    ObdLinkState.connecting => 'Conectando…',
    ObdLinkState.reconnecting => 'Reconectando…',
    ObdLinkState.waitingForCar => signal == ObdSignal.adapterVoltage ? 'Conectando…' : 'Ligue o carro',
    ObdLinkState.receiving => service.supports(signal) == false ? 'Seu carro não informa este dado' : 'Aguardando dados…',
  };
}

String _format(ObdSignal signal, double value) => switch (signal) {
      ObdSignal.adapterVoltage || ObdSignal.moduleVoltage => value.toStringAsFixed(1).replaceAll('.', ','),
      _ => value.round().toString(),
    };

/// A dashboard widget for one OBD-II value (phase 1): the live value; before
/// any value, what the link is doing; after a drop, the **last** value with
/// the card's border in red (owner decision, 2026-11-13) — reported through
/// [onAlertColorChanged], the same central card-alert path the artificial
/// horizon uses, so the dashboard keeps one border mechanism.
///
/// Display only: reads the [ObdService]'s state and last values (through
/// `DashboardSensorStreams.obd`); it never talks to the adapter.
class ObdSignalView extends StatefulWidget {
  const ObdSignalView({
    super.key,
    required this.signal,
    required this.service,
    required this.unit,
    this.tachometer = false,
    this.onAlertColorChanged,
  }) : previewValue = null;

  /// A static look for the style picker.
  const ObdSignalView.preview({super.key, required this.signal, required this.unit, required double value, this.tachometer = false})
      : service = null,
        onAlertColorChanged = null,
        previewValue = value;

  final ObdSignal signal;
  final ObdService? service;
  final String unit;
  final bool tachometer;
  final ValueChanged<Color?>? onAlertColorChanged;
  final double? previewValue;

  @override
  State<ObdSignalView> createState() => _ObdSignalViewState();
}

class _ObdSignalViewState extends State<ObdSignalView> {
  StreamSubscription<ObdReadings>? _readings;
  Timer? _freshness;
  Color? _reportedAlert;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(ObdSignalView oldWidget) {
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
    // A value goes stale with no event of its own (ObdService.maxAge).
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

  void _reportAlert(Color? color) {
    if (color == _reportedAlert) return;
    _reportedAlert = color;
    final callback = widget.onAlertColorChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(color);
    });
  }

  @override
  void dispose() {
    _detach(widget.service);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = widget.service;
    final double? value;
    final bool stale;
    if (widget.previewValue != null) {
      value = widget.previewValue;
      stale = false;
    } else {
      value = service?.readings[widget.signal]?.value;
      stale = value != null && !(service?.isFresh(widget.signal) ?? false);
    }
    _reportAlert(stale ? dashboardAlertColor(EventSeverity.critical, theme.brightness) : null);

    if (value == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            obdStatusText(service, widget.signal),
            key: const ValueKey('obdStatusText'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final text = _format(widget.signal, value);
    final valueColor = stale ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface;
    final caption = stale ? obdStatusText(service, widget.signal) : null;
    if (widget.tachometer) {
      return _Tachometer(rpm: value, text: text, unit: widget.unit, color: valueColor, caption: caption);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: FittedBox(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          text,
                          key: const ValueKey('obdValueText'),
                          style: theme.textTheme.displayMedium?.copyWith(color: valueColor, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 4),
                        Text(widget.unit, style: theme.textTheme.titleMedium?.copyWith(color: valueColor)),
                      ],
                    ),
                  ),
                ),
                if (caption != null)
                  Text(caption, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The rev counter: a 240° arc to [_maxRpmFor] with the last 1000 rpm marked
/// red, the needle, and the value in the middle.
class _Tachometer extends StatelessWidget {
  const _Tachometer({required this.rpm, required this.text, required this.unit, required this.color, this.caption});

  final double rpm;
  final String text;
  final String unit;
  final Color color;
  final String? caption;

  static double _maxRpmFor(double rpm) => rpm > 7000 ? 9000 : 7000;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = _maxRpmFor(rpm);
    return Padding(
      padding: const EdgeInsets.all(6),
      child: AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(
          key: const ValueKey('obdTachometer'),
          painter: _TachometerPainter(
            fraction: (rpm / max).clamp(0.0, 1.0),
            redFrom: (max - 1000) / max,
            track: theme.colorScheme.surfaceContainerHighest,
            arc: theme.colorScheme.primary,
            red: theme.colorScheme.error,
            needle: color,
            ticks: max ~/ 1000,
          ),
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.6,
              heightFactor: 0.45,
              child: FittedBox(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(text, key: const ValueKey('obdValueText'), style: theme.textTheme.displaySmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
                    Text(unit, style: theme.textTheme.labelLarge?.copyWith(color: color)),
                    if (caption != null) Text(caption!, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TachometerPainter extends CustomPainter {
  _TachometerPainter({
    required this.fraction,
    required this.redFrom,
    required this.track,
    required this.arc,
    required this.red,
    required this.needle,
    required this.ticks,
  });

  final double fraction;
  final double redFrom;
  final Color track;
  final Color arc;
  final Color red;
  final Color needle;
  final int ticks;

  static const _start = math.pi * 5 / 6; // 150°: lower left
  static const _sweep = math.pi * 4 / 3; // 240°

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 * 0.9;
    final stroke = radius * 0.12;
    final rect = Rect.fromCircle(center: center, radius: radius);
    Paint line(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.butt;

    canvas.drawArc(rect, _start, _sweep, false, line(track, stroke));
    canvas.drawArc(rect, _start + _sweep * redFrom, _sweep * (1 - redFrom), false, line(red.withValues(alpha: 0.35), stroke));
    canvas.drawArc(rect, _start, _sweep * fraction, false, line(fraction >= redFrom ? red : arc, stroke));

    final tick = line(needle.withValues(alpha: 0.6), stroke * 0.25);
    for (var i = 0; i <= ticks; i++) {
      final a = _start + _sweep * i / ticks;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * (radius - stroke), center + dir * (radius - stroke * 1.8), tick);
    }

    final a = _start + _sweep * fraction;
    final dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(center + dir * radius * 0.55, center + dir * (radius - stroke * 0.5), line(needle, stroke * 0.35)..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_TachometerPainter old) =>
      old.fraction != fraction || old.redFrom != redFrom || old.track != track || old.arc != arc || old.red != red || old.needle != needle;
}
