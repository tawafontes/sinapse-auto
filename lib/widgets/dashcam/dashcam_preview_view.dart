import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../models/dashcam_status.dart';
import '../../screens/sessions/dashcam_recordings_screen.dart';
import '../../screens/settings/dashcam_settings_screen.dart';
import '../../services/dashcam_session_controller.dart';
import '../../services/driving_session_recorder.dart' show DrivingSessionRecorderState, SessionAdmissionRejected;

/// The Dashcam fullscreen `content` (pushed via the same `SensorFullscreenScreen`
/// every other instrument uses, Fase 15) — a live [CameraPreview] with a
/// slim status bar while recording, or a state-appropriate empty view
/// (disabled/idle/error) otherwise, mirroring `SessionRecordingScreen`'s own
/// empty-state convention.
class DashcamPreviewView extends StatefulWidget {
  const DashcamPreviewView({super.key, required this.controller});

  final DashcamSessionController controller;

  @override
  State<DashcamPreviewView> createState() => _DashcamPreviewViewState();
}

class _DashcamPreviewViewState extends State<DashcamPreviewView> {
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.controller.status == DashcamStatus.recording) setState(() {});
    });
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _tickTimer?.cancel();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _formatMb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.status;
    final previewController = controller.dashcamService.previewController;

    if (status == DashcamStatus.recording && previewController != null && previewController.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(previewController),
          Positioned(left: 0, right: 0, bottom: 0, child: _StatusBar(controller: controller, formatElapsed: _formatElapsed, formatMb: _formatMb)),
        ],
      );
    }

    return _EmptyState(controller: controller);
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller, required this.formatElapsed, required this.formatMb});

  final DashcamSessionController controller;
  final String Function(Duration) formatElapsed;
  final String Function(int) formatMb;

  @override
  Widget build(BuildContext context) {
    final startedAt = controller.recordingStartedAt;
    final elapsed = startedAt == null ? null : DateTime.now().difference(startedAt);
    // Fase 16.2-R4.4-HW-MIG-5-SIG-2: only this bar changes; the preview above it
    // stays mounted through a rotation.
    final confirmed = controller.segmentPresentation == DashcamSegmentPresentation.videoConfirmed;
    final label = confirmed ? 'REC' : controller.statusLabel;

    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.black54),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            confirmed ? const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 14) : const Icon(Icons.videocam_outlined, color: Colors.white70, size: 14),
            const SizedBox(width: 6),
            Text(
              elapsed == null ? label : '$label · ${formatElapsed(elapsed)}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '${formatMb(controller.totalClipBytes)} / ${formatMb(controller.quotaBytes)} MB',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (_canStopFromPreview(controller)) ...[
              const SizedBox(width: 12),
              _StopButton(controller: controller),
            ],
          ],
        ),
      ),
    );
  }
}

/// Fase 16.2-R4.3-R2.6.4: this button may have been rendered a moment before a
/// start became unavailable (a stop issued elsewhere); the controller then
/// refuses with [SessionAdmissionRejected] before touching anything, and its own
/// notification rebuilds this view — so that one, expected refusal is not an
/// error here. Any other error still propagates.
void _startFromTile(DashcamSessionController controller) {
  try {
    controller.startSession();
  } on SessionAdmissionRejected {
    // Expected and side-effect-free — see above.
  }
}

/// Whether this preview offers to stop: only while the driving session is
/// recording — not while it is being finalized (the stop is already under way)
/// and not after a failed finalization, whose retry stays on the session
/// screen (see the idle message below).
bool _canStopFromPreview(DashcamSessionController controller) =>
    controller.sessionRecorder.state == DrivingSessionRecorderState.recording;

bool _cameraEngaged(DashcamStatus status) => switch (status) {
  DashcamStatus.initializing || DashcamStatus.recording || DashcamStatus.cameraUnavailable || DashcamStatus.error => true,
  DashcamStatus.disabled || DashcamStatus.idle || DashcamStatus.finalizing => false,
};

/// The same request as the session screen's "Finalizar sessão": it stops the
/// camera and finishes the driving session together, and a double tap joins
/// the stop already in flight ([DashcamSessionController.stopSession]). A
/// persistence failure is kept by the recorder and offered for retry on the
/// session screen; anything else must still surface.
void _stopFromPreview(DashcamSessionController controller) {
  unawaited(
    controller.stopSession().catchError((Object error) {
      if (controller.sessionRecorder.state != DrivingSessionRecorderState.finalizationFailed) throw error;
    }),
  );
}

