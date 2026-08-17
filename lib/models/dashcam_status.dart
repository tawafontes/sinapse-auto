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

  /// The camera failed (init error, permission denied, storage full,
  /// hardware taken by another app, ...) — see the controller's own
  /// `errorMessage`. The driving session itself is unaffected (Fase 15's
  /// failure-isolation requirement).
  error,
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
    case DashcamStatus.error:
      return 'Erro';
  }
}
