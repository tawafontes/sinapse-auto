// Fase 16.2-R4.3-R2.6.10 — X144–X150: DashcamTelemetryWriter I/O failure
// semantics (pre-audit R2.6.9 P2-A/P2-B). "real" tests use dart:io with no fake
// at all (an unopenable path: the .jsonl is a directory; a mid-stream write
// failure: a Windows byte-range lock taken by a second handle). "gated" tests
// fail or hold a write explicitly (test/support/telemetry_io_gate.dart). Every
// test checks what reached the file and the writer's own accounting —
// accepted vs persisted vs refused — not only the absence of an exception.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/dashcam_telemetry_sample.dart';
import 'package:synapse_auto/services/dashcam_telemetry_writer.dart';

import 'support/telemetry_io_gate.dart';

final _t0 = DateTime(2026, 1, 1, 12);

/// Sample #[i] carries speed [i]: its identity in the file.
DashcamTelemetrySample _sample(int i) => DashcamTelemetrySample(timestamp: _t0.add(Duration(milliseconds: 200 * i)), speedKmh: i.toDouble());

List<int> _range(int from, int to) => [for (var i = from; i <= to; i++) i];

/// Runs [body] in an error zone (inside [gate]'s overrides when given) and
/// returns every uncaught asynchronous error it produced. A failure of [body]
/// itself (an `expect` inside it) is rethrown outside the zone.
Future<List<Object>> _uncaughtErrorsOf(Future<void> Function() body, {TelemetryIoGate? gate}) {
  final uncaught = <Object>[];
  final done = Completer<List<Object>>();
  runZonedGuarded(() async {
    Object? bodyError;
    StackTrace? bodyStack;
    try {
      await (gate == null ? body() : gate.run(body));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } catch (e, s) {
      bodyError = e;
      bodyStack = s;
    }
    if (bodyError != null) {
      done.completeError(bodyError, bodyStack);
    } else {
      done.complete(uncaught);
    }
  }, (e, s) => uncaught.add(e));
  return done.future;
}

/// Outcome of a Future observed without awaiting it.
class _Watched {
  _Watched(Future<Object?> future) {
    future.then<void>(
      (_) {
        done = true;
      },
      onError: (Object e, StackTrace _) {
        done = true;
        error = e;
      },
    );
  }
  bool done = false;
  Object? error;
}

Future<Object?> _errorOf(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (e) {
    return e;
  }
}

