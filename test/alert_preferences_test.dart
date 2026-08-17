import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/services/alert_preferences.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('alert_preferences_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('every alert type defaults to enabled', () {
    final prefs = AlertPreferences();
    for (final type in AlertType.values) {
      expect(prefs.isEnabled(type), isTrue);
    }
  });

  test('alert types with a threshold default to the documented value', () {
    final prefs = AlertPreferences();
    expect(prefs.thresholdFor(AlertType.highSpeed), defaultAlertThresholds[AlertType.highSpeed]);
    expect(prefs.thresholdFor(AlertType.harshAcceleration), defaultAlertThresholds[AlertType.harshAcceleration]);
    expect(prefs.thresholdFor(AlertType.harshBraking), defaultAlertThresholds[AlertType.harshBraking]);
    expect(prefs.thresholdFor(AlertType.highInclination), defaultAlertThresholds[AlertType.highInclination]);
  });

  test('alert types without a threshold report null', () {
    final prefs = AlertPreferences();
    expect(prefs.thresholdFor(AlertType.weakGnss), isNull);
    expect(prefs.thresholdFor(AlertType.gnssLost), isNull);
  });

  test('setEnabled updates the value and notifies listeners', () async {
    final prefs = AlertPreferences();
    var notified = false;
    prefs.addListener(() => notified = true);

    await prefs.setEnabled(AlertType.highSpeed, false);

    expect(prefs.isEnabled(AlertType.highSpeed), isFalse);
    expect(notified, isTrue);
  });

  test('setThreshold updates the value and notifies listeners', () async {
    final prefs = AlertPreferences();
    var notified = false;
    prefs.addListener(() => notified = true);

    await prefs.setThreshold(AlertType.highSpeed, 150);

    expect(prefs.thresholdFor(AlertType.highSpeed), 150);
    expect(notified, isTrue);
  });

  test('setThreshold on a type with no threshold is a safe no-op', () async {
    final prefs = AlertPreferences();
    await prefs.setThreshold(AlertType.weakGnss, 999); // must not throw.
    expect(prefs.thresholdFor(AlertType.weakGnss), isNull);
  });

  test('preferences survive being re-read from a fresh instance (persistence)', () async {
    final first = AlertPreferences();
    await first.setEnabled(AlertType.harshBraking, false);
    await first.setThreshold(AlertType.highSpeed, 100);

    final second = AlertPreferences();
    expect(second.isEnabled(AlertType.harshBraking), isFalse);
    expect(second.thresholdFor(AlertType.highSpeed), 100);
  });
}
