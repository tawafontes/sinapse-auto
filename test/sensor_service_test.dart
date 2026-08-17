import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/sensor_service.dart';

void main() {
  group('SensorService external providers', () {
    test('registered provider forwards source events to externalStream', () async {
      final service = SensorService();
      addTearDown(() => unawaited(service.dispose()));
      final source = StreamController<int>();
      addTearDown(() => unawaited(source.close()));

      service.registerExternalProvider<int>('test', source.stream);

      final results = <int>[];
      final sub = service.externalStream<int>('test').listen(results.add);
      addTearDown(sub.cancel);

      source.add(1);
      source.add(2);
      await Future<void>.delayed(Duration.zero);

      expect(results, [1, 2]);
    });

    test(
      'replacing the same key cancels the previous subscription — the old source stops '
      'delivering, the new one works',
      () async {
        final service = SensorService();
        addTearDown(() => unawaited(service.dispose()));
        final oldSource = StreamController<int>();
        final newSource = StreamController<int>();
        addTearDown(() {
          unawaited(oldSource.close());
          unawaited(newSource.close());
        });

        service.registerExternalProvider<int>('test', oldSource.stream);
        final oldResults = <int>[];
        final oldSub = service.externalStream<int>('test').listen(oldResults.add);
        addTearDown(oldSub.cancel);

        oldSource.add(1);
        await Future<void>.delayed(Duration.zero);
        expect(oldResults, [1]);

        service.registerExternalProvider<int>('test', newSource.stream);
        await Future<void>.delayed(Duration.zero);
        expect(oldSource.hasListener, isFalse);

        final newResults = <int>[];
        final newSub = service.externalStream<int>('test').listen(newResults.add);
        addTearDown(newSub.cancel);

        oldSource.add(999); // must never arrive anywhere — the old subscription was cancelled.
        newSource.add(2);
        await Future<void>.delayed(Duration.zero);

        expect(oldResults, [1]); // unchanged — the old controller stopped receiving on replacement.
        expect(newResults, [2]);
      },
    );

    test(
      'replacing a key sends done to listeners of the old externalStream, without affecting the new one',
      () async {
        final service = SensorService();
        addTearDown(() => unawaited(service.dispose()));
        final oldSource = StreamController<int>();
        final newSource = StreamController<int>();
        addTearDown(() {
          unawaited(oldSource.close());
          unawaited(newSource.close());
        });

        service.registerExternalProvider<int>('test', oldSource.stream);
        var oldIsDone = false;
        final oldSub = service.externalStream<int>('test').listen((_) {}, onDone: () => oldIsDone = true);
        addTearDown(oldSub.cancel);

        service.registerExternalProvider<int>('test', newSource.stream);
        await Future<void>.delayed(Duration.zero);

        expect(oldIsDone, isTrue);

        final newResults = <int>[];
        var newIsDone = false;
        final newSub = service.externalStream<int>('test').listen(newResults.add, onDone: () => newIsDone = true);
        addTearDown(newSub.cancel);

        newSource.add(1);
        await Future<void>.delayed(Duration.zero);

        expect(newResults, [1]);
        expect(newIsDone, isFalse); // the old controller's close() must not reach the new stream.
      },
    );

    test('dispose cancels every external provider subscription across multiple keys', () async {
      final service = SensorService();
      final firstSource = StreamController<int>();
      final secondSource = StreamController<String>();
      addTearDown(() {
        unawaited(firstSource.close());
        unawaited(secondSource.close());
      });

      service.registerExternalProvider<int>('first', firstSource.stream);
      service.registerExternalProvider<String>('second', secondSource.stream);
      expect(firstSource.hasListener, isTrue);
      expect(secondSource.hasListener, isTrue);

      var firstIsDone = false;
      var secondIsDone = false;
      final firstSub = service.externalStream<int>('first').listen((_) {}, onDone: () => firstIsDone = true);
      final secondSub = service.externalStream<String>('second').listen((_) {}, onDone: () => secondIsDone = true);
      addTearDown(() async {
        await firstSub.cancel();
        await secondSub.cancel();
      });

      await service.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(firstSource.hasListener, isFalse);
      expect(secondSource.hasListener, isFalse);
      expect(firstIsDone, isTrue);
      expect(secondIsDone, isTrue);
    });

    test('when the external source completes, externalStream also completes', () async {
      final service = SensorService();
      addTearDown(() => unawaited(service.dispose()));
      final source = StreamController<int>();
      addTearDown(() => unawaited(source.close()));

      service.registerExternalProvider<int>('test', source.stream);

      final results = <int>[];
      var isDone = false;
      final sub = service.externalStream<int>('test').listen(results.add, onDone: () => isDone = true);
      addTearDown(sub.cancel);

      source.add(1);
      await source.close(); // the source ends on its own — e.g. a disconnecting Bluetooth adapter.
      await Future<void>.delayed(Duration.zero);

      expect(results, [1]);
      expect(isDone, isTrue);
    });

    test(
      'replacing a key and immediately emitting on the old source does not throw or leak '
      'into the new stream',
      () async {
        final service = SensorService();
        addTearDown(() => unawaited(service.dispose()));
        final oldSource = StreamController<int>();
        final newSource = StreamController<int>();
        addTearDown(() {
          unawaited(oldSource.close());
          unawaited(newSource.close());
        });

        service.registerExternalProvider<int>('test', oldSource.stream);
        service.registerExternalProvider<int>('test', newSource.stream);
        // Emitted in the same synchronous turn as the replacement above — the
        // scenario a "close the old controller before cancelling its
        // subscription" ordering would get wrong (StateError: Cannot add
        // event after closing).
        oldSource.add(999);

        final results = <int>[];
        final sub = service.externalStream<int>('test').listen(results.add);
        addTearDown(sub.cancel);

        newSource.add(1);
        await Future<void>.delayed(Duration.zero);

        expect(results, [1]);
      },
    );

    test('multiple listeners on the same externalStream all receive broadcast events', () async {
      final service = SensorService();
      addTearDown(() => unawaited(service.dispose()));
      final source = StreamController<int>();
      addTearDown(() => unawaited(source.close()));

      service.registerExternalProvider<int>('test', source.stream);

      final firstResults = <int>[];
      final secondResults = <int>[];
      final firstSub = service.externalStream<int>('test').listen(firstResults.add);
      final secondSub = service.externalStream<int>('test').listen(secondResults.add);
      addTearDown(() async {
        await firstSub.cancel();
        await secondSub.cancel();
      });

      source.add(1);
      await Future<void>.delayed(Duration.zero);

      expect(firstResults, [1]);
      expect(secondResults, [1]);
    });

    test('errors from the source propagate to externalStream listeners', () async {
      final service = SensorService();
      addTearDown(() => unawaited(service.dispose()));
      final source = StreamController<int>();
      addTearDown(() => unawaited(source.close()));

      service.registerExternalProvider<int>('test', source.stream);

      final errors = <Object>[];
      final sub = service.externalStream<int>('test').listen((_) {}, onError: errors.add);
      addTearDown(sub.cancel);

      source.addError(StateError('boom'));
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    });
  });
}
