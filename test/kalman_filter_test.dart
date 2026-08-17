import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/services/kalman_filter.dart';

void main() {
  test('the first reading seeds the estimate directly, no ramp-up from zero', () {
    final filter = KalmanFilter1D(processNoise: 0.5, measurementNoise: 1.0);
    expect(filter.filter(42.0), 42.0);
  });

  test('converges toward a step input over successive updates', () {
    final filter = KalmanFilter1D(processNoise: 0.5, measurementNoise: 1.0);
    filter.filter(0);
    double last = 0;
    for (var i = 0; i < 20; i++) {
      last = filter.filter(10);
    }
    expect(last, closeTo(10, 0.5));
  });

  test('a single high-measurementNoise-override reading barely moves the estimate', () {
    final filter = KalmanFilter1D(processNoise: 0.1, measurementNoise: 0.1);
    filter.filter(10); // seeds estimate at 10.
    filter.filter(10); // one normal update to build up confidence.
    final before = filter.value!;
    final after = filter.filter(1000, measurementNoise: 1e9); // wildly untrustworthy reading.
    expect((after - before).abs(), lessThan(0.1));
  });

  test('settles near a noisy-but-stationary true value over many updates', () {
    final filter = KalmanFilter1D(processNoise: 0.05, measurementNoise: 1.0);
    const trueValue = 25.0;
    final noise = [0.8, -0.6, 0.3, -0.9, 0.5, -0.2, 0.7, -0.4, 0.1, -0.3];
    double last = 0;
    for (var i = 0; i < 50; i++) {
      last = filter.filter(trueValue + noise[i % noise.length]);
    }
    expect(last, closeTo(trueValue, 0.5));
  });
}
