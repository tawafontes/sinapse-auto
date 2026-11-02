import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/unit_system.dart';
import '../../services/dashcam_session_controller.dart';
import '../../services/driving_session_recorder.dart';
import '../../services/gnss_quality.dart';
import '../../services/unit_preferences.dart';

/// Start/stop control for a driving session — reads/writes the shared
/// [DrivingSessionRecorder] the caller already owns (never constructs its
/// own, so this screen can be closed and reopened, or the app can be
/// backgrounded, without interrupting an active recording).
///
/// [dashcamController] (Fase 15), when present, becomes the actual
/// start/stop entry point instead of calling [recorder] directly — it
/// starts/stops the driving session AND (if Dashcam is enabled) the camera
/// together, with the camera side isolated from failure (see that
/// controller's own doc). Nullable and optional so existing callers/tests
/// that only pass [recorder] keep compiling unchanged.
class SessionRecordingScreen extends StatefulWidget {
  const SessionRecordingScreen({super.key, required this.recorder, this.dashcamController});

  final DrivingSessionRecorder recorder;
  final DashcamSessionController? dashcamController;

  @override
  State<SessionRecordingScreen> createState() => _SessionRecordingScreenState();
}

class _SessionRecordingScreenState extends State<SessionRecordingScreen> {
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    widget.recorder.addListener(_onRecorderChanged);
    widget.dashcamController?.addListener(_onRecorderChanged);
    // The recorder itself only notifies on a new telemetry sample (~1Hz
    // while GPS/sensors are actually producing readings) — this separate,
    // lightweight UI-only timer keeps the elapsed-time readout ticking
    // smoothly even during a brief lull (e.g. a momentary GNSS gap),
    // matching the polish of a real stopwatch rather than looking frozen.
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.recorder.isRecording) setState(() {});
    });
  }

  void _onRecorderChanged() => setState(() {});

  @override
  void dispose() {
    widget.recorder.removeListener(_onRecorderChanged);
    widget.dashcamController?.removeListener(_onRecorderChanged);
    _tickTimer?.cancel();
    super.dispose();
  }

  void _startSession() {
    final dashcamController = widget.dashcamController;
    try {
      if (dashcamController != null) {
        dashcamController.startSession();
      } else {
        widget.recorder.startSession();
      }
    } on SessionAdmissionRejected {
      // Fase 16.2-R4.3-R2.6.4: expected only if this button was rendered a
      // moment before a session started finalizing; nothing was touched, and
      // the recorder's own notification rebuilds this screen.
    }
  }

  /// Also the RETRY (Fase 16.2-R4.3-R2.6.4): while the recorder reports
  /// [DrivingSessionRecorderState.finalizationFailed], stopping again repeats
  /// only the persistence that is still missing for the same session — offered
  /// only once the controller says a stop would do that (Fase 16.2-R4.4-R1.2,
  /// see `build`).
  void _stopSession() {
    final dashcamController = widget.dashcamController;
    final stop = dashcamController != null ? dashcamController.stopSession() : widget.recorder.stopSession();
    unawaited(
      stop.catchError((Object error) {
        // A persistence failure is kept by the recorder and shown below, with a
        // retry; anything else is not expected here and must still surface.
        if (widget.recorder.state != DrivingSessionRecorderState.finalizationFailed) throw error;
      }),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.recorder.activeSession;
    final recorderState = widget.recorder.state;
    // Fase 16.2-R4.4-R1.2 (X66-screen): the recorder reports its failure while
    // the session's STOP request may still be finishing (camera, telemetry);
    // a stop requested then joins that request and retries nothing. The retry is
    // executable only once the controller says a stop would retry — it notifies
    // when that changes.
    final dashcamController = widget.dashcamController;
    final retryWaiting =
        recorderState == DrivingSessionRecorderState.finalizationFailed && dashcamController != null && !dashcamController.canRetrySessionFinalization;
    final colorScheme = Theme.of(context).colorScheme;
    final prefs = UnitPreferencesScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Sessão de condução')),
      // SingleChildScrollView (Fase 13.1 incidental fix): this screen's
      // content overflowed in landscape (a RenderFlex overflow, confirmed on
      // device) — the wrap keeps the same centered look when everything
      // fits, and scrolls instead of clipping when it doesn't.
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: session == null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer_outlined, size: 64, color: colorScheme.onSurfaceVariant),
                        const SizedBox(height: 16),
                        const Text('Nenhuma sessão em andamento', textAlign: TextAlign.center),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _startSession,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Iniciar sessão'),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // An ended session (being finalized) no longer grows.
                        Text(_formatDuration((session.endTime ?? DateTime.now()).difference(session.startTime)), style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 24),
                        _StatRow(
                          label: 'Velocidade atual',
                          value: widget.recorder.currentSpeedKmh == null
                              ? '—'
                              : '${convertSpeedFromKmh(widget.recorder.currentSpeedKmh!, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}',
                        ),
                        _StatRow(
                          label: 'Distância',
                          value: '${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
                        ),
                        _StatRow(
                          label: 'Velocidade média',
                          value: session.avgSpeedKmh == null
                              ? '—'
                              : '${convertSpeedFromKmh(session.avgSpeedKmh!, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}',
                        ),
                        _StatRow(
                          label: 'Velocidade máxima',
                          value: session.maxSpeedKmh == null
                              ? '—'
                              : '${convertSpeedFromKmh(session.maxSpeedKmh!, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}',
                        ),
                        _StatRow(
                          label: 'Altitude',
                          value: session.maxAltitudeMeters == null || session.minAltitudeMeters == null
                              ? '—'
                              : '${convertAltitudeFromMeters(session.minAltitudeMeters!, prefs.altitudeUnit).toStringAsFixed(0)} – '
                                    '${convertAltitudeFromMeters(session.maxAltitudeMeters!, prefs.altitudeUnit).toStringAsFixed(0)} ${altitudeUnitLabel(prefs.altitudeUnit)}',
                        ),
                        _StatRow(
                          label: 'Aceleração G máxima',
                          value: session.maxGForceMagnitude == null ? '—' : '${session.maxGForceMagnitude!.toStringAsFixed(2)} g',
                        ),
                        _StatRow(
                          label: 'Qualidade GNSS',
                          value: gnssQualityLabel(widget.recorder.currentGnssQuality),
                        ),
                        if (widget.dashcamController != null)
                          _StatRow(
                            label: 'Dashcam',
                            value: widget.dashcamController!.statusLabel,
                          ),
                        // Fase 16.2-R4.3-R2.6.10: the video keeps recording, but the
                        // telemetry file failed and nothing more is being saved to it.
                        if (widget.dashcamController?.telemetryFailureMessage case final telemetryFailure?)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(telemetryFailure, textAlign: TextAlign.center, style: TextStyle(color: colorScheme.error)),
                          ),
                        // Fase 16.2-R4.3-R2.6.4: a failed finalization is shown, with the retry.
                        if (recorderState == DrivingSessionRecorderState.finalizationFailed) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Não foi possível salvar a sessão (${widget.recorder.lastFinalizationError}). '
                            'Os dados continuam preservados; verifique o armazenamento e tente finalizar novamente.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colorScheme.error),
                          ),
                          if (retryWaiting) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'A tentativa anterior ainda está terminando (câmera e telemetria). '
                              'A nova tentativa fica disponível assim que ela terminar.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
                          onPressed: recorderState == DrivingSessionRecorderState.finalizing || retryWaiting ? null : _stopSession,
                          icon: const Icon(Icons.stop),
                          label: Text(switch (recorderState) {
                            DrivingSessionRecorderState.finalizing => 'Finalizando…',
                            DrivingSessionRecorderState.finalizationFailed => 'Tentar finalizar novamente',
                            _ => 'Finalizar sessão',
                          }),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: Theme.of(context).textTheme.bodyLarge),
          Text(value, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
