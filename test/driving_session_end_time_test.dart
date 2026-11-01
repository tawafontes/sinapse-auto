import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:synapse_auto/models/detected_event.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_event.dart';

import 'support/hive_box_io_gate.dart';

// Fase 16.2-R4.3-R2.6.13 — X208–X210: the model's side of "a record write
// requested before the STOP never stores the session as finished"
// (session_checkpoint_ordering_test.dart has the recorder's side, and the
// defect). A DrivingSession's end time is either UNCONFIRMED — read by
// everyone, stored by no write, whenever that write runs — or confirmed, which
// is what writes store. Field 2 kept its index and type: a file written by the
// build before this round reads the same, and this build writes the same
// bytes.
void main() {
  final t0 = DateTime.utc(2026, 6, 1, 8);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  setUpAll(() {
    if (!Hive.isAdapterRegistered(DrivingSessionAdapter().typeId)) Hive.registerAdapter(DrivingSessionAdapter());
    if (!Hive.isAdapterRegistered(DrivingSessionEventTypeAdapter().typeId)) Hive.registerAdapter(DrivingSessionEventTypeAdapter());
    if (!Hive.isAdapterRegistered(EventSeverityAdapter().typeId)) Hive.registerAdapter(EventSeverityAdapter());
    if (!Hive.isAdapterRegistered(DrivingSessionEventAdapter().typeId)) Hive.registerAdapter(DrivingSessionEventAdapter());
  });

  group('Fase 16.2-R4.3-R2.6.13 — the end time a write stores', () {
    test('X208 — an unconfirmed end time is read by endTime / isActive / state / duration and is NOT among the fields the adapter '
        'writes, nor in a detachedCopy; the first one is kept; confirmEndTime makes it the stored one, once; the setter and the '
        'constructor set a stored end time', () {
      final s = DrivingSession(id: 's', startTime: t0, sampleCount: 3);
      expect([s.endTime, s.isActive, _fieldsWritten(s)[2]], [null, true, null], reason: 'setup: recording');

      s.endUnconfirmed(at(5));

      expect(s.endTime, at(5));
      expect(s.isActive, isFalse);
      expect(s.state, DrivingSessionState.completed);
      expect(s.duration, const Duration(minutes: 5));
      expect(_fieldsWritten(s)[2], isNull, reason: 'pre-fix: the end time — a write stored it the moment it was set');
      expect(_fieldsWritten(s)[16], 3, reason: 'everything else is written as it is');
      expect(s.detachedCopy().endTime, isNull, reason: 'the copy carries what a write stores');
      expect(s.detachedCopy().isActive, isTrue);

      s.endUnconfirmed(at(9));
      expect(s.endTime, at(5), reason: 'a session that ended is not ended again: a retried finalization keeps the first end time');

      s.confirmEndTime();
      expect(s.endTime, at(5));
      expect(_fieldsWritten(s)[2], at(5), reason: 'confirmed: what every write stores from now on');
      expect(s.detachedCopy().endTime, at(5));
      s.confirmEndTime();
      s.endUnconfirmed(at(9));
      expect([s.endTime, _fieldsWritten(s)[2]], [at(5), at(5)], reason: 'confirming again or ending again changes nothing');

      final viaSetter = DrivingSession(id: 'r', startTime: t0)..endUnconfirmed(at(1));
      viaSetter.endTime = at(2);
      expect([viaSetter.endTime, _fieldsWritten(viaSetter)[2]], [at(2), at(2)], reason: 'the setter sets a stored end time');
      viaSetter.confirmEndTime();
      expect(viaSetter.endTime, at(2), reason: 'and replaced the unconfirmed one');
      viaSetter.endTime = null;
      expect([viaSetter.isActive, _fieldsWritten(viaSetter)[2]], [true, null]);

      final viaConstructor = DrivingSession(id: 'c', startTime: t0, endTime: at(3));
      expect([viaConstructor.endTime, _fieldsWritten(viaConstructor)[2]], [at(3), at(3)]);
      final neverEnded = DrivingSession(id: 'n', startTime: t0)..confirmEndTime();
      expect([neverEnded.endTime, _fieldsWritten(neverEnded)[2]], [null, null], reason: 'nothing to confirm');
    });

    test('X209 — the checkpoint test at the level of the box itself: a write of the record is requested while it has NO end time, '
        'the session then ends, and only then does the write run — it stores no end time. And the boundary of that, pinned: the '
        'plain setter means "writes store this", so the write that runs next does', () async {
      final dir = Directory.systemTemp.createTempSync('driving_session_end_time_test');
      final file = HiveBoxIoGate('checkpoints');
      Hive.init(dir.path);
      final box = await file.open(() => Hive.openBox<DrivingSession>('checkpoints'));
      try {
        final a = DrivingSession(id: 'a', startTime: t0, sampleCount: 4);
        final b = DrivingSession(id: 'b', startTime: t0, sampleCount: 4);
        await box.put(a.id, a);
        await box.put(b.id, b);

        // The file is busy: both checkpoints below are requested, not serialized.
        file.hold = true;
        final busy = box.put('other', DrivingSession(id: 'other', startTime: t0, endTime: t0));
        await file.untilHolding();
        final checkpointOfA = a.save();
        final checkpointOfB = b.save();

        a.endUnconfirmed(at(5)); // what a STOP does
        b.endTime = at(9); // a confirmed end: the recovery's, an edited record's
        expect([a.endTime, b.endTime], [at(5), at(9)], reason: 'setup: both read as ended');

        file.releaseAll();
        await Future.wait([busy, checkpointOfA, checkpointOfB]);
        final onDisk = {for (final id in ['a', 'b']) id: await _recordInFile(dir, id)};

        expect(onDisk['a']!.endTime, isNull, reason: 'pre-fix: the end time set AFTER the write was requested');
        expect(onDisk['a']!.sampleCount, 4);
        expect(onDisk['b']!.endTime, at(9), reason: 'hive serializes when the write runs: a confirmed end time is stored by whichever write runs next');

        a.confirmEndTime();
        await a.save();
        expect((await _recordInFile(dir, 'a'))!.endTime, at(5), reason: 'once confirmed, the next write stores it');
      } finally {
        file.releaseAll();
        await Hive.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('X210 — the stored format did not change: a sessions box file written by the build BEFORE this round (a finished session '
        'with every field set, an active one, one marked for deletion) reads back field by field, and this build writes the '
        'same three records as the very same bytes', () async {
      final dir = Directory.systemTemp.createTempSync('driving_session_end_time_test');
      Hive.init(dir.path);
      try {
        final before = base64.decode(_boxFileOfThePreviousBuild);
        File('${dir.path}/previous.hive').writeAsBytesSync(before);

        final box = await Hive.openBox<DrivingSession>('previous');
        expect(box.keys, ['active', 'ended', 'marked']);
        final ended = box.get('ended')!;
        final start = DateTime.utc(2026, 3, 14, 9, 26, 53);
        expect(ended.startTime, start);
        expect(ended.endTime, start.add(const Duration(minutes: 42, seconds: 7)));
        expect(ended.isActive, isFalse);
        expect(
          [ended.distanceMeters, ended.maxSpeedKmh, ended.avgSpeedKmh, ended.maxAltitudeMeters, ended.minAltitudeMeters, ended.maxAccelerationG, ended.maxDecelerationG],
          [31415.9, 118.5, 44.25, 912.5, 760.25, 0.31, 0.62],
        );
        expect(
          [ended.initialAltitudeMeters, ended.finalAltitudeMeters, ended.initialHeadingDegrees, ended.finalHeadingDegrees, ended.maxLateralG, ended.maxGForceMagnitude, ended.sampleCount],
          [801.5, 799.75, 12.5, 271.25, 0.44, 0.71, 2527],
        );
        expect(
          [ended.initialLatitude, ended.initialLongitude, ended.finalLatitude, ended.finalLongitude, ended.avgGnssQualityIndex, ended.altitudeGainMeters, ended.altitudeLossMeters],
          [-23.5505, -46.6333, -23.6821, -46.8755, 3.25, 151.5, 153.25],
        );
        expect(ended.events, hasLength(1));
        expect([ended.events.single.type, ended.events.single.severity, ended.events.single.id, ended.events.single.durationMs], [DrivingSessionEventType.hardBraking, EventSeverity.warning, 'e1', 800]);
        expect(ended.deletionPending, isFalse);
        expect(
          [ended.dashcamTelemetryOutcome, ended.dashcamTelemetryAcceptedCount, ended.dashcamTelemetryPersistedCount, ended.dashcamTelemetryRefusedCount],
          [DashcamTelemetryOutcome.failed, 2527, 2500, 3],
        );

        final active = box.get('active')!;
        expect([active.endTime, active.isActive, active.sampleCount, active.distanceMeters, active.maxSpeedKmh], [null, true, 7, 12.5, 33.0]);
        expect(active.startTime, start.add(const Duration(hours: 1)));

        final marked = box.get('marked')!;
        expect([marked.endTime, marked.sampleCount, marked.deletionPending], [start.add(const Duration(hours: 2, minutes: 5)), 13, true]);

        // The same three records, written by this build.
        final rewritten = await Hive.openBox<DrivingSession>('rewritten');
        for (final key in ['ended', 'active', 'marked']) {
          await rewritten.put(key, box.get(key)!.detachedCopy());
        }
        await rewritten.close();
        await box.close();
        expect(File('${dir.path}/rewritten.hive').readAsBytesSync(), before, reason: 'byte for byte what the previous build wrote');
      } finally {
        await Hive.close();
        dir.deleteSync(recursive: true);
      }
    });
  });
}

/// What the `checkpoints` box file in [dir] holds for [id], read by a box
/// opened on a COPY of it (so the open box and its cache are not involved).
Future<DrivingSession?> _recordInFile(Directory dir, String id) async {
  final copyDir = Directory.systemTemp.createTempSync('driving_session_end_time_copy');
  try {
    File('${dir.path}/checkpoints.hive').copySync('${copyDir.path}/copy.hive');
    final copy = await Hive.openBox<DrivingSession>('copy', path: copyDir.path);
    try {
      return copy.get(id)?.detachedCopy();
    } finally {
      await copy.close();
    }
  } finally {
    copyDir.deleteSync(recursive: true);
  }
}

/// Field index → value, as the generated adapter writes [s].
Map<int, Object?> _fieldsWritten(DrivingSession s) {
  final capture = _FieldCapture();
  DrivingSessionAdapter().write(capture, s);
  final e = capture.entries;
  return {for (var i = 1; i + 1 < e.length; i += 2) e[i]! as int: e[i + 1]};
}

/// Every call the generated adapter makes on a writer, in order.
class _FieldCapture implements BinaryWriter {
  final entries = <Object?>[];

  @override
  void writeByte(int value) => entries.add(value);

  @override
  void write<T>(T value, {bool writeTypeId = true}) => entries.add(value);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('$invocation');
}

/// `driving_sessions`-format box file (711 bytes, SHA-256 254f414e…892a)
/// written by the tree as it was before Fase 16.2-R4.3-R2.6.13 — generated by
/// scratchpad/fase16_2_r4_3_r2_6_13/05_format_fixture/p13_make_fixture_test.dart
/// on that tree.
const _boxFileOfThePreviousBuild =
    'qgEAAAEFZW5kZWQqHgAEBQAAAGVuZGVkARIAgHS4us55QgECEgAAZiG9znlCAQMCmpmZmfmt3kAEAgAAAAAAoF1ABQIAAAAAACBGQAYCAAAAAACEjEAHAgAA'
    'AAAAwodACALXo3A9CtfTPwkC16NwPQrX4z8KAgAAAAAADIlACwIAAAAAAP6IQAwCAAAAAAAAKUANAgAAAAAA9HBADgIpXI/C9SjcPw8CuB6F61G45j8QAQAA'
    'AAAAvqNAEQKwcmiR7Yw3wBICRUdy+Q9RR8ATAgKaCBuerjfAFALy0k1iEHBHwBUCAAAAAAAACkAWAgAAAAAA8GJAFwIAAAAAAChjQBgKAQAAAC0NACwBARIA'
    'gGbkus55QgECAtejcD0K1+M/AwQCAAAAZTEEAQAAAAAAAIlABQKPwvUoXI83wAYCUrgehetRR8AHAgAAAAAAwE5ACAIAAAAAALSIQAkC16NwPQrX478KApqZ'
    'mZmZmak/CwIpXI/C9SjkPwwuARkDABoBAAAAAAAAAEAbAQAAAAAAvqNAHAEAAAAAAIijQB0BAAAAAAAACEDntfbAjgAAAAEGYWN0aXZlKh4ABAYAAABhY3Rp'
    'dmUBEgCAXCe+znlCAQIAAwIAAAAAAAApQAQCAAAAAACAQEAFAAYABwAIAAkACgALAAwADQAOAA8AEAEAAAAAAAAcQBEAEgATABQAFQAWAgAAAAAAAAAAFwIA'
    'AAAAAAAAABgKAAAAABkDABoAGwAcAB0A8Af/Z48AAAABBm1hcmtlZCoeAAQGAAAAbWFya2VkARIAgESWwc55QgECEgCAgt/BznlCAQMCAAAAAAAAAAAEAAUA'
    'BgAHAAgACQAKAAsADAANAA4ADwAQAQAAAAAAACpAEQASABMAFAAVABYCAAAAAAAAAAAXAgAAAAAAAAAAGAoAAAAAGQMBGgAbABwAHQBH9B/j';
