import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/sensor_reading.dart';
import '../../models/unit_system.dart';
import '../../services/altitude_trend.dart';
import '../../services/dashboard_sensor_streams.dart';
import '../../services/gnss_quality.dart';
import '../../services/unit_preferences.dart';

/// Portuguese label for how much a GNSS-derived reading (speed, heading)
/// should be trusted, derived from the same [GnssQuality] that already
/// gates the reading itself — pulled out as its own function (rather than
/// inlined per call site) so "what counts as high/medium/low confidence" is
/// defined exactly once, matching [gnssQualityLabel]'s own convention.
@visibleForTesting
String gnssConfidenceLabel(GnssQuality quality) {
  switch (quality) {
    case GnssQuality.excellent:
    case GnssQuality.good:
      return 'Alta';
    case GnssQuality.moderate:
      return 'Média';
    case GnssQuality.weak:
    case GnssQuality.unavailable:
      return 'Baixa';
  }
}

/// Portuguese label + a short icon for [AltitudeTrend] — pulled out as a top-
/// level function for the same direct-unit-testability reason as
/// [gnssQualityLabel].
@visibleForTesting
String altitudeTrendLabel(AltitudeTrend trend) {
  switch (trend) {
    case AltitudeTrend.rising:
      return 'Subindo';
    case AltitudeTrend.falling:
      return 'Descendo';
    case AltitudeTrend.stable:
      return 'Estável';
  }
}

IconData _altitudeTrendIcon(AltitudeTrend trend) {
  switch (trend) {
    case AltitudeTrend.rising:
      return Icons.trending_up;
    case AltitudeTrend.falling:
      return Icons.trending_down;
    case AltitudeTrend.stable:
      return Icons.trending_flat;
  }
}

/// Whether a sensor is considered actively reporting — [last] (the
/// timestamp of its most recent sample) is recent enough relative to [now].
/// A null [last] (no sample ever received) is never fresh.
@visibleForTesting
bool isSampleFresh(DateTime? last, {required DateTime now, Duration staleAfter = const Duration(seconds: 3)}) {
  if (last == null) return false;
  return now.difference(last) <= staleAfter;
}

