import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/screens/onboarding/sensor_selection_screen.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

/// Regression coverage for the fix that removed `AppSettings.selectedSensors`
/// as a second, independently-persisted source of "which sensors are
/// selected" — [SensorSelectionScreen] now derives its initial selection
/// directly from [SensorWidgetRepository], the dashboard's own source of
/// truth, so a sensor deleted from the dashboard can never linger here as
/// still checked (the bug this fixes).
void main() {
  late Directory dir;
  late Box<SensorWidgetConfig> box;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sensor_selection_screen_test');
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

  Future<void> addConfig(SensorType type) => box.add(
    SensorWidgetConfig(
      sensorType: type,
      displayStyle: DisplayStyle.numericWithHistory,
      position: WidgetPosition(x: 0, y: 0),
      size: WidgetSize(width: 1, height: 1),
    ),
  );

  SwitchListTile switchFor(WidgetTester tester, String label) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label));

  Widget buildScreen() => const MaterialApp(home: SensorSelectionScreen(isEditMode: true));

  testWidgets('the AppBar title reads "Adicione as ferramentas"', (tester) async {
    await tester.pumpWidget(buildScreen());
    expect(find.text('Adicione as ferramentas'), findsOneWidget);
    expect(find.text('Selecione as ferramentas'), findsNothing);
  });

  testWidgets('the initial selection reflects SensorWidgetRepository, not a separate stored set', (tester) async {
    await tester.runAsync(() => addConfig(SensorType.speed));
    await tester.pumpWidget(buildScreen());

    expect(switchFor(tester, 'Velocidade').value, isTrue);
    expect(switchFor(tester, 'Inclinação').value, isFalse);
  });

  testWidgets(
    'a sensor deleted from the dashboard no longer shows as selected the next time this screen opens',
    (tester) async {
      await tester.runAsync(() async {
        await addConfig(SensorType.speed);
        await addConfig(SensorType.inclination);
      });

      await tester.pumpWidget(buildScreen());
      expect(switchFor(tester, 'Velocidade').value, isTrue);
      expect(switchFor(tester, 'Inclinação').value, isTrue);

      // Mirrors exactly what DashboardScreen._handleDelete does for a
      // tile's long-press "Excluir" action.
      await tester.runAsync(
        () => SensorWidgetRepository.deleteConfig(SensorWidgetRepository.forSensor(SensorType.inclination)!),
      );

      // Simulates re-opening the screen (a fresh instance, as the dashboard's
      // "+" button always creates) rather than rebuilding the same one, so
      // this proves the *next open* reads fresh state, not stale State.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(buildScreen());

      expect(switchFor(tester, 'Velocidade').value, isTrue);
      expect(switchFor(tester, 'Inclinação').value, isFalse, reason: 'deleted from the dashboard, so no longer selected');
    },
  );

  testWidgets('a sensor unmarked by a dashboard deletion can be selected again normally', (tester) async {
    // A second sensor (inclination) stays on the dashboard throughout, so the
    // repository never goes fully empty — otherwise SensorSelectionScreen's
    // own "nothing on the dashboard yet" fallback (default to every sensor
    // selected) would mask exactly the state this test means to check.
    await tester.runAsync(() async {
      await addConfig(SensorType.speed);
      await addConfig(SensorType.inclination);
      await SensorWidgetRepository.deleteConfig(SensorWidgetRepository.forSensor(SensorType.speed)!);
    });

    await tester.pumpWidget(buildScreen());
    expect(switchFor(tester, 'Velocidade').value, isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Velocidade'));
    await tester.pump();

    expect(switchFor(tester, 'Velocidade').value, isTrue);
  });
}
