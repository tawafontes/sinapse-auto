import '../models/dashcam_telemetry_sample.dart';

/// Finds the [DashcamTelemetrySample] whose [DashcamTelemetrySample.timestamp]
/// is closest to [target] — the concrete answer to "given a video playback
/// position, what was telemetry doing at that instant" (Fase 15).
///
/// A linear scan tracking minimum absolute distance, not a binary search,
/// matching this codebase's existing "nearest timestamp" idiom
/// (`_indexNearestTimestamp` in `session_time_series_chart.dart`/
/// `gg_diagram.dart` is also a linear scan despite operating on
/// chronologically-sorted data) — a single clip's sample count (at most a
/// few thousand, bounded by [DashcamTelemetryWriter]'s own segment length)
/// makes the algorithmic difference immaterial, and matching the house idiom
/// is worth more than the eked-out cycles a binary search would save.
///
/// Returns `null` only if [samples] is empty.
DashcamTelemetrySample? nearestDashcamSample(List<DashcamTelemetrySample> samples, DateTime target) {
  if (samples.isEmpty) return null;
  var nearest = samples.first;
  var nearestDistance = target.difference(nearest.timestamp).abs();
  for (var i = 1; i < samples.length; i++) {
    final distance = target.difference(samples[i].timestamp).abs();
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = samples[i];
    }
  }
  return nearest;
}
