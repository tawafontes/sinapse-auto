import 'package:flutter/foundation.dart';

/// Runs the "Resetar e calibrar sistema" global-button operation: given every
/// sensor widget's own bare reset/calibration trigger (see
/// `LineChart.onImmediateResetRequested`, `GForceMeter.
/// onImmediateResetRequested`, `ArtificialHorizon.onImmediateResetRequested`),
/// invokes each one in turn.
///
/// Deliberately stateless and free of any registry of its own — the caller
/// (`DashboardScreen`) owns the up-to-date collection of triggers (one per
/// currently-built sensor tile), the exact same way it already owns
/// `_resetTriggers` for the per-tile "Resetar registros" menu item. That's
/// what makes a future widget automatically included here with zero changes
/// to this class: as long as it registers a trigger the same way the
/// existing three do, whatever triggers the caller passes in get run.
///
/// A thrown exception from any trigger propagates out of [resetAndCalibrateAll]
/// immediately, skipping the remaining triggers — the caller is expected to
/// wrap the call in its own try/catch to show a friendly error message,
/// keeping that UI concern out of this service.
class DashboardMaintenanceService {
  const DashboardMaintenanceService();

  Future<void> resetAndCalibrateAll(Iterable<VoidCallback> triggers) async {
    for (final trigger in triggers) {
      trigger();
    }
  }
}
