import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/dashcam_clip_record.dart';
import '../../models/dashcam_telemetry_sample.dart';
import '../../services/dashcam_telemetry_lookup.dart';
import '../../services/dashcam_telemetry_writer.dart';

/// Plays back one recorded dashcam clip with a persistent scrubber and a
/// telemetry overlay tracking the current frame (Fase 15).
///
/// Deliberately **not** built on `SensorFullscreenScreen` (unlike the live
/// preview) — playback has an entirely different, well-established UX
/// convention (a persistent scrubber, not tap-to-reveal auto-hiding chrome),
/// so forcing it into that component would fight its design rather than
/// reuse it cleanly. A standalone [Scaffold] with its own [AppBar] instead.
class DashcamPlaybackScreen extends StatefulWidget {
  const DashcamPlaybackScreen({super.key, required this.clip, required this.sessionId});

  final DashcamClipRecord clip;
  final String sessionId;

  @override
  State<DashcamPlaybackScreen> createState() => _DashcamPlaybackScreenState();
}

class _DashcamPlaybackScreenState extends State<DashcamPlaybackScreen> {
  VideoPlayerController? _controller;
  List<DashcamTelemetrySample> _telemetry = const [];
  bool _fileMissing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final file = File(widget.clip.filePath);
    // A clip's file can legitimately be gone by the time this screen opens
    // — storage-quota enforcement may have deleted it since this session
    // ended (only *protected* clips are exempt) — this must read as a clear
    // message, not a crash (a required Fase 15 test scenario).
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() => _fileMissing = true);
      return;
    }

    final telemetry = await loadDashcamTelemetry(widget.sessionId);
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
    } catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }

    controller.addListener(_onControllerChanged);
    setState(() {
      _controller = controller;
      _telemetry = telemetry;
    });
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    final controller = _controller;
    controller?.removeListener(_onControllerChanged);
    controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reprodução')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_fileMissing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Vídeo removido (limite de armazenamento atingido).', textAlign: TextAlign.center),
        ),
      );
    }

    final errorMessage = _errorMessage;
    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Não foi possível reproduzir este vídeo.\n$errorMessage', textAlign: TextAlign.center),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    // The concrete answer to "given a playback position, what was telemetry
    // doing at that instant" (Fase 15 §7): the clip's own recordedAt (the
    // wall-clock instant recording started, see DashcamClip's own doc) plus
    // however far into the clip playback currently is — no cross-clock
    // conversion needed, both are the same DateTime.now() domain used
    // throughout this app. Precision is bounded by the sampler's own ~200ms
    // cadence (DashcamSessionController) — not claimed to be frame-exact.
    final position = controller.value.position;
    final targetInstant = widget.clip.recordedAt.add(position);
    final sample = nearestDashcamSample(_telemetry, targetInstant);

    return Column(
      children: [
        // Expanded + Center (Fase 15 hardware-testing fix): a bare AspectRatio
        // directly in this Column sizes itself from the video's own aspect
        // ratio against the FULL available width, independent of whatever
        // height the scrubber/controls/telemetry-empty-message below it also
        // need — for a portrait-recorded clip (the common case: this app's
        // camera captures in the phone's own portrait mount orientation,
        // aspectRatio well under 1) that computed height alone exceeds the
        // whole screen, silently pushing the play/pause button, scrubber, and
        // duration text off-screen entirely (confirmed on-device: a real
        // RenderFlex "BOTTOM OVERFLOWED" and the play button became
        // untappable, not just visually clipped). Expanded instead bounds the
        // video to whatever space is actually left over after those fixed-
        // size siblings are laid out, and Center lets AspectRatio letterbox
        // within that space rather than stretch or overflow it.
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: Stack(
                alignment: Alignment.bottomLeft,
                children: [
                  VideoPlayer(controller),
                  if (sample != null) _TelemetryOverlay(sample: sample),
                ],
              ),
            ),
          ),
        ),
        VideoProgressIndicator(controller, allowScrubbing: true, padding: const EdgeInsets.all(8)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(position)),
              IconButton(
                icon: Icon(controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 48),
                onPressed: _togglePlay,
              ),
              Text(_formatDuration(controller.value.duration)),
            ],
          ),
        ),
        if (_telemetry.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nenhuma telemetria associada a este vídeo.', textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

class _TelemetryOverlay extends StatelessWidget {
  const _TelemetryOverlay({required this.sample});

  final DashcamTelemetrySample sample;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sample.speedKmh != null)
            Text('${sample.speedKmh!.toStringAsFixed(0)} km/h', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          if (sample.resultantG != null)
            Text('${sample.resultantG!.toStringAsFixed(2)} g', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (sample.altitudeMeters != null)
            Text('${sample.altitudeMeters!.toStringAsFixed(0)} m', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
