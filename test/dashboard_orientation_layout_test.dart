import 'dart:io';

import 'package:flutter/widgets.dart' show Orientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/sensor_widget_config.dart';
import 'package:synapse_auto/services/dashboard_orientation_layout.dart';
import 'package:synapse_auto/services/hive_boxes.dart';
import 'package:synapse_auto/services/sensor_widget_repository.dart';

// The landscape dashboard's own layout (owner request, 2026-11-12) over real Hive
// files: a LandscapeWidgetLayout reads and writes only the landscape fields of
// its widget, never the portrait ones, and the repository's page operations work
// on whichever layout they are given.
void main() {
  late Directory dir;

  Box<SensorWidgetConfig> box() => Hive.box<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('orientation_layout_test');
    if (!Hive.isAdapterRegistered(SensorTypeAdapter().typeId)) {
      Hive.registerAdapter(SensorTypeAdapter());
      Hive.registerAdapter(DisplayStyleAdapter());
      Hive.registerAdapter(WidgetPositionAdapter());
      Hive.registerAdapter(WidgetSizeAdapter());
      Hive.registerAdapter(SensorWidgetConfigAdapter());
    }
    Hive.init(dir.path);
    await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Future<SensorWidgetConfig> add(SensorType type, DisplayStyle style, {double x = -1, double y = -1, int page = 0}) async {
    final config = SensorWidgetConfig(
      sensorType: type,
      displayStyle: style,
      position: WidgetPosition(x: x, y: y),
      size: WidgetSize(width: 2, height: 2),
      page: page,
    );
    await box().add(config);
    return config;
  }

  ({double x, double y, double w, double h, int page}) portraitOf(SensorWidgetConfig c) =>
      (x: c.position.x, y: c.position.y, w: c.size.width, h: c.size.height, page: c.page);

  test('portrait is the stored configs themselves', () async {
    final a = await add(SensorType.speed, DisplayStyle.numericWithHistory, x: 0, y: 0);
    final layout = dashboardLayoutFor(Orientation.portrait, [a]);
    expect(identical(layout.single, a), isTrue);
  });

  test('landscape: one layout per widget, in the portrait reading order, unplaced ones last; none placed yet', () async {
    final unplaced = await add(SensorType.refuel, DisplayStyle.refuelSummary);
    final secondPage = await add(SensorType.altitude, DisplayStyle.lineChart, x: 0, y: 0, page: 1);
    final lowerRight = await add(SensorType.gForce, DisplayStyle.gForceMeter, x: 2, y: 2);
    final lowerLeft = await add(SensorType.inclination, DisplayStyle.artificialHorizon, x: 0, y: 2);
    final top = await add(SensorType.speed, DisplayStyle.numericWithHistory, x: 2, y: 0);

    final layout = dashboardLayoutFor(Orientation.landscape, SensorWidgetRepository.all);
    expect(layout.every((c) => c is LandscapeWidgetLayout), isTrue);
    expect([for (final c in layout) (c as LandscapeWidgetLayout).stored], [top, lowerLeft, lowerRight, secondPage, unplaced]);
    expect(layout.every((c) => c.position.x == -1 && c.position.y == -1), isTrue, reason: 'no landscape layout stored yet');
  });

  test('saving a landscape layout stores only the landscape fields, durably; the portrait layout is untouched', () async {
    final speed = await add(SensorType.speed, DisplayStyle.numericWithHistory, x: 2, y: 4, page: 1);
    final before = portraitOf(speed);
    final view = dashboardLayoutFor(Orientation.landscape, [speed]).single;

    await SensorWidgetRepository.updateLayout(view, position: WidgetPosition(x: 6, y: 0), size: WidgetSize(width: 2, height: 3), page: 2);

    await Hive.close();
    await Hive.openBox<SensorWidgetConfig>(HiveBoxNames.sensorWidgetConfigs);
    final stored = box().values.single;
    expect(portraitOf(stored), before);
    expect(
      (stored.landscapePosition!.x, stored.landscapePosition!.y, stored.landscapeSize!.width, stored.landscapeSize!.height, stored.landscapePage),
      (6.0, 0.0, 2.0, 3.0, 2),
    );
    final again = dashboardLayoutFor(Orientation.landscape, SensorWidgetRepository.all).single;
    expect((again.position.x, again.position.y, again.size.width, again.size.height, again.page), (6.0, 0.0, 2.0, 3.0, 2));
  });

  test('a portrait change leaves the landscape layout alone', () async {
    final speed = await add(SensorType.speed, DisplayStyle.numericWithHistory, x: 0, y: 0);
    await SensorWidgetRepository.updateLayout(
      dashboardLayoutFor(Orientation.landscape, [speed]).single,
      position: WidgetPosition(x: 4, y: 0),
      size: WidgetSize(width: 2, height: 3),
      page: 0,
    );
    await SensorWidgetRepository.updateLayout(speed, position: WidgetPosition(x: 2, y: 2), size: WidgetSize(width: 4, height: 2));
    expect((speed.landscapePosition!.x, speed.landscapeSize!.height), (4.0, 3.0));
  });

  test('the style is the widget\'s own (read and written through), and deleting the layout deletes the widget', () async {
    final speed = await add(SensorType.gForce, DisplayStyle.gForceMeter, x: 0, y: 0);
    final view = dashboardLayoutFor(Orientation.landscape, [speed]).single;
    speed.displayStyle = DisplayStyle.lineChart;
    expect(view.displayStyle, DisplayStyle.lineChart);
    expect(view.sensorType, SensorType.gForce);
    await SensorWidgetRepository.deleteConfig(view);
    expect(box().isEmpty, isTrue);
  });

  test('deleting a landscape page deletes the widgets on it and shifts later landscape pages, not the portrait ones', () async {
    Future<SensorWidgetConfig> placed(SensorType type, DisplayStyle style, {required int portraitPage, required int landscapePage}) async {
      final c = await add(type, style, x: 0, y: 0, page: portraitPage);
      await dashboardLayoutFor(Orientation.landscape, [c]).single.let((v) {
        v.position = WidgetPosition(x: 0, y: 0);
        v.size = WidgetSize(width: 2, height: 3);
        v.page = landscapePage;
        return v.save();
      });
      return c;
    }

    final onFirst = await placed(SensorType.speed, DisplayStyle.numericWithHistory, portraitPage: 0, landscapePage: 0);
    final onSecond = await placed(SensorType.gForce, DisplayStyle.gForceMeter, portraitPage: 0, landscapePage: 1);
    final onThird = await placed(SensorType.altitude, DisplayStyle.lineChart, portraitPage: 1, landscapePage: 2);

    final layout = dashboardLayoutFor(Orientation.landscape, SensorWidgetRepository.all);
    final deleted = await SensorWidgetRepository.deleteConfigsOnPage(1, configs: layout);
    await SensorWidgetRepository.shiftPagesAfterDelete(1, configs: layout.where((c) => !deleted.contains(c.sensorType)));

    expect(deleted, [SensorType.gForce]);
    expect(box().values, isNot(contains(onSecond)));
    expect((onFirst.landscapePage, onThird.landscapePage), (0, 1), reason: 'landscape pages shifted down');
    expect((onFirst.page, onThird.page), (0, 1), reason: 'portrait pages untouched');
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
