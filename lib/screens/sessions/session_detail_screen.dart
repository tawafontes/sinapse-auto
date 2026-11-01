import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../models/dashcam_clip_record.dart';
import '../../models/driving_session.dart';
import '../../models/driving_session_event.dart';
import '../../models/driving_session_sample.dart';
import '../../models/unit_system.dart';
import '../../services/gnss_quality.dart';
import '../../services/hive_boxes.dart';
import '../../services/session_analysis_engine.dart';
import '../../services/unit_preferences.dart';
import '../../widgets/telemetry/gg_diagram.dart';
import '../../widgets/telemetry/session_time_series_chart.dart';
import 'dashcam_playback_screen.dart';

/// Full analysis view for one completed [DrivingSession] — Fase 12's
/// "Análise da sessão": a summary (including Fase 12 §40's "resumo
/// inteligente" highlights), per-signal time-series charts, a G-G diagram,
/// the session's relevant events, and a map-free trajectory sketch, laid
/// out as tabs (Fase 12 §7) rather than one long, increasingly-crowded
/// scroll now that interactivity/messaging were added to each section.
///
/// Everything here is built from the session's own persisted
/// [DrivingSessionSample]s (fetched once, on demand, from the lazy samples
/// box — never eagerly loaded just because a session exists in the
/// lightweight `driving_sessions` box `SessionHistoryScreen` lists) plus a
/// [SessionAnalysisResult] derived from them (Fase 12 §5's "Analysis
/// Engine" — see `SessionAnalysisEngine`). No sensor or live stream is ever
/// touched here (Fase 12 §4/§56): this screen is a pure consumer of
/// already-recorded data.
///
/// The "Vídeo" tab (Fase 15) follows the same on-demand-load pattern as
/// [_samples]: [DashcamClipRecord]s are fetched once from the
/// `dashcam_session_videos` box in [_loadClips], only when this screen is
/// actually opened — never eagerly just because a session exists.
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final DrivingSession session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

enum _AccelerationSignal { longitudinal, lateral, pitch, roll }

class _SessionDetailScreenState extends State<SessionDetailScreen> with SingleTickerProviderStateMixin {
  static const _tabTitles = ['Resumo', 'Velocidade', 'Altitude', 'Aceleração', 'G-G', 'Eventos', 'Trajetória', 'Vídeo'];
  static const _speedTabIndex = 1;
  static const _altitudeTabIndex = 2;
  static const _accelerationTabIndex = 3;
  static const _ggTabIndex = 4;

