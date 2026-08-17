import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/dashboard_maintenance_service.dart';

void main() {
  group('DashboardMaintenanceService', () {
    const service = DashboardMaintenanceService();

    test('runs every trigger, in order', () async {
      final calls = <int>[];
      await service.resetAndCalibrateAll([() => calls.add(1), () => calls.add(2), () => calls.add(3)]);

      expect(calls, [1, 2, 3]);
    });

    test('an empty trigger list completes without error', () async {
      await expectLater(service.resetAndCalibrateAll(const <VoidCallback>[]), completes);
    });

    test('a trigger that throws stops the remaining triggers from running', () async {
      final calls = <int>[];
      final triggers = <VoidCallback>[
        () => calls.add(1),
        () => throw StateError('boom'),
        () => calls.add(3),
      ];

      await expectLater(service.resetAndCalibrateAll(triggers), throwsStateError);
      expect(calls, [1]);
    });
  });
}
