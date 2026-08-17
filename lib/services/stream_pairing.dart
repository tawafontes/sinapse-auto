import 'dart:async';

/// Pairs every [source] emission with the latest value [latestFrom] has
/// produced so far (null until its first emission) — not a full
/// combineLatest (which would also re-emit on every [latestFrom] tick, and
/// [latestFrom] is typically the far-slower-ticking signal of the two
/// here). Used wherever a frequent signal needs to be read alongside the
/// most recent reading of a slower (or comparably-fast) companion signal,
/// without letting the companion drive the emission rate.
///
/// Current uses: `vehicle_coordinate_system.dart`'s `pairedWithMountOrientation`
/// (g-force axis correction, pairing user-acceleration samples with the
/// latest gravity-including reading) and `dashboard_sensor_streams.dart`'s
/// inclination fusion (pairing accelerometer samples with the latest
/// gyroscope reading).
///
/// Broadcast, deliberately: real call sites feed it streams that are
/// themselves broadcast ([SensorService.accelerometerStream]/
/// [SensorService.userAccelerometerStream]/[SensorService.gyroscopeStream]),
/// and the chains built on top of this (g-force's and inclination's own
/// memoized `late final` streams) legitimately need more than one
/// simultaneous listener — a dashboard tile's sensor widget and a
/// fullscreen view of the same signal both subscribe independently while
/// the tile stays mounted underneath the pushed route. A single-subscription
/// controller here previously threw "Bad state: Stream has already been
/// listened to." the moment a second listener (fullscreen) attached.
/// Broadcast is the correct fix, not a workaround:
/// [StreamController.broadcast]'s `onListen` only fires on the 0→1 listener
/// transition and `onCancel` only on 1→0, so [source]/[latestFrom] are
/// still subscribed exactly once no matter how many downstream consumers
/// are attached at once — no duplicate sensor reads, same teardown
/// guarantee as before.
Stream<(A, B?)> pairedWithLatest<A, B>(Stream<A> source, Stream<B> latestFrom) {
  late StreamController<(A, B?)> controller;
  StreamSubscription<B>? latestSub;
  StreamSubscription<A>? sourceSub;
  B? latest;

  controller = StreamController<(A, B?)>.broadcast(
    onListen: () {
      latestSub = latestFrom.listen((v) => latest = v);
      sourceSub = source.listen(
        (v) => controller.add((v, latest)),
        onError: controller.addError,
        onDone: controller.close,
      );
    },
    onCancel: () async {
      await latestSub?.cancel();
      await sourceSub?.cancel();
    },
  );
  return controller.stream;
}
