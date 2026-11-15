import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

/// Write-only adapter that always emits byte 7 — the old `engineCoolant`
/// card, retired on 2026-11-15 when the engine temperature moved into the
/// "Temperaturas" panel. Simulates a phone that still has that card.
class _RetiredCoolantSensorTypeWriter extends TypeAdapter<SensorType> {
  @override
  final int typeId = 0;

  @override
  SensorType read(BinaryReader reader) => throw UnimplementedError('write-only');

  @override
  void write(BinaryWriter writer, SensorType obj) => writer.writeByte(7);
}

void main() {
  test(
    'a config persisted with the retired engine temperature byte (7) reads back as unknown and is discarded on startup, '
    'without touching any other widget',
    () async {
      final dir = Directory.systemTemp.createTempSync('retired_coolant_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      Hive.registerAdapter(DisplayStyleAdapter());
      Hive.registerAdapter(WidgetPositionAdapter());
      Hive.registerAdapter(WidgetSizeAdapter());
      Hive.registerAdapter(SensorWidgetConfigAdapter());

      // Phase 1: write one config with the retired engine temperature byte (7) and one
      // ordinary speed config, as an already-installed user's box would
      // have on disk before updating.
      Hive.registerAdapter(_RetiredCoolantSensorTypeWriter());
      Hive.init(dir.path);
      var box = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
      await box.add(
        SensorWidgetConfig(
          sensorType: SensorType.speed, // ignored — the writer above always emits byte 7.
          displayStyle: DisplayStyle.obdValue,
          position: WidgetPosition(x: 1, y: 1),
          size: WidgetSize(width: 2, height: 2),
        ),
      );
      await box.close();
      await Hive.close();

      // Phase 2: reopen with the real adapter, same as a real app upgrade,
      // and add a normal, unrelated widget alongside the orphaned one.
      Hive.registerAdapter(SensorTypeAdapter(), override: true);
      Hive.init(dir.path);
      box = await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
      await box.add(
        SensorWidgetConfig(
          sensorType: SensorType.speed,
          displayStyle: DisplayStyle.numericWithHistory,
          position: WidgetPosition(x: 0, y: 0),
          size: WidgetSize(width: 1, height: 1),
        ),
      );
      addTearDown(() async {
        await box.close();
        await Hive.close();
      });

      // Reading the retired byte alone must not throw, and already lands on
      // the unknown sentinel — the other, unrelated config reads normally.
      expect(box.getAt(0)!.sensorType, SensorType.unknown);
      expect(box.getAt(1)!.sensorType, SensorType.speed);

      // The startup migration discards only the orphaned engine temperature config,
      // leaving the other widget's data fully intact.
      await SensorWidgetRepository.discardUnknownSensors();

      final remaining = SensorWidgetRepository.all;
      expect(remaining, hasLength(1));
      expect(remaining.single.sensorType, SensorType.speed);
      expect(remaining.single.position.x, 0);
      expect(remaining.single.size.width, 1);
    },
  );
}
