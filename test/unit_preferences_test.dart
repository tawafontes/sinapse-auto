import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/unit_system.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/unit_preferences.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('unit_preferences_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('defaults to km/h and meters when never set', () {
    final prefs = UnitPreferences();
    expect(prefs.speedUnit, SpeedUnit.kmh);
    expect(prefs.altitudeUnit, AltitudeUnit.meters);
  });

  test('setSpeedUnit updates the live value and notifies listeners', () async {
    final prefs = UnitPreferences();
    var notified = false;
    prefs.addListener(() => notified = true);

    await prefs.setSpeedUnit(SpeedUnit.mph);

    expect(prefs.speedUnit, SpeedUnit.mph);
    expect(notified, isTrue);
  });

  test('setAltitudeUnit updates the live value and notifies listeners', () async {
    final prefs = UnitPreferences();
    var notified = false;
    prefs.addListener(() => notified = true);

    await prefs.setAltitudeUnit(AltitudeUnit.feet);

    expect(prefs.altitudeUnit, AltitudeUnit.feet);
    expect(notified, isTrue);
  });

  test('setting the same unit again does not notify (no-op)', () async {
    final prefs = UnitPreferences();
    var notifyCount = 0;
    prefs.addListener(() => notifyCount++);

    await prefs.setSpeedUnit(SpeedUnit.kmh); // already kmh by default.

    expect(notifyCount, 0);
  });

  test('preferences survive being re-read from a fresh instance (persistence)', () async {
    final first = UnitPreferences();
    await first.setSpeedUnit(SpeedUnit.mph);
    await first.setAltitudeUnit(AltitudeUnit.feet);

    final second = UnitPreferences();
    expect(second.speedUnit, SpeedUnit.mph);
    expect(second.altitudeUnit, AltitudeUnit.feet);
  });
}
