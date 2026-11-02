/// Observable state of `DashcamSessionController` — drives the REC
/// indicator, the fullscreen preview's empty states, and the "Dashcam: ..."
/// line on the session-recording screen. Not persisted (contrast with
/// [DashcamConfig], which is); this is purely live, in-memory state.
enum DashcamStatus {
  /// [DashcamConfig.enabled] is off — the feature is switched off entirely,
  /// no camera hardware is touched.
  disabled,

  /// Enabled, but no driving session is currently active — the camera is
  /// not recording.
  idle,

  /// A session just started; the camera is being initialized/starting loop
  /// recording.
  initializing,

  /// Actively loop-recording during an active driving session.
  recording,

  /// A driving session wants Dashcam recording, but the camera is currently
  /// known to be unavailable (backgrounded and revoked by Android, or a
  /// native start/stop call timed out — see `DashcamService.cameraKnownUnavailable`'s
  /// own doc) and no recovery attempt is in flight yet. Distinct from
  /// [error]: this is an expected, self-recovering condition, not a failure
  /// requiring the user's "Tentar novamente" action, and distinct from
  /// [recording]: no video is actually being captured right now, however
  /// briefly. Added in Fase 16.2-R1 after an independent review demonstrated
  /// that, without it, `DashcamSessionController.status` could report
  /// [recording] while the camera was known-unavailable — a real, testable
  /// "false REC" gap (see that method's own doc).
  cameraUnavailable,

  /// The camera failed (init error, permission denied, storage full,
  /// hardware taken by another app, ...) — see the controller's own
  /// `errorMessage`. The driving session itself is unaffected (Fase 15's
  /// failure-isolation requirement).
  error,

  /// Fase 16.2-R4.3-R2.6.10: a session was stopped and its camera already
  /// released, but its telemetry file is still being finalized (the last
  /// samples written, the file closed) — e.g. a slow or hung disk. Not
  /// [idle]: that session is not finished yet, and a telemetry failure found
  /// while finishing it still turns this into [error]. A new session may start
  /// meanwhile (it uses its own file and the released camera).
  finalizing,
}

/// Fase 16.2-R4.4-HW-MIG-5-SIG-2: what the REC indicators may claim about the
/// current segment, apart from [DashcamStatus] — the session stays `recording`
/// through a rotation (and the preview stays mounted because of that), so this
/// could not be another status. Only [videoConfirmed] is shown as REC.
enum DashcamSegmentPresentation {
  /// No segment is being presented: the session is not recording, or it is
  /// being stopped.
  inactive,

  /// A rotation is ending the previous segment.
  transitioning,

  /// A START is in progress or returned, with no video confirmed yet. A
  /// recorder that started is not proof of video.
  startPending,

  /// The muxer accepted video of the current segment, and its end has not been
  /// observed. Not proof of continuous recording, image content or durability.
  videoConfirmed,

  /// The current segment ended by itself, with no stop requested.
  segmentEnded,
}

/// What to say instead of REC while [DashcamStatus.recording] holds.
String dashcamSegmentPresentationLabel(DashcamSegmentPresentation presentation) {
  switch (presentation) {
    case DashcamSegmentPresentation.inactive:
      return 'Encerrando gravação…';
    case DashcamSegmentPresentation.transitioning:
      return 'Trocando segmento…';
    case DashcamSegmentPresentation.startPending:
      return 'Iniciando segmento…';
    case DashcamSegmentPresentation.videoConfirmed:
      return dashcamStatusLabel(DashcamStatus.recording);
    case DashcamSegmentPresentation.segmentEnded:
      return 'Segmento encerrado inesperadamente';
  }
}

String dashcamStatusLabel(DashcamStatus status) {
  switch (status) {
    case DashcamStatus.disabled:
      return 'Desativado';
    case DashcamStatus.idle:
      return 'Pronto';
    case DashcamStatus.initializing:
      return 'Iniciando…';
    case DashcamStatus.recording:
      return 'Gravando';
    case DashcamStatus.cameraUnavailable:
      return 'Câmera indisponível';
    case DashcamStatus.error:
      return 'Erro';
    case DashcamStatus.finalizing:
      return 'Finalizando…';
  }
}
