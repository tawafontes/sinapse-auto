import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/dashcam_config.dart';
import 'package:synapse_auto/screens/settings/dashcam_settings_screen.dart';
import 'package:synapse_auto/services/dashcam_preferences.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

/// DashcamConfig as stored before `dualFrontPrimary` (field 6) existed.
class _OldDashcamConfigAdapter extends TypeAdapter<DashcamConfig> {
  @override
  final int typeId = 7;

  @override
  DashcamConfig read(BinaryReader reader) => throw UnimplementedError();

  @override
  void write(BinaryWriter writer, DashcamConfig obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.cameraSelection)
      ..writeByte(1)
      ..write(obj.storageQuotaMb)
      ..writeByte(2)
      ..write(obj.audioEnabled)
      ..writeByte(3)
      ..write(obj.resolution)
      ..writeByte(4)
      ..write(obj.frameRate)
      ..writeByte(5)
      ..write(obj.enabled);
  }
}

void registerAdapters() {
  if (!Hive.isAdapterRegistered(5)) Hive.registerAdapter(CameraSelectionAdapter());
  if (!Hive.isAdapterRegistered(6)) Hive.registerAdapter(VideoResolutionAdapter());
  if (!Hive.isAdapterRegistered(7)) Hive.registerAdapter(DashcamConfigAdapter());
}

DashcamConfig sample({bool frontPrimary = false}) => DashcamConfig(
      cameraSelection: CameraSelection.both,
      storageQuotaMb: 2048,
      audioEnabled: false,
      resolution: VideoResolution.hd720,
      frameRate: 30,
      enabled: true,
      dualFrontPrimary: frontPrimary,
    );

void main() {
  group('persistence', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('dashcam_dual_settings_test');
      Hive.init(dir.path);
      registerAdapters();
    });

    tearDown(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    test('the primary camera choice survives a reopen', () async {
      var box = await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
      await box.put('config', sample(frontPrimary: true));
      await box.close();
      box = await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
      expect(box.get('config')!.dualFrontPrimary, isTrue);
      expect(box.get('config')!.cameraSelection, CameraSelection.both);
    });

    test('a config stored before the field reads the back camera as primary', () async {
      Hive.registerAdapter(_OldDashcamConfigAdapter(), override: true);
      var box = await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
      await box.put('config', sample(frontPrimary: true));
      await box.close();
      Hive.registerAdapter(DashcamConfigAdapter(), override: true);
      box = await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig);
      final config = box.get('config')!;
      expect(config.dualFrontPrimary, isFalse, reason: 'defaultValue: the field was never written');
      expect(config.storageQuotaMb, 2048, reason: 'the other fields intact');
    });
  });

  group('the settings screen', () {
    setUp(() async {
      Hive.init('unused');
      registerAdapters();
      await Hive.openBox<DashcamConfig>(HiveBoxNames.dashcamConfig, bytes: Uint8List(0));
    });

    tearDown(() async {
      await Hive.close();
    });

    Future<DashcamPreferences> mount(WidgetTester tester, {required bool supported}) async {
      final prefs = DashcamPreferences();
      await tester.pumpWidget(MaterialApp(
        home: DashcamPreferencesScope(
          preferences: prefs,
          child: DashcamSettingsScreen(dualSupported: () async => supported),
        ),
      ));
      await tester.pump();
      return prefs;
    }

    testWidgets('"Ambas" is hidden where the phone cannot run both cameras', (tester) async {
      await mount(tester, supported: false);
      expect(find.byKey(const ValueKey('dashcamSettings_both')), findsNothing);
      expect(find.text('Traseira'), findsOneWidget);
    });

    testWidgets('"Ambas" and the primary camera choice', (tester) async {
      final prefs = await mount(tester, supported: true);
      expect(find.byKey(const ValueKey('dashcamSettings_both')), findsOneWidget);
      expect(find.text('Câmera principal'), findsNothing, reason: 'only with "Ambas"');

      await tester.tap(find.byKey(const ValueKey('dashcamSettings_both')));
      await tester.pump();
      expect(prefs.cameraSelection, CameraSelection.both);
      expect(find.text('Câmera principal'), findsOneWidget);
      expect(prefs.dualFrontPrimary, isFalse, reason: 'back camera with the front one in the corner by default');

      await tester.tap(find.byKey(const ValueKey('dashcamSettings_frontPrimary')));
      await tester.pump();
      expect(prefs.dualFrontPrimary, isTrue);
    });
  });
}
