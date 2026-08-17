import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_telemetry_sample.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_telemetry_writer_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      null,
    );
    dir.deleteSync(recursive: true);
  });

  final t0 = DateTime(2026, 1, 1, 12);

  test('loadDashcamTelemetry returns an empty list when no file exists yet for the session', () async {
    final samples = await loadDashcamTelemetry('never-recorded-session');
    expect(samples, isEmpty);
  });

  test('a sample written and flushed round-trips through loadDashcamTelemetry', () async {
    final writer = DashcamTelemetryWriter(sessionId: 'session-1');
    await writer.open();
    writer.add(
      DashcamTelemetrySample(timestamp: t0, latitude: 1.5, longitude: 2.5, speedKmh: 42, resultantG: 0.3),
    );
    await writer.close();

    final samples = await loadDashcamTelemetry('session-1');
    expect(samples, hasLength(1));
    expect(samples.single.timestamp, t0);
    expect(samples.single.latitude, 1.5);
    expect(samples.single.longitude, 2.5);
    expect(samples.single.speedKmh, 42);
    expect(samples.single.resultantG, 0.3);
  });

  test('auto-flushes once 25 samples have been buffered, without needing close()', () async {
    final writer = DashcamTelemetryWriter(sessionId: 'session-auto-flush');
    await writer.open();
    for (var i = 0; i < 25; i++) {
      writer.add(DashcamTelemetrySample(timestamp: t0.add(Duration(seconds: i)), speedKmh: i.toDouble()));
    }
    // add() flushes fire-and-forget (unawaited) once the threshold is hit —
    // a real, generous delay (not just Duration.zero, which isn't always
    // enough to let a multi-await IOSink.flush() chain fully land on disk
    // when run alongside a large full suite) gives it time to actually
    // reach disk.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final samples = await loadDashcamTelemetry('session-auto-flush');
    expect(samples, hasLength(25));

    await writer.close();
  });

  test('a malformed/truncated last line is skipped, not fatal to the rest of the file', () async {
    final writer = DashcamTelemetryWriter(sessionId: 'session-truncated');
    await writer.open();
    writer.add(DashcamTelemetrySample(timestamp: t0, speedKmh: 10));
    writer.add(DashcamTelemetrySample(timestamp: t0.add(const Duration(seconds: 1)), speedKmh: 20));
    await writer.close();

    // Simulate a process kill mid-write: append a truncated, invalid JSON
    // line directly, bypassing the writer.
    final file = await DashcamTelemetryWriter.fileForSession('session-truncated');
    await file.writeAsString('{"t":"2026-01-01T12:00:02.000","spd":3', mode: FileMode.append);

    final samples = await loadDashcamTelemetry('session-truncated');
    expect(samples, hasLength(2));
    expect(samples[0].speedKmh, 10);
    expect(samples[1].speedKmh, 20);
  });

  test('eventType round-trips through JSON', () async {
    final writer = DashcamTelemetryWriter(sessionId: 'session-event');
    await writer.open();
    writer.add(DashcamTelemetrySample(timestamp: t0, eventType: DetectedEventType.hardBraking));
    writer.add(DashcamTelemetrySample(timestamp: t0.add(const Duration(seconds: 1))));
    await writer.close();

    final samples = await loadDashcamTelemetry('session-event');
    expect(samples, hasLength(2));
    expect(samples[0].eventType, DetectedEventType.hardBraking);
    expect(samples[1].eventType, isNull);
  });
}
