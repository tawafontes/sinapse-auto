import '../models/driving_session.dart';
import '../models/driving_session_sample.dart';

/// What a session's recorded samples actually contain, signal by signal —
/// computed once by [SessionAnalysisEngine.analyze] so every screen/widget
/// downstream asks "is there data for X" the same way, instead of each
/// re-deriving its own notion of "empty" from `samples.isEmpty`. That check
/// alone is the wrong question per Fase 12 §39: a session can have plenty of
/// samples yet still lack every accelerometer (or GPS, or barometer)
/// reading if that particular sensor wasn't available while recording, and
/// the UI needs to tell "no data for this signal" apart from "session has
/// no samples at all".
class SessionDataAvailability {
  const SessionDataAvailability({
    required this.hasSpeedData,
    required this.hasAltitudeData,
    required this.hasLongitudinalGData,
    required this.hasLateralGData,
    required this.hasPitchRollData,
    required this.hasTrajectoryData,
    required this.hasGGData,
  });

  final bool hasSpeedData;
  final bool hasAltitudeData;
  final bool hasLongitudinalGData;
  final bool hasLateralGData;
  final bool hasPitchRollData;

  /// At least 2 samples carry a GPS fix — the minimum a route sketch needs
  /// to draw a line at all (see `computeTrajectoryLayout`).
  final bool hasTrajectoryData;

  /// At least one sample has both a longitudinal and a lateral G reading —
  /// the minimum the G-G diagram needs to plot a single point.
  final bool hasGGData;

  bool get hasAccelerationData => hasLongitudinalGData || hasLateralGData;
}

/// One objectively-measurable fact about a completed session — Fase 12
/// §40's "Resumo inteligente": highest speed, hardest brake, biggest G, etc.
/// Deliberately never a subjective judgement of the driver (explicitly
/// excluded by §40) — every value here is one already computed and stored
/// on [DrivingSession] by `DrivingSessionRecorder`, just re-surfaced as a
/// single flat, presentable list instead of buried in the general stats
/// block.
enum SessionHighlightKind { maxSpeed, maxAcceleration, maxBraking, maxLateralG, maxGForce, altitudeGain, altitudeLoss }

class SessionHighlight {
  const SessionHighlight({required this.kind, required this.value});

  final SessionHighlightKind kind;

  /// Always in the session's canonical unit (km/h or g or meters) — this
  /// engine never converts for display (Fase 12 §6/§33), so it stays
  /// reusable regardless of the user's unit preference. Convert only where
  /// the value is actually rendered.
  final double value;
}

/// How a session's altitude moved overall — a plain-language summary of
/// [DrivingSession.altitudeGainMeters] vs [DrivingSession.altitudeLossMeters],
/// both of which are themselves already protected by the Fase 10 altitude
/// trend classifier's hysteresis (see `AltitudeTrendClassifier`). No second
/// noise filter is invented here — this only compares two numbers that are
/// already reliable.
enum AltitudeTrendSummary { noData, flat, mostlyClimbing, mostlyDescending, mixed }

/// Derived, presentation-ready analysis of one completed [DrivingSession] —
/// Fase 12's "Analysis Engine" output (§5: "Não colocar toda a lógica
/// dentro da UI"). Built once, from data [DrivingSessionRecorder] already
/// persisted; never touches a sensor or stream itself (Fase 12 §4/§56).
class SessionAnalysisResult {
  const SessionAnalysisResult({required this.availability, required this.highlights, required this.altitudeTrendSummary});

  final SessionDataAvailability availability;
  final List<SessionHighlight> highlights;
  final AltitudeTrendSummary altitudeTrendSummary;
}

/// Pure, stateless transform: a [DrivingSession] plus its
/// [DrivingSessionSample]s in, a [SessionAnalysisResult] out. No I/O, no
/// Hive access of its own — the caller already loaded both from
/// `HiveBoxNames.drivingSessions`/`drivingSessionSamples` (see
/// `SessionDetailScreen`). Reused, not recreated, per session opened: a
/// plain static function over immutable inputs needs no instance state.
class SessionAnalysisEngine {
  SessionAnalysisEngine._();

  /// Below this magnitude (meters), accumulated gain/loss is treated as
  /// noise-level rather than a genuine climb/descent — the same "small
  /// change isn't a real trend" judgement call the altitude trend
  /// classifier itself embodies, not a new physical threshold invented
  /// here.
  static const double _flatAltitudeThresholdMeters = 3.0;

  /// One side must exceed the other by this factor to call the session
  /// "predominantly" one direction rather than "mixed" — e.g. a session
  /// that climbed 100m and descended 95m round-tripped, it didn't "mostly
  /// climb".
  static const double _dominantAltitudeRatio = 1.3;

