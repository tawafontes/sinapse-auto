import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/power_profile.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/power_profile_preferences.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('power_profile_preferences_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('defaults to PowerProfile.normal when never set', () {
    final prefs = PowerProfilePreferences();
    expect(prefs.profile, PowerProfile.normal);
  });

  test('setProfile updates the live value and notifies listeners', () async {
    final prefs = PowerProfilePreferences();
    var notified = false;
    prefs.addListener(() => notified = true);

    await prefs.setProfile(PowerProfile.economy);

    expect(prefs.profile, PowerProfile.economy);
    expect(notified, isTrue);
  });

  test('setting the same profile again does not notify (no-op)', () async {
    final prefs = PowerProfilePreferences();
    var notifyCount = 0;
    prefs.addListener(() => notifyCount++);

    await prefs.setProfile(PowerProfile.normal); // already normal by default.

    expect(notifyCount, 0);
  });

  test('every profile value round-trips through persistence correctly', () async {
    for (final profile in PowerProfile.values) {
      final first = PowerProfilePreferences();
      await first.setProfile(profile);

      final second = PowerProfilePreferences();
      expect(second.profile, profile, reason: 'failed for $profile');
    }
  });

  group('powerProfileLabel / powerProfileDescription', () {
    test('every profile has a non-empty label and description', () {
      for (final profile in PowerProfile.values) {
        expect(powerProfileLabel(profile), isNotEmpty);
        expect(powerProfileDescription(profile), isNotEmpty);
      }
    });

    test('dashcamReady is explicit that it does not enable video capture', () {
      expect(powerProfileDescription(PowerProfile.dashcamReady).toLowerCase(), contains('não ativa'));
    });
  });
}
