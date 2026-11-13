import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/dashcam_gallery_exporter.dart';
import '../../services/dual_camera/dual_camera_probe_bridge.dart';

/// "Teste de câmeras simultâneas" — the dashcam dual camera phase 0 tool
/// (2026-11-13), reached from Diagnóstico. Not part of the product: it binds
/// the back and front cameras together through CameraX's composition
/// ([DualCameraProbeBridge]), shows the composed preview, records a short test
/// clip and copies it to the gallery, so the composed file can be checked on
/// the device. Every step is also logged (`adb logcat -s flutter`, prefix
/// "dual camera probe:"). Nothing here touches the dashcam.
class DualCameraProbeScreen extends StatefulWidget {
  DualCameraProbeScreen({super.key, DualCameraProbeBridge? bridge, this.directory, DashcamGalleryExporter? exporter})
    : bridge = bridge ?? MethodChannelDualCameraProbeBridge(),
      exporter = exporter ?? const MethodChannelDashcamGalleryExporter();

  final DualCameraProbeBridge bridge;

  /// Where the test clips go; the app's documents when null (tests pass a
  /// temporary one).
  final Directory? directory;

  final DashcamGalleryExporter exporter;

  static const recordDuration = Duration(seconds: 10);

  /// The compositions to try. Offsets and scales are CameraX's normalized
  /// device coordinates (-1..1, center 0,0); a uniform scale keeps a camera's
  /// shape. Side by side and stacked were tried first (SM-S918B, 2026-11-13):
  /// at 0.5 x 0.5 they leave half the frame black, and the owner chose a
  /// picture-in-picture — the back camera over the whole frame, the front one
  /// in a corner at 1/3. Which sign of y is the bottom is what the paired
  /// variants below find out.
  static const List<DualLayout> layouts = [
    (name: 'PiP 1/3 (x+, y−)', back: _full, front: (offsetX: _third, offsetY: -_third, scaleX: 1 / 3, scaleY: 1 / 3), frontPrimary: false),
    (name: 'PiP 1/3 (x+, y+)', back: _full, front: (offsetX: _third, offsetY: _third, scaleX: 1 / 3, scaleY: 1 / 3), frontPrimary: false),
    (name: 'PiP 1/4 (x+, y−)', back: _full, front: (offsetX: _quarter, offsetY: -_quarter, scaleX: 1 / 4, scaleY: 1 / 4), frontPrimary: false),
    (name: 'Frontal principal, PiP traseira 1/3 (x+, y−)', back: (offsetX: _third, offsetY: -_third, scaleX: 1 / 3, scaleY: 1 / 3), front: _full, frontPrimary: true),
  ];

  static const CameraPlacement _full = (offsetX: 0.0, offsetY: 0.0, scaleX: 1.0, scaleY: 1.0);

  /// The PiP's center: 1 minus its half-size (= its scale, in a -1..1 span)
  /// minus a 0.05 margin (2.5% of the frame).
  static const double _third = 1 - 1 / 3 - 0.05;
  static const double _quarter = 1 - 1 / 4 - 0.05;

  @override
  State<DualCameraProbeScreen> createState() => _DualCameraProbeScreenState();
}

class _DualCameraProbeScreenState extends State<DualCameraProbeScreen> {
  final List<String> _lines = [];
  StreamSubscription<Map<String, Object?>>? _events;
  DualLayout _layout = DualCameraProbeScreen.layouts.first;
  DualCameraStart? _started;
  Size? _surface;
  int _rotationDegrees = 0;
  int _extraTurns = 0;
  bool _ready = false;
  bool _busy = false;
  bool _recording = false;
  Timer? _recordTimer;
  DateTime? _recordStartedAt;

  /// The composed frame's orientation is fixed when the cameras are bound
  /// (SM-S918B, 2026-11-13: bound in portrait, a turned phone kept a portrait
  /// frame, small in the landscape screen). So a turn rebinds — and, mid-clip,
  /// ends the clip and starts the next one — and this measures how long that
  /// takes: what the dashcam would lose at each turn.
  Orientation? _orientation;
  Stopwatch? _sinceRotation;
  bool _resumeRecordingAfterRotation = false;

  /// From a turn mid-clip until the next clip's first frame: the stopwatch
  /// must run through the rebind (it used to stop at the preview, SM-S918B).
  bool _awaitingRecordingResume = false;

  @override
  void initState() {
    super.initState();
    _events = widget.bridge.events.listen(_onEvent);
    _prepare();
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _events?.cancel();
    if (_started != null) widget.bridge.release().catchError((_) {});
    super.dispose();
  }

