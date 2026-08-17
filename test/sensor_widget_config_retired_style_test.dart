import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

/// Write-only adapter that always emits byte 0 — the old `numeric` field,
/// retired (along with `gaugeCircular`/`bar`) when Speed was narrowed down
/// to `numericWithHistory` only. Simulates a config an already-installed
/// user still has on disk from before that retirement.
class _RetiredDisplayStyleWriter extends TypeAdapter<DisplayStyle> {
  @override
  final int typeId = 1;

  @override
  DisplayStyle read(BinaryReader reader) => throw UnimplementedError('write-only');

  @override
  void write(BinaryWriter writer, DisplayStyle obj) => writer.writeByte(0);
}

void main() {
  test('a speed config persisted with a retired style byte reads back safely and migrates to numericWithHistory', () async {
    final dir = Directory.systemTemp.createTempSync('retired_style_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    Hive.registerAdapter(SensorTypeAdapter());
    Hive.registerAdapter(WidgetPositionAdapter());
    Hive.registerAdapter(WidgetSizeAdapter());
    Hive.registerAdapter(SensorWidgetConfigAdapter());

    // Phase 1: write with the retired byte, as an already-installed user's
    // box would have on disk.
    Hive.registerAdapter(_RetiredDisplayStyleWriter());
    Hive.init(dir.path);
    var box = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
    await box.add(
      SensorWidgetConfig(
        sensorType: SensorType.speed,
        displayStyle: DisplayStyle.numericWithHistory, // ignored — the writer above always emits byte 0.
        position: WidgetPosition(x: 0, y: 0),
        size: WidgetSize(width: 1, height: 1),
      ),
    );
    await box.close();
    await Hive.close();

    // Phase 2: reopen with the real adapter, same as a real app upgrade.
    Hive.registerAdapter(DisplayStyleAdapter(), override: true);
    Hive.init(dir.path);
    box = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
    addTearDown(() async {
      await box.close();
      await Hive.close();
    });

    // Reading the retired byte alone must not throw, and already lands on
    // the fallback value.
    expect(box.getAt(0)!.displayStyle, DisplayStyle.numericWithHistory);

    // The startup migration confirms it as the correct, valid style for speed.
    await SensorWidgetRepository.migrateInvalidStyles();
    expect(box.getAt(0)!.displayStyle, DisplayStyle.numericWithHistory);
  });
}
