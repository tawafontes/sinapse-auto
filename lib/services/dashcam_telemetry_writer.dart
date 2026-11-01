import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/dashcam_telemetry_sample.dart';

/// Lifecycle of a [DashcamTelemetryWriter] (Fase 16.2-R4.3-R2.6.10) — ONE
/// field, changed at one place per transition, never a set of booleans that
/// could disagree:
///
/// `created → opening → open → closing → closed`, with `failed` reachable from
/// `opening`/`open` on the first real I/O failure. `failed` is terminal for
/// writing (nothing is accepted or written any more); [DashcamTelemetryWriter
/// .close] still moves it through `closing` to `closed` to release the file.
/// The first failure itself is kept separately, as a record, in
/// [DashcamTelemetryWriter.failure] — it survives `closing`/`closed`.
enum DashcamTelemetryWriterState {
  /// Constructed; [DashcamTelemetryWriter.open] not requested yet.
  created,

  /// [DashcamTelemetryWriter.open] requested; the file is not confirmed open.
  opening,

  /// The file is open and every write so far succeeded — the only state in
  /// which [DashcamTelemetryWriter.add] accepts a sample.
  open,

  /// A real I/O failure happened (opening, or writing) before close was
  /// requested. Terminal for writing.
  failed,

  /// [DashcamTelemetryWriter.close] requested and still running.
  closing,

  /// Closed; the file handle, if one was ever acquired, is released.
  closed,
}

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
///
/// Fase 16.2-R4.3-R2.6.9 — concurrency contract. Every operation that touches
/// the file ([open], [flush], [close]) runs on ONE serialized chain
/// ([_serialized]), so at most one of them uses the file at a time; [add]
/// never touches the file itself; [close] is one memoized operation that
/// waits for every operation accepted before it. (R2.6.9 was about dart:io's
/// IOSink, which throws "StreamSink is bound to a stream" while a flush is in
/// flight; the [RandomAccessFile] used since R2.6.10 has the same rule — "An
/// async operation is currently pending" — so the chain is still what keeps
/// the file consistent.)
///
/// Fase 16.2-R4.3-R2.6.10 — failure semantics (pre-audit R2.6.9, 3×P2):
/// - **The file is really opened by [open].** `File.openWrite` opens lazily:
///   an unopenable path used to surface only as an uncaught asynchronous error,
///   while [open] completed normally and [add] accepted every sample of the
///   session (100% lost, UI showing "recording"). Measured
///   (`RELATORIO_R4_3_R2_6_10.md` §4): only `File.open` completes after the
///   operating system opened the file and reports a failure to its caller, so
///   the writer now opens with `File.open(mode: append)` and writes through
///   that [RandomAccessFile]. [open] completes with `true` only once the file
///   is open; on a failure it completes with `false` (it does not throw) and
///   the writer is [DashcamTelemetryWriterState.failed].
/// - **The first real I/O failure is terminal.** From then on [add] refuses
///   every sample (returns false, counted in [refusedSampleCount]) and nothing
///   is written again: no retry, no reopen — a failed write may already have
///   put part of its bytes on disk, and writing the batch again would duplicate
///   them. [failure] keeps that first error; [close] still releases the file
///   and completes with it, never with a secondary cleanup error.
/// - **A batch leaves [_pending] only after its write succeeded**
///   ([persistedSampleCount]); samples accepted before the failure and never
///   written stay counted as [unpersistedSampleCount] — the loss is reported,
///   never hidden by rewriting a counter.
///
/// Errors: every failure completes the Future of the operation that hit it
/// (an automatic flush's Future is unawaited, so its failure is an uncaught
/// async error, as before) and is reported to [onFailure] once.
class DashcamTelemetryWriter {
  DashcamTelemetryWriter({required this.sessionId, this.onFailure});

  final String sessionId;

  /// Called once, synchronously, when the writer records its first real I/O
  /// failure (opening, writing or closing) — how its owner learns about a
  /// failure no caller is awaiting (an automatic flush).
  final void Function(DashcamTelemetryWriter writer)? onFailure;