  late final TabController _tabController;
  List<DrivingSessionSample>? _samples;
  SessionAnalysisResult? _analysis;
  List<DashcamClipRecord>? _clips;
  _AccelerationSignal _accelerationSignal = _AccelerationSignal.longitudinal;
  DateTime? _speedJumpTimestamp;
  DateTime? _altitudeJumpTimestamp;
  DateTime? _accelerationJumpTimestamp;
  DateTime? _ggJumpTimestamp;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabTitles.length, vsync: this);
    _loadSamples();
    _loadClips();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSamples() async {
    final box = Hive.lazyBox(HiveBoxNames.drivingSessionSamples);
    final raw = await box.get(widget.session.id) as List?;
    if (!mounted) return;
    final samples = raw == null ? <DrivingSessionSample>[] : List<DrivingSessionSample>.from(raw);
    setState(() {
      _samples = samples;
      _analysis = SessionAnalysisEngine.analyze(widget.session, samples);
    });
  }

  Future<void> _loadClips() async {
    final box = Hive.box(HiveBoxNames.dashcamSessionVideos);
    final raw = box.get(widget.session.id) as List?;
    if (!mounted) return;
    setState(() {
      _clips = raw == null ? <DashcamClipRecord>[] : List<DashcamClipRecord>.from(raw);
    });
  }

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

  String _formatDuration(Duration? d) {
    if (d == null) return '—';
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// Routes a tapped event to the tab/instant that shows it (Fase 12 §21,
  /// Fase 13 §36-37) — motion events go to Aceleração (pre-selecting the
  /// axis that actually triggered them); cornering and combined-G events go
  /// to G-G, since a single-axis chart can't show what a *combined*
  /// longitudinal+lateral force actually looked like; GNSS/speed/motion
  /// events route to Velocidade (signal quality and speed are most directly
  /// relevant there); altitude-trend events go to Altitude.
  void _jumpToEvent(DrivingSessionEvent event) {
    switch (event.type) {
      case DrivingSessionEventType.hardAcceleration:
      case DrivingSessionEventType.hardBraking:
        setState(() {
          _accelerationSignal = _AccelerationSignal.longitudinal;
          _accelerationJumpTimestamp = event.timestamp;
        });
        _tabController.animateTo(_accelerationTabIndex);
      case DrivingSessionEventType.hardCornering:
      case DrivingSessionEventType.hardCorneringLeft:
      case DrivingSessionEventType.hardCorneringRight:
      case DrivingSessionEventType.highResultantG:
        setState(() => _ggJumpTimestamp = event.timestamp);
        _tabController.animateTo(_ggTabIndex);
      case DrivingSessionEventType.gnssLost:
      case DrivingSessionEventType.gnssRecovered:
      case DrivingSessionEventType.speedLimitExceeded:
      case DrivingSessionEventType.stopped:
      case DrivingSessionEventType.resumed:
        setState(() => _speedJumpTimestamp = event.timestamp);
        _tabController.animateTo(_speedTabIndex);
      case DrivingSessionEventType.altitudeRisingSignificant:
      case DrivingSessionEventType.altitudeFallingSignificant:
        setState(() => _altitudeJumpTimestamp = event.timestamp);
        _tabController.animateTo(_altitudeTabIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final samples = _samples;
    final analysis = _analysis;

    return Scaffold(
      appBar: AppBar(
        title: Text(_formatDate(session.startTime)),
        bottom: TabBar(controller: _tabController, isScrollable: true, tabs: _tabTitles.map((t) => Tab(text: t)).toList()),
      ),
      body: SafeArea(
        child: samples == null || analysis == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tabController,
                children: [
                  _ResumoTab(session: session, analysis: analysis, formatTime: _formatTime, formatDuration: _formatDuration),
                  _SpeedTab(session: session, samples: samples, availability: analysis.availability, initialSelectedTimestamp: _speedJumpTimestamp),
                  _AltitudeTab(session: session, samples: samples, analysis: analysis, initialSelectedTimestamp: _altitudeJumpTimestamp),
                  _AccelerationTab(
                    samples: samples,
                    events: session.events,
                    availability: analysis.availability,
                    signal: _accelerationSignal,
                    onSignalChanged: (s) => setState(() => _accelerationSignal = s),
                    initialSelectedTimestamp: _accelerationJumpTimestamp,
                  ),
                  _GGTab(samples: samples, initialSelectedTimestamp: _ggJumpTimestamp),
                  _EventsTab(session: session, formatTime: _formatTime, onEventTap: _jumpToEvent),
                  _TrajectoryTab(samples: samples, hasTrajectoryData: analysis.availability.hasTrajectoryData),
                  _VideoTab(clips: _clips, sessionId: session.id),
                ],
              ),
      ),
    );
  }
}

class _ResumoTab extends StatelessWidget {
  const _ResumoTab({required this.session, required this.analysis, required this.formatTime, required this.formatDuration});

  final DrivingSession session;
  final SessionAnalysisResult analysis;
  final String Function(DateTime) formatTime;
  final String Function(Duration?) formatDuration;

  String _formatHighlightValue(SessionHighlightKind kind, double value, UnitPreferences prefs) {
    switch (kind) {
      case SessionHighlightKind.maxSpeed:
        return '${convertSpeedFromKmh(value, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}';
      case SessionHighlightKind.maxAcceleration:
      case SessionHighlightKind.maxBraking:
      case SessionHighlightKind.maxLateralG:
      case SessionHighlightKind.maxGForce:
        return '${value.toStringAsFixed(2)} g';
      case SessionHighlightKind.altitudeGain:
      case SessionHighlightKind.altitudeLoss:
        return '${convertAltitudeFromMeters(value, prefs.altitudeUnit).toStringAsFixed(0)} ${altitudeUnitLabel(prefs.altitudeUnit)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = UnitPreferencesScope.of(context);
    // Fase 16.2-R4.3-R2.6.11: how this session's dashcam telemetry ended, from
    // its own record — absent for a session with no recorded outcome.
    final telemetry = dashcamTelemetryOutcomeSummary(session);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Resumo', style: Theme.of(context).textTheme.titleMedium),
                const Divider(height: 20),
                _StatRow('Início', formatTime(session.startTime)),
                _StatRow('Término', session.endTime == null ? '—' : formatTime(session.endTime!)),
                _StatRow('Duração', formatDuration(session.duration)),
                _StatRow('Distância', '${(session.distanceMeters / 1000).toStringAsFixed(2)} km'),
                _StatRow(
                  'Velocidade máxima',
                  session.maxSpeedKmh == null
                      ? '—'
                      : '${convertSpeedFromKmh(session.maxSpeedKmh!, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}',
                ),
                _StatRow(
                  'Velocidade média',
                  session.avgSpeedKmh == null
                      ? '—'
                      : '${convertSpeedFromKmh(session.avgSpeedKmh!, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}',
                ),
                _StatRow(
                  'Altitude (mín – máx)',
                  session.minAltitudeMeters == null || session.maxAltitudeMeters == null
                      ? '—'
                      : '${convertAltitudeFromMeters(session.minAltitudeMeters!, prefs.altitudeUnit).toStringAsFixed(0)} – '
                            '${convertAltitudeFromMeters(session.maxAltitudeMeters!, prefs.altitudeUnit).toStringAsFixed(0)} ${altitudeUnitLabel(prefs.altitudeUnit)}',
                ),
                _StatRow('Tendência de altitude', altitudeTrendSummaryLabel(analysis.altitudeTrendSummary)),
                _StatRow(
                  'G resultante máximo',
                  session.maxGForceMagnitude == null ? '—' : '${session.maxGForceMagnitude!.toStringAsFixed(2)} g',
                ),
                _StatRow(
                  'Qualidade GNSS (média)',
                  session.avgGnssQualityIndex == null ? '—' : gnssQualityLabel(gnssQualityFromAverageIndex(session.avgGnssQualityIndex!)),
                ),
                _StatRow('Amostras', '${session.sampleCount}'),
                _StatRow('Eventos', '${session.events.length}'),
                if (telemetry != null) _StatRow('Telemetria da dashcam', '${telemetry[0].toUpperCase()}${telemetry.substring(1)}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (analysis.highlights.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Resumo da condução', style: Theme.of(context).textTheme.titleMedium),
                  const Divider(height: 20),
                  for (final highlight in analysis.highlights)
                    _StatRow(sessionHighlightLabel(highlight.kind), _formatHighlightValue(highlight.kind, highlight.value, prefs)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SpeedTab extends StatelessWidget {
  const _SpeedTab({required this.session, required this.samples, required this.availability, required this.initialSelectedTimestamp});

  final DrivingSession session;
  final List<DrivingSessionSample> samples;
  final SessionDataAvailability availability;
  final DateTime? initialSelectedTimestamp;

  @override
  Widget build(BuildContext context) {
    if (!availability.hasSpeedData) {
      return const _EmptySignalMessage('Dados de velocidade indisponíveis nesta sessão.');
    }
    final prefs = UnitPreferencesScope.of(context);
    final unit = speedUnitLabel(prefs.speedUnit);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SessionTimeSeriesChart(
        samples: samples,
        valueOf: (s) => s.speedKmh == null ? null : convertSpeedFromKmh(s.speedKmh!, prefs.speedUnit),
        unit: unit,
        color: Theme.of(context).colorScheme.primary,
        events: session.events,
        highlightMaxValue: session.maxSpeedKmh == null ? null : convertSpeedFromKmh(session.maxSpeedKmh!, prefs.speedUnit),
        highlightAverageValue: session.avgSpeedKmh == null ? null : convertSpeedFromKmh(session.avgSpeedKmh!, prefs.speedUnit),
        initialSelectedTimestamp: initialSelectedTimestamp,
      ),
    );
  }
}

class _AltitudeTab extends StatelessWidget {
  const _AltitudeTab({required this.session, required this.samples, required this.analysis, required this.initialSelectedTimestamp});

  final DrivingSession session;
  final List<DrivingSessionSample> samples;
  final SessionAnalysisResult analysis;
  final DateTime? initialSelectedTimestamp;

  @override
  Widget build(BuildContext context) {
    if (!analysis.availability.hasAltitudeData) {
      return const _EmptySignalMessage('Dados de altitude indisponíveis nesta sessão.');
    }
    final prefs = UnitPreferencesScope.of(context);
    final unit = altitudeUnitLabel(prefs.altitudeUnit);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatRow(
            'Ganho / perda de altitude',
            '+${convertAltitudeFromMeters(session.altitudeGainMeters, prefs.altitudeUnit).toStringAsFixed(0)} / '
                '-${convertAltitudeFromMeters(session.altitudeLossMeters, prefs.altitudeUnit).toStringAsFixed(0)} $unit',
          ),
          _StatRow(
            'Inicial → final',
            session.initialAltitudeMeters == null || session.finalAltitudeMeters == null
                ? '—'
                : '${convertAltitudeFromMeters(session.initialAltitudeMeters!, prefs.altitudeUnit).toStringAsFixed(0)} → '
                      '${convertAltitudeFromMeters(session.finalAltitudeMeters!, prefs.altitudeUnit).toStringAsFixed(0)} $unit',
          ),
          _StatRow('Tendência', altitudeTrendSummaryLabel(analysis.altitudeTrendSummary)),
          const SizedBox(height: 12),
          SessionTimeSeriesChart(
            samples: samples,
            valueOf: (s) => s.altitudeMeters == null ? null : convertAltitudeFromMeters(s.altitudeMeters!, prefs.altitudeUnit),
            unit: unit,
            color: Theme.of(context).colorScheme.primary,
            events: session.events,
            highlightMaxValue: session.maxAltitudeMeters == null ? null : convertAltitudeFromMeters(session.maxAltitudeMeters!, prefs.altitudeUnit),
            initialSelectedTimestamp: initialSelectedTimestamp,
          ),
        ],
      ),
    );
  }
}

class _AccelerationTab extends StatelessWidget {
  const _AccelerationTab({
    required this.samples,
    required this.events,
    required this.availability,
    required this.signal,
    required this.onSignalChanged,
    required this.initialSelectedTimestamp,
  });

  final List<DrivingSessionSample> samples;
  final List<DrivingSessionEvent> events;
  final SessionDataAvailability availability;
  final _AccelerationSignal signal;
  final ValueChanged<_AccelerationSignal> onSignalChanged;
  final DateTime? initialSelectedTimestamp;

  bool get _hasSelectedSignalData {
    switch (signal) {
      case _AccelerationSignal.longitudinal:
        return availability.hasLongitudinalGData;
      case _AccelerationSignal.lateral:
        return availability.hasLateralGData;
      case _AccelerationSignal.pitch:
      case _AccelerationSignal.roll:
        return availability.hasPitchRollData;
    }
  }

  // Abbreviated ("Long." not "Longitudinal") so all four segments fit on one
  // line each even on a compact phone width — a wrapped 3-line segment label
  // was genuinely illegible on the physical device during Fase 12
  // validation, which the automotive-UX principle (§64: legibility over
  // decoration) rules out.
  String _label(_AccelerationSignal s) {
    switch (s) {
      case _AccelerationSignal.longitudinal:
        return 'Long.';
      case _AccelerationSignal.lateral:
        return 'Lateral';
      case _AccelerationSignal.pitch:
        return 'Pitch';
      case _AccelerationSignal.roll:
        return 'Roll';
    }
  }

  String _unit(_AccelerationSignal s) {
    switch (s) {
      case _AccelerationSignal.longitudinal:
      case _AccelerationSignal.lateral:
        return 'g';
      case _AccelerationSignal.pitch:
      case _AccelerationSignal.roll:
        return '°';
    }
  }

  double? _valueOf(_AccelerationSignal s, DrivingSessionSample sample) {
    switch (s) {
      case _AccelerationSignal.longitudinal:
        return sample.longitudinalG;
      case _AccelerationSignal.lateral:
        return sample.lateralG;
      case _AccelerationSignal.pitch:
        return sample.pitchDegrees;
      case _AccelerationSignal.roll:
        return sample.rollDegrees;
    }
  }

  /// Hard-acceleration/braking/cornering events are markers for the G
  /// signals they were derived from; pitch/roll have no associated event
  /// type, so no marker is meaningful there.
  List<DrivingSessionEvent> get _eventsForSelectedSignal {
    switch (signal) {
      case _AccelerationSignal.longitudinal:
        return events
            .where((e) => e.type == DrivingSessionEventType.hardAcceleration || e.type == DrivingSessionEventType.hardBraking)
            .toList();
      case _AccelerationSignal.lateral:
        return events
            .where(
              (e) =>
                  e.type == DrivingSessionEventType.hardCornering ||
                  e.type == DrivingSessionEventType.hardCorneringLeft ||
                  e.type == DrivingSessionEventType.hardCorneringRight,
            )
            .toList();
      case _AccelerationSignal.pitch:
      case _AccelerationSignal.roll:
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!availability.hasAccelerationData && !availability.hasPitchRollData) {
      return const _EmptySignalMessage('Dados de aceleração indisponíveis nesta sessão.');
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<_AccelerationSignal>(
            segments: _AccelerationSignal.values.map((s) => ButtonSegment(value: s, label: Text(_label(s)))).toList(),
            selected: {signal},
            onSelectionChanged: (selection) => onSignalChanged(selection.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 12),
          if (!_hasSelectedSignalData)
            const _EmptySignalMessage('Dados indisponíveis para este sinal nesta sessão.')
          else
            SessionTimeSeriesChart(
              key: ValueKey(signal),
              samples: samples,
              valueOf: (s) => _valueOf(signal, s),
              unit: _unit(signal),
              color: Theme.of(context).colorScheme.primary,
              events: _eventsForSelectedSignal,
              initialSelectedTimestamp: initialSelectedTimestamp,
            ),
        ],
      ),
    );
  }
}

