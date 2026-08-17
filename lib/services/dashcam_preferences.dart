import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../models/dashcam_config.dart';
import 'hive_boxes.dart';

/// Owns the app's single, persisted [DashcamConfig] (Fase 15) — mirrors
/// [ThemeController]'s exact single-entry-box pattern, since [DashcamConfig]
/// is already a typed [HiveObject] in its own box, the same shape as
/// `ThemeConfig`.
///
/// Defaults are deliberately conservative: [DashcamConfig.enabled] and
/// [DashcamConfig.audioEnabled] both start `false` (a fresh install touches
/// no camera/microphone hardware until the user explicitly opts in), and
/// [DashcamConfig.resolution] defaults to [VideoResolution.hd720] rather
/// than a higher preset — the target device (Samsung SM-A326B) is a
/// budget/mid-range chipset already running the full sensor+GPS+rendering
/// pipeline characterized in Fase 14; 720p30 prioritizes stability over
/// maximum resolution, matching the Fase 15 spec's explicit instruction,
/// while `fhd1080`/`uhd4k` stay selectable for anyone who wants to override.
class DashcamPreferences extends ChangeNotifier {
  DashcamPreferences() : _config = _readPersistedOrDefault();

  static const _key = 'config';

  static Box<DashcamConfig> get _box =>
      Hive.box<DashcamConfig>(HiveBoxNames.dashcamConfig);

  static DashcamConfig _readPersistedOrDefault() {
    return _box.get(_key) ??
        DashcamConfig(
          cameraSelection: CameraSelection.rear,
          storageQuotaMb: 1024,
          audioEnabled: false,
          resolution: VideoResolution.hd720,
          frameRate: 30,
          enabled: false,
        );
  }

  final DashcamConfig _config;

  DashcamConfig get config => _config;

  bool get enabled => _config.enabled;
  CameraSelection get cameraSelection => _config.cameraSelection;
  VideoResolution get resolution => _config.resolution;
  int get frameRate => _config.frameRate;
  bool get audioEnabled => _config.audioEnabled;
  int get storageQuotaMb => _config.storageQuotaMb;

  Future<void> setEnabled(bool value) => _update(() => _config.enabled = value);

  Future<void> setCameraSelection(CameraSelection value) =>
      _update(() => _config.cameraSelection = value);

  Future<void> setResolution(VideoResolution value) =>
      _update(() => _config.resolution = value);

  Future<void> setFrameRate(int value) => _update(() => _config.frameRate = value);

  /// Callers must have already obtained `Permission.microphone` before
  /// enabling audio — this preferences object only persists the choice, it
  /// never requests the permission itself (see `DashcamSettingsScreen`).
  Future<void> setAudioEnabled(bool value) => _update(() => _config.audioEnabled = value);

  Future<void> setStorageQuotaMb(int value) => _update(() => _config.storageQuotaMb = value);

  Future<void> _update(void Function() mutate) async {
    mutate();
    notifyListeners();
    await _box.put(_key, _config);
  }
}

/// Makes the app's single [DashcamPreferences] instance reachable from any
/// descendant via [DashcamPreferencesScope.of] — same pattern as
/// [ThemeControllerScope]/`AlertPreferencesScope`/`PowerProfilePreferencesScope`.
class DashcamPreferencesScope extends InheritedNotifier<DashcamPreferences> {
  const DashcamPreferencesScope({
    super.key,
    required DashcamPreferences preferences,
    required super.child,
  }) : super(notifier: preferences);

  static DashcamPreferences of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DashcamPreferencesScope>();
    assert(scope != null, 'No DashcamPreferencesScope found in context');
    return scope!.notifier!;
  }
}
