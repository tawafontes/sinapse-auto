// Fase 16.2-R4.3-R2.6.9 — X131–X139: DashcamTelemetryWriter flush/close
// serialization. "real" tests run the writer over dart:io's own file consumer
// (no fake at all): the IOSink stays bound for at least one real I/O round
// trip, which cannot complete inside the synchronous slice where the second
// operation starts, so the pre-fix race is reached deterministically. "gated"
// tests hold or fail a delivery explicitly (test/support/telemetry_io_gate.dart:
// the real IOSink over a controllable file consumer). Every test checks the
// data that reached the file — count, order, no duplicate — not only the
// absence of an exception.
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
      // Let a straggling automatic flush or timer report its error here.
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
  _Watched(this.future) {
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
  final Future<void> future;
  bool done = false;
  Object? error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dashcam_telemetry_writer_concurrency_test');
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

  Future<List<int?>> speedsOnDisk(String sessionId) async => [for (final s in await loadDashcamTelemetry(sessionId)) s.speedKmh?.toInt()];

  /// On Windows an open handle makes the deletion fail (errno 32): this is the
  /// real-I/O proof that close() released the file.
  Future<void> expectFileReleased(String sessionId) async {
    final file = await DashcamTelemetryWriter.fileForSession(sessionId);
    expect(() => file.deleteSync(), returnsNormally, reason: 'the telemetry file handle must be closed');
  }

  group('Fase 16.2-R4.3-R2.6.9 — telemetry writer flush/close serialization', () {
    test('X131 (real) a second automatic flush while the first is still bound writes every sample once, in order', () async {
      final writer = DashcamTelemetryWriter(sessionId: 'x131-real');
      final errors = await _uncaughtErrorsOf(() async {
        await writer.open();
        for (var i = 1; i <= 50; i++) {
          expect(writer.add(_sample(i)), isTrue);
        }
        // Samples 1-25 triggered flush #1 (bound on the real IOSink); 26-50
        // triggered flush #2 in the same slice.
        await writer.close();
      });
      expect(errors, isEmpty, reason: 'pre-fix: StateError "StreamSink is bound to a stream" from flush #2');
      expect(await speedsOnDisk('x131-real'), _range(1, 50), reason: 'pre-fix: 26..50 lost');
      await expectFileReleased('x131-real');
    });

    test('X131 (gated) flush requests while a flush is held join one queued flush; nothing is written twice or lost', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x131-gated');
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await gate.untilHeld();
        for (var i = 26; i <= 30; i++) {
          writer.add(_sample(i));
        }
        final f1 = _Watched(writer.flush());
        final f2 = _Watched(writer.flush());
        expect(identical(f1.future, f2.future), isTrue, reason: 'a flush queued behind the held one is shared, not duplicated');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(f1.done, isFalse, reason: 'the queued flush runs only after the held one');
        expect(gate.deliveries, 1, reason: 'no second consumer while the first delivery is bound');
        gate.hold = false;
        gate.releaseAll();
        await f1.future;
        expect(gate.deliveries, 2);
        expect(gate.maxActiveDeliveries, 1);
        expect(gate.writtenSpeeds, _range(1, 30));
        await writer.close();
      });
      expect(errors, isEmpty);
      expect(gate.writtenSpeeds, _range(1, 30));
      expect(gate.closes, 1);
      expect(gate.openHandles, 0);
    });

    test('X132 (real) close() while the automatic flush is still bound waits for it and closes the file', () async {
      final writer = DashcamTelemetryWriter(sessionId: 'x132-real');
      Object? closeError;
      final errors = await _uncaughtErrorsOf(() async {
        await writer.open();
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        try {
          await writer.close();
        } catch (e) {
          closeError = e;
        }
      });
      expect(closeError, isNull, reason: 'pre-fix: StateError "StreamSink is bound to a stream"');
      expect(errors, isEmpty);
      expect(await speedsOnDisk('x132-real'), _range(1, 25));
      await expectFileReleased('x132-real');
    });

    test('X132 (gated) close() during a held flush completes only after it, then writes the rest and releases the handle once', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x132-gated');
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await gate.untilHeld();
        for (var i = 26; i <= 28; i++) {
          writer.add(_sample(i));
        }
        final close = _Watched(writer.close());
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(close.done, isFalse, reason: 'close waits for the flush accepted before it');
        expect(gate.closes, 0, reason: 'the file is not closed under a bound flush');
        expect(gate.deliveries, 1);
        gate.hold = false;
        gate.releaseAll();
        await close.future;
        expect(close.error, isNull);
      });
      expect(errors, isEmpty);
      expect(gate.writtenSpeeds, _range(1, 28), reason: 'pre-fix: 26..28 lost');
      expect(gate.deliveries, 2, reason: 'the held flush, then close\'s final batch');
      expect(gate.maxActiveDeliveries, 1);
      expect(gate.closes, 1);
      expect(gate.openHandles, 0, reason: 'pre-fix: handle left open');
      expect(await speedsOnDisk('x132-gated'), _range(1, 28));
    });

    test('X133 (real) two close() calls in the same slice are one close: same Future, no error, data once', () async {
      final writer = DashcamTelemetryWriter(sessionId: 'x133-real');
      late Future<void> c1;
      late Future<void> c2;
      final errors = await _uncaughtErrorsOf(() async {
        await writer.open();
        for (var i = 1; i <= 3; i++) {
          writer.add(_sample(i));
        }
        c1 = writer.close();
        c2 = writer.close();
        await Future.wait([c1, c2]);
      });
      expect(identical(c1, c2), isTrue);
      expect(errors, isEmpty, reason: 'pre-fix: the second close throws "StreamSink is bound to a stream"');
      expect(await speedsOnDisk('x133-real'), _range(1, 3));
      await expectFileReleased('x133-real');
    });

    test('X133 (gated) close during a held close, and after it, creates no work: one delivery, one handle release', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x133-gated');
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 3; i++) {
          writer.add(_sample(i));
        }
        final c1 = writer.close();
        await gate.untilHeld();
        final c2 = writer.close();
        expect(identical(c1, c2), isTrue);
        gate.hold = false;
        gate.releaseAll();
        await c1;
        final c3 = writer.close();
        final f = writer.flush();
        expect(identical(c3, c1), isTrue);
        expect(identical(f, c1), isTrue, reason: 'flush after close queues nothing');
        await c3;
      });
      expect(errors, isEmpty);
      expect(gate.deliveries, 1);
      expect(gate.closes, 1);
      expect(gate.openHandles, 0);
      expect(gate.writtenSpeeds, _range(1, 3));
    });

    test('X134 add() while closing is refused (returns false, nothing buffered) and flush() queues nothing; accepted data is complete', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x134');
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await gate.untilHeld();
        writer.add(_sample(26));
        writer.add(_sample(27));
        final close = writer.close();
        expect(writer.isClosed, isTrue);
        for (var i = 28; i <= 60; i++) {
          expect(writer.add(_sample(i)), isFalse, reason: 'sample $i arrived after close()');
        }
        expect(identical(writer.flush(), close), isTrue);
        expect(writer.acceptedSampleCountForTest, 27);
        gate.hold = false;
        gate.releaseAll();
        await close;
      });
      expect(errors, isEmpty);
      expect(gate.writtenSpeeds, _range(1, 27), reason: 'exactly the accepted samples, once each');
      expect(gate.deliveries, 2);
      expect(gate.closes, 1);
    });

    test('X135 a late callback (timer) after close neither writes, nor reopens the writer, nor throws', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x135-after');
      final lateResults = <bool>[];
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        for (var i = 1; i <= 3; i++) {
          writer.add(_sample(i));
        }
        final close = writer.close();
        await close;
        final fired = Completer<void>();
        Timer(const Duration(milliseconds: 10), () {
          for (var i = 4; i <= 33; i++) {
            lateResults.add(writer.add(_sample(i)));
          }
          expect(identical(writer.flush(), close), isTrue);
          unawaited(writer.open());
          fired.complete();
        });
        await fired.future;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      expect(errors, isEmpty);
      expect(lateResults, everyElement(isFalse));
      expect(gate.opens, 1, reason: 'pre-fix: the late open() reopened the file (2 opens, 1 handle leaked)');
      expect(gate.openHandles, 0);
      expect(gate.writtenSpeeds, _range(1, 3), reason: 'pre-fix: 30 late samples kept in memory and silently dropped');
    });

    test('X135 a late callback while close waits on a held flush is refused; the held and pending data are written once', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x135-during');
      final lateResults = <bool>[];
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await gate.untilHeld();
        writer.add(_sample(26));
        writer.add(_sample(27));
        final close = writer.close();
        final fired = Completer<void>();
        Timer(const Duration(milliseconds: 10), () {
          for (var i = 28; i <= 52; i++) {
            lateResults.add(writer.add(_sample(i)));
          }
          fired.complete();
        });
        await fired.future;
        gate.hold = false;
        gate.releaseAll();
        await close;
      });
      expect(errors, isEmpty, reason: 'pre-fix: the 25 late samples triggered a flush on the bound sink (StateError)');
      expect(lateResults, everyElement(isFalse));
      expect(gate.writtenSpeeds, _range(1, 27));
      expect(gate.closes, 1);
      expect(gate.openHandles, 0);
    });

    test('X136 (real) an I/O failure during close is reported by close, and by the second close as the same Future', () async {
      // No fake: the telemetry path is a directory, so dart:io cannot open it.
      Directory('${dir.path}/dashcam_telemetry/x136.jsonl').createSync(recursive: true);
      final writer = DashcamTelemetryWriter(sessionId: 'x136');
      late Future<void> c1;
      late Future<void> c2;
      Object? e1;
      Object? e2;
      final errors = await _uncaughtErrorsOf(() async {
        await writer.open();
        for (var i = 1; i <= 3; i++) {
          writer.add(_sample(i));
        }
        c1 = writer.close();
        c2 = writer.close();
        try {
          await c1;
        } catch (e) {
          e1 = e;
        }
        try {
          await c2;
        } catch (e) {
          e2 = e;
        }
        expect(identical(writer.flush(), c1), isTrue);
      });
      expect(identical(c1, c2), isTrue);
      expect(e1, isA<FileSystemException>(), reason: 'a real I/O failure is not converted into success');
      expect(identical(e2, e1), isTrue, reason: 'pre-fix: the second close failed with StateError "StreamSink is bound to a stream"');
      expect(errors, isEmpty, reason: 'no secondary error of the failed file');
    });

    test('X137 (gated) the held flush fails while close waits: the flush and close report that I/O error; the handle is released', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x137');
      const ioError = FileSystemException('disk full (injected)', 'x137.jsonl');
      Object? flushError;
      Object? closeError;
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.hold = true;
        for (var i = 1; i <= 10; i++) {
          writer.add(_sample(i));
        }
        final flush = writer.flush();
        await gate.untilHeld();
        for (var i = 11; i <= 13; i++) {
          writer.add(_sample(i));
        }
        final close = writer.close();
        gate.failNext(ioError);
        gate.hold = false;
        gate.releaseAll();
        try {
          await flush;
        } catch (e) {
          flushError = e;
        }
        try {
          await close;
        } catch (e) {
          closeError = e;
        }
      });
      expect(errors, isEmpty);
      expect(identical(flushError, ioError), isTrue);
      expect(identical(closeError, ioError), isTrue, reason: 'close reports the writer\'s first I/O failure, not success and not a StateError');
      expect(gate.closes, 1, reason: 'the file is closed even after a failed write');
      expect(gate.openHandles, 0);
      expect(gate.writtenLines, isEmpty, reason: 'nothing is claimed written after the failure');
    });

    test('X138 (gated) an automatic flush\'s I/O failure stays observable (one uncaught error) and close reports it', () async {
      final gate = TelemetryIoGate();
      final writer = DashcamTelemetryWriter(sessionId: 'x138');
      const ioError = FileSystemException('write failed (injected)', 'x138.jsonl');
      Object? closeError;
      final errors = await _uncaughtErrorsOf(gate: gate, () async {
        await writer.open();
        gate.failNext(ioError);
        for (var i = 1; i <= 25; i++) {
          writer.add(_sample(i));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        try {
          await writer.close();
        } catch (e) {
          closeError = e;
        }
      });
      expect(errors, [same(ioError)], reason: 'the unawaited automatic flush fails loudly, exactly once');
      expect(identical(closeError, ioError), isTrue, reason: 'close does not report success for a file that lost data');
      expect(gate.closes, 1);
      expect(gate.openHandles, 0);
    });

    test('X139 (gated) stress: random interleavings of add/flush/close/hold/release/late callbacks keep the file exact', () async {
      for (final seed in [1, 7, 42, 2024, 31337]) {
        final random = Random(seed);
        final gate = TelemetryIoGate();
        final writer = DashcamTelemetryWriter(sessionId: 'x139-$seed');
        var next = 0;
        var accepted = 0;
        var refusedBeforeClose = 0;
        var acceptedAfterClose = 0;
        var refusedAfterClose = 0;
        var flushesWhileHeld = 0;
        var maxHeld = 0;
        final watched = <_Watched>[];
        Future<void>? close;
        final errors = await _uncaughtErrorsOf(gate: gate, () async {
          await writer.open();
          for (var step = 0; step < 300; step++) {
            if (gate.heldCount > maxHeld) maxHeld = gate.heldCount;
            switch (random.nextInt(8)) {
              case 0 || 1 || 2:
                for (var k = random.nextInt(30); k > 0; k--) {
                  final ok = writer.add(_sample(++next));
                  if (ok) accepted++;
                  if (close == null && !ok) refusedBeforeClose++;
                  if (close != null && ok) acceptedAfterClose++;
                  if (close != null && !ok) refusedAfterClose++;
                }
              case 3:
                if (gate.heldCount > 0) flushesWhileHeld++;
                watched.add(_Watched(writer.flush()));
              case 4:
                gate.hold = !gate.hold;
              case 5:
                gate.releaseNext();
              case 6:
                if (close == null && step > 150) {
                  close = writer.close();
                  watched.add(_Watched(close!));
                } else {
                  // A late timer callback, possibly after close.
                  Timer(Duration(milliseconds: random.nextInt(3)), () {
                    final ok = writer.add(_sample(++next));
                    if (ok) accepted++;
                    if (close != null && ok) acceptedAfterClose++;
                    if (close != null && !ok) refusedAfterClose++;
                  });
                }
              case _:
                await Future<void>.delayed(Duration(milliseconds: random.nextInt(3)));
            }
          }
          close ??= writer.close();
          watched.add(_Watched(close!));
          gate.hold = false;
          gate.releaseAll();
          await close;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        expect(errors, isEmpty, reason: 'seed $seed');
        // The run really exercised the races (not a vacuous pass).
        expect(maxHeld, greaterThan(0), reason: 'seed $seed: some delivery was held');
        expect(flushesWhileHeld, greaterThan(0), reason: 'seed $seed: flushes were requested under a held delivery');
        expect(refusedAfterClose, greaterThan(0), reason: 'seed $seed: late samples arrived after close');
        expect(gate.deliveries, greaterThan(3), reason: 'seed $seed');
        expect(refusedBeforeClose, 0, reason: 'seed $seed');
        expect(acceptedAfterClose, 0, reason: 'seed $seed');
        expect(watched.every((w) => w.done && w.error == null), isTrue, reason: 'seed $seed: every flush/close completes without error');
        expect(writer.acceptedSampleCountForTest, accepted, reason: 'seed $seed');
        final written = gate.writtenSpeeds;
        expect(written.length, accepted, reason: 'seed $seed: every accepted sample written, none twice');
        expect(written.toSet().length, written.length, reason: 'seed $seed: no duplicate');
        final sorted = List.of(written)..sort((a, b) => a!.compareTo(b!));
        expect(written, sorted, reason: 'seed $seed: order preserved');
        expect(gate.maxActiveDeliveries, 1, reason: 'seed $seed');
        expect(gate.closes, 1, reason: 'seed $seed');
        expect(gate.openHandles, 0, reason: 'seed $seed');
        expect(await speedsOnDisk('x139-$seed'), written, reason: 'seed $seed: the app\'s reader sees the same');
      }
    });
  });
}
