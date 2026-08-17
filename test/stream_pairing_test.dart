import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/stream_pairing.dart';

void main() {
  group('pairedWithLatest', () {
    test('pairs each source emission with the latest value from latestFrom, null before its first', () async {
      final source = StreamController<String>();
      final latestFrom = StreamController<int>();
      addTearDown(() {
        unawaited(source.close());
        unawaited(latestFrom.close());
      });

      final results = <(String, int?)>[];
      final sub = pairedWithLatest(source.stream, latestFrom.stream).listen(results.add);
      addTearDown(sub.cancel);

      source.add('a');
      await Future<void>.delayed(Duration.zero);
      expect(results, [('a', null)]);

      latestFrom.add(1);
      await Future<void>.delayed(Duration.zero);
      source.add('b');
      await Future<void>.delayed(Duration.zero);
      expect(results, [('a', null), ('b', 1)]);

      // latestFrom ticking again doesn't emit anything on its own — only
      // the next source emission picks up the new value.
      latestFrom.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(results, hasLength(2));
      source.add('c');
      await Future<void>.delayed(Duration.zero);
      expect(results, [('a', null), ('b', 1), ('c', 2)]);
    });

    test('supports two simultaneous listeners without throwing — the dashboard-tile + '
        'fullscreen-view regression this stream must survive', () async {
      final source = StreamController<String>();
      final latestFrom = StreamController<int>();
      addTearDown(() {
        unawaited(source.close());
        unawaited(latestFrom.close());
      });

      final paired = pairedWithLatest(source.stream, latestFrom.stream);

      final firstListenerResults = <(String, int?)>[];
      final firstSub = paired.listen(firstListenerResults.add);
      addTearDown(firstSub.cancel);

      final secondListenerResults = <(String, int?)>[];
      final secondSub = paired.listen(secondListenerResults.add);
      addTearDown(secondSub.cancel);

      latestFrom.add(1);
      await Future<void>.delayed(Duration.zero);
      source.add('a');
      await Future<void>.delayed(Duration.zero);

      expect(firstListenerResults, [('a', 1)]);
      expect(secondListenerResults, [('a', 1)]);
    });
  });
}