class _GGTab extends StatelessWidget {
  const _GGTab({required this.samples, required this.initialSelectedTimestamp});

  final List<DrivingSessionSample> samples;
  final DateTime? initialSelectedTimestamp;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: GGDiagram(samples: samples, initialSelectedTimestamp: initialSelectedTimestamp),
    );
  }
}

class _EventsTab extends StatelessWidget {
  const _EventsTab({required this.session, required this.formatTime, required this.onEventTap});

  final DrivingSession session;
  final String Function(DateTime) formatTime;
  final ValueChanged<DrivingSessionEvent> onEventTap;

  /// [DrivingSessionEvent.magnitude]'s own doc is explicit that its unit
  /// depends on the event type ("g for G-based events, km/h for speed/motion
  /// ones") — this formats it accordingly instead of assuming "g" for every
  /// type (Fase 13.3 incidental fix: a real drive produced a "Retomada de
  /// movimento" event labeled "13.29 g", which is a physically absurd,
  /// crash-level reading for a car pulling away from a stop — the value
  /// itself was a perfectly ordinary 13.29 km/h; only the unit label was
  /// wrong). Altitude events are millimeter/meter-scale by nature, so they
  /// get the same unit-preference-aware conversion the Resumo tab's own
  /// `_formatHighlightValue` already uses for consistency.
  String _formatMagnitude(DrivingSessionEventType type, double magnitude, UnitPreferences prefs) {
    switch (type) {
      case DrivingSessionEventType.hardAcceleration:
      case DrivingSessionEventType.hardBraking:
      case DrivingSessionEventType.hardCornering:
      case DrivingSessionEventType.hardCorneringLeft:
      case DrivingSessionEventType.hardCorneringRight:
      case DrivingSessionEventType.highResultantG:
        return '${magnitude.toStringAsFixed(2)} g';
      case DrivingSessionEventType.speedLimitExceeded:
      case DrivingSessionEventType.stopped:
      case DrivingSessionEventType.resumed:
        return '${convertSpeedFromKmh(magnitude, prefs.speedUnit).toStringAsFixed(0)} ${speedUnitLabel(prefs.speedUnit)}';
      case DrivingSessionEventType.altitudeRisingSignificant:
      case DrivingSessionEventType.altitudeFallingSignificant:
        return '${convertAltitudeFromMeters(magnitude, prefs.altitudeUnit).toStringAsFixed(0)} ${altitudeUnitLabel(prefs.altitudeUnit)}';
      case DrivingSessionEventType.gnssLost:
      case DrivingSessionEventType.gnssRecovered:
        return magnitude.toStringAsFixed(2);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (session.events.isEmpty) {
      return const _EmptySignalMessage('Nenhum evento relevante registrado nesta sessão.');
    }
    final prefs = UnitPreferencesScope.of(context);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: session.events.length,
      itemBuilder: (context, index) {
        final event = session.events[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.bolt),
            title: Text(driveSessionEventTypeLabel(event.type)),
            subtitle: Text(formatTime(event.timestamp)),
            trailing: event.magnitude == null ? null : Text(_formatMagnitude(event.type, event.magnitude!, prefs)),
            onTap: () => onEventTap(event),
          ),
        );
      },
    );
  }
}

