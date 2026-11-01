// Fake of the FILE-SYSTEM edge under DashcamTelemetryWriter.
//
// Inside [TelemetryIoGate.run], IOOverrides hands every `File(...)` whose path
// is a dashcam telemetry file (`.../dashcam_telemetry/<id>.jsonl`) to a
// [_GatedTelemetryFile]. Since Fase 16.2-R4.3-R2.6.10 the writer opens its file
// with `File.open(mode: append)` and writes through the [RandomAccessFile]
// (R2.6.9's version of this gate wrapped dart:io's real IOSink, which the
// writer no longer uses): open() returns a [_GatedRandomAccessFile] over a real
// synchronous handle. Each writeFrom() is one DELIVERY, which the gate can
// HOLD (a slow or hung disk) or FAIL (a write error). Released deliveries are
// appended to the real file with synchronous I/O, so the app's own reader
// (loadDashcamTelemetry) sees what reached "disk", and a released delivery
// completes without needing real asynchronous time (FakeAsync tests). Opening
// itself is never held: `hold` is about writes.
//
// Failure/concurrency model = dart:io's own `_RandomAccessFile` (measured in
// R2.6.10, `02_open_readiness`): a failed write leaves the handle OPEN (close
// still releases it); a second asynchronous operation while one is in flight
// fails with "An async operation is currently pending" (the RandomAccessFile
// analogue of the IOSink's "StreamSink is bound to a stream"); anything after
// close fails with "File closed".
//
// Every other path is an ordinary dart:io File.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class TelemetryIoGate {
  /// While true, each delivery (one writeFrom of the writer) is held until
  /// [releaseAll]/[releaseNext].
  bool hold = false;

  Object? _failNext;
  Object? _failNextClose;
  final List<Completer<void>> _held = [];
  final List<(int, Completer<void>)> _heldWaiters = [];

  /// open() calls on telemetry files (one per file handle the writer opens).
  int opens = 0;

  /// writeFrom() calls (deliveries) received.
  int deliveries = 0;

  /// Deliveries received and not yet finished.
  int activeDeliveries = 0;
  int maxActiveDeliveries = 0;

  /// close() calls that released a handle.
  int closes = 0;

  /// Real handles opened and not closed yet.
  int openHandles = 0;
  int failures = 0;

  /// Every line that reached the real file, in order.
  final List<String> writtenLines = [];

  int get heldCount => _held.length;

  /// Runs [body] with the overrides installed (zone-scoped).
  R run<R>(R Function() body) => IOOverrides.runWithIOOverrides(body, _GateOverrides(this));

  /// The next delivery fails with [error] instead of being written.
  void failNext(Object error) => _failNext = error;

  /// The next close() of a telemetry handle completes with [error] (the fake
  /// still releases its real handle, so a test's directory can be deleted).
  void failNextClose(Object error) => _failNextClose = error;

  void releaseAll() {
    final held = List.of(_held);
    _held.clear();
    for (final c in held) {
      c.complete();
    }
  }

  void releaseNext() {
    if (_held.isEmpty) return;
    _held.removeAt(0).complete();
  }

  /// Completes once at least [count] deliveries are held at the same time.
  Future<void> untilHeld([int count = 1]) {
    if (_held.length >= count) return Future.value();
    final c = Completer<void>();
    _heldWaiters.add((count, c));
    return c.future;
  }

  void _notifyHeld() {
    _heldWaiters.removeWhere((w) {
      if (_held.length >= w.$1) {
        w.$2.complete();
        return true;
      }
      return false;
    });
  }

  /// Decoded `spd` (speed) values of every written line, in order.
  List<num?> get writtenSpeeds => [for (final l in writtenLines) (jsonDecode(l) as Map<String, Object?>)['spd'] as num?];

  Map<String, Object?> toJson() => {
    'opens': opens,
    'deliveries': deliveries,
    'activeDeliveries': activeDeliveries,
    'maxActiveDeliveries': maxActiveDeliveries,
    'held': heldCount,
    'closes': closes,
    'openHandles': openHandles,
    'failures': failures,
    'writtenLines': writtenLines.length,
  };

  static bool isTelemetryPath(String path) {
    final p = path.replaceAll('\\', '/');
    return p.contains('/dashcam_telemetry/') && p.endsWith('.jsonl');
  }
}

