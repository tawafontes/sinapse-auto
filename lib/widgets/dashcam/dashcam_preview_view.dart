import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../models/dashcam_status.dart';
import '../../screens/settings/dashcam_settings_screen.dart';
import '../../services/dashcam_session_controller.dart';

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

    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.black54),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 14),
            const SizedBox(width: 6),
            Text(
              elapsed == null ? 'REC' : 'REC · ${formatElapsed(elapsed)}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '${formatMb(controller.totalClipBytes)} / ${formatMb(controller.quotaBytes)} MB',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
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
        message = 'Nenhuma sessão em andamento';
        action = FilledButton.icon(
          onPressed: () => controller.startSession(),
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
      case DashcamStatus.error:
        icon = Icons.error_outline;
        message = controller.errorMessage ?? 'Erro na câmera';
        action = OutlinedButton.icon(
          onPressed: () => controller.retryCamera(),
          icon: const Icon(Icons.refresh),
          label: const Text('Tentar novamente'),
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
        ],
      ),
    );
  }
}
