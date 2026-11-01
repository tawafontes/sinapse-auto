// Reads what a Hive box FILE holds, without going through the open box.
//
// A non-lazy box answers `get` from its cache — for a session being recorded,
// the very instance its recorder mutates in memory — so it cannot say what is
// durable. Closing and reopening the box would, but that changes the scenario:
// the box then holds a new instance, read from the file. Here the file is
// COPIED and the copy is opened as another box, by Hive's own reader: the live
// box, its cache and every object bound to it are left untouched. A copy taken
// while a write is landing ends in a partial frame, which Hive discards when
// it opens the copy — so the snapshot is what was complete on disk right then.
//
// Real asynchronous I/O: under FakeAsync (testWidgets) call these inside
// `tester.runAsync`.
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:synapse_auto/models/driving_session.dart';
import 'package:synapse_auto/models/driving_session_sample.dart';
import 'package:synapse_auto/services/hive_boxes.dart';

var _snapshots = 0;

Future<T> _withCopyOf<T>(Directory hiveDir, String boxName, Future<T> Function(String name, String path) read) async {
  final copyDir = Directory.systemTemp.createTempSync('hive_file_snapshot');
  try {
    final name = 'snapshot_${_snapshots++}';
    final source = File('${hiveDir.path}/$boxName.hive');
    if (source.existsSync()) source.copySync('${copyDir.path}/$name.hive');
    return await read(name, copyDir.path);
  } finally {
    copyDir.deleteSync(recursive: true);
  }
}

/// Every session record the sessions box FILE in [hiveDir] holds, by id — as
/// unbound copies.
Future<Map<String, DrivingSession>> sessionRecordsOnDisk(Directory hiveDir) => _withCopyOf(hiveDir, HiveBoxNames.drivingSessions, (name, path) async {
  final box = await Hive.openBox<DrivingSession>(name, path: path);
  try {
    return {for (final key in box.keys) key as String: box.get(key)!.detachedCopy()};
  } finally {
    await box.close();
  }
});

/// The session record the sessions box FILE holds for [id]; null = none.
Future<DrivingSession?> sessionRecordOnDisk(Directory hiveDir, String id) async => (await sessionRecordsOnDisk(hiveDir))[id];

/// The samples the samples box FILE holds for [id]; null = no entry.
Future<List<DrivingSessionSample>?> sessionSamplesOnDisk(Directory hiveDir, String id) => _withCopyOf(hiveDir, HiveBoxNames.drivingSessionSamples, (name, path) async {
  final box = await Hive.openLazyBox(name, path: path);
  try {
    final raw = await box.get(id) as List?;
    return raw == null ? null : List<DrivingSessionSample>.from(raw);
  } finally {
    await box.close();
  }
});

/// The invariant between a session's summary and its trajectory, read from the
/// FILES: every record that reads as DURABLY FINALIZED — an end time, and no
/// deletion marker — declares exactly the samples stored for it, each once and
/// in order. Only that checkpoint is judged: a record still active on disk is
/// allowed to be ahead of its stored samples (the summary is written on every
/// sample, the samples every tenth), which is what the startup recovery
/// reconciles. Returns the violations, each naming its session by [names]
/// (id → role) when given; empty = the invariant holds.
Future<List<String>> durablyFinalizedViolations(Directory hiveDir, {Map<String, String> names = const {}}) async {
  final violations = <String>[];
  final records = await sessionRecordsOnDisk(hiveDir);
  for (final MapEntry(key: id, value: record) in records.entries) {
    if (record.endTime == null || record.deletionPending) continue;
    final who = names[id] ?? id;
    final stored = await sessionSamplesOnDisk(hiveDir, id) ?? const <DrivingSessionSample>[];
    if (record.sampleCount != stored.length) {
      violations.add('$who: finalized on disk declaring ${record.sampleCount} samples, ${stored.length} stored');
    }
    for (var i = 1; i < stored.length; i++) {
      if (!stored[i].timestamp.isAfter(stored[i - 1].timestamp)) {
        violations.add('$who: stored samples ${i - 1} and $i are not in order (a sample stored twice?)');
        break;
      }
    }
  }
  return violations;
}