class _TrajectoryTab extends StatelessWidget {
  const _TrajectoryTab({required this.samples, required this.hasTrajectoryData});

  final List<DrivingSessionSample> samples;
  final bool hasTrajectoryData;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return const _EmptySignalMessage('Nenhuma amostra registrada para esta sessão.');
    }
    if (!hasTrajectoryData) {
      return const _EmptySignalMessage('Nenhum ponto de GPS registrado nesta sessão.');
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: AspectRatio(
        aspectRatio: 1.1,
        child: CustomPaint(
          size: Size.infinite,
          painter: _TrajectoryPainter(samples: samples, color: Theme.of(context).colorScheme.primary),
        ),
      ),
    );
  }
}

/// Fase 15 — lists this session's recorded clips (if any); tapping one opens
/// [DashcamPlaybackScreen]. Never decodes/loads a video itself — only the
/// lightweight [DashcamClipRecord] metadata (path, duration, size,
/// protected flag) already loaded by [_SessionDetailScreenState._loadClips].
class _VideoTab extends StatelessWidget {
  const _VideoTab({required this.clips, required this.sessionId});

  final List<DashcamClipRecord>? clips;
  final String sessionId;

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _formatSize(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final clips = this.clips;
    if (clips == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (clips.isEmpty) {
      return const _EmptySignalMessage('Nenhum clipe de vídeo gravado nesta sessão.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: clips.length,
      itemBuilder: (context, index) {
        final clip = clips[index];
        return Card(
          child: ListTile(
            leading: Icon(clip.isProtected ? Icons.shield : Icons.videocam),
            title: Text('Clipe ${index + 1} · ${_formatTime(clip.recordedAt)}'),
            subtitle: Text('${_formatDuration(clip.durationSeconds)} · ${_formatSize(clip.sizeBytes)}'),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DashcamPlaybackScreen(clip: clip, sessionId: sessionId)),
            ),
          ),
        );
      },
    );
  }
}