/// The dashcam fullscreen's double-tap ([SensorFullscreenScreen.confirmExit]):
/// with nothing recording it just leaves; while the session records it asks
/// "Deseja encerrar a gravação?" — "Sim" issues the same stop as "Parar" and
/// leaves, "Não" (or dismissing the dialog) stays and keeps recording.
Future<bool> confirmLeaveDashcamFullscreen(BuildContext context, DashcamSessionController controller) async {
  if (!_canStopFromPreview(controller)) return true;
  final end = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Deseja encerrar a gravação?'),
      content: const Text('A gravação e a sessão de condução serão finalizadas e salvas.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Não')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sim')),
      ],
    ),
  );
  if (end != true) return false;
  // The session may have ended while the dialog was open (e.g. stopped from
  // the session screen): stopSession() then joins or finds nothing to stop.
  _stopFromPreview(controller);
  return true;
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.controller});

  final DashcamSessionController controller;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.error,
        foregroundColor: Theme.of(context).colorScheme.onError,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => _stopFromPreview(controller),
      icon: const Icon(Icons.stop),
      label: const Text('Parar'),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller});

  final DashcamSessionController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = controller.status;
    final canStart = controller.canStartSession;

    late final IconData icon;
    late final String message;
    late final Widget action;

    switch (status) {
      case DashcamStatus.disabled:
        icon = Icons.videocam_off_outlined;
        message = 'Dashcam desativado';
        action = OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashcamSettingsScreen())),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Abrir configurações'),
        );
      case DashcamStatus.idle:
        icon = Icons.videocam_outlined;
        // Fase 16.2-R4.3-R2.6.4: say why a start is unavailable — the previous
        // session is still being finalized, or its finalization failed and must
        // be retried from the session screen.
        message = controller.sessionFinalizationFailed
            ? 'A sessão anterior não pôde ser salva. Finalize-a novamente na tela da sessão.'
            : (canStart ? 'Nenhuma sessão em andamento' : 'Finalizando a sessão anterior…');
        action = FilledButton.icon(
          // Fase 16.2-R4.3-R2.6.1: the previous session may still be ending (its
          // camera side can already be idle) — see
          // [DashcamSessionController.canStartSession]; the controller notifies
          // once it flips back, which rebuilds this view.
          onPressed: canStart ? () => _startFromTile(controller) : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Iniciar sessão'),
        );
      case DashcamStatus.initializing:
        icon = Icons.videocam_outlined;
        message = 'Iniciando câmera…';
        action = const Padding(padding: EdgeInsets.only(top: 8), child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator()));
      case DashcamStatus.recording:
        // Reached only if the CameraController hasn't finished initializing
        // its own preview surface yet (a brief moment right after status
        // flips to recording) — same message/spinner as `initializing`.
        icon = Icons.videocam_outlined;
        message = 'Preparando pré-visualização…';
        action = const Padding(padding: EdgeInsets.only(top: 8), child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator()));
      case DashcamStatus.cameraUnavailable:
        // Fase 16.2-R1: expected, self-recovering — not an error needing a
        // manual retry (see DashcamStatus.cameraUnavailable's own doc), so
        // no action button, same calm framing as idle/initializing (§10).
        icon = Icons.videocam_outlined;
        message = 'Câmera temporariamente indisponível';
        action = const SizedBox.shrink();
      case DashcamStatus.error:
        icon = Icons.error_outline;
        message = controller.errorMessage ?? 'Erro na câmera';
        action = OutlinedButton.icon(
          onPressed: () => controller.retryCamera(),
          icon: const Icon(Icons.refresh),
          label: const Text('Tentar novamente'),
        );
      case DashcamStatus.finalizing:
        // Fase 16.2-R4.3-R2.6.10: the camera is already free (a new session
        // may start and use it); the previous session's telemetry file is
        // still being finalized, so this is not "Nenhuma sessão em andamento".
        icon = Icons.videocam_outlined;
        message = 'Finalizando a gravação anterior…';
        action = FilledButton.icon(
          onPressed: canStart ? () => _startFromTile(controller) : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Iniciar sessão'),
        );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          action,
          // The session may be recording while the camera is still starting,
          // briefly unavailable or in error: stopping must not depend on it.
          // Not while the camera is idle/disabled/finalizing: nothing is being
          // recorded by it then, and that view already offers its own start for
          // the session (a recorder-only session, e.g. the dashcam enabled
          // mid-session) — a stop next to "Nenhuma sessão em andamento" would
          // read as a contradiction. The session screen still stops it.
          if (_cameraEngaged(status) && _canStopFromPreview(controller)) ...[
            const SizedBox(height: 16),
            _StopButton(controller: controller),
          ],
          // A shortcut to the recordings whenever the camera is not in use —
          // never next to a live recording's own controls.
          if (!_cameraEngaged(status)) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashcamRecordingsScreen())),
              icon: const Icon(Icons.video_library_outlined),
              label: const Text('Ver gravações'),
            ),
          ],
        ],
      ),
    );
  }
}
