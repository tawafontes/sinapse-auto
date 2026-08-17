/// Consumption profile controlling how aggressively the Telemetry Engine
/// throttles non-essential signal emission — never applied to
/// safety-relevant signals (see `TelemetryEngine`'s own doc: g-force is
/// never throttled, in every profile, since it must react as fast as the
/// accelerometer itself delivers regardless of battery posture).
enum PowerProfile { normal, economy, performance, dashcamReady }

String powerProfileLabel(PowerProfile profile) {
  switch (profile) {
    case PowerProfile.normal:
      return 'Normal';
    case PowerProfile.economy:
      return 'Economia';
    case PowerProfile.performance:
      return 'Performance';
    case PowerProfile.dashcamReady:
      return 'Pronto para Dashcam';
  }
}

String powerProfileDescription(PowerProfile profile) {
  switch (profile) {
    case PowerProfile.normal:
      return 'Equilíbrio entre precisão, atualização e consumo — recomendado para uso geral.';
    case PowerProfile.economy:
      return 'Reduz a frequência de atualização de velocidade/altitude/heading para economizar bateria. '
          'Não afeta segurança: aceleração G e inclinação continuam na frequência máxima do sensor.';
    case PowerProfile.performance:
      return 'Maior frequência de atualização e menor latência. O ganho real depende do hardware — '
          'o GPS do aparelho continua sendo o fator limitante para velocidade/altitude.';
    case PowerProfile.dashcamReady:
      return 'Prepara a arquitetura para uso simultâneo futuro da Dashcam (câmera + GPS + sensores + '
          'armazenamento). Não ativa gravação de vídeo nesta versão.';
  }
}
