// Platform fakes for mounting the real app in widget tests (the same idea as
// fake_camera_platform.dart). Imports only packages this app already depends
// on: geolocator and sensors_plus re-export their platform interfaces.
import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Counts the platform subscriptions a stream receives. `SensorService` opens
/// at most one platform subscription per sensor, so the number of concurrent
/// ones is the number of live sensor pipelines.
class ListenCounter {
  int listens = 0;
  int cancels = 0;
  int active = 0;
  int maxActive = 0;

  Stream<T> wrap<T>(Stream<T> source) => Stream<T>.multi((c) {
    listens++;
    active++;
    if (active > maxActive) maxActive = active;
    final sub = source.listen(c.add, onError: c.addError);
    c.onCancel = () {
      active--;
      cancels++;
      return sub.cancel();
    };
  }, isBroadcast: true);

  @override
  String toString() => 'listens=$listens cancels=$cancels active=$active maxActive=$maxActive';
}

/// A GPS that only emits when told to ([emit]); location is always enabled and
/// permitted. [accuracy] > 50 m makes the next fixes classify as
/// `GnssQuality.unavailable`.
class FakeGeolocatorPlatform extends GeolocatorPlatform {
  final _positions = StreamController<Position>.broadcast();
  final positions = ListenCounter();
  int emitted = 0;
  double accuracy = 4;
  int permissionRequests = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async => LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async {
    permissionRequests++;
    return LocationPermission.whileInUse;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) => positions.wrap(_positions.stream);

  void emit() {
    emitted++;
    _positions.add(
      Position(
        latitude: -23.55 + emitted * 1e-5,
        longitude: -46.63,
        timestamp: DateTime.now(),
        accuracy: accuracy,
        altitude: 760 + (emitted % 7).toDouble(),
        altitudeAccuracy: 3,
        heading: 90,
        headingAccuracy: 5,
        speed: 4.4,
        speedAccuracy: 0.5,
      ),
    );
  }
}

/// Motion sensors that never emit; only their subscriptions are observable.
class FakeSensorsPlatform extends SensorsPlatform {
  final accelerometer = ListenCounter();
  final userAccelerometer = ListenCounter();
  final gyroscope = ListenCounter();
  final magnetometer = ListenCounter();
  final barometer = ListenCounter();

  @override
  Stream<AccelerometerEvent> accelerometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      accelerometer.wrap(StreamController<AccelerometerEvent>.broadcast().stream);

  @override
  Stream<UserAccelerometerEvent> userAccelerometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      userAccelerometer.wrap(StreamController<UserAccelerometerEvent>.broadcast().stream);

  @override
  Stream<GyroscopeEvent> gyroscopeEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      gyroscope.wrap(StreamController<GyroscopeEvent>.broadcast().stream);

  @override
  Stream<MagnetometerEvent> magnetometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      magnetometer.wrap(StreamController<MagnetometerEvent>.broadcast().stream);

  @override
  Stream<BarometerEvent> barometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      barometer.wrap(StreamController<BarometerEvent>.broadcast().stream);

  int get activeSubscriptions =>
      accelerometer.active + userAccelerometer.active + gyroscope.active + magnetometer.active + barometer.active;

  int get totalListens =>
      accelerometer.listens + userAccelerometer.listens + gyroscope.listens + magnetometer.listens + barometer.listens;
}

/// Installed with `wakelockPlusPlatformInstance = FakeWakelockPlatform()`.
/// Extends the Windows plugin only because it is the one concrete
/// implementation `package:wakelock_plus` exports (the interface package is
/// not a dependency of this app); both methods are overridden, so no platform
/// call is ever made.
class FakeWakelockPlatform extends WakelockPlusWindowsPlugin {
  bool on = false;

  @override
  Future<void> toggle({required bool enable}) async => on = enable;

  @override
  Future<bool> get enabled async => on;
}
