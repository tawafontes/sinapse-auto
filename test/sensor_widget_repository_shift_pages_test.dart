import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

void main() {
  late Directory dir;
  late Box<SensorWidgetConfig> box;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shift_pages_test');
    // Hive.close() (in tearDown) doesn't unregister adapters, so a guard is
    // needed once this setUp runs for a second test in the same file.
    if (!Hive.isAdapterRegistered(SensorTypeAdapter().typeId)) {
      Hive.registerAdapter(SensorTypeAdapter());
      Hive.registerAdapter(DisplayStyleAdapter());
      Hive.registerAdapter(WidgetPositionAdapter());
      Hive.registerAdapter(WidgetSizeAdapter());
      Hive.registerAdapter(SensorWidgetConfigAdapter());
    }
    Hive.init(dir.path);
    box = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
  });

  tearDown(() async {
    await box.close();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> addConfig(SensorType type, int page) => box.add(
    SensorWidgetConfig(
      sensorType: type,
      displayStyle: DisplayStyle.numericWithHistory,
      position: WidgetPosition(x: 0, y: 0),
      size: WidgetSize(width: 1, height: 1),
      page: page,
    ),
  );

  test('shiftPagesAfterDelete reindexes every page after the deleted (empty) one down by one', () async {
    // Page 1 is deliberately left empty here — shiftPagesAfterDelete alone
    // assumes the deleted page has already had its own configs removed.
    await addConfig(SensorType.speed, 0);
    await addConfig(SensorType.gForce, 2);
    await addConfig(SensorType.altitude, 3);

    await SensorWidgetRepository.shiftPagesAfterDelete(1);

    final byType = {for (final c in SensorWidgetRepository.all) c.sensorType: c.page};
    expect(byType[SensorType.speed], 0); // before the deleted page: untouched.
    expect(byType[SensorType.gForce], 1); // was page 2, shifts down.
    expect(byType[SensorType.altitude], 2); // was page 3, shifts down.
  });

  test('deleteConfigsOnPage removes only the widgets on that page and reports their types', () async {
    await addConfig(SensorType.speed, 0);
    await addConfig(SensorType.gForce, 1);
    await addConfig(SensorType.altitude, 1);
    await addConfig(SensorType.inclination, 2);

    final deletedTypes = await SensorWidgetRepository.deleteConfigsOnPage(1);

    expect(deletedTypes.toSet(), {SensorType.gForce, SensorType.altitude});
    final remaining = SensorWidgetRepository.all.map((c) => c.sensorType).toSet();
    expect(remaining, {SensorType.speed, SensorType.inclination});
  });

  test('deleting a non-empty page: deleteConfigsOnPage followed by shiftPagesAfterDelete leaves indices contiguous', () async {
    await addConfig(SensorType.speed, 0);
    await addConfig(SensorType.gForce, 1);
    await addConfig(SensorType.altitude, 1);
    await addConfig(SensorType.inclination, 2);

    await SensorWidgetRepository.deleteConfigsOnPage(1);
    await SensorWidgetRepository.shiftPagesAfterDelete(1);

    final byType = {for (final c in SensorWidgetRepository.all) c.sensorType: c.page};
    expect(byType, {SensorType.speed: 0, SensorType.inclination: 1});
  });
}
