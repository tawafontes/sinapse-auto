import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/sensor_reading.dart';

/// The platform's own default GPS interval (Android: 5000ms, applied as both
/// the requested interval AND a hard minimum-update floor — verified from
/// `geolocator_android`'s native `LocationOptions`/`FusedLocationClient`) is
/// slower than this app needs for a live dashboard. `AndroidSettings` is the
/// only [LocationSettings] subtype that exposes an interval, so this is
/// Android-specific; other platforms keep their own plugin defaults via the
/// plain [LocationSettings] fallback below.
const Duration _androidPositionInterval = Duration(seconds: 1);

/// Contract for a single live telemetry source that can be plugged into
/// [SensorService].
///
/// The built-in signals (speed, accelerometer, ...) are wired directly
/// inside this service today, but any *future* data source — an OBD-II
/// adapter talking over Bluetooth, a microphone-based noise-level meter,
/// etc. — should be able to implement this same shape and be added via
/// [SensorService.registerExternalProvider] without modifying this file's
/// existing public API.
abstract class SensorProvider<T> {
  Stream<T> get stream;
  Future<void> dispose();
}

/// The resources [SensorService] owns for one
/// [SensorService.registerExternalProvider] registration — the broadcast
/// [controller] every [SensorService.externalStream] call reads from, paired
/// with the upstream [subscription] feeding it, so a key replacement or
/// [SensorService.dispose] can tear down the exact previous source instead
/// of leaking its subscription.
typedef _ExternalProviderBinding = ({
  StreamController<Object?> controller,
  StreamSubscription<Object?> subscription,
});

/// Unifies every sensor/telemetry source the app reads from behind one
/// service with a single broadcast stream per signal.
///
/// Each stream is lazily started the first time it gets a listener and
/// torn down when the last listener cancels, so screens can simply listen
/// to the getters they care about.
///
/// ### Extensibility
/// New hardware/data sources are expected over time (an OBD-II Bluetooth
/// adapter for engine telemetry, a microphone-based ambient noise level,
/// etc). Rather than growing this class' constructor or breaking existing
/// callers when that happens, two extension points are provided:
///  * [registerExternalProvider] / [externalStream] let a new source be
///    plugged in at runtime under a string key and consumed with the same
///    unified service instance.
///  * Alternatively a new strongly-typed getter can be added following the
///    same lazy-broadcast pattern as [accelerometerStream] etc. — existing
///    getters are untouched either way.
class SensorService {
  SensorService({LocationSettings? locationSettings})
    : _locationSettings = locationSettings ?? _defaultLocationSettings();

