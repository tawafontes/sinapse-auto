// The dashcam preview shows the whole recorded frame, undistorted, in either
// orientation (2026-11-13): `CameraPreview` was stretched to the fullscreen's
// tight box and, while recording, oriented by the segment's START orientation.

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart' show CameraPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/widgets/dashcam/dashcam_preview_view.dart';

import 'support/fake_camera_platform.dart';

class _PreviewFake extends FakeCameraPlatform {
  _PreviewFake({required super.tempDir});

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand(key: Key('surface'));
}

void main() {
  late Directory tempDir;
  late CameraController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dashcam_surface_');
    CameraPlatform.instance = _PreviewFake(tempDir: tempDir);
    controller = CameraController(
      const CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90),
      ResolutionPreset.veryHigh,
      enableAudio: false,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Size area) async {
    await tester.runAsync(controller.initialize);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.fromSize(
            size: area,
            child: Stack(fit: StackFit.expand, children: [DashcamCameraSurface(controller: controller)]),
          ),
        ),
      ),
    );
  }

  Size shown(WidgetTester tester) => tester.getSize(find.byType(RotatedBox));

  void orient(DeviceOrientation orientation, {DeviceOrientation? recordingFrom}) {
    controller.value = controller.value.copyWith(
      deviceOrientation: orientation,
      isRecordingVideo: recordingFrom != null,
      recordingOrientation: Optional.fromNullable(recordingFrom),
    );
  }

  testWidgets('portrait: the 1920x1080 frame is shown 9:16, full width, not stretched to the area', (tester) async {
    await mount(tester, const Size(300, 600));
    orient(DeviceOrientation.portraitUp);
    await tester.pump();

    expect(shown(tester).width, 300);
    expect(shown(tester).height, closeTo(300 * 16 / 9, 0.01));
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);
  });

  testWidgets('landscape: the frame is shown 16:9, full height, with black bars on the sides', (tester) async {
    await mount(tester, const Size(800, 360));
    orient(DeviceOrientation.landscapeLeft);
    await tester.pump();

    expect(shown(tester).height, 360);
    expect(shown(tester).width, closeTo(360 * 16 / 9, 0.01));
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 3);
  });

  testWidgets('turned to landscape while a segment started in portrait records: follows the live orientation, the one the plugin corrects by', (tester) async {
    await mount(tester, const Size(800, 360));
    orient(DeviceOrientation.landscapeRight, recordingFrom: DeviceOrientation.portraitUp);
    await tester.pump();

    expect(shown(tester).width / shown(tester).height, closeTo(16 / 9, 0.001));
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
  });
}
