/// Centralized unit conversion — the single place speed/altitude values are
/// ever converted between metric and imperial. Widgets never implement
/// their own conversion formula: they receive a value already in the
/// engine's canonical internal unit (km/h, meters — matching every
/// persisted record and every Kalman/filter threshold already tuned in
/// those units) plus this file's pure functions to transform it for
/// display only, at the last possible step.
library;

enum SpeedUnit { kmh, mph }

enum AltitudeUnit { meters, feet }

const double _kmhToMph = 0.621371;
const double _metersToFeet = 3.28084;

/// Converts a canonical km/h value to [to]. The engine, persistence, and
/// every internal filter threshold always stay in km/h regardless of this
/// — only ever called at the final display step.
double convertSpeedFromKmh(double kmh, SpeedUnit to) {
  switch (to) {
    case SpeedUnit.kmh:
      return kmh;
    case SpeedUnit.mph:
      return kmh * _kmhToMph;
  }
}

/// Converts a canonical meters value to [to]. Same display-only contract as
/// [convertSpeedFromKmh].
double convertAltitudeFromMeters(double meters, AltitudeUnit to) {
  switch (to) {
    case AltitudeUnit.meters:
      return meters;
    case AltitudeUnit.feet:
      return meters * _metersToFeet;
  }
}

String speedUnitLabel(SpeedUnit unit) {
  switch (unit) {
    case SpeedUnit.kmh:
      return 'km/h';
    case SpeedUnit.mph:
      return 'mph';
  }
}

String altitudeUnitLabel(AltitudeUnit unit) {
  switch (unit) {
    case AltitudeUnit.meters:
      return 'm';
    case AltitudeUnit.feet:
      return 'ft';
  }
}
