import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// A minimal, real (not mocked) [VideoPlayerPlatform] implementation for
/// tests — the same seam pattern `test/support/fake_camera_platform.dart`
/// already uses for the `camera` plugin, letting `DashcamPlaybackScreen` run
/// against a genuine [VideoPlayerController] in a widget test without
/// touching a real platform decoder.
///
/// Only implements the subset of [VideoPlayerPlatform] that
/// `VideoPlayerController.initialize()`/`play()`/`pause()`/`dispose()`
/// actually call — every other method keeps the base class's
/// `UnimplementedError` default, same rationale as [FakeCameraPlatform]'s
/// own doc: a test that exercises a path this fake doesn't support should
/// fail loudly, not silently succeed against an under-specified double.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  /// The [Duration]/[Size] the next created player's `initialized` event
  /// will report — set [initializedSize] to a portrait aspect ratio (the
  /// default) to reproduce the exact real-world shape found on physical
  /// hardware (Fase 15): this app's dashcam clips are recorded in the
  /// phone's own portrait mount orientation.
  Duration initializedDuration = const Duration(seconds: 8);
  Size initializedSize = const Size(720, 1280);

  int _nextPlayerId = 0;
  final Map<int, StreamController<VideoEvent>> _eventControllers = {};
  final List<String> calls = [];

  @override
  Future<void> init() async {
    calls.add('init');
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('createWithOptions');
    return _nextPlayerId++;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    // Delivered from `onListen` — guaranteed to run synchronously once the
    // caller's subscription (VideoPlayerController.initialize()'s own
    // `.listen(...)`, called synchronously right after this method returns)
    // is actually attached, unlike a scheduleMicrotask/Timer-deferred emit
    // which isn't guaranteed to run before a widget-test binding considers
    // the frame settled.
    late final StreamController<VideoEvent> controller;
    controller = StreamController<VideoEvent>.broadcast(
      onListen: () {
        controller.add(
          VideoEvent(eventType: VideoEventType.initialized, duration: initializedDuration, size: initializedSize),
        );
      },
    );
    _eventControllers[playerId] = controller;
    return controller.stream;
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seekTo');
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    // A real platform returns a Texture; this test only needs *some*
    // fixed-size box occupying the AspectRatio's child slot so the layout
    // under test renders exactly as it would with a real video surface.
    return const SizedBox.expand();
  }

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _eventControllers.remove(playerId)?.close();
  }
}