  static SessionAnalysisResult analyze(DrivingSession session, List<DrivingSessionSample> samples) {
    final availability = _analyzeAvailability(samples);
    return SessionAnalysisResult(
      availability: availability,
      highlights: _buildHighlights(session),
      altitudeTrendSummary: _summarizeAltitudeTrend(session, availability),
    );
  }

  static SessionDataAvailability _analyzeAvailability(List<DrivingSessionSample> samples) {
    var hasSpeed = false;
    var hasAltitude = false;
    var hasLongitudinalG = false;
    var hasLateralG = false;
    var hasPitchRoll = false;
    var fixCount = 0;
    var ggCount = 0;
    for (final s in samples) {
      if (s.speedKmh != null) hasSpeed = true;
      if (s.altitudeMeters != null) hasAltitude = true;
      if (s.longitudinalG != null) hasLongitudinalG = true;
      if (s.lateralG != null) hasLateralG = true;
      if (s.pitchDegrees != null || s.rollDegrees != null) hasPitchRoll = true;
      if (s.latitude != null && s.longitude != null) fixCount++;
      if (s.longitudinalG != null && s.lateralG != null) ggCount++;
    }
    return SessionDataAvailability(
      hasSpeedData: hasSpeed,
      hasAltitudeData: hasAltitude,
      hasLongitudinalGData: hasLongitudinalG,
      hasLateralGData: hasLateralG,
      hasPitchRollData: hasPitchRoll,
      hasTrajectoryData: fixCount >= 2,
      hasGGData: ggCount >= 1,
    );
  }

  static List<SessionHighlight> _buildHighlights(DrivingSession session) {
    final highlights = <SessionHighlight>[];
    void add(SessionHighlightKind kind, double? value) {
      if (value != null) highlights.add(SessionHighlight(kind: kind, value: value));
    }

    add(SessionHighlightKind.maxSpeed, session.maxSpeedKmh);
    add(SessionHighlightKind.maxAcceleration, session.maxAccelerationG);
    add(SessionHighlightKind.maxBraking, session.maxDecelerationG);
    add(SessionHighlightKind.maxLateralG, session.maxLateralG);
    add(SessionHighlightKind.maxGForce, session.maxGForceMagnitude);
    if (session.altitudeGainMeters > 0) add(SessionHighlightKind.altitudeGain, session.altitudeGainMeters);
    if (session.altitudeLossMeters > 0) add(SessionHighlightKind.altitudeLoss, session.altitudeLossMeters);
    return highlights;
  }

  static AltitudeTrendSummary _summarizeAltitudeTrend(DrivingSession session, SessionDataAvailability availability) {
    if (!availability.hasAltitudeData) return AltitudeTrendSummary.noData;
    final gain = session.altitudeGainMeters;
    final loss = session.altitudeLossMeters;
    if (gain < _flatAltitudeThresholdMeters && loss < _flatAltitudeThresholdMeters) return AltitudeTrendSummary.flat;
    if (gain > loss * _dominantAltitudeRatio) return AltitudeTrendSummary.mostlyClimbing;
    if (loss > gain * _dominantAltitudeRatio) return AltitudeTrendSummary.mostlyDescending;
    return AltitudeTrendSummary.mixed;
  }
}

/// Portuguese label for [SessionHighlightKind] — pure presentation, kept
/// alongside the engine (not inside a screen file) so any future screen can
/// reuse it without a screens-importing-screens dependency, matching how
/// `driveSessionEventTypeLabel` already lives beside `DrivingSessionEvent`.
String sessionHighlightLabel(SessionHighlightKind kind) {
  switch (kind) {
    case SessionHighlightKind.maxSpeed:
      return 'Maior velocidade';
    case SessionHighlightKind.maxAcceleration:
      return 'Maior aceleração';
    case SessionHighlightKind.maxBraking:
      return 'Maior frenagem';
    case SessionHighlightKind.maxLateralG:
      return 'Maior G lateral';
    case SessionHighlightKind.maxGForce:
      return 'Maior G resultante';
    case SessionHighlightKind.altitudeGain:
      return 'Maior ganho de altitude';
    case SessionHighlightKind.altitudeLoss:
      return 'Maior perda de altitude';
  }
}

String altitudeTrendSummaryLabel(AltitudeTrendSummary summary) {
  switch (summary) {
    case AltitudeTrendSummary.noData:
      return 'Sem dados de altitude';
    case AltitudeTrendSummary.flat:
      return 'Estável';
    case AltitudeTrendSummary.mostlyClimbing:
      return 'Predominantemente ascendente';
    case AltitudeTrendSummary.mostlyDescending:
      return 'Predominantemente descendente';
    case AltitudeTrendSummary.mixed:
      return 'Variada (subidas e descidas)';
  }
}
