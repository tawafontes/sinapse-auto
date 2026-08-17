/// Downsamples [input] to at most [maxPoints] elements by taking every Nth
/// element — used before painting a session's stored samples (which can
/// number in the thousands for a long session) so a chart never has to lay
/// out/paint more path segments than the screen can meaningfully show.
/// Always keeps the first and last element so a chart's time range never
/// visually shrinks just because of decimation.
///
/// Kept for callers that only need *any* representative subset (e.g. a
/// trajectory sketch, where every fix is roughly equally informative about
/// shape). For a signal where the true peak/trough matters — a chart axis,
/// a G-G scatter's highlighted extreme — prefer [minMaxBucketIndices]
/// instead: a plain stride like this one has no guarantee of ever landing on
/// the series' actual maximum or minimum sample.
List<T> decimate<T>(List<T> input, {required int maxPoints}) {
  if (input.length <= maxPoints || maxPoints < 2) return input;
  final step = (input.length - 1) / (maxPoints - 1);
  final result = <T>[];
  for (var i = 0; i < maxPoints; i++) {
    final index = (i * step).round().clamp(0, input.length - 1);
    result.add(input[index]);
  }
  return result;
}

/// Selects up to roughly [maxPoints] indices out of a series of [length]
/// items, preferring each time-ordered bucket's local min and max (by
/// [valueOf]) over an even stride — so a downsampled render still contains
/// the series' true peak and trough, not just whichever samples happened to
/// land on a fixed step. Always includes index 0 and `length - 1`.
///
/// [valueOf] may return `null` for an index with no reading at all (e.g. a
/// GNSS-lost gap): such an index is never chosen as a bucket's extreme, but
/// if a whole bucket has no reading, one representative index from it is
/// still emitted — dropping it entirely would silently shrink a real gap in
/// the data into nothing, which is exactly what a downsampling step must
/// not do (see Fase 12 §18/§29/§38).
///
/// Result length can slightly exceed [maxPoints] (each bucket may
/// contribute both a min and a max) — this is a soft target, not a hard
/// cap: precisely preserving extremes takes priority over an exact count,
/// and the overshoot is bounded (never more than double the bucket count).
List<int> minMaxBucketIndices(int length, {required int maxPoints, required double? Function(int index) valueOf}) {
  if (length <= maxPoints || maxPoints < 2) return List<int>.generate(length, (i) => i);

  final bucketCount = (maxPoints / 2).floor().clamp(1, length);
  final bucketSize = length / bucketCount;
  final indices = <int>{0, length - 1};

  for (var bucket = 0; bucket < bucketCount; bucket++) {
    final start = (bucket * bucketSize).floor();
    final end = ((bucket + 1) * bucketSize).floor().clamp(start + 1, length);

    int? minIndex;
    int? maxIndex;
    double? minValue;
    double? maxValue;
    for (var i = start; i < end; i++) {
      final value = valueOf(i);
      if (value == null) continue;
      if (minValue == null || value < minValue) {
        minValue = value;
        minIndex = i;
      }
      if (maxValue == null || value > maxValue) {
        maxValue = value;
        maxIndex = i;
      }
    }

    if (minIndex != null) indices.add(minIndex);
    if (maxIndex != null) indices.add(maxIndex);
    if (minIndex == null && maxIndex == null) indices.add(start);
  }

  return indices.toList()..sort();
}