class _EmptySignalMessage extends StatelessWidget {
  const _EmptySignalMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          const SizedBox(width: 12),
          // Flexible (Fase 13.3 incidental fix): a long value — e.g.
          // altitudeTrendSummaryLabel's "Predominantemente descendente" —
          // previously overflowed this Row on a narrow phone width. Wrapping
          // lets it break onto a second line instead, matching every other
          // value here that already fits on one.
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// Map-free trajectory sketch: projects each sample's latitude/longitude
/// into local canvas coordinates scaled to the session's own bounding box
/// (not a real geographic projection — a session's driving area is small
/// enough that this simple linear scaling doesn't visibly distort shape),
/// so a session's route is visible at a glance without a map tile
/// dependency/API key this app doesn't otherwise need (Fase 12 §24-26).
@visibleForTesting
class TrajectoryLayout {
  const TrajectoryLayout({required this.points});
  final List<Offset> points;
}

/// Pure geometry: converts raw lat/lon samples into a list of normalized
/// (0..1, 0..1) points preserving the route's shape — pulled out of the
/// painter so it's independently unit-testable.
@visibleForTesting
TrajectoryLayout computeTrajectoryLayout(List<DrivingSessionSample> samples) {
  final withFix = samples.where((s) => s.latitude != null && s.longitude != null).toList();
  if (withFix.length < 2) return const TrajectoryLayout(points: []);

  final lats = withFix.map((s) => s.latitude!).toList();
  final lons = withFix.map((s) => s.longitude!).toList();
  final minLat = lats.reduce((a, b) => a < b ? a : b);
  final maxLat = lats.reduce((a, b) => a > b ? a : b);
  final minLon = lons.reduce((a, b) => a < b ? a : b);
  final maxLon = lons.reduce((a, b) => a > b ? a : b);
  final latRange = (maxLat - minLat).abs() < 1e-9 ? 1.0 : maxLat - minLat;
  final lonRange = (maxLon - minLon).abs() < 1e-9 ? 1.0 : maxLon - minLon;

  final points = withFix
      .map((s) => Offset((s.longitude! - minLon) / lonRange, 1 - (s.latitude! - minLat) / latRange))
      .toList();
  return TrajectoryLayout(points: points);
}

class _TrajectoryPainter extends CustomPainter {
  _TrajectoryPainter({required this.samples, required this.color});

  final List<DrivingSessionSample> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = computeTrajectoryLayout(samples);
    if (layout.points.length < 2) return;

    const margin = 16.0;
    Offset toCanvas(Offset p) => Offset(margin + p.dx * (size.width - margin * 2), margin + p.dy * (size.height - margin * 2));

    final path = Path()..moveTo(toCanvas(layout.points.first).dx, toCanvas(layout.points.first).dy);
    for (final point in layout.points.skip(1)) {
      final canvasPoint = toCanvas(point);
      path.lineTo(canvasPoint.dx, canvasPoint.dy);
    }
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);

    canvas.drawCircle(toCanvas(layout.points.first), 5, Paint()..color = Colors.green);
    canvas.drawCircle(toCanvas(layout.points.last), 5, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(covariant _TrajectoryPainter oldDelegate) => oldDelegate.samples != samples;
}
