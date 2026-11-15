import '../../services/obd/obd_service.dart';

/// How old a reading of the car's odometer may be and still fill a refuel
/// or recharge form: the car is usually switched off at the pump or the
/// charger, so the last reading before that is the one wanted.
const obdOdometerMaxAge = Duration(minutes: 30);

/// The car's odometer as read over OBD-II (PID A6), whole km, when the
/// adapter read it in the last [obdOdometerMaxAge]; `null` otherwise (no
/// adapter, a car that does not report it, an old reading).
({double km, DateTime at})? obdOdometerForForm(ObdService? service, {DateTime? now}) {
  final sample = service?.readings[ObdSignal.odometer];
  if (sample == null) return null;
  final age = (now ?? DateTime.now()).difference(sample.at);
  if (age.isNegative || age > obdOdometerMaxAge) return null;
  return (km: sample.value.roundToDouble(), at: sample.at);
}

String obdOdometerHelper(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Lido do carro pelo OBD-II às ${two(at.hour)}:${two(at.minute)}. Confira no painel.';
}
