# Dashcam com duas câmeras — continuação (handoff)

Estado em 2026-11-13, para continuar o trabalho em outra máquina (por você ou pelo Claude Code).
Leia junto com o `CLAUDE.md` da raiz, que continua valendo.

## Onde está cada coisa

| Branch | Último commit | Conteúdo | Situação |
|---|---|---|---|
| `main` | `7ef37b4` | correção do OBD fase 0 (queda do link) | publicado |
| `fix/dashcam-preview-aspect` | `028198e` | **Etapa A**: preview da dashcam sem distorção, de borda a borda | publicado, **sem PR e sem merge** |
| `feature/dashcam-dual-camera` | este arquivo, sobre `49d7074` | Etapa A + **Fase 0 da Etapa B** (sonda) + este handoff | publicado, branch de trabalho |

Continue no `feature/dashcam-dual-camera`. Para a Etapa A chegar à `main`: abrir PR de
`fix/dashcam-preview-aspect` (ainda não foi aberto). Push e merge só com autorização do dono (CLAUDE.md §9).

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
   e `flutter test --no-pub` (**1584 testes passando** no `feature/dashcam-dual-camera`).
6. APK: `flutter build apk --debug --no-pub`. Se o build falhar em `compressDebugAssets` por arquivos
   ausentes, pare o daemon (`android\gradlew -p android --stop`), rode `flutter clean`, `pub get` e repita.

**Assinatura:** cada máquina tem sua chave de debug. Instalar por cima de um app instalado de outra
máquina falha com `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; é preciso desinstalar antes (apaga os dados
do app; a dashcam volta a ficar desativada e precisa ser ligada em Configurações > Dashcam).

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

## Próximos passos

1. **Fase 1 — seam de câmera, sem mudar comportamento.** O `DashcamService`
   (`lib/services/dashcam_service.dart`, ~6000 linhas) usa um `CameraController` do pacote `camera`
   diretamente. Introduzir uma interface (inicializar, iniciar gravação, parar, liberar, preview,
   eventos de evidência `videoProgress`/`recordingEnded`) e envolver o caminho atual nela. Critério:
   os 1584 testes continuam passando, nada muda no aparelho.
2. **Fase 2 — implementação "duas câmeras"** sobre a mesma interface, num canal nativo próprio
   (evolução do `DualCameraProbe.kt`), emitindo os mesmos sinais de evidência que o fork do plugin
   emite, para reaproveitar rotação de segmentos, timeouts, índice, cota e telemetria. Inclui: as
   opções em Configurações (`CameraSelection.both` já existe no modelo Hive, typeId 5; a câmera
   principal é um campo novo — com `defaultValue`, ver CLAUDE.md §6), o preview em PiP em tela cheia
   (reaproveitar `DashcamCameraSurface`/`fullBleed`), a religação ao girar, e o fim do fallback em
   `DashcamService._pickCamera` que hoje troca "both" pela traseira.
3. **Validação** no aparelho e numa viagem real: aquecimento, bateria, rotação de segmentos (o
   histórico do projeto tem um P1 de START atrasado 7–20 s após rotação), armazenamento.
4. Pelo CLAUDE.md §12 é tarefa **crítica** (câmera/dashcam, concorrência): revisão independente pelo
   Codex antes do merge na `main`.

## Pendências fora da dashcam

- OBD-II fase 0: a correção da queda de link está na `main` e no aparelho, mas ainda não foi testada
  no carro (Configurações > Diagnóstico > Teste do adaptador OBD-II; tirar o adaptador durante a
  leitura contínua deve gerar uma linha de erro só e devolver o botão "Conectar").