  /// Buffered, not yet appended to disk — flushed automatically every
  /// [_flushEverySamples] samples (proportionally *more* frequent than
  /// `DrivingSessionRecorder`'s own 10-samples/~10s flush policy,
  /// deliberately: a crash coinciding with a hard-braking event is exactly
  /// when this footage/data is most valuable, so this errs toward losing
  /// less on an unclean kill).
  static const _flushEverySamples = 25;

  DashcamTelemetryWriterState _state = DashcamTelemetryWriterState.created;

  /// Set by [open]'s operation, cleared by [close]'s. Non-null means a file
  /// handle is held.
  RandomAccessFile? _file;

  /// Accepted and not yet confirmed written, in acceptance order. The running
  /// write's batch is its first [_writing] samples: they are removed only once
  /// that write has succeeded.
  final List<DashcamTelemetrySample> _pending = [];
  int _writing = 0;

  /// Completes when the last operation queued by [_serialized] has finished
  /// (successfully or not) — never with an error, so a failed operation does
  /// not stop the ones queued after it.
  Future<void> _lastOperation = Future<void>.value();

  /// A [flush] queued behind a running operation and not started yet. Further
  /// flush requests join it instead of queueing more work: it takes whatever
  /// is pending when it starts.
  Future<void>? _queuedFlush;

  /// The one [open] operation (memoized: a late call never reopens).
  Future<bool>? _open;

  /// The one [close] operation. Non-null = closing or closed.
  Future<void>? _close;

  /// The first real I/O failure — what [failure] exposes and [close] reports.
  (Object, StackTrace)? _firstFailure;

  int _acceptedSampleCount = 0;
  int _refusedSampleCount = 0;
  int _persistedSampleCount = 0;

  DashcamTelemetryWriterState get state => _state;

  /// The writer's first real I/O failure, or `null`. Kept once closed.
  Object? get failure => _firstFailure?.$1;

  /// Samples [add] accepted over this writer's life. Never decremented.
  int get acceptedSampleCount => _acceptedSampleCount;

  /// Samples offered to [add] and refused (not open yet, failed, closing or
  /// closed) — produced, never accepted.
  int get refusedSampleCount => _refusedSampleCount;

  /// Accepted samples whose write the file confirmed.
  int get persistedSampleCount => _persistedSampleCount;

  /// Accepted and not (yet) confirmed written. Once [close] has completed,
  /// non-zero only after a failure: those samples are lost.
  int get unpersistedSampleCount => _acceptedSampleCount - _persistedSampleCount;

  /// Fase 16.2-R4.3-R2.6.9 seam, kept for its tests: [acceptedSampleCount].
  @visibleForTesting
  int get acceptedSampleCountForTest => _acceptedSampleCount;

  /// Whether [close] has been called (the writer may still be finishing it).
  bool get isClosed => _close != null;

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

  /// Opens the session's file for appending and completes with `true` once it
  /// is really open ([DashcamTelemetryWriterState.open]). Completes with
  /// `false` — never throws — when it could not be opened (the writer is then
  /// [DashcamTelemetryWriterState.failed], see [failure]) or when [close] was
  /// requested first. Memoized: a later call returns the same Future and
  /// never reopens the file.
  Future<bool> open() {
    if (_state == DashcamTelemetryWriterState.created) _state = DashcamTelemetryWriterState.opening;
    return _open ??= _serialized(_openFile);
  }

  Future<bool> _openFile() async {
    // close() requested before this operation ran: acquire nothing.
    if (_state != DashcamTelemetryWriterState.opening) return false;
    try {
      final file = await fileForSession(sessionId);
      // close() may have been requested while the path was being resolved.
      if (_state != DashcamTelemetryWriterState.opening) return false;
      _file = await file.open(mode: FileMode.append);
    } catch (error, stack) {
      _fail(error, stack);
      return false;
    }
    // close() requested while the OS was opening: the close queued behind this
    // operation releases the handle; nothing is accepted.
    if (_state != DashcamTelemetryWriterState.opening) return false;
    _state = DashcamTelemetryWriterState.open;
    return true;
  }

