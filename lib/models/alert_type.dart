/// Every alert kind the app can raise — deliberately a closed, small set
/// (not an open string key) so every consumer (the engine, the settings
/// screen, the dashboard banner) is exhaustively checked by the analyzer
/// whenever a new one is added.
///
/// This is a shared, user-configurable *threshold/enable vocabulary* — used
/// by [AlertPreferences]/`AlertsScreen` regardless of which runtime engine
/// actually detects a given type. As of Fase 13.1, `highSpeed`/
/// `harshAcceleration`/`harshBraking`/`hardCornering`/`highResultantG`/
/// `gnssLost` are detected exclusively by `EventDetectionEngine` (see that
/// class's doc); [AlertEngine] itself only still independently detects
/// `highInclination`/`weakGnss`. `hardCornering` stays a single,
/// direction-agnostic type here even though `EventDetectionEngine` splits
/// its own `DetectedEventType` into left/right — a live banner just needs
/// "a hard turn happened," not which way, unlike the persisted session
/// event, which does split left/right for later analysis; both share this
/// one threshold.
enum AlertType { highSpeed, weakGnss, gnssLost, harshAcceleration, harshBraking, highInclination, hardCornering, highResultantG }

String alertTypeLabel(AlertType type) {
  switch (type) {
    case AlertType.highSpeed:
      return 'Velocidade elevada';
    case AlertType.weakGnss:
      return 'GNSS com baixa qualidade';
    case AlertType.gnssLost:
      return 'Perda de sinal GNSS';
    case AlertType.harshAcceleration:
      return 'Aceleração intensa';
    case AlertType.harshBraking:
      return 'Frenagem intensa';
    case AlertType.highInclination:
      return 'Inclinação elevada';
    case AlertType.hardCornering:
      return 'Curva forte';
    case AlertType.highResultantG:
      return 'G resultante elevado';
  }
}

/// Whether [type] has a user-configurable numeric threshold at all — GNSS
/// alerts key off [GnssQuality]'s own fixed classification bands instead
/// (see `GnssQualityThresholds`), so there's nothing meaningful for a user
/// to tune there.
bool alertTypeHasThreshold(AlertType type) {
  switch (type) {
    case AlertType.highSpeed:
    case AlertType.harshAcceleration:
    case AlertType.harshBraking:
    case AlertType.highInclination:
    case AlertType.hardCornering:
    case AlertType.highResultantG:
      return true;
    case AlertType.weakGnss:
    case AlertType.gnssLost:
      return false;
  }
}
