// Dashcam dual camera phase 0 (2026-11-13): the probe screen against a fake
// native side — what it shows, what it asks the native side for, and that a
// finished test clip is copied to the gallery.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/settings/dual_camera_probe_screen.dart';
import 'package:synapse_auto/services/dashcam_gallery_exporter.dart';
import 'package:synapse_auto/services/dual_camera/dual_camera_probe_bridge.dart';

class _FakeBridge implements DualCameraProbeBridge {
  _FakeBridge({this.combos = const [['back (sensor 90°)', 'front (sensor 270°)']]});

  final List<List<String>> combos;
  final calls = <String>[];
  final started = <DualLayout>[];
  final _events = StreamController<Map<String, Object?>>.broadcast();
  String? recordedPath;

  void emit(Map<String, Object?> event) => _events.add(event);

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<DualCameraSupport> inspect() async {
    calls.add('inspect');
    return (feature: combos.isNotEmpty, combos: combos, concurrentModeOn: false);
  }

  @override
  Future<DualCameraStart> start(DualLayout layout) async {
    calls.add('start');
    started.add(layout);
    return (
      textureId: 7,
      handlesCropAndRotation: true,
      preview: '1280x720',
      previewRotation: 90,
      video: '1280x720',
      videoRotation: 90,
      concurrentModeOn: true,
    );
  }

  @override
  Future<void> record(String path) async {
    calls.add('record');
    recordedPath = path;
  }

  @override
  Future<void> stopRecording() async => calls.add('stopRecording');

  @override
  Future<void> release() async => calls.add('release');
}

class _FakeExporter implements DashcamGalleryExporter {
  final saved = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> saveVideo({required String path, required String displayName, required DateTime recordedAt}) async {
    saved.add('$path -> $displayName');
  }
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('dual_probe_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(_FakeBridge, _FakeExporter)> mount(WidgetTester tester, {_FakeBridge? bridge}) async {
    final fake = bridge ?? _FakeBridge();
    final exporter = _FakeExporter();
    await tester.pumpWidget(MaterialApp(home: DualCameraProbeScreen(bridge: fake, directory: dir, exporter: exporter)));
    await tester.pump();
    return (fake, exporter);
  }

  testWidgets('shows the concurrent combinations and offers to start', (tester) async {
    final (bridge, _) = await mount(tester);

    expect(bridge.calls, ['inspect']);
    expect(find.textContaining('combinação: back (sensor 90°) + front (sensor 270°)'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('dual_start'))).onPressed, isNotNull);
  });

  testWidgets('a device with no combination cannot start', (tester) async {
    await mount(tester, bridge: _FakeBridge(combos: const []));

    expect(find.textContaining('nenhuma combinação'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('dual_start'))).onPressed, isNull);
  });

  testWidgets('start shows the composed texture in the surface\'s proportion; another layout restarts', (tester) async {
    final (bridge, _) = await mount(tester);

    await tester.tap(find.byKey(const ValueKey('dual_start')));
    await tester.pump();
    bridge.emit({'kind': 'previewSurface', 'width': 1280, 'height': 720});
    await tester.pump();

    expect(bridge.started.single.name, DualCameraProbeScreen.layouts.first.name);
    final texture = find.byKey(const ValueKey('dual_texture'));
    expect(texture, findsOneWidget);
    final size = tester.getSize(texture);
    expect(size.width / size.height, closeTo(1280 / 720, 0.001));

    await tester.tap(find.text(DualCameraProbeScreen.layouts[1].name));
    await tester.pump();
    expect(bridge.started.map((l) => l.name), [for (final l in DualCameraProbeScreen.layouts.take(2)) l.name]);
  });

  testWidgets('a test clip records for 10 s, then its file is copied to the gallery', (tester) async {
    final (bridge, exporter) = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('dual_start')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('dual_record')));
    await tester.pump();
    expect(bridge.recordedPath, startsWith(dir.path));
    expect(find.text('Gravando…'), findsOneWidget);

    await tester.pump(DualCameraProbeScreen.recordDuration);
    expect(bridge.calls.last, 'stopRecording');

    bridge.emit({'kind': 'recordFinalize', 'path': bridge.recordedPath, 'error': 0, 'durationMs': 10000, 'bytes': 4096000});
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('gravação finalizada: erro 0, 10000 ms, 4000 KB'), findsOneWidget);
    expect(exporter.saved.single, startsWith('${bridge.recordedPath} -> SynapseAuto_dual_'));
  });

  Future<void> turnTo(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await tester.pump();
    await tester.pump();
  }

  testWidgets('turning the phone rebinds the cameras in the new orientation', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await turnTo(tester, const Size(400, 800));
    final (bridge, _) = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('dual_start')));
    await tester.pump();

    await turnTo(tester, const Size(800, 400));

    expect(bridge.started, hasLength(2));
    expect(find.textContaining('girou para paisagem: religando'), findsOneWidget);
    expect(find.byKey(const ValueKey('dual_start')), findsNothing, reason: 'still on');
  });

  testWidgets('turning it mid-clip ends the clip, rebinds, and records the next one', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await turnTo(tester, const Size(400, 800));
    final (bridge, exporter) = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('dual_start')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dual_record')));
    await tester.pump();
    final first = bridge.recordedPath;

    await turnTo(tester, const Size(800, 400));
    expect(bridge.calls.last, 'stopRecording');
    expect(bridge.started, hasLength(1), reason: 'the clip ends first');

    await tester.pump(const Duration(seconds: 1));
    bridge.emit({'kind': 'recordFinalize', 'path': first, 'error': 0, 'durationMs': 3000, 'bytes': 1024});
    await tester.pump();
    await tester.pump();

    expect(bridge.started, hasLength(2));
    expect(bridge.calls.where((c) => c == 'record'), hasLength(2));
    expect(bridge.recordedPath, isNot(first));
    expect(exporter.saved.single, startsWith('$first -> '));
    bridge.emit({'kind': 'recordProgress'});
    await tester.pump();
    expect(find.textContaining('gravação retomada'), findsOneWidget);
    await tester.pump(DualCameraProbeScreen.recordDuration);
  });

  testWidgets('leaving the screen releases the cameras', (tester) async {
    final (bridge, _) = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('dual_start')));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    expect(bridge.calls.last, 'release');
  });
}
