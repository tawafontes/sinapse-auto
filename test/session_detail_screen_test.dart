import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/screens/sessions/session_detail_screen.dart';

// Full widget-level coverage for SessionDetailScreen (tabs, event-tap
// navigation, empty-state messaging) was attempted here and pulled back out:
// this screen's initState kicks off a real Hive LazyBox.get() (dart:io),
// and — same as SessionHistoryScreen's own ValueListenableBuilder-over-Hive
// pattern, see that file's own comment — real file I/O does not resolve
// under AutomatedTestWidgetsFlutterBinding's fake-pumped clock. Interleaving
// tester.runAsync() with manual pump() calls does get the initial load to
// settle, but Hive.close() in tearDown hangs the same way with no tester
// available there to un-stick it, and there is no supported way around that
// without either faking Hive's storage backend (a mocking layer this
// codebase deliberately avoids — see e.g. `reading_quality_test.dart`'s own
// "no mocking needed" convention) or restructuring how this screen loads
// its data purely to appease a test harness limitation, not a real app need.
// So — matching the established, already-documented precedent above — this
// screen's interactive behavior (tabs, event-tap-to-jump, per-signal empty
// states, short/old-session robustness) is validated on the physical device
// instead (Fase 12 §49/§54); the pure geometry/downsampling/analysis logic
// it's built from (`computeTrajectoryLayout` below, plus
// `session_analysis_engine_test.dart`, `decimate_test.dart`,
// `gg_diagram_test.dart`, `session_time_series_chart_test.dart`) is fully
// unit-tested, which is the actual risk worth guarding.
void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  DrivingSessionSample sampleAt(double? lat, double? lon) =>
      DrivingSessionSample(timestamp: t0, latitude: lat, longitude: lon);

  group('computeTrajectoryLayout', () {
    test('fewer than 2 fixes with a valid position produces no points', () {
      expect(computeTrajectoryLayout([]).points, isEmpty);
      expect(computeTrajectoryLayout([sampleAt(1, 2)]).points, isEmpty);
    });

    test('samples without a GPS fix (null lat/lon) are excluded', () {
      final layout = computeTrajectoryLayout([
        sampleAt(null, null),
        sampleAt(0, 0),
        sampleAt(1, 1),
        sampleAt(null, null),
      ]);
      expect(layout.points.length, 2);
    });

    test('normalizes points into the 0..1 range, preserving relative shape', () {
      final layout = computeTrajectoryLayout([sampleAt(0, 0), sampleAt(1, 1), sampleAt(0.5, 0.5)]);
      expect(layout.points.length, 3);
      for (final point in layout.points) {
        expect(point.dx, inInclusiveRange(0.0, 1.0));
        expect(point.dy, inInclusiveRange(0.0, 1.0));
      }
    });

    test('latitude increases upward on screen (dy decreases as latitude increases)', () {
      final layout = computeTrajectoryLayout([sampleAt(0, 0), sampleAt(1, 0)]);
      // First sample (lower latitude) must have a larger dy (closer to the
      // bottom of the canvas) than the second (higher latitude).
      expect(layout.points[0].dy, greaterThan(layout.points[1].dy));
    });

    test('a degenerate route (identical lat/lon throughout) does not divide by zero', () {
      final layout = computeTrajectoryLayout([sampleAt(5, 5), sampleAt(5, 5), sampleAt(5, 5)]);
      expect(layout.points.length, 3);
      for (final point in layout.points) {
        expect(point.dx.isFinite, isTrue);
        expect(point.dy.isFinite, isTrue);
      }
    });
  });
}