Future<void> _until(bool Function() condition, String what) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!condition()) fail('timed out waiting for: $what');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_telemetry_writer_failure_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProviderChannel, null);
    // Fails the test if a telemetry file handle was left open (Windows refuses
    // to delete an open file).
    dir.deleteSync(recursive: true);
  });

  String pathOf(String id) => '${dir.path}/dashcam_telemetry/$id.jsonl';

  List<int?> linesOnDisk(String id) {
    final f = File(pathOf(id));
    if (!f.existsSync() || FileSystemEntity.isDirectorySync(f.path)) return const [];
    return [for (final s in f.readAsLinesSync().where((l) => l.isNotEmpty)) int.parse(RegExp(r'"spd":(\d+)').firstMatch(s)!.group(1)!)];
  }

  group('Fase 16.2-R4.3-R2.6.10 — telemetry writer I/O failures', () {
    test('X144 (real) open() of a path dart:io cannot open completes false without an uncaught error; the writer is failed: '
        'add refuses, flush and close report the open failure, and nothing reopens it', () async {
      // No fake: the telemetry path is a directory (pre-fix: open() "succeeded"
      // lazily and every sample of the session was accepted and lost).
      Directory(pathOf('x144')).createSync(recursive: true);
      final notified = <DashcamTelemetryWriter>[];
      final writer = DashcamTelemetryWriter(sessionId: 'x144', onFailure: notified.add);
      late bool opened;
      late List<bool> adds;
      Object? flushError;
      late Future<void> c1;
      Object? closeError;
      late bool lateOpen;
      final errors = await _uncaughtErrorsOf(() async {
        final open = writer.open();
        expect(writer.state, DashcamTelemetryWriterState.opening, reason: 'not open before the operating system opened the file');
        opened = await open;
        adds = [for (var i = 1; i <= 30; i++) writer.add(_sample(i))];
        flushError = await _errorOf(writer.flush());
        c1 = writer.close();
        closeError = await _errorOf(c1);
        lateOpen = await writer.open();
      });
      expect(errors, isEmpty, reason: 'pre-fix: the open failure was an uncaught asynchronous error');
      expect(opened, isFalse);
      expect(writer.failure, isA<FileSystemException>());
      expect(notified, [same(writer)], reason: 'reported once');
      expect(adds, everyElement(isFalse), reason: 'pre-fix: 30/30 accepted, 0 written');
      expect(writer.acceptedSampleCount, 0);
      expect(writer.refusedSampleCount, 30);
      expect(identical(flushError, writer.failure), isTrue, reason: 'a flush after the failure does not report success');
      expect(identical(closeError, writer.failure), isTrue);
      expect(identical(writer.close(), c1), isTrue);
      expect(writer.state, DashcamTelemetryWriterState.closed);
      expect(lateOpen, isFalse, reason: 'open() is memoized: no retry, no reopen');
      expect(notified, hasLength(1));
      expect(FileSystemEntity.isDirectorySync(pathOf('x144')), isTrue, reason: 'nothing was created');
    });

    test('X145 (gated) open readiness: open() completes true only once the file is open; add before that is refused; '
        'a close requested before the open ran acquires nothing', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x145');
      final early = DashcamTelemetryWriter(sessionId: 'x145-early');
      late bool opened;
      late bool addWhileOpening;
      late bool earlyOpened;
      late bool earlyLateOpen;
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        final open = writer.open();
        addWhileOpening = writer.add(_sample(0));
        expect(identical(writer.open(), open), isTrue, reason: 'one open operation');
        opened = await open;
        expect(writer.state, DashcamTelemetryWriterState.open);
        expect(gate.openHandles, 1, reason: 'the handle exists when open() reports success');
        expect(File(pathOf('x145')).existsSync(), isTrue);
        for (var i = 1; i <= 3; i++) {
          expect(writer.add(_sample(i)), isTrue);
        }
        await writer.close();

        // close() in the same slice as open(): the open operation runs first on
        // the chain but finds the close already requested.
        final earlyOpen = early.open();
        final earlyClose = early.close();
        earlyOpened = await earlyOpen;
        await earlyClose;
        earlyLateOpen = await early.open();
      });
      expect(errors, isEmpty);
      expect(addWhileOpening, isFalse, reason: 'refused until the file is really open');
      expect(opened, isTrue);
      expect(writer.refusedSampleCount, 1);
      expect(writer.persistedSampleCount, 3);
      expect(linesOnDisk('x145'), _range(1, 3));
      expect(earlyOpened, isFalse);
      expect(earlyLateOpen, isFalse);
      expect(early.state, DashcamTelemetryWriterState.closed);
      expect(gate.opens, 1, reason: 'the early writer never opened a handle');
      expect(gate.openHandles, 0);
    });

    test('X146 (gated) the first write failure is terminal: add refuses from then on, the accepted-but-unwritten samples '
        'are counted as unpersisted, flush and close report the failure, and the handle is released', () async {
      final gate = TelemetryIoGate();
      final notified = <DashcamTelemetryWriter>[];
      final writer = DashcamTelemetryWriter(sessionId: 'x146', onFailure: notified.add);
      const ioError = FileSystemException('write failed (injected)', 'x146.jsonl');
      late List<bool> addsAfterFailure;
      Object? flushError;
      Object? closeError;
      late Future<void> c1;
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await _until(() => writer.persistedSampleCount == 25, 'first automatic flush');
        gate.failNext(ioError);
        for (var i = 26; i <= 50; i++) {
          writer.add(_sample(i));
        }
        await _until(() => writer.failure != null, 'the second automatic flush failed');
        expect(writer.state, DashcamTelemetryWriterState.failed);
        addsAfterFailure = [for (var i = 51; i <= 53; i++) writer.add(_sample(i))];
        flushError = await _errorOf(writer.flush());
        c1 = writer.close();
        closeError = await _errorOf(c1);
      });
      expect(errors, [same(ioError)], reason: 'the unawaited automatic flush fails loudly, exactly once');
      expect(notified, [same(writer)]);
      expect(addsAfterFailure, everyElement(isFalse), reason: 'pre-fix: accepted, never written');
      expect(writer.acceptedSampleCount, 50, reason: 'the history is not rewritten');
      expect(writer.persistedSampleCount, 25);
      expect(writer.unpersistedSampleCount, 25, reason: '26..50 accepted before the failure and lost — counted, not hidden');
      expect(writer.refusedSampleCount, 3);
      expect(identical(flushError, ioError), isTrue);
      expect(identical(closeError, ioError), isTrue);
      expect(identical(writer.close(), c1), isTrue, reason: 'the same terminal result');
      expect(writer.state, DashcamTelemetryWriterState.closed);
      expect(gate.closes, 1, reason: 'released even after the failure');
      expect(gate.openHandles, 0);
      expect(gate.deliveries, 2, reason: 'no retry of the failed batch');
      expect(linesOnDisk('x146'), _range(1, 25), reason: 'a prefix of the accepted samples, no duplicate');
    });

    test('X147 (real) a real mid-stream write failure (byte-range lock): terminal, no secondary "File closed" errors, '
        'file = what was persisted, handle released', () async {
      final writer = DashcamTelemetryWriter(sessionId: 'x147');
      RandomAccessFile? locker;
      late List<bool> addsAfterFailure;
      Object? closeError;
      final errors = await _uncaughtErrorsOf(() async {
        await writer.open();
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await _until(() => writer.persistedSampleCount == 25, 'first automatic flush');
        locker = File(pathOf('x147')).openSync(mode: FileMode.append)..lockSync(FileLock.exclusive, 0, 1 << 40);
        for (var i = 26; i <= 50; i++) {
          writer.add(_sample(i));
        }
        await _until(() => writer.failure != null, 'the automatic flush failed for real');
        addsAfterFailure = [for (var i = 51; i <= 53; i++) writer.add(_sample(i))];
        closeError = await _errorOf(writer.close());
        locker!.unlockSync(0, 1 << 40);
        locker!.closeSync();
        locker = null;
      });
      if (locker != null) {
        locker!.unlockSync(0, 1 << 40);
        locker!.closeSync();
      }
      expect(writer.failure, isA<FileSystemException>());
      expect(errors, [same(writer.failure)], reason: 'only the automatic flush\'s own failure (pre-fix: +1 "File closed" per later write)');
      expect(addsAfterFailure, everyElement(isFalse));
      expect(identical(closeError, writer.failure), isTrue, reason: 'close reports the primary error');
      expect(writer.persistedSampleCount, 25);
      expect(writer.unpersistedSampleCount, 25);
      expect(linesOnDisk('x147'), _range(1, 25));
      final f = File(pathOf('x147'));
      expect(() => f.renameSync('${f.path}.x'), returnsNormally, reason: 'the handle was released');
    }, skip: Platform.isWindows ? false : 'a byte-range lock only makes the write fail on Windows (mandatory locking)');

    test('X148 (gated) close failures: the final write failing is reported by close; a cleanup error after a write '
        'failure never replaces the primary error', () async {
      final gate = TelemetryIoGate();
      final a = DashcamTelemetryWriter(sessionId: 'x148a');
      final b = DashcamTelemetryWriter(sessionId: 'x148b');
      const finalWriteError = FileSystemException('final write failed (injected)', 'x148a.jsonl');
      const writeError = FileSystemException('write failed (injected)', 'x148b.jsonl');
      const closeError = FileSystemException('close failed (injected)', 'x148b.jsonl');
      Object? aClose;
      Object? bClose;
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await a.open();
        for (var i = 1; i <= 3; i++) {
          a.add(_sample(i));
        }
        gate.failNext(finalWriteError);
        aClose = await _errorOf(a.close());

        await b.open();
        gate.failNext(writeError);
        for (var i = 1; i <= 25; i++) {
          b.add(_sample(i));
        }
        await _until(() => b.failure != null, 'b\'s automatic flush failed');
        gate.failNextClose(closeError);
        bClose = await _errorOf(b.close());
      });
      expect(identical(aClose, finalWriteError), isTrue, reason: 'pre-fix W6 behavior kept: close reports its own write failure');
      expect(a.persistedSampleCount, 0);
      expect(a.unpersistedSampleCount, 3);
      expect(identical(bClose, writeError), isTrue, reason: 'the primary error, not the cleanup one');
      expect(identical(b.failure, writeError), isTrue);
      expect(errors, [same(writeError)], reason: 'only b\'s automatic flush');
      expect(gate.closes, 2, reason: 'both handles released');
      expect(gate.openHandles, 0);
    });

    test('X149 (gated) a batch leaves the queue only after its write succeeded; a failed batch is never retried or '
        'written twice', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x149');
      const ioError = FileSystemException('write failed (injected)', 'x149.jsonl');
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await gate.untilHeld();
        expect(writer.persistedSampleCount, 0, reason: 'not counted before the file accepted it');
        expect(writer.unpersistedSampleCount, 25);
        for (var i = 26; i <= 30; i++) {
          writer.add(_sample(i));
        }
        expect(gate.deliveries, 1, reason: 'the in-flight batch does not count towards the next automatic flush');
        gate.hold = false;
        gate.releaseAll();
        await writer.flush();
        expect(writer.persistedSampleCount, 30);

        // Now a held write that fails while more samples arrive behind it.
        gate.hold = true;
        for (var i = 31; i <= 55; i++) {
          writer.add(_sample(i));
        }
        await gate.untilHeld();
        for (var i = 56; i <= 58; i++) {
          writer.add(_sample(i));
        }
        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        await _until(() => writer.failure != null, 'the held write failed');
        final deliveriesAtFailure = gate.deliveries;
        expect(identical(await _errorOf(writer.close()), ioError), isTrue);
        expect(gate.deliveries, deliveriesAtFailure, reason: 'close does not retry the failed batch');
      });
      expect(errors, [same(ioError)]);
      expect(writer.persistedSampleCount, 30);
      expect(writer.unpersistedSampleCount, 28, reason: '31..58: the failed batch and the samples queued behind it');
      expect(linesOnDisk('x149'), _range(1, 30));
      expect(gate.writtenSpeeds, _range(1, 30));
    });

    test('X150 (gated) stress with a random real-failure injection: the file is always exactly the persisted prefix of '
        'the accepted samples, nothing is accepted after the failure, and the loss is fully accounted', () async {
      var withFailure = 0;
      for (final seed in [3, 11, 42, 2024, 31337, 7, 99, 123]) {
        final random = Random(seed);
        final gate = TelemetryIoGate();
        final writer = DashcamTelemetryWriter(sessionId: 'x150-$seed');
        final ioError = FileSystemException('write failed (injected, seed $seed)', 'x150.jsonl');
        final failAt = 40 + random.nextInt(200);
        var next = 0;
        var acceptedAfterFailure = 0;
        final watched = <_Watched>[];
        final errors = await _uncaughtErrorsOf(gate: gate, () async {
          await writer.open();
          for (var step = 0; step < 300; step++) {
            if (step == failAt) gate.failNext(ioError);
            switch (random.nextInt(7)) {
              case 0 || 1 || 2:
                for (var k = random.nextInt(30); k > 0; k--) {
                  final failedBefore = writer.failure != null;
                  if (writer.add(_sample(++next)) && failedBefore) acceptedAfterFailure++;
                }
              case 3:
                watched.add(_Watched(writer.flush()));
              case 4:
                gate.hold = !gate.hold;
              case 5:
                gate.releaseNext();
              case _:
                await Future<void>.delayed(Duration(milliseconds: random.nextInt(3)));
            }
          }
          gate.hold = false;
          gate.releaseAll();
          final close = writer.close();
          watched.add(_Watched(close));
          try {
            await close;
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        final failure = writer.failure;
        if (failure != null) withFailure++;
        expect(acceptedAfterFailure, 0, reason: 'seed $seed');
        expect(errors.every((e) => identical(e, failure)), isTrue, reason: 'seed $seed: only the primary failure surfaces');
        expect(watched.every((w) => w.done && (w.error == null || identical(w.error, failure))), isTrue, reason: 'seed $seed');
        expect(writer.state, DashcamTelemetryWriterState.closed, reason: 'seed $seed');
        final written = gate.writtenSpeeds;
        expect(written, [for (var i = 1; i <= written.length; i++) i], reason: 'seed $seed: a contiguous prefix, no duplicate or reorder');
        expect(written.length, writer.persistedSampleCount, reason: 'seed $seed: persisted = what the file holds');
        expect(writer.acceptedSampleCount - writer.persistedSampleCount, writer.unpersistedSampleCount, reason: 'seed $seed');
        if (failure == null) expect(writer.unpersistedSampleCount, 0, reason: 'seed $seed: healthy path loses nothing');
        expect(gate.maxActiveDeliveries, 1, reason: 'seed $seed');
        expect(gate.closes, 1, reason: 'seed $seed');
        expect(gate.openHandles, 0, reason: 'seed $seed');
        expect(linesOnDisk('x150-$seed'), written, reason: 'seed $seed');
      }
      expect(withFailure, greaterThan(0), reason: 'the injected failure really hit a write in some seeds');
    });
  });
}
