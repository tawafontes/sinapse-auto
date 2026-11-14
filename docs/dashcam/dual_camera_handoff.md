# Dashcam com duas câmeras — continuação (handoff)

Estado em 2026-11-14. Leia junto com o `CLAUDE.md` da raiz, que continua valendo.

## Onde está cada coisa

Tudo está na **`main`**: a Etapa A, a Fase 0 da Etapa B (sonda) e a **Etapa B implementada** (commit
`6fe7213`, seção "Etapa B — implementação"). As branches `fix/dashcam-preview-aspect` e
`feature/dashcam-dual-camera` foram juntadas na `main` em 2026-11-13 (fast-forward) e não têm mais
nada próprio; o PR da Etapa A não é mais necessário. O dono trabalha numa branch só (`main`).

## Preparar a outra máquina

O projeto foi criado com **Flutter 3.44.7** (`.metadata`, revisão `84fc5cb`). Não use o stable mais novo:
o 3.50 exige Gradle 9.3.1 (o projeto usa 9.1.0), muda 8 pacotes do `pubspec.lock` e deixa testes instáveis.

1. Flutter 3.44.7: `git clone https://github.com/flutter/flutter.git` e `git checkout 3.44.7`; `bin` no PATH.
2. JDK 17 (o AGP 9 exige Java 17+). Nesta máquina: Temurin 17 via `winget install EclipseAdoptium.Temurin.17.JDK`.
3. Android SDK: command-line tools + `platform-tools`, `platforms;android-36`, `build-tools;36.0.0`,
   `ndk;28.2.13676358`; aceitar as licenças; `JAVA_HOME` e `ANDROID_HOME` definidos;
   `flutter config --android-sdk <sdk> --jdk-dir <jdk>`.
4. No repositório: `flutter pub get --enforce-lockfile` (o lockfile deve ficar intacto).
5. Verificação: `flutter analyze --no-pub lib test` (só 2 `info` antigos de `prefer_initializing_formals`)
   e `flutter test --no-pub` (**1616 testes passando** na `main` em 2026-11-14; ver "Testes instáveis conhecidos").
6. APK: `flutter build apk --debug --no-pub`. Se o build falhar em `compressDebugAssets` por arquivos
   ausentes, pare o daemon (`android\gradlew -p android --stop`), rode `flutter clean`, `pub get` e repita.

