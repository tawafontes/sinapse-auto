import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/dashcam_telemetry_sample.dart';

/// Appends [DashcamTelemetrySample]s for one active recording session to an
/// append-only JSON-Lines file — deliberately not Hive.
///
/// `DrivingSessionRecorder`'s own doc comment already explains why it
/// decimates telemetry to 1Hz before persisting: a `LazyBox`-style
/// read-modify-rewrite-the-whole-list flush is fine at that rate, but would
/// scale badly (hours × several Hz × rewrite-whole-list, into hundreds of
/// MB-GB of cumulative I/O) at the ~5Hz this sampler runs at during an
/// active dashcam recording. An append-only file sidesteps that entirely:
/// every flush only appends new bytes, regardless of how large the file
/// already is.
///
/// One compact JSON object per line (not a hand-rolled binary format):
/// human-debuggable, trivially forward-compatible (a reader from an older
/// build just ignores unknown keys), and needs no new dependency beyond
/// `dart:convert`, already used throughout the app.
class DashcamTelemetryWriter {
  DashcamTelemetryWriter({required this.sessionId});

  final String sessionId;

  /// Buffered, not yet appended to disk — flushed automatically every
  /// [_flushEverySamples] samples (proportionally *more* frequent than
  /// `DrivingSessionRecorder`'s own 10-samples/~10s flush policy,
  /// deliberately: a crash coinciding with a hard-braking event is exactly
  /// when this footage/data is most valuable, so this errs toward losing
  /// less on an unclean kill).
  static const _flushEverySamples = 25;

  IOSink? _sink;
  final List<DashcamTelemetrySample> _pending = [];

  static Future<Directory> _telemetryDirectory() async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${documentsDir.path}/dashcam_telemetry');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> fileForSession(String sessionId) async {
    final dir = await _telemetryDirectory();
    return File('${dir.path}/$sessionId.jsonl');
  }

  Future<void> open() async {
    final file = await fileForSession(sessionId);
    _sink = file.openWrite(mode: FileMode.append);
  }

  void add(DashcamTelemetrySample sample) {
    _pending.add(sample);
    if (_pending.length >= _flushEverySamples) {
      unawaited(flush());
    }
  }

  Future<void> flush() async {
    final sink = _sink;
    if (sink == null || _pending.isEmpty) return;
    final toWrite = List<DashcamTelemetrySample>.of(_pending);
    _pending.clear();
    for (final sample in toWrite) {
      sink.writeln(jsonEncode(sample.toJson()));
    }
    await sink.flush();
  }

  Future<void> close() async {
    await flush();
    await _sink?.close();
    _sink = null;
  }
}

/// Loads a session's whole telemetry file at once — only meant to be called
/// on demand (e.g. when a session's "Vídeo" tab is opened), matching
/// `session_detail_screen.dart`'s existing lazy-`_loadSamples()` convention.
/// Returns an empty list (never throws) if the file doesn't exist yet (no
/// dashcam recording happened for this session) or can't be read.
///
/// Skips, rather than fails on, any malformed/truncated line — a session
/// killed mid-write must still yield every sample recorded before the kill,
/// not lose the whole readout to one bad trailing line.
Future<List<DashcamTelemetrySample>> loadDashcamTelemetry(String sessionId) async {
  final file = await DashcamTelemetryWriter.fileForSession(sessionId);
  if (!await file.exists()) return const [];

  final samples = <DashcamTelemetrySample>[];
  try {
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, Object?>) {
          final sample = DashcamTelemetrySample.tryFromJson(decoded);
          if (sample != null) samples.add(sample);
        }
      } on FormatException {
        // Malformed/truncated line (e.g. a process kill mid-write) — skip
        // just this one sample, not the whole file.
        continue;
      }
    }
  } on IOException {
    return samples;
  }
  return samples;
}
