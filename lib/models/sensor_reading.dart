/// Runtime telemetry value types produced by [SensorService].
///
/// These are plain (non-Hive) models: they represent live, ephemeral sensor
/// data, not persisted configuration.
library;

import 'dart:math' as math;

/// Vehicle speed sample, sourced from the device's location provider.
class SpeedReading {
  const SpeedReading({
    required this.metersPerSecond,
    required this.accuracy,
    required this.timestamp,
  });

  final double metersPerSecond;

  /// Estimated speed accuracy in meters per second, as reported by the
  /// platform location backend. May be null if unsupported.
  final double? accuracy;

  final DateTime timestamp;

  double get kilometersPerHour => metersPerSecond * 3.6;
}

/// A single XYZ vector sample, shared by accelerometer, gyroscope and
/// magnetometer readings (they differ only in unit/meaning, not shape).
class VectorReading {
  const VectorReading({
    required this.x,
    required this.y,
    required this.z,
    required this.timestamp,
  });

  final double x;
  final double y;
  final double z;
  final DateTime timestamp;

  /// Euclidean magnitude of the vector, e.g. used for G-force thresholding.
  double get magnitude => math.sqrt(x * x + y * y + z * z);
}

/// Altitude sample, sourced from the same location provider as [SpeedReading].
class AltitudeReading {
  const AltitudeReading({required this.meters, required this.timestamp});

  final double meters;
  final DateTime timestamp;
}

/// Barometric pressure sample, sourced from the device's barometer (when
/// present — not every device has one). Insulates the rest of the app from
/// `sensors_plus`'s `BarometerEvent` type, same as [VectorReading] does for
/// the other `sensors_plus`-backed streams.
class BarometerReading {
  const BarometerReading({required this.pressureHpa, required this.timestamp});

  /// Atmospheric pressure in hectopascals (hPa).
  final double pressureHpa;
  final DateTime timestamp;
}