**Assinatura:** cada máquina gera sua chave de debug. Instalar por cima de um app instalado de outra
máquina falha com `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Para não precisar desinstalar (o que apaga os
dados do app), copie `%USERPROFILE%\.android\debug.keystore` da máquina que instalou o app. Se for
preciso desinstalar, faça antes um backup dos dados pelo `run-as` (o app é de debug):
`adb exec-out run-as com.synapseauto.synapse_auto sh -c 'cd /data/data/com.synapseauto.synapse_auto && tar -cf - --exclude=app_flutter/flutter_assets app_flutter files shared_prefs' > backup.tar`
e restaure com `adb push` + `run-as … tar -xf`. Guarde o backup em `scratchpad/` (fora do git).

Aparelho de validação: Galaxy S23 Ultra, SM-S918B, Android 17. Instalação: `adb install -r --user 0 <apk>`.
Log: `adb logcat -v time flutter:V AndroidRuntime:E '*:S'`; as linhas úteis começam com
`dashcam preview:` e `dual camera probe:`.

## Etapa A — concluída

Problema: o preview da dashcam esticava a imagem. Causa: `CameraPreview` dentro de `StackFit.expand`
(o `AspectRatio` dele era ignorado) e, gravando, orientado pela orientação do início do segmento,
enquanto o plugin CameraX corrige pela orientação atual.

Solução (`lib/widgets/dashcam/dashcam_preview_view.dart`): `DashcamCameraSurface` no lugar do
`CameraPreview` — quadro inteiro, em proporção, faixas pretas, pela orientação atual. A tela cheia
genérica ganhou `fullBleed` (`sensor_fullscreen_screen.dart`), usado só pela dashcam: sem margem e
sem SafeArea; a dashcam pinta o próprio fundo (preto com câmera, cor do tema parada).
Validado no aparelho: 9:16 em retrato, 16:9 nas duas paisagens, sem moldura branca.

Limitação conhecida (não alterada): com uma câmera, o arquivo fixa a orientação no início de cada
segmento; girar no meio do segmento só muda o arquivo no segmento seguinte.

## Etapa B — decisões do dono

- Configurações: seletor **Traseira | Frontal | Ambas** (exibir e gravar). "Ambas" só aparece se o
  aparelho suporta câmeras simultâneas (`getAvailableConcurrentCameraInfos()` com back + front);
  senão fica escondida (convenção do app: esconder, nunca falhar em silêncio).
- Com "Ambas": **PiP** — câmera principal no quadro inteiro, a outra com **1/3** do tamanho no
  **canto inferior direito**. Lado a lado / empilhado foram testados e **rejeitados**.
- Opção em Configurações para escolher a **principal**: traseira (com PiP da frontal, padrão) ou
  frontal (com PiP da traseira).
- **Um único arquivo** composto, **uma trilha de áudio**.
- Frontal **sem espelho** (o texto sai legível; o dono confirmou que está correto assim).
- Resolução reduzida no modo "Ambas" é aceitável (sem 4K).
- **Rotação durante a gravação: acompanhar na hora** — fechar o segmento e religar na nova
  orientação, aceitando ~1 s sem vídeo por giro.

## Etapa B — Fase 0 (sonda) e o que ela provou

Ferramenta só de diagnóstico: Configurações > Diagnóstico > **Teste de câmeras simultâneas**
(`DualCameraProbe.kt`, `lib/services/dual_camera/dual_camera_probe_bridge.dart`,
`lib/screens/settings/dual_camera_probe_screen.dart`). Não é usada pela dashcam. Use com a dashcam parada.

Medido no SM-S918B:

- A composição back + front liga nas duas orientações (CameraX 1.6.2, `ConcurrentCamera` +
  `CompositionSettings`, um `Preview` e um `VideoCapture` compartilhados = um encoder, um arquivo).
- Vídeo 1280×720 (paisagem) / 720×1280 (retrato); preview fixado em 16:9 para bater com o vídeo
  (sem isso ele saía 3:4, 1080×1440, outro enquadramento).
- PiP no canto inferior direito: `offset(x = 1 - 1/3 - 0.05, y = -(1 - 1/3 - 0.05))`,
  `scale(1/3, 1/3)` — **y negativo é embaixo**. A câmera do PiP é a **segunda** da lista do
  `bindToLifecycle` (desenhada por cima).
- `CompositionSettings` só oferece posição, escala e opacidade: sem borda, recorte, rotação por
  câmera ou espelhamento (isso exigiria `camera-effects`, dependência nova — não proposto).
- A orientação do quadro composto é fixada **no bind**. Girar exige religar: preview volta em
  93–268 ms; gravando, ~1 s sem vídeo entre o clipe que fecha e o que abre.
- Em modo concorrente o CameraX **recusa `unbind(useCase)`**: é preciso `unbindAll()`.
- O CameraX é um singleton do processo, compartilhado com o plugin `camera_android_camerax` da
  dashcam: modo de duas câmeras e o plugin não podem estar ligados ao mesmo tempo.

`build.gradle.kts` declara `camera-core`, `camera-lifecycle` e `camera-video` 1.6.2 só para o Kotlin
do app compilar; são os mesmos módulos do plugin, e o `camera-video` continua resolvendo para o build
com o patch F2 (`third_party/androidx_camera_video_f2`) — confirmado com
`gradlew :app:dependencies --configuration debugRuntimeClasspath`.

## Etapa B — implementação (2026-11-14)

Por decisão do dono, implementada **sem** a análise prévia nem a revisão independente do Codex
(CLAUDE.md §12) — a revisão fica pendente, assim como a validação no aparelho e numa viagem.

**Mudança de abordagem em relação à "Fase 1 — seam de câmera" planejada acima.** Em vez de uma
interface por cima do `CameraController` dentro do `DashcamService` (~6000 linhas, onde o controller
é a identidade de dezenas de decisões de concorrência já validadas no aparelho), o modo "Ambas"
entra **abaixo** dele, pela emenda que o projeto já usa nos testes: o `CameraPlatform`.

- `lib/services/dual_camera/dashcam_camera_platform.dart` — `DashcamCameraPlatform`, o
  `CameraPlatform` do app (instalado em `main()`, só no Android). As câmeras do plugin vão para o
  plugin sem mudança; a câmera **composta** é mais uma `CameraDescription`
  (`synapse_dual:back_primary` / `synapse_dual:front_primary`, `lensDirection: external`), oferecida
  só onde o aparelho roda traseira + frontal juntas. Ela reporta a mesma `RecordingEvidence` do fork
  do plugin (um slot, o token do START, progresso de vídeo, Finalize com o erro). Para o
  `DashcamService` é um `CameraController` como outro qualquer: START/STOP, rotação de segmentos,
  timeouts, índice, cota e telemetria são **reaproveitados, não duplicados**.
- `DualCameraRecorder.kt` — evolução de produção da sonda: concorrente com composição, PiP 1/3 no
  canto inferior direito, 720p, um arquivo, uma trilha de áudio (se o microfone estiver permitido),
  `setTargetRotation` no bind.
- **Rotação:** parado, um giro religa na hora; gravando, o giro chama
  `DashcamService.rotateSegmentNow()` (o mesmo caminho do timer de segmento, com todas as suas
  proteções) e o START seguinte religa na orientação nova — a decisão do dono (~1 s sem vídeo).
- `_pickCamera`: "Ambas" escolhe a composta; sem suporte, a traseira, como antes.
- Configurações: "Ambas" aparece só onde há suporte; com ela, a **câmera principal**
  (`DashcamConfig.dualFrontPrimary`, campo 6, `defaultValue: false` = traseira).
- `camera_platform_interface` passou de `dev_dependencies` para `dependencies` (mesmo pacote e
  versão, já transitivo pelo `camera`; o lockfile só troca "direct dev" por "direct main").

Testes: `test/dashcam_dual_camera_test.dart` (plataforma com um `CameraController` real, e o
`DashcamService` real gravando na composta e trocando de segmento ao girar) e
`test/dashcam_dual_settings_test.dart` (tela e persistência, incluindo um registro no formato antigo).
Suíte: **1616 testes passando** no Flutter 3.44.7.

### Validado no aparelho (SM-S918B, 2026-11-14)

- As duas câmeras ligam em "Ambas" (preview 1920×1080, vídeo 720p) e a imagem composta aparece
  **sem distorção, em pé, em retrato e nas duas paisagens** (confirmado pelo dono).
- Girar gravando fecha o segmento na hora e o seguinte é gravado na orientação nova — conferido
  dentro dos arquivos: segmentos alternando 720×1280 e 1280×720, conforme os giros.
- Correção encontrada no aparelho: o plugin só observa a orientação do aparelho depois de abrir uma
  câmera própria, o que nunca acontece em "Ambas"; a dashcam ficava em retrato após um giro. Agora o
  `DualCameraRecorder.kt` informa a rotação da tela (`DisplayListener`).

### O que ainda validar

- Reproduzir os clipes em Gravações com a telemetria; trocar a câmera principal (PiP invertido).
- Viagem real: aquecimento, bateria, rotação de segmentos (histórico de START atrasado 7–20 s
  após rotação), armazenamento e cota.

### Roteiro original de validação

1. Configurações > Dashcam: "Ambas" aparece no S23; a câmera principal muda o PiP.
2. **Preview:** a imagem composta aparece em pé, sem distorção, em retrato e nas duas paisagens.
   A rotação do preview (`_DualPreview`) segue a fórmula da sonda (textura girada por
   `rotationDegrees`, descontado o giro do aparelho, porque o `DashcamCameraSurface` gira por ele) —
   é o ponto mais provável de ajuste. O log mostra `dual camera: open …` e `dual camera: rebound …`.
3. Gravar uma sessão, girar o celular gravando: um segmento fecha, o seguinte abre na nova
   orientação, ~1 s sem vídeo; os clipes aparecem em Gravações e tocam com a telemetria.
4. Viagem real: aquecimento, bateria, rotação de segmentos (histórico de START atrasado 7–20 s
   após rotação), armazenamento e cota.

## Testes instáveis conhecidos

- `test/dashcam_storage_session_test.dart`, X513 ("a quota pass completes while the camera FIFO is
  held by a native STOP…"): falhou 2 vezes em 6 rodando sozinho numa cópia limpa da `main` de
  2026-11-14 (antes de qualquer mudança da Etapa B), esperando o gatilho `settingChanged` e
  recebendo `publication`. É fragilidade de tempo do teste, não defeito do produto observado —
  documentado aqui (CLAUDE.md §7), não corrigido.

## Pendências fora da dashcam

- OBD-II: a fase 0 foi testada no carro (VW Nivus, 2026-11-13) e a fase 1 foi implementada (ver
  `docs/obd/`); falta a rodada no Haval e a validação da fase 1 no carro.
