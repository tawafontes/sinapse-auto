import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/screens/sessions/session_history_screen.dart';

// Widget-level coverage for SessionHistoryScreen (ValueListenableBuilder
// over a live Hive Box.listenable()) is validated on the physical device
// instead of here — the pure filtering/sorting logic below is unit-tested
// directly (which is the actual risk worth guarding), matching this
// codebase's established convention for other Hive/hardware-backed screens
// (SensorService, DashboardSensorStreams) that likewise have no dedicated
// widget-pump test.
void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('visibleSessionsSortedByRecency', () {
    test('excludes an active (not-yet-finished) session', () {
      final active = DrivingSession(id: 'a', startTime: t0);
      final finished = DrivingSession(id: 'b', startTime: t0, endTime: t0.add(const Duration(minutes: 5)));
      expect(visibleSessionsSortedByRecency([active, finished]), [finished]);
    });

    test('sorts most-recent start time first', () {
      final older = DrivingSession(id: 'a', startTime: t0, endTime: t0.add(const Duration(minutes: 1)));
      final newer = DrivingSession(
        id: 'b',
        startTime: t0.add(const Duration(days: 1)),
        endTime: t0.add(const Duration(days: 1, minutes: 1)),
      );
      expect(visibleSessionsSortedByRecency([older, newer]), [newer, older]);
    });

    test('an empty input yields an empty list', () {
      expect(visibleSessionsSortedByRecency([]), isEmpty);
    });

    test('multiple finished sessions all sort correctly, active ones filtered throughout', () {
      final s1 = DrivingSession(id: '1', startTime: t0, endTime: t0.add(const Duration(minutes: 1)));
      final s2 = DrivingSession(
        id: '2',
        startTime: t0.add(const Duration(hours: 2)),
        endTime: t0.add(const Duration(hours: 2, minutes: 1)),
      );
      final activeMidway = DrivingSession(id: '3', startTime: t0.add(const Duration(hours: 1)));
      final s4 = DrivingSession(
        id: '4',
        startTime: t0.add(const Duration(hours: 3)),
        endTime: t0.add(const Duration(hours: 3, minutes: 1)),
      );
      expect(visibleSessionsSortedByRecency([s1, s2, activeMidway, s4]), [s4, s2, s1]);
    });
  });
}