/// Read-only technical diagnostics for GNSS and the MEMS sensors — reached
/// from Settings. Purely informative: no control here can change any
/// internal parameter (no calibration trigger, no sensor toggle), matching
/// the screen's own purpose of showing raw system health, not configuring
/// it.
///
/// Reuses the *same* [DashboardSensorStreams] instance the Dashboard itself
/// already owns (passed in, never constructed here) — opening this screen
/// starts no new sensor subscription that didn't already exist; it only
/// adds listeners to streams ([DashboardSensorStreams.snapshot], the raw
/// accelerometer/gyroscope/barometer streams for their sample-rate
/// counters) that are already safely multi-listener (`asBroadcastStream`)
/// by construction. Closing this screen simply removes those listeners —
/// if the Dashboard isn't also listening to the same signals, the
/// underlying hardware subscription stops exactly like it would for any
/// other screen transition.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.streams});

  final DashboardSensorStreams streams;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  static const _staleAfter = Duration(seconds: 3);

  StreamSubscription<void>? _snapshotSub;
  StreamSubscription<void>? _accelSub;
  StreamSubscription<void>? _gyroSub;
  StreamSubscription<void>? _positionSub;
  Timer? _rateTimer;

  double? _speedKmh;
  double? _altitudeMeters;
  double? _headingDegrees;
  double? _horizontalAccuracy;
  double? _verticalAccuracy;
  GnssQuality _gnssQuality = GnssQuality.unavailable;
  AltitudeTrend _altitudeTrend = AltitudeTrend.stable;
  double? _pitchDegrees;
  double? _rollDegrees;
  bool _barometerActive = false;

  DateTime? _lastAccelSample;
  DateTime? _lastGyroSample;
  DateTime? _lastPositionSample;
  int _accelCountThisSecond = 0;
  int _gyroCountThisSecond = 0;
  double _accelHz = 0;
  double _gyroHz = 0;

  @override
  void initState() {
    super.initState();
    _snapshotSub = widget.streams.snapshot.listen((snapshot) {
      setState(() {
        _speedKmh = snapshot.speedKmh;
        _altitudeMeters = snapshot.altitudeMeters;
        _headingDegrees = snapshot.headingDegrees;
        _horizontalAccuracy = snapshot.horizontalAccuracyMeters;
        _verticalAccuracy = snapshot.verticalAccuracyMeters;
        _gnssQuality = snapshot.gnssQuality;
        _altitudeTrend = snapshot.altitudeTrend;
        _pitchDegrees = snapshot.pitchDegrees;
        _rollDegrees = snapshot.rollDegrees;
        _barometerActive = snapshot.barometerActive;
      });
    });

    _accelSub = widget.streams.sensors.accelerometerStream.listen((VectorReading _) {
      _lastAccelSample = DateTime.now();
      _accelCountThisSecond++;
    });
    _gyroSub = widget.streams.sensors.gyroscopeStream.listen((VectorReading _) {
      _lastGyroSample = DateTime.now();
      _gyroCountThisSecond++;
    });
    // Purely for the "Última leitura" age display below — the fix's own
    // lat/lng/accuracy/quality already arrive via [snapshot] above; this
    // listener only needs the arrival timestamp, not another copy of the
    // position itself. Same already-shared, ref-counted GPS subscription
    // `positionStream` always is — no new hardware connection.
    _positionSub = widget.streams.sensors.positionStream.listen((_) {
      setState(() => _lastPositionSample = DateTime.now());
    });

    _rateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _accelHz = _accelCountThisSecond.toDouble();
        _gyroHz = _gyroCountThisSecond.toDouble();
        _accelCountThisSecond = 0;
        _gyroCountThisSecond = 0;
      });
    });
  }

  @override
  void dispose() {
    _snapshotSub?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _positionSub?.cancel();
    _rateTimer?.cancel();
    super.dispose();
  }

  bool _isFresh(DateTime? last) => isSampleFresh(last, now: DateTime.now(), staleAfter: _staleAfter);

  /// "120 ms" / "2.4 s" style age of the last GNSS fix — matches section
  /// 29's own example format ("Última leitura: 120 ms") rather than a raw
  /// timestamp, since what's diagnostically useful here is *how current*
  /// the fix is, not the wall-clock time it arrived.
  String _lastReadingAgeLabel(DateTime? last) {
    if (last == null) return '—';
    final age = DateTime.now().difference(last);
    if (age.inMilliseconds < 1000) return '${age.inMilliseconds} ms';
    return '${(age.inMilliseconds / 1000).toStringAsFixed(1)} s';
  }

  Color _gnssQualityColor(GnssQuality quality, ColorScheme colorScheme) {
    switch (quality) {
      case GnssQuality.unavailable:
        return colorScheme.error;
      case GnssQuality.weak:
        return Colors.orange;
      case GnssQuality.moderate:
        return Colors.amber;
      case GnssQuality.good:
        return Colors.lightGreen;
      case GnssQuality.excellent:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final prefs = UnitPreferencesScope.of(context);
    final speedUnit = speedUnitLabel(prefs.speedUnit);
    final altitudeUnit = altitudeUnitLabel(prefs.altitudeUnit);
    final speedValue = _speedKmh == null ? null : convertSpeedFromKmh(_speedKmh!, prefs.speedUnit);
    final altitudeValue = _altitudeMeters == null ? null : convertAltitudeFromMeters(_altitudeMeters!, prefs.altitudeUnit);
    final verticalAccuracyValue = _verticalAccuracy == null ? null : convertAltitudeFromMeters(_verticalAccuracy!, prefs.altitudeUnit);
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _SectionCard(
              title: 'GNSS',
              icon: Icons.satellite_alt,
              rows: [
                _DiagnosticRow(
                  'Estado',
                  gnssQualityLabel(_gnssQuality),
                  valueColor: _gnssQualityColor(_gnssQuality, colorScheme),
                ),
                const _DiagnosticRow('Satélites', 'Não exposto pela plataforma'),
                _DiagnosticRow('Precisão horizontal', _horizontalAccuracy == null ? '—' : '±${_horizontalAccuracy!.toStringAsFixed(1)} m'),
                _DiagnosticRow('Precisão vertical', verticalAccuracyValue == null ? '—' : '±${verticalAccuracyValue.toStringAsFixed(1)} $altitudeUnit'),
                _DiagnosticRow('Última leitura', _lastReadingAgeLabel(_lastPositionSample)),
                _DiagnosticRow('Altitude', altitudeValue == null ? '—' : '${altitudeValue.toStringAsFixed(0)} $altitudeUnit'),
                _DiagnosticRow(
                  'Tendência da altitude',
                  altitudeValue == null ? '—' : altitudeTrendLabel(_altitudeTrend),
                  icon: altitudeValue == null ? null : _altitudeTrendIcon(_altitudeTrend),
                ),
                _DiagnosticRow('Velocidade', speedValue == null ? '—' : '${speedValue.toStringAsFixed(0)} $speedUnit'),
                if (speedValue != null) ...[
                  const _DiagnosticRow('  Fonte', 'GNSS'),
                  _DiagnosticRow('  Confiança', gnssConfidenceLabel(_gnssQuality)),
                ],
                _DiagnosticRow('Direção (heading)', _headingDegrees == null ? 'Indisponível (baixa velocidade ou sem precisão)' : '${_headingDegrees!.toStringAsFixed(0)}°'),
                if (_headingDegrees != null) ...[
                  const _DiagnosticRow('  Fonte', 'GNSS'),
                  _DiagnosticRow('  Confiança', gnssConfidenceLabel(_gnssQuality)),
                ],
              ],
            ),
            _SectionCard(
              title: 'Acelerômetro',
              icon: Icons.speed,
              rows: [
                _DiagnosticRow('Estado', _isFresh(_lastAccelSample) ? 'Ativo' : 'Aguardando amostras', valueColor: _isFresh(_lastAccelSample) ? Colors.green : null),
                _DiagnosticRow('Frequência', '${_accelHz.toStringAsFixed(0)} Hz'),
              ],
            ),
            _SectionCard(
              title: 'Giroscópio',
              icon: Icons.threed_rotation,
              rows: [
                _DiagnosticRow('Estado', _isFresh(_lastGyroSample) ? 'Ativo' : 'Aguardando amostras', valueColor: _isFresh(_lastGyroSample) ? Colors.green : null),
                _DiagnosticRow('Frequência', '${_gyroHz.toStringAsFixed(0)} Hz'),
              ],
            ),
            _SectionCard(
              title: 'Barômetro',
              icon: Icons.compress,
              rows: [
                _DiagnosticRow(
                  'Estado',
                  _barometerActive ? 'Ativo' : 'Não disponível neste dispositivo',
                  valueColor: _barometerActive ? Colors.green : null,
                ),
              ],
            ),
            _SectionCard(
              title: 'Inclinação',
              icon: Icons.architecture,
              rows: [
                const _DiagnosticRow('Estado', 'Ativo', valueColor: Colors.green),
                _DiagnosticRow('Pitch', _pitchDegrees == null ? '—' : '${_pitchDegrees!.toStringAsFixed(1)}°'),
                _DiagnosticRow('Roll', _rollDegrees == null ? '—' : '${_rollDegrees!.toStringAsFixed(1)}°'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.icon, required this.rows});

  final String title;
  final IconData icon;
  final List<_DiagnosticRow> rows;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(height: 20),
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow(this.label, this.value, {this.valueColor, this.icon});

  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: valueColor),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: valueColor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
