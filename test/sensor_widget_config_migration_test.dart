import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';

/// Mimics the pre-`page`-field generated adapter (4 fields, no field 4) —
/// simulates a [SensorWidgetConfig] that was already persisted on disk
/// before that field existed. Write-only: this test never reads with it.
class _OldSensorWidgetConfigAdapter extends TypeAdapter<SensorWidgetConfig> {
  @override
  final int typeId = 4;

  @override
  SensorWidgetConfig read(BinaryReader reader) =>
      throw UnimplementedError('write-only — simulates the pre-page-field format');

  @override
  void write(BinaryWriter writer, SensorWidgetConfig obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.sensorType)
      ..writeByte(1)
      ..write(obj.displayStyle)
      ..writeByte(2)
      ..write(obj.position)
      ..writeByte(3)
      ..write(obj.size);
  }
}

void main() {
  test('a config persisted before the page field existed reads back as page 0', () async {
    final dir = Directory.systemTemp.createTempSync('sensor_widget_config_migration_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    Hive.registerAdapter(SensorTypeAdapter());
    Hive.registerAdapter(DisplayStyleAdapter());
    Hive.registerAdapter(WidgetPositionAdapter());
    Hive.registerAdapter(WidgetSizeAdapter());

    // Phase 1: write with the OLD (4-field) format.
    Hive.registerAdapter(_OldSensorWidgetConfigAdapter());
    Hive.init(dir.path);
    var box = await Hive.openBox<SensorWidgetConfig>('migration_test_box');
    await box.add(
      SensorWidgetConfig(
        sensorType: SensorType.speed,
        displayStyle: DisplayStyle.numericWithHistory,
        position: WidgetPosition(x: 1, y: 2),
        size: WidgetSize(width: 2, height: 2),
      ),
    );
    await box.close();
    await Hive.close();

    // Phase 2: reopen with the REAL (current) adapter, which knows about
    // `page` and must default it to 0 for the old, page-less record.
    Hive.registerAdapter(SensorWidgetConfigAdapter(), override: true);
    Hive.init(dir.path);
    box = await Hive.openBox<SensorWidgetConfig>('migration_test_box');
    final restored = box.getAt(0)!;

    expect(restored.page, 0);
    expect(restored.sensorType, SensorType.speed);
    expect(restored.position.x, 1);

    await box.close();
    await Hive.close();
  });
}