final class _GateOverrides extends IOOverrides {
  _GateOverrides(this.gate);
  final TelemetryIoGate gate;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return TelemetryIoGate.isTelemetryPath(path) ? _GatedTelemetryFile(real, gate) : real;
  }
}

class _GatedTelemetryFile implements File {
  _GatedTelemetryFile(this._real, this._gate);
  final File _real;
  final TelemetryIoGate _gate;

  @override
  String get path => _real.path;

  @override
  Uri get uri => _real.uri;

  @override
  File get absolute => _real.absolute;

  @override
  Future<bool> exists() => _real.exists();

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => _real.delete(recursive: recursive);

  @override
  void deleteSync({bool recursive = false}) => _real.deleteSync(recursive: recursive);

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) => _real.readAsLines(encoding: encoding);

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) => _real.readAsLinesSync(encoding: encoding);

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    _gate.opens++;
    try {
      return Future.value(_GatedRandomAccessFile(_real, mode, _gate));
    } catch (error, stack) {
      // A real open failure (e.g. the path is a directory), reported to the
      // caller like dart:io's own File.open.
      return Future.error(error, stack);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('_GatedTelemetryFile.${invocation.memberName}');
}

class _GatedRandomAccessFile implements RandomAccessFile {
  _GatedRandomAccessFile(File real, FileMode mode, this._gate) : _raf = real.openSync(mode: mode), path = real.path {
    _gate.openHandles++;
  }

  final TelemetryIoGate _gate;
  final RandomAccessFile _raf;
  bool _closed = false;
  bool _busy = false;
  final _pendingLine = StringBuffer();

  @override
  final String path;

  /// dart:io's `_RandomAccessFile._dispatch` rules.
  FileSystemException? _unavailable() {
    if (_closed) return FileSystemException('File closed', path);
    if (_busy) return FileSystemException('An async operation is currently pending', path);
    return null;
  }

  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) {
    final unavailable = _unavailable();
    if (unavailable != null) return Future.error(unavailable);
    _busy = true;
    _gate.deliveries++;
    _gate.activeDeliveries++;
    if (_gate.activeDeliveries > _gate.maxActiveDeliveries) _gate.maxActiveDeliveries = _gate.activeDeliveries;
    final data = Uint8List.fromList(buffer.sublist(start, end));
    return () async {
      try {
        if (_gate.hold) {
          final release = Completer<void>();
          _gate._held.add(release);
          _gate._notifyHeld();
          await release.future;
        }
        final fail = _gate._failNext;
        _gate._failNext = null;
        if (fail != null) {
          // The handle stays open, as with dart:io's RandomAccessFile.
          _gate.failures++;
          throw fail;
        }
        _raf.writeFromSync(data);
        _pendingLine.write(utf8.decode(data));
        final lines = _pendingLine.toString().split('\n');
        _pendingLine
          ..clear()
          ..write(lines.removeLast());
        _gate.writtenLines.addAll(lines.where((l) => l.isNotEmpty));
        return this;
      } finally {
        _gate.activeDeliveries--;
        _busy = false;
      }
    }();
  }

  @override
  Future<void> close() {
    final unavailable = _unavailable();
    if (unavailable != null) return Future.error(unavailable);
    _closed = true;
    _raf.closeSync();
    _gate.closes++;
    _gate.openHandles--;
    final fail = _gate._failNextClose;
    _gate._failNextClose = null;
    if (fail != null) {
      _gate.failures++;
      return Future.error(fail);
    }
    return Future.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('_GatedRandomAccessFile.${invocation.memberName}');
}