  /// Buffers [sample]. Returns false — and keeps nothing — unless the writer
  /// is [DashcamTelemetryWriterState.open]: before [open] confirmed the file,
  /// after the first I/O failure, and once [close] has been called (e.g. a
  /// late timer/event callback of a recording that is being torn down).
  bool add(DashcamTelemetrySample sample) {
    if (_state != DashcamTelemetryWriterState.open) {
      _refusedSampleCount++;
      return false;
    }
    _pending.add(sample);
    _acceptedSampleCount++;
    if (_pending.length - _writing >= _flushEverySamples) {
      unawaited(flush());
    }
    return true;
  }

  /// Appends every sample accepted before this call. After [close] has been
  /// called this queues no work and returns [close]'s own Future (which
  /// covers those samples). After a failure it queues nothing and completes
  /// with that failure — nothing will be written any more.
  Future<void> flush() {
    final closing = _close;
    if (closing != null) return closing;
    final failure = _firstFailure;
    if (failure != null) return Future<void>.error(failure.$1, failure.$2);
    return _queuedFlush ??= _serialized(() {
      _queuedFlush = null;
      return _writePending();
    });
  }

  /// Idempotent: the first call queues the close behind every operation
  /// already accepted; every later call returns the same Future. Refuses new
  /// samples from the call on; writes what is pending unless the writer has
  /// failed; always releases the file; completes with [failure], if any.
  Future<void> close() {
    final existing = _close;
    if (existing != null) return existing;
    _state = DashcamTelemetryWriterState.closing;
    return _close = _serialized(_closeFile);
  }

  /// Runs [operation] after every operation queued before it has finished,
  /// and returns [operation]'s own outcome. The chain itself never fails, so
  /// a failed flush does not prevent the close queued after it.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _lastOperation;
    final finished = Completer<void>();
    _lastOperation = finished.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        finished.complete();
      }
    }();
  }

  /// Records the first real I/O failure: `failed` from `opening`/`open` (a
  /// close already requested stays `closing`), reported once to [onFailure].
  void _fail(Object error, StackTrace stack) {
    if (_firstFailure != null) return;
    _firstFailure = (error, stack);
    if (_state == DashcamTelemetryWriterState.opening || _state == DashcamTelemetryWriterState.open) {
      _state = DashcamTelemetryWriterState.failed;
    }
    onFailure?.call(this);
  }

  /// Only ever runs on the chain, so nobody else uses [_file] meanwhile. The
  /// batch is everything pending when the operation starts (a flush queued
  /// behind another one writes all of it, once), and leaves [_pending] only
  /// after the file accepted it.
  Future<void> _writePending() async {
    final failure = _firstFailure;
    if (failure != null) {
      // Terminal: nothing is written again. What is still pending is lost —
      // this flush does not report success for it.
      if (_pending.isNotEmpty) Error.throwWithStackTrace(failure.$1, failure.$2);
      return;
    }
    final file = _file;
    if (file == null || _pending.isEmpty) return;
    final count = _pending.length;
    _writing = count;
    try {
      final lines = StringBuffer();
      for (var i = 0; i < count; i++) {
        lines
          ..write(jsonEncode(_pending[i].toJson()))
          ..write('\n');
      }
      await file.writeFrom(utf8.encode(lines.toString()));
    } catch (error, stack) {
      _writing = 0;
      _fail(error, stack);
      rethrow;
    }
    _pending.removeRange(0, count);
    _writing = 0;
    _persistedSampleCount += count;
  }

  Future<void> _closeFile() async {
    final file = _file;
    if (file != null) {
      if (_firstFailure == null) {
        try {
          await _writePending();
        } catch (_) {
          // Recorded as the first failure; the file is still released below.
        }
      }
      _file = null;
      try {
        await file.close();
      } catch (error, stack) {
        // Kept only if it is the first failure: a cleanup error never
        // replaces the primary one.
        _fail(error, stack);
      }
    }
    _state = DashcamTelemetryWriterState.closed;
    final failure = _firstFailure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
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