  static LocationSettings _defaultLocationSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: _androidPositionInterval,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
  }

  final LocationSettings _locationSettings;

  StreamController<SpeedReading>? _speedController;
  StreamController<AltitudeReading>? _altitudeController;
  StreamController<Position>? _positionController;
  StreamController<VectorReading>? _accelerometerController;
  StreamController<VectorReading>? _userAccelerometerController;
  StreamController<VectorReading>? _gyroscopeController;
  StreamController<VectorReading>? _magnetometerController;
  StreamController<BarometerReading>? _barometerController;

  StreamSubscription<Position>? _positionSub;
  int _positionListenerRefCount = 0;
  StreamSubscription<AccelerometerEvent>? _accelerometerSub;
  StreamSubscription<UserAccelerometerEvent>? _userAccelerometerSub;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSub;
  StreamSubscription<MagnetometerEvent>? _magnetometerSub;
  StreamSubscription<BarometerEvent>? _barometerSub;

  final Map<String, _ExternalProviderBinding> _externalProviders = {};

  /// Vehicle speed, sourced from the platform location provider.
  Stream<SpeedReading> get speedStream {
    return (_speedController ??= StreamController<SpeedReading>.broadcast(
      onListen: _startPositionRef,
      onCancel: _stopPositionRef,
    )).stream;
  }

  /// Altitude, sourced from the same location provider as [speedStream] —
  /// both share a single underlying GPS subscription (see
  /// [_startPositionRef]/[_stopPositionRef]) rather than opening two.
  Stream<AltitudeReading> get altitudeStream {
    return (_altitudeController ??= StreamController<AltitudeReading>.broadcast(
      onListen: _startPositionRef,
      onCancel: _stopPositionRef,
    )).stream;
  }

  /// The raw platform [Position] behind [speedStream]/[altitudeStream],
  /// unmapped — for consumers (the telemetry engine) that need fields the
  /// mapped readings don't carry, e.g. `accuracy`/`altitudeAccuracy`/
  /// `headingAccuracy`. Shares the exact same ref-counted GPS subscription
  /// as the other two — still only ever one underlying GPS connection.
  Stream<Position> get positionStream {
    return (_positionController ??= StreamController<Position>.broadcast(
      onListen: _startPositionRef,
      onCancel: _stopPositionRef,
    )).stream;
  }

  /// Raw accelerometer (includes gravity).
  Stream<VectorReading> get accelerometerStream {
    return (_accelerometerController ??=
            StreamController<VectorReading>.broadcast(
              onListen: _startAccelerometer,
              onCancel: _stopAccelerometer,
            ))
        .stream;
  }

  /// Linear acceleration with gravity removed — the better signal for
  /// detecting harsh braking/impact (G-force) events, e.g. to decide when
  /// to call `DashcamService.markClipAsProtected()`.
  Stream<VectorReading> get userAccelerometerStream {
    return (_userAccelerometerController ??=
            StreamController<VectorReading>.broadcast(
              onListen: _startUserAccelerometer,
              onCancel: _stopUserAccelerometer,
            ))
        .stream;
  }

  Stream<VectorReading> get gyroscopeStream {
    return (_gyroscopeController ??=
            StreamController<VectorReading>.broadcast(
              onListen: _startGyroscope,
              onCancel: _stopGyroscope,
            ))
        .stream;
  }

  Stream<VectorReading> get magnetometerStream {
    return (_magnetometerController ??=
            StreamController<VectorReading>.broadcast(
              onListen: _startMagnetometer,
              onCancel: _stopMagnetometer,
            ))
        .stream;
  }

  /// Barometric pressure, when the device has a barometer — the stream
  /// simply never emits on a device without one, which is what lets
  /// altitude sensor fusion fall back to GPS-only automatically with no
  /// explicit "has barometer" flag needed anywhere else.
  Stream<BarometerReading> get barometerStream {
    return (_barometerController ??=
            StreamController<BarometerReading>.broadcast(
              onListen: _startBarometer,
              onCancel: _stopBarometer,
            ))
        .stream;
  }

  /// Registers an additional/future telemetry source under [key] (e.g.
  /// `"obd2"` for a Bluetooth OBD-II adapter, `"microphoneNoise"` for an
  /// ambient noise meter) so it can be consumed through this same service
  /// instance via [externalStream], without changing this class' existing
  /// public API.
  ///
  /// Registering under a [key] already in use replaces it: cancelling the
  /// previous binding's subscription and closing its controller are both
  /// *requested* — `unawaited`, this class' usual fire-and-forget
  /// cancellation convention (see e.g. [_stopAccelerometer]) — before the new
  /// [source] is connected; this method itself never awaits anything, so it
  /// stays synchronous, and neither `Future` is guaranteed to have completed
  /// by the time the new [source] is connected. That's still enough to keep
  /// a straggling in-flight event from the old [source] from ever hitting
  /// `controller.add` after `close()` (which would throw `StateError`):
  /// per the `Stream` contract, [StreamSubscription.cancel] stops further
  /// delivery to that subscription's callbacks as soon as it's *called*,
  /// regardless of when the `Future` it returns completes. [dispose] tears
  /// down every remaining registration the same way.
  void registerExternalProvider<T extends Object>(String key, Stream<T> source) {
    final previous = _externalProviders.remove(key);
    if (previous != null) {
      unawaited(previous.subscription.cancel());
      unawaited(previous.controller.close());
    }
    final controller = StreamController<T>.broadcast();
    final subscription = source.listen(
      controller.add,
      onError: controller.addError,
      // Lets `externalStream(key)` terminate correctly if the source itself
      // ends, rather than leaving that controller silently open forever.
      onDone: controller.close,
    );
    _externalProviders[key] = (controller: controller, subscription: subscription);
  }

  /// Retrieves the stream registered under [key] via
  /// [registerExternalProvider]. Throws a [StateError] if nothing was
  /// registered under that key yet.
  Stream<T> externalStream<T extends Object>(String key) {
    final binding = _externalProviders[key];
    if (binding == null) {
      throw StateError('No external sensor provider registered under "$key"');
    }
    return binding.controller.stream.cast<T>();
  }

  /// [speedStream], [altitudeStream] and [positionStream] all call this on
  /// listen; only the first concurrent listener actually opens the GPS
  /// subscription, and it's only torn down once every listener across all
  /// three streams has cancelled.
  Future<void> _startPositionRef() async {
    _positionListenerRefCount++;
    if (_positionListenerRefCount > 1) return;

    final hasPermission = await _ensureLocationPermission();
    if (!hasPermission) {
      final error = StateError('Location permission was not granted');
      _speedController?.addError(error);
      _altitudeController?.addError(error);
      _positionController?.addError(error);
      return;
    }
    _positionSub =
        Geolocator.getPositionStream(locationSettings: _locationSettings).listen(
          (position) {
            _speedController?.add(
              SpeedReading(
                metersPerSecond: position.speed,
                accuracy: position.speedAccuracy,
                timestamp: position.timestamp,
              ),
            );
            _altitudeController?.add(
              AltitudeReading(meters: position.altitude, timestamp: position.timestamp),
            );
            _positionController?.add(position);
          },
          onError: (Object e, StackTrace st) {
            _speedController?.addError(e, st);
            _altitudeController?.addError(e, st);
            _positionController?.addError(e, st);
          },
        );
  }

  void _stopPositionRef() {
    _positionListenerRefCount--;
    if (_positionListenerRefCount > 0) return;
    _positionListenerRefCount = 0;
    unawaited(_positionSub?.cancel());
    _positionSub = null;
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Both accelerometer streams below explicitly request
  /// [SensorInterval.gameInterval] (20ms/50Hz) rather than accepting
  /// `sensors_plus`'s own default ([SensorInterval.normalInterval], 200ms/
  /// 5Hz) — 5Hz is far too coarse for the g-force meter to look like a
  /// "professional telemetry instrument": every reading sits on screen for
  /// up to 200ms, which reads as stutter rather than motion. 50Hz is the
  /// standard "smooth, motion-reactive UI" rate (matches what most
  /// game/AR-style Android apps request) — comfortably above what the human
  /// eye perceives as continuous, without the extra battery/CPU cost of an
  /// unbounded [SensorInterval.fastestInterval]. This also benefits the
  /// artificial horizon ([DashboardSensorStreams.inclinationPitchRollDegrees]),
  /// which shares this same accelerometer stream and already time-normalizes
  /// its own filtering (see [OneEuroFilter]), so a faster feed only improves
  /// its tracking, never destabilizes it.
  void _startAccelerometer() {
    _accelerometerSub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (event) => _accelerometerController?.add(
        VectorReading(
          x: event.x,
          y: event.y,
          z: event.z,
          timestamp: event.timestamp,
        ),
      ),
      onError: (Object e, StackTrace st) =>
          _accelerometerController?.addError(e, st),
    );
  }

  void _stopAccelerometer() {
    unawaited(_accelerometerSub?.cancel());
    _accelerometerSub = null;
  }

  /// See [_startAccelerometer]'s doc comment for why [SensorInterval.gameInterval]
  /// is used here too.
  void _startUserAccelerometer() {
    _userAccelerometerSub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (event) => _userAccelerometerController?.add(
        VectorReading(
          x: event.x,
          y: event.y,
          z: event.z,
          timestamp: event.timestamp,
        ),
      ),
      onError: (Object e, StackTrace st) =>
          _userAccelerometerController?.addError(e, st),
    );
  }

  void _stopUserAccelerometer() {
    unawaited(_userAccelerometerSub?.cancel());
    _userAccelerometerSub = null;
  }

  /// [SensorInterval.gameInterval] (50Hz), matching [_startAccelerometer]/
  /// [_startUserAccelerometer] — the artificial horizon's complementary
  /// filter integrates this rate over time to bridge gaps between
  /// accelerometer samples, so it needs a comparably fast, low-latency feed;
  /// the default 5Hz would introduce visible integration lag and a poor
  /// match against the 50Hz accelerometer it's paired with.
  void _startGyroscope() {
    _gyroscopeSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (event) => _gyroscopeController?.add(
        VectorReading(
          x: event.x,
          y: event.y,
          z: event.z,
          timestamp: event.timestamp,
        ),
      ),
      onError: (Object e, StackTrace st) =>
          _gyroscopeController?.addError(e, st),
    );
  }

  void _stopGyroscope() {
    unawaited(_gyroscopeSub?.cancel());
    _gyroscopeSub = null;
  }

  void _startMagnetometer() {
    _magnetometerSub = magnetometerEventStream().listen(
      (event) => _magnetometerController?.add(
        VectorReading(
          x: event.x,
          y: event.y,
          z: event.z,
          timestamp: event.timestamp,
        ),
      ),
      onError: (Object e, StackTrace st) =>
          _magnetometerController?.addError(e, st),
    );
  }

  void _stopMagnetometer() {
    unawaited(_magnetometerSub?.cancel());
    _magnetometerSub = null;
  }

  void _startBarometer() {
    _barometerSub = barometerEventStream().listen(
      (event) => _barometerController?.add(
        BarometerReading(pressureHpa: event.pressure, timestamp: event.timestamp),
      ),
      onError: (Object e, StackTrace st) => _barometerController?.addError(e, st),
    );
  }

  void _stopBarometer() {
    unawaited(_barometerSub?.cancel());
    _barometerSub = null;
  }

  /// Cancels every active subscription and closes every stream. Call when
  /// the service is no longer needed (e.g. app shutdown / DI container
  /// disposal).
  Future<void> dispose() async {
    unawaited(_positionSub?.cancel());
    _positionSub = null;
    _positionListenerRefCount = 0;
    _stopAccelerometer();
    _stopUserAccelerometer();
    _stopGyroscope();
    _stopMagnetometer();
    _stopBarometer();

    await _speedController?.close();
    await _altitudeController?.close();
    await _positionController?.close();
    await _accelerometerController?.close();
    await _userAccelerometerController?.close();
    await _gyroscopeController?.close();
    await _magnetometerController?.close();
    await _barometerController?.close();
    for (final binding in _externalProviders.values) {
      unawaited(binding.subscription.cancel());
      await binding.controller.close();
    }
    _externalProviders.clear();
  }
}
