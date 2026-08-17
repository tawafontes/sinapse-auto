import 'alert_type.dart';

/// A single alert state transition — [active] `true` means [type] just
/// started firing, `false` means it just cleared. [AlertEngine] emits one
/// of these only on an actual transition, never a repeated "still active"
/// event every telemetry tick.
class AlertEvent {
  const AlertEvent({required this.type, required this.active, required this.timestamp});
  final AlertType type;
  final bool active;
  final DateTime timestamp;
}
