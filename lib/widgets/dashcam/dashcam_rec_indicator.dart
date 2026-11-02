import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/dashcam_status.dart';
import '../../services/dashcam_session_controller.dart';

/// The Dashboard AppBar's Dashcam entry point — an icon whose look reflects
/// [DashcamSessionController.status] at a glance, always opening the same
/// fullscreen preview on tap regardless of state (consistent with every
/// other entry point in this app). Mirrors `SessionRecordingScreen`'s own
/// `addListener`/local-ticker pattern rather than `ListenableBuilder`, to
/// match this codebase's established idiom for observing a [ChangeNotifier].
class DashcamRecIndicator extends StatefulWidget {
  const DashcamRecIndicator({super.key, required this.controller, required this.onTap});

  final DashcamSessionController controller;
  final VoidCallback onTap;

  @override
  State<DashcamRecIndicator> createState() => _DashcamRecIndicatorState();
}

class _DashcamRecIndicatorState extends State<DashcamRecIndicator> {
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.controller.status == DashcamStatus.recording) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant DashcamRecIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _tickTimer?.cancel();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = widget.controller.status;

    late final IconData icon;
    late final Color color;
    late final String tooltip;

    switch (status) {
      case DashcamStatus.disabled:
        icon = Icons.videocam_outlined;
        color = colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
        tooltip = 'Dashcam desativado';
      case DashcamStatus.idle:
        icon = Icons.videocam_outlined;
        color = colorScheme.onSurfaceVariant;
        tooltip = 'Dashcam';
      case DashcamStatus.initializing:
        icon = Icons.videocam_outlined;
        color = colorScheme.primary;
        tooltip = 'Iniciando câmera…';
      case DashcamStatus.recording:
        // Fase 16.2-R4.4-HW-MIG-5-SIG-2: the session is recording, but the red
        // icon claims video of the current segment.
        final confirmed = widget.controller.segmentPresentation == DashcamSegmentPresentation.videoConfirmed;
        icon = confirmed ? Icons.fiber_manual_record : Icons.videocam_outlined;
        color = confirmed ? colorScheme.error : colorScheme.onSurfaceVariant;
        final startedAt = widget.controller.recordingStartedAt;
        final elapsed = startedAt == null ? null : DateTime.now().difference(startedAt);
        final label = widget.controller.statusLabel;
        final recording = elapsed == null ? label : '$label · ${_formatElapsed(elapsed)}';
        // Fase 16.2-R4.3-R2.6.10: video is still being recorded, but its
        // telemetry file failed (see DashcamSessionController.telemetryFailureMessage).
        final telemetryFailure = widget.controller.telemetryFailureMessage;
        tooltip = telemetryFailure == null ? recording : '$recording\n$telemetryFailure';
      case DashcamStatus.cameraUnavailable:
        // Fase 16.2-R1: deliberately NOT the REC icon/color — no video is
        // actually being captured right now, however briefly (see
        // DashcamStatus.cameraUnavailable's own doc). Calm, not alarmist
        // (§10): same neutral icon as idle/initializing, not the error icon.
        icon = Icons.videocam_outlined;
        color = colorScheme.onSurfaceVariant;
        tooltip = 'Câmera indisponível';
      case DashcamStatus.error:
        icon = Icons.videocam_off;
        color = colorScheme.error;
        tooltip = widget.controller.errorMessage ?? 'Erro na câmera';
      case DashcamStatus.finalizing:
        // Fase 16.2-R4.3-R2.6.10: camera released, the stopped session's
        // telemetry file still being finalized — not "ready" yet.
        icon = Icons.videocam_outlined;
        color = colorScheme.onSurfaceVariant;
        tooltip = 'Finalizando a gravação anterior…';
    }

    return IconButton(icon: Icon(icon, color: color), tooltip: tooltip, onPressed: widget.onTap);
  }
}