  void _log(String line) {
    debugPrint('dual camera probe: $line');
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > 200) _lines.removeAt(0);
    });
  }

  Future<void> _prepare() async {
    if (widget.directory == null) {
      if (!MethodChannelDualCameraProbeBridge.isSupported) {
        _log('disponível só no Android');
        return;
      }
      if (!(await Permission.camera.request()).isGranted) {
        _log('sem a permissão de câmera');
        return;
      }
    }
    try {
      final support = await widget.bridge.inspect();
      _log('recurso de câmeras simultâneas: ${support.feature ? 'sim' : 'não'}');
      for (final combo in support.combos) {
        _log('combinação: ${combo.join(' + ')}');
      }
      if (support.combos.isEmpty) _log('nenhuma combinação de câmeras simultâneas');
      if (mounted) setState(() => _ready = support.combos.isNotEmpty);
    } on DualCameraProbeException catch (e) {
      _log('inspect falhou: $e');
    }
  }

  void _onEvent(Map<String, Object?> event) {
    switch (event['kind']) {
      case 'previewSurface':
        final size = Size((event['width'] as num).toDouble(), (event['height'] as num).toDouble());
        setState(() => _surface = size);
        _log('superfície do preview: ${size.width.round()}x${size.height.round()}');
        final sinceRotation = _sinceRotation;
        if (sinceRotation != null) {
          _log('preview religado ${sinceRotation.elapsedMilliseconds} ms após girar');
          if (!_awaitingRecordingResume) _sinceRotation = null;
        }
      case 'transform':
        setState(() => _rotationDegrees = event['rotationDegrees'] as int? ?? 0);
        _log('transformação: rotação ${event['rotationDegrees']}°, espelhado ${event['mirroring']}');
      case 'recordStart':
        _log('gravação iniciada');
      case 'recordProgress':
        _log('primeiro quadro gravado');
        final sinceRotation = _sinceRotation;
        if (sinceRotation != null && _awaitingRecordingResume) {
          _log('gravação retomada ${sinceRotation.elapsedMilliseconds} ms após girar (o intervalo fica sem vídeo)');
          _sinceRotation = null;
          _awaitingRecordingResume = false;
        }
      case 'recordFinalize':
        _recordTimer?.cancel();
        if (mounted) setState(() => _recording = false);
        final error = event['error'] as int? ?? 0;
        _log(
          'gravação finalizada: erro $error${event['cause'] == null ? '' : ' (${event['cause']})'}, '
          '${event['durationMs']} ms, ${((event['bytes'] as num? ?? 0) / 1024).round()} KB',
        );
        final path = event['path'] as String?;
        if (path != null && error == 0) unawaited(_export(path));
        if (_resumeRecordingAfterRotation) {
          _resumeRecordingAfterRotation = false;
          unawaited(_restartRecordingAfterRotation());
        }
      default:
        _log('evento: $event');
    }
  }

  Future<void> _export(String path) async {
    if (!widget.exporter.isSupported) {
      _log('galeria indisponível; o clipe ficou em $path');
      return;
    }
    final recordedAt = _recordStartedAt ?? DateTime.now();
    final name = 'SynapseAuto_dual_${_stamp(recordedAt)}.mp4';
    try {
      await widget.exporter.saveVideo(path: path, displayName: name, recordedAt: recordedAt);
      _log('copiado para a galeria: Movies/Synapse Auto/$name');
    } catch (e) {
      _log('cópia para a galeria falhou: $e');
    }
  }

  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  Future<void> _guard(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } on DualCameraProbeException catch (e) {
      _log('falhou: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() => _guard(() async {
    final started = await widget.bridge.start(_layout);
    setState(() {
      _started = started;
      _extraTurns = 0;
    });
    _log(
      'ligadas (${_layout.name}): preview ${started.preview} rot ${started.previewRotation}°, '
      'vídeo ${started.video} rot ${started.videoRotation}°, '
      'textura corrige rotação: ${started.handlesCropAndRotation}, modo concorrente: ${started.concurrentModeOn}',
    );
  });

  Future<void> _stop() => _guard(() async {
    await widget.bridge.release();
    setState(() {
      _started = null;
      _surface = null;
      _recording = false;
    });
    _log('desligadas');
  });

  Future<void> _record() => _guard(() async {
    final dir = widget.directory ?? Directory('${(await getApplicationDocumentsDirectory()).path}/dual_camera_probe');
    dir.createSync(recursive: true);
    _recordStartedAt = DateTime.now();
    // Milliseconds too: after a turn the next clip can start within the same
    // second, while the previous one is still being copied to the gallery.
    final path = '${dir.path}/probe_${_stamp(_recordStartedAt!)}_${_recordStartedAt!.millisecond}.mp4';
    await widget.bridge.record(path);
    setState(() => _recording = true);
    _recordTimer = Timer(DualCameraProbeScreen.recordDuration, () => widget.bridge.stopRecording().catchError((_) {}));
  });

  void _onRotated(Orientation orientation) {
    if (!mounted || _started == null) return;
    _log('girou para ${orientation == Orientation.landscape ? 'paisagem' : 'retrato'}: religando');
    _sinceRotation = Stopwatch()..start();
    if (_recording) {
      _resumeRecordingAfterRotation = true;
      _awaitingRecordingResume = true;
      _recordTimer?.cancel();
      widget.bridge.stopRecording().catchError((_) {});
    } else {
      unawaited(_start());
    }
  }

  Future<void> _restartRecordingAfterRotation() async {
    await _start();
    await _record();
  }

  Future<void> _selectLayout(DualLayout layout) async {
    setState(() => _layout = layout);
    if (_started != null) await _start();
  }

  Widget _preview() {
    final started = _started;
    final surface = _surface;
    if (started == null || surface == null) {
      return const Center(child: Text('Câmeras desligadas', style: TextStyle(color: Colors.white70)));
    }
    final turns = (started.handlesCropAndRotation ? 0 : _rotationDegrees ~/ 90) + _extraTurns;
    final ratio = turns.isOdd ? surface.height / surface.width : surface.width / surface.height;
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: RotatedBox(quarterTurns: turns, child: Texture(key: const ValueKey('dual_texture'), textureId: started.textureId)),
      ),
    );
  }

  Widget _layoutChips() => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final layout in DualCameraProbeScreen.layouts)
        ChoiceChip(
          label: Text(layout.name),
          visualDensity: VisualDensity.compact,
          selected: _layout == layout,
          onSelected: _busy || _recording ? null : (_) => _selectLayout(layout),
        ),
    ],
  );

  Widget _buttons() {
    final on = _started != null;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!on)
          FilledButton(key: const ValueKey('dual_start'), onPressed: _ready && !_busy ? _start : null, child: const Text('Ligar câmeras'))
        else
          OutlinedButton(key: const ValueKey('dual_stop'), onPressed: _busy || _recording ? null : _stop, child: const Text('Desligar')),
        FilledButton.tonal(
          key: const ValueKey('dual_record'),
          onPressed: on && !_busy && !_recording ? _record : null,
          child: Text(_recording ? 'Gravando…' : 'Gravar ${DualCameraProbeScreen.recordDuration.inSeconds} s'),
        ),
        OutlinedButton(
          onPressed: on ? () => setState(() => _extraTurns = (_extraTurns + 1) % 4) : null,
          child: const Text('Girar preview'),
        ),
      ],
    );
  }

  Widget _transcript(TextStyle? style) => ListView.builder(
    key: const ValueKey('dual_transcript'),
    reverse: true,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    itemCount: _lines.length,
    itemBuilder: (_, i) => Text(_lines[_lines.length - 1 - i], style: style),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11);
    final orientation = MediaQuery.orientationOf(context);
    if (_orientation != null && orientation != _orientation) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onRotated(orientation));
    }
    _orientation = orientation;
    const title = 'Teste de câmeras simultâneas';

    if (orientation == Orientation.landscape) {
      // The preview takes all the height; the controls go to a side column.
      return Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: ColoredBox(color: Colors.black, child: _preview())),
              SizedBox(
                width: 280,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [const BackButton(), Expanded(child: Text(title, style: theme.textTheme.titleSmall))]),
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_layoutChips(), const SizedBox(height: 8), _buttons()]),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(flex: 2, child: _transcript(mono)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Fase 0 da dashcam com duas câmeras. Use com a dashcam parada. Ao girar o celular, as câmeras '
                'religam na nova orientação (gravando, o clipe termina e outro começa) e o tempo disso vai para a '
                'transcrição. Grave ${DualCameraProbeScreen.recordDuration.inSeconds} s: o clipe vai para a galeria '
                '(Movies/Synapse Auto), para comparar com o que apareceu aqui.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: _layoutChips()),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: _buttons()),
            Expanded(flex: 5, child: ColoredBox(color: Colors.black, child: _preview())),
            const Divider(height: 1),
            Expanded(flex: 1, child: _transcript(mono)),
          ],
        ),
      ),
    );
  }
}
