import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/services/app_settings.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('app_settings_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('dashboardPageCount defaults to 1 when never set', () {
    expect(AppSettings.dashboardPageCount, 1);
  });

  test('dashboardPageCount persists whatever is set', () async {
    await AppSettings.setDashboardPageCount(3);
    expect(AppSettings.dashboardPageCount, 3);
  });

  test('dashboardLastViewedPage defaults to 0 when never set', () {
    expect(AppSettings.dashboardLastViewedPage, 0);
  });

  test('dashboardLastViewedPage persists whatever is set', () async {
    await AppSettings.setDashboardLastViewedPage(2);
    expect(AppSettings.dashboardLastViewedPage, 2);
  });
}
