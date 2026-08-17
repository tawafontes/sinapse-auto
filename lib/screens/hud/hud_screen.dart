import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChrome, SystemUiMode;

import '../../models/telemetry_snapshot.dart';
import '../../models/unit_system.dart';
import '../../services/app_settings.dart';
import '../../services/dashboard_sensor_streams.dart';
import '../../services/unit_preferences.dart';

/// Compact 8-point compass abbreviation for a heading in degrees — pulled
/// out as a pure function so the bucketing math is independently
/// unit-testable. `null` (no reliable heading — see
/// `TelemetryEngine.headingDegrees`'s own doc) reads as "--", never a
/// guessed direction.
@visibleForTesting
String headingCompassAbbreviation(double? headingDegrees) {
  if (headingDegrees == null) return '--';
  const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final normalized = headingDegrees % 360;
  final index = ((normalized / 45) + 0.5).floor() % 8;
  return directions[index];
}

/// Windshield-projection ("head-up display") mode — the same essential
/// telemetry (speed, heading, altitude, G-force) already shown on the
/// Dashboard, reformatted for legibility when reflected off glass: large,
/// high-contrast text on a deliberately pure-black background (light
/// doesn't reflect off black, only the bright text does — a fixed choice
/// for this screen's specific optical purpose, not a bypass of the app's
/// own day/night theme switching, which continues to govern every other
/// screen exactly as before).
///
/// Reuses the exact same [DashboardSensorStreams] instance the Dashboard
/// itself owns (passed in, never constructed here) — opening the HUD
/// starts no new sensor subscription; it reads
/// [DashboardSensorStreams.snapshot], the same central telemetry stream
/// every other consumer (Diagnostics, sessions, alerts) already reads.
///
/// [_mirrored] flips the *presentation* only (a [Transform] applied at the
/// very end of the widget tree) — every underlying value stays exactly as
/// measured; only which side of the screen it's drawn on changes. Reuses
/// this app's existing immersive-mode pattern
/// (`SensorFullscreenScreen`'s own [SystemChrome] usage) rather than a
/// second implementation.
class HudScreen extends StatefulWidget {
  const HudScreen({super.key, required this.streams});

  final DashboardSensorStreams streams;

  @override
  State<HudScreen> createState() => _HudScreenState();
}

class _HudScreenState extends State<HudScreen> {
  StreamSubscription<TelemetrySnapshot>? _sub;
  TelemetrySnapshot? _snapshot;
  late bool _mirrored;

  @override
  void initState() {
    super.initState();
    _mirrored = AppSettings.hudMirrored;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _sub = widget.streams.snapshot.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _toggleMirror() {
    setState(() => _mirrored = !_mirrored);
    unawaited(AppSettings.setHudMirrored(_mirrored));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    final snapshot = _snapshot;
    final speed = snapshot?.speedKmh;
    final altitude = snapshot?.altitudeMeters;
    final heading = snapshot?.headingDegrees;
    final gForce = snapshot?.gForceMagnitude;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => Navigator.of(context).pop(),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(_mirrored ? -1.0 : 1.0, 1.0, 1.0),
          child: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _HudSpeedReadout(
                        speedKmh: speed,
                        unit: speedUnitLabel(prefs.speedUnit),
                        transform: (kmh) => convertSpeedFromKmh(kmh, prefs.speedUnit),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _HudMinorReadout(
                            label: headingCompassAbbreviation(heading),
                            value: heading == null ? '--' : '${heading.toStringAsFixed(0)}°',
                          ),
                          const SizedBox(width: 48),
                          _HudMinorReadout(
                            label: 'ALT',
                            value: altitude == null
                                ? '--'
                                : '${convertAltitudeFromMeters(altitude, prefs.altitudeUnit).toStringAsFixed(0)} ${altitudeUnitLabel(prefs.altitudeUnit)}',
                          ),
                          const SizedBox(width: 48),
                          _HudMinorReadout(label: 'G', value: gForce == null ? '--' : gForce.toStringAsFixed(1)),
                        ],
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: Icon(_mirrored ? Icons.flip : Icons.flip_outlined, color: Colors.white24),
                    tooltip: 'Espelhar',
                    onPressed: _toggleMirror,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HudSpeedReadout extends StatelessWidget {
  const _HudSpeedReadout({required this.speedKmh, required this.unit, required this.transform});

  final double? speedKmh;
  final String unit;
  final double Function(double) transform;

  @override
  Widget build(BuildContext context) {
    final display = speedKmh == null ? '--' : transform(speedKmh!).toStringAsFixed(0);
    return Column(
      children: [
        Text(display, style: const TextStyle(color: Colors.white, fontSize: 140, fontWeight: FontWeight.bold, height: 1)),
        Text(unit, style: const TextStyle(color: Colors.white70, fontSize: 24, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _HudMinorReadout extends StatelessWidget {
  const _HudMinorReadout({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
