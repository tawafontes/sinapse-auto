// Fase 16.2-R4.3-R2.6.8 — X129.
//
// R4.3-D2 F29: AlertEngine and EventDetectionEngine ended in a bare
// asBroadcastStream(), which keeps its source subscription after its last
// listener leaves — every disposed dashboard left the snapshot pipeline (and
// its 1 Hz GNSS timer) subscribed for the rest of the process. Now their
// events are a RefCountedBroadcast: one source subscription however many
// listeners, released with the last one, a FRESH detector for the next
// listening period, closed by dispose().
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/alert_event.dart';
import 'package:synapse_auto/models/alert_type.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/telemetry_snapshot.dart';
import 'package:synapse_auto/services/alert_engine.dart';
import 'package:synapse_auto/services/alert_preferences.dart';
import 'package:synapse_auto/services/event_detection_engine.dart';
import 'package:synapse_auto/services/gnss_quality.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

import 'support/fake_sensor_platforms.dart' show ListenCounter;

void main() {
  late Directory dir;
  late AlertPreferences prefs;
  late StreamController<TelemetrySnapshot> source;
  late ListenCounter counter;
  late Stream<TelemetrySnapshot> snapshots;
  final t0 = DateTime(2026, 1, 1, 12);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('engine_snapshot_subscription_test');
    Hive.init(dir.path);
    await Hive.openBox(HiveBoxNames.appSettings);
    prefs = AlertPreferences();
    source = StreamController<TelemetrySnapshot>.broadcast();
    counter = ListenCounter();
    snapshots = counter.wrap(source.stream);
  });

  tearDown(() async {
    await source.close();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  group('Fase 16.2-R4.3-R2.6.8 — X129 engines hold the snapshot stream only while listened to', () {
    test('X129 AlertEngine: one source subscription for two listeners, released with the last one, a fresh '
        'detector for the next listener, closed by dispose', () async {
      final engine = AlertEngine(snapshots, prefs);
      expect(counter.listens, 0, reason: 'nothing subscribed before a listener');

      final first = <AlertEvent>[];
      final second = <AlertEvent>[];
      final a = engine.events.listen(first.add);
      final b = engine.events.listen(second.add);
      expect(counter.active, 1, reason: 'one source subscription for two listeners');
      source.add(TelemetrySnapshot(timestamp: t0, pitchDegrees: 35, gnssQuality: GnssQuality.excellent));
      await flush();
      expect(first.where((e) => e.type == AlertType.highInclination && e.active), hasLength(1));
      expect(second.where((e) => e.type == AlertType.highInclination && e.active), hasLength(1), reason: 'the same event reaches both');

      await a.cancel();
      expect(counter.active, 1, reason: 'still listened to');
      await b.cancel();
      expect(counter.active, 0, reason: 'released with the last listener');

      // A new listening period, within the old cooldown: a fresh detector fires again.
      final third = <AlertEvent>[];
      final c = engine.events.listen(third.add);
      expect(counter.listens, 2);
      expect(counter.active, 1);
      source.add(TelemetrySnapshot(timestamp: t0.add(const Duration(seconds: 1)), pitchDegrees: 35, gnssQuality: GnssQuality.excellent));
      await flush();
      expect(third.where((e) => e.type == AlertType.highInclination && e.active), hasLength(1));

      final done = Completer<void>();
      c.onDone(done.complete);
      engine.dispose();
      await done.future;
      expect(counter.active, 0, reason: 'dispose releases the source');
    });

    test('X129 EventDetectionEngine: one source subscription for two listeners, released with the last one, '
        'resubscribed for the next listener, closed by dispose', () async {
      final engine = EventDetectionEngine(snapshots, prefs);
      expect(counter.listens, 0);

      final first = <DetectedEvent>[];
      final second = <DetectedEvent>[];
      final a = engine.events.listen(first.add);
      final b = engine.events.listen(second.add);
      expect(counter.active, 1);
      source.add(TelemetrySnapshot(timestamp: t0, gnssQuality: GnssQuality.unavailable));
      await flush();
      expect(first.map((e) => e.type), contains(DetectedEventType.gnssLost));
      expect(second.map((e) => e.type), contains(DetectedEventType.gnssLost));

      await a.cancel();
      await b.cancel();
      expect(counter.active, 0, reason: 'released with the last listener');

      final third = <DetectedEvent>[];
      final c = engine.events.listen(third.add);
      expect(counter.listens, 2);
      expect(counter.active, 1);
      source.add(TelemetrySnapshot(timestamp: t0.add(const Duration(seconds: 1)), gnssQuality: GnssQuality.unavailable));
      await flush();
      expect(third.map((e) => e.type), contains(DetectedEventType.gnssLost), reason: 'a fresh detector for the new listening period');

      final done = Completer<void>();
      c.onDone(done.complete);
      engine.dispose();
      await done.future;
      expect(counter.active, 0);
    });
  });
}
