import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_clip_record.dart';
import 'package:synapse_auto/screens/sessions/dashcam_playback_screen.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeVideoPlayerPlatform fakePlatform;

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_playback_screen_test');
    fakePlatform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fakePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    dir.deleteSync(recursive: true);
  });

  testWidgets(
    'a portrait-recorded clip does not overflow the screen and leaves the play/pause button '
    'reachable (Fase 15 — regression for a real bug found via physical hardware testing: a bare '
    'AspectRatio directly in the controls Column sized itself from a portrait video\'s aspect '
    'ratio against the FULL available width, computing a height that alone exceeded the whole '
    'screen and pushed the scrubber/play-pause/duration controls off-screen — confirmed on-device '
    'as a real RenderFlex "BOTTOM OVERFLOWED" with the play button no longer tappable, not merely '
    'visually clipped)',
    (tester) async {
      // A real recorded clip file must exist on disk — DashcamPlaybackScreen
      // checks File.exists() before doing anything else.
      final clipFile = File('${dir.path}/clip_test.mp4')..writeAsBytesSync(List<int>.filled(1024, 0));
      final clip = DashcamClipRecord(
        filePath: clipFile.path,
        recordedAt: DateTime(2026, 8, 16, 13, 26, 25),
        durationSeconds: 8,
        sizeBytes: clipFile.lengthSync(),
      );

      // The exact real-hardware-found shape: a portrait video (width < height)
      // — the fake platform's default (see its own doc) already matches this,
      // set explicitly here so the intent is obvious at the call site.
      fakePlatform.initializedSize = const Size(720, 1280);

      // Matches this project's actual target hardware (SM-A326B) screen
      // proportions closely enough to reproduce the exact failure — a
      // narrower, standard phone test surface reproduces it too, but this
      // stays close to the device the bug was physically found on.
      await tester.binding.setSurfaceSize(const Size(720, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // pumpWidget itself runs inside runAsync — DashcamPlaybackScreen kicks
      // off _init() (real dart:io File.exists() calls, not a mocked platform
      // channel) from initState(), during pumpWidget(). Running only a
      // *later*, disconnected runAsync(Future.delayed(...)) block after
      // pumpWidget does NOT reliably let that already-in-flight real I/O
      // resolve — the completion callback ends up queued against whichever
      // zone initState() actually ran under, and a separate runAsync call
      // swapping to the real zone and back doesn't retroactively fix that.
      // Starting the whole sequence inside one runAsync block sidesteps the
      // fake/real zone boundary entirely.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: DashcamPlaybackScreen(clip: clip, sessionId: 'session-under-test')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      // Deliberately NOT pumpAndSettle(): while _init() is still pending,
      // the build shows an indeterminate CircularProgressIndicator, whose
      // Ticker-driven animation never completes — pumpAndSettle() spins
      // forever against that and times out. A bounded number of plain
      // pump()s applies every setState the now-real-async-settled runAsync
      // block queued, without ever waiting on an indeterminate animation.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The most direct, real assertion: no rendering exception (e.g. a
      // RenderFlex overflow) was thrown while laying out/painting this frame.
      expect(tester.takeException(), isNull);

      // Belt-and-suspenders: the play/pause button must actually be within
      // the visible screen bounds, not just "no exception" — a widget can
      // silently render past the bottom edge in some overflow scenarios
      // without necessarily throwing in every configuration.
      final playButtonFinder = find.byIcon(Icons.play_circle_filled);
      expect(playButtonFinder, findsOneWidget, reason: 'the play button must be present in the tree at all');
      final buttonBottom = tester.getBottomLeft(playButtonFinder).dy;
      expect(
        buttonBottom,
        lessThanOrEqualTo(1600),
        reason: 'the play button must be within the screen\'s visible height, not pushed off-screen',
      );

      // And confirm it's genuinely tappable end-to-end (play/pause actually
      // reaches the platform), not just present in the widget tree.
      await tester.tap(playButtonFinder);
      await tester.pump();
      expect(fakePlatform.calls, contains('play'));

      // The real VideoPlayerController.play() starts its own internal
      // position-polling Timer.periodic — a genuine implementation detail of
      // the (deliberately real, not mocked) controller class, unrelated to
      // this app's own code. Tapping pause before the test ends cancels it;
      // otherwise flutter_test's own end-of-test invariant check ("A Timer
      // is still pending even after the widget tree was disposed") fails,
      // which is a test-hygiene issue, not evidence of a real leak in this
      // app (the same principle Fase 14 established for platform noise).
      await tester.tap(find.byIcon(Icons.pause_circle_filled));
      await tester.pump();
      expect(fakePlatform.calls, contains('pause'));
    },
  );
}
