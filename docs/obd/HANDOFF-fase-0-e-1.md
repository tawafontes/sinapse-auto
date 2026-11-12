# Handoff — OBD-II, fases 0 e 1 (Synapse Auto)

> **Para o agente que receber este arquivo:** é o prompt de entrada para continuar o trabalho de OBD-II do Synapse Auto em outra máquina. Leia este arquivo inteiro e depois o `CLAUDE.md` da raiz, que tem as regras do projeto e prevalece sobre qualquer coisa aqui. Responda ao dono **em português do Brasil**. Escrito em 12/11/2026, ao fim de uma sessão longa com o dono.

---

## 1. Como trabalhar com o dono (preferências confirmadas)

- **Instalar no celular, commit e push:** só quando ele pedir, a cada vez. Commits locais podem ser feitos ao fim de uma tarefa validada; `git push` só com pedido explícito (CLAUDE.md §9).
- **Uma branch só:** `main`. Ele não quer branches paralelas.
- **Dados do app no celular:** nunca desinstalar nem limpar. Instalar sempre com `adb install -r --user 0 <apk>`; o S23 tem um segundo usuário (150, Pasta Segura), então `pm list packages` também precisa de `--user 0`.
- **`scratchpad/`:** nunca entra em `git add`. Não mexer no `.gitignore` sem avisar.
- **Dependência nova:** propor e explicar antes de adicionar (CLAUDE.md §10).
- **Tarefa crítica** (telemetria, sensores, `DashboardSensorStreams`, `TelemetrySnapshot`, Hive, concorrência; CLAUDE.md §12): análise do Codex antes, revisão independente depois. **A fase 1 é crítica.**
- **Estilo das respostas:** ele gosta de propostas desenhadas e de discutir antes de codificar ("vamos discutir antes de codificar"). Quando ele aprova, executa direto.

## 2. Estado do repositório

- **Remoto:** `origin` = https://github.com/tawafontes/sinapse-auto.git, branch `main`.
- **Commits desta sessão, antes da fase 0:**
  - `395496b` — textos do framework em pt-BR (`flutter_localizations`);
  - `a197e89` — Meu veículo, Abastecimentos, widget de abastecimento e relatório de consumo;
  - `3afce08` — layout próprio em paisagem (grade 8×3, campos Hive 5–7 em `SensorWidgetConfig`);
  - `0e1ad8f` — híbridos e recargas de plug-in;
  - `78752e2` — nome "Synapse Auto" no launcher do Android.
- **Fase 0:** o commit que acompanha este arquivo traz a ferramenta (seção 4).
- **Pendente de processo:** revisão do Codex de todas as mudanças de persistência acima (veículo, abastecimentos, paisagem, híbridos). O dono sabe; fazer antes ou junto da análise da fase 1.
- **Verificação:**
  - `flutter analyze --no-pub lib test` (sem caminhos, a análise trava porque varre `scratchpad/` e `third_party/`);
  - `flutter test --no-pub` (~1570 testes, ~2 min).

## 3. Decisões do projeto OBD-II (fechadas com o dono)

**Hardware e carro**
- Adaptador: **Vgate iCar Pro, ELM327 v2.3, Bluetooth 3.0 (Classic SPP/RFCOMM, não BLE)**. Nome no pareamento provavelmente "V-LINK"; PIN 1234 ou 0000 (não confirmado).
- Carro do dono: **GWM Haval H6 PHEV19** (híbrido plug-in, gasolina; bateria LFP de 313 V × 61 Ah ≈ 19,1 kWh nominais; autonomia elétrica INMETRO 73 km). Ele roda **só no elétrico na cidade**; o motor a combustão liga quando a bateria acaba (no painel, ~2 km de autonomia elétrica) ou no modo HEV com reserva "Forçada".
- Celular de teste: Samsung Galaxy S23 Ultra (SM-S918B, Android 17, serial `RQCW809TSSP`). O relógio do celular está em UTC−5.

**Arquitetura e regras**
- **Ponte nativa própria em Kotlin**, sem plugin novo. Já existe em `android/app/src/main/kotlin/.../ObdBridge.kt`.
- **Permissões:** só `BLUETOOTH_CONNECT` (Android 12+), mais `BLUETOOTH`/`BLUETOOTH_ADMIN` com `maxSdkVersion=30`. Sem varredura, sem localização para Bluetooth: o pareamento é feito nas configurações do Android e o app só lista os aparelhos já pareados.
- **Sensores da fase 1:** rotação (`010C`), temperatura do motor (`0105`), bateria (`ATRV` / `0142`), carga do motor (`0104`). Conta-giros como estilo novo.
- **Apagar códigos (modo 04):** oferecido só no relatório de Diagnóstico (fase 3), com o carro parado, explicação e confirmação. **A fase 0 nunca envia modo 04.**
- **Relatórios:** ficam no menu próprio **Configurações → Veículo** (Meu veículo, Abastecimentos, Relatórios; a conexão OBD entra aqui na fase 1).

**Dinâmica de conexão** (aprovada: "está ótimo do jeito que vc desenhou")
- Pareamento uma vez em **Veículo → Adaptador OBD-II**: a permissão só é pedida ali e o app guarda o endereço do adaptador.
- **Conexão automática e silenciosa** ao abrir o app e ao voltar para ele, com o adaptador conhecido. Há uma **chave para desligar** e um **botão Conectar/Desconectar** no menu.
- **Estados:**
  - Sem adaptador;
  - Conectando…;
  - Adaptador conectado, aguardando o carro (o ELM respondeu, a ECU não: ignição desligada);
  - Recebendo dados;
  - Reconectando, com backoff de 5 s, 15 s, 30 s e 60 s.
- **Widgets OBD ficam sempre no painel e mostram o estado** ("Configurar adaptador", "Conectando…", "Ligue o carro", "Seu carro não informa este dado", valor ao vivo). Nunca aparecem e somem. Depois da primeira conexão, o "+" marca os PIDs que o carro não suporta.
- **Ícone OBD na barra do topo**, ao lado do REC: cinza desligado, piscando conectando, âmbar aguardando o carro, verde recebendo, vermelho erro. Um toque abre o menu do adaptador.
- **Segundo plano:** a conexão continua **só enquanto uma sessão de condução grava**; fora disso, o app solta o adaptador.
- **Iniciar a sessão sozinho:** chave em Configurações, **desligada por padrão**. Quando ligada, "carro respondendo" (OBD) inicia a sessão de condução.
- O `ObdService` é **dono único** da conexão, vive no `DrivingSessionHost` (escopo do app) e é a segunda fonte física, alimentando o `DashboardSensorStreams`. Valem a regra do pipeline único (CLAUDE.md §4: consumidores ouvem `DashboardSensorStreams.snapshot`) e campos opcionais de veículo no `TelemetrySnapshot`.

**Já implementado e publicado** (não refazer)
- **Meu veículo:**
  - perfil único com propulsão (Combustão / Híbrido / Plug-in), combustível, tanque, km/L de referência por combustível e combustível padrão;
  - no plug-in: bateria útil, autonomia elétrica de referência e preço padrão do kWh;
  - chave "Atualizar referências com as minhas medições", ligada por padrão.
- **Abastecimentos e recargas:** linha do tempo única, hodômetro sugerido, total calculado, métodos tanque cheio a tanque cheio e de recarga.
- **No plug-in:**
  - o % do painel na recarga é sempre pedido; o kWh do carregador é opcional, com margem fixa de 10%;
  - "Usou combustível desde o último registro?" pede a autonomia a combustão do painel; a queda dá os km a combustão;
  - o km/kWh só é medido em intervalos sem combustível; recargas curtas se somam até 30%.
- **Widget "Abastecimento" no "+"** e relatório de Consumo, com a versão plug-in.
- **Fase 2 vai melhorar a separação:** com o OBD, carro andando com o motor a 0 rpm é km elétrico. Isso substitui a estimativa feita pela autonomia do painel.

**Hive:**
- **Registro de typeIds:** comentário em `lib/models/sensor_widget_config.dart`; **próximo livre: 22**.
- **`SensorType`:** adapter escrito à mão; o byte 5 é o `refuel`. Novos sensores OBD usam os bytes 6+.
- **`DisplayStyle`:** o campo 9 é o `refuelSummary`. Estilos novos usam 10+ (o conta-giros, por exemplo).
- **`VehicleProfile`:** campos 0–11 ocupados. A cilindrada fica reservada como campo 12, só se a fase 0 mostrar que o carro não tem MAF (`0110`).

## 4. Fase 0 — o que existe e como rodar

**Código** (somente leitura no carro; não mexe no painel, no pipeline nem no Hive):
- `android/app/src/main/kotlin/com/synapseauto/synapse_auto/ObdBridge.kt`:
  - canal `com.synapseauto.synapse_auto/obd`, com os métodos `bondedDevices`, `connect(address)`, `send(command, timeoutMs)` e `disconnect`;
  - uma thread só;
  - na conexão, tenta socket seguro, inseguro e `createRfcommSocket(1)`, e registra qual funcionou;
  - o `send` lê até o prompt `>` ou até o timeout.
- `lib/services/obd/obd_bridge.dart`: interface `ObdBridge` e `MethodChannelObdBridge`.
- `lib/services/obd/elm327_decode.dart`: decodificação pura (linhas, erros, bytes, mapa de PIDs, VIN multi-frame, DTCs, valores legíveis).
- `lib/services/obd/obd_phase0_runner.dart`, a sequência:
  1. configuração: `ATZ`, `ATE0 ATL0 ATS0 ATH0`, `ATI`, `AT@1`, `ATRV`, `ATSP0`;
  2. protocolo e mapa: `0100` (busca), `ATDP`/`ATDPN`, e a cadeia de bitmaps `0120…01C0`, enquanto o bitmap anterior anunciar o próximo;
  3. estado e PIDs de interesse: `0101`, depois `51 5B 2F 42 05 0C 0D 04 10 0B` se suportados;
  4. chassi e códigos: `0900`/`0902` (VIN), `03 07 0A` (DTCs);
  5. tempo: 20× `010C` para medir latência, depois multi-PID (`010C0D…`);
  6. modos extras: `probeCar()` (`ATRV` + `0100`) para os testes de ignição, e `runLive()` com rápidos em todo ciclo, lentos a cada 10 ciclos e `ATRV` a cada 20.
- `lib/screens/settings/obd_phase0_screen.dart`, acessada por **Configurações → Diagnóstico → "Teste do adaptador OBD-II"**:
  - pede `Permission.bluetoothConnect` e lista os pareados, pré-selecionando nomes com obd/v-link/vgate/icar/elm;
  - botões: Conectar, 1. Sequência, 2. Contínua 5 min, Parar, Verificar carro;
  - chips de nota: ignição desligada/ligada, motor ligado, andando, modo EV, motor a combustão ligou;
  - grava a transcrição.
- `test/obd_phase0_test.dart`: decodificação e um carro falso roteirizado, que também confere que nada fora de AT/01/03/07/09/0A é enviado. A tela também é testada.

**Roteiro no carro (com o dono):**
1. Adaptador na tomada OBD (embaixo do painel, lado do motorista) e ignição ligada. Parear nas configurações de Bluetooth do Android.
2. Instalar o APK de debug: `flutter build apk --debug`, depois `adb install -r --user 0 build/app/outputs/flutter-apk/app-debug.apk`.
3. Na tela de teste:
   1. Conectar → **1. Sequência**, com o carro parado e a ignição ligada.
   2. Nota "ignição desligada" → Verificar carro. Nota "ignição ligada" → Verificar carro.
   3. Com o motor ligado e o carro andando: **2. Contínua 5 min**. O motorista não mexe no celular; alguém no passageiro marca as notas.

**Pegar a transcrição** (APK de debug):
```
adb exec-out run-as com.synapseauto.synapse_auto sh -c 'ls app_flutter/obd_phase0'
adb exec-out run-as com.synapseauto.synapse_auto cat app_flutter/obd_phase0/<arquivo>.txt > phase0.txt
```
No Windows/Git Bash, use `MSYS_NO_PATHCONV=1` antes do `adb`. A transcrição tem o **VIN do carro do dono**: guardar em `scratchpad/` (não versionado) ou mascarar o VIN antes de versionar qualquer evidência.

**O que analisar na transcrição para decidir a fase 1:**
- método de conexão que funcionou e tempo para conectar;
- versão do ELM, protocolo (`ATDPN`; espera-se CAN 11/500, `6`) e resultado da busca;
- mapa de PIDs suportados: confirmar `0C 05 04 42`, ver se há MAF (`10`) ou só MAP (`0B`), nível de combustível (`2F`), tipo de combustível (`51`) e bateria híbrida (`5B`);
- VIN legível? Marca pelo WMI (caracteres 1–3), offline;
- latência por PID e taxa real; se o multi-PID é aceito e com quantos bytes; plano de polling (rápido/médio/lento);
- comportamento com a ignição desligada: o adaptador responde? `ATRV`? `0100` vira `UNABLE TO CONNECT` / `NO DATA`? Ele dorme? Tempo para voltar a responder ao religar;
- PHEV: rotação 0 enquanto anda no modo EV, e o que muda quando o motor a combustão liga (nota do passageiro).

Registrar a análise e pedir ao dono para confirmar o plano da fase 1 antes de codificar.

## 5. Fase 1 — o que construir (tarefa crítica)

**Fluxo obrigatório** (CLAUDE.md §12): análise do Codex → implementação → revisão independente do Codex → ajustes → validação → commit. Validação no carro real (CLAUDE.md §8).

**Escopo:**
1. **`ObdService`:** dono único do link, criado no `DrivingSessionHost`, com a máquina de estados da seção 3, reconexão com backoff e fila de comandos numa thread nativa (reaproveitar o `ObdBridge.kt` e evoluí-lo: leitor contínuo, sem polling de `available()`, se a fase 0 mostrar necessidade). Começar pelo método de conexão que funcionou na fase 0.
2. **Polling por prioridade:** rápido (RPM, carga), médio e lento (temperatura e bateria a cada 5–10 s), ajustado pela latência medida. Multi-PID se a fase 0 provar que funciona.
3. **Integração:** os sinais OBD entram no `DashboardSensorStreams`, com campos opcionais no `TelemetrySnapshot`. Nenhum consumidor novo abre conexão própria.
4. **Tela Veículo → Adaptador OBD-II:**
   - escolher o pareado (com a permissão pedida ali);
   - chave de conexão automática;
   - Conectar/Desconectar;
   - estado e diagnóstico, incluindo PIDs suportados e protocolo.
5. **Ícone OBD na barra do topo,** com os estados da seção 3.
6. **Widgets no "+":** Rotação (estilo novo de conta-giros), Temperatura do motor, Bateria (V) e Carga (%), cada um mostrando o estado da conexão quando não há dado. `SensorType` com bytes 6+, `DisplayStyle` com campos 10+, metadados e cores.
7. **Chave "Iniciar sessão quando o carro ligar":** em Configurações, desligada por padrão.
8. **Testes:** o "carro falso" a partir da transcrição real da fase 0, cobrindo adaptador desligado, ignição desligada, queda no meio da viagem e reconexão.

**Fases seguintes** (para contexto, não fazer agora):
- **Fase 2:** leituras OBD gravadas na sessão (Hive, caixa lazy por sessão, apagada com a sessão), consumo por MAF/MAP, relatório de Viagens e separação real dos km elétricos no PHEV.
- **Fase 3:** Diagnóstico (DTCs com descrição em português, freeze frame, apagar códigos com confirmação, ícone da luz de injeção).
- **Fase 4:** velocidade do OBD ajudando o GPS no `TelemetryEngine`, alertas do motor no `EventDetectionEngine` e marcha estimada.

## 6. Armadilhas já conhecidas neste projeto

- **Arquivos com CRLF:** muitos arquivos do repositório têm CRLF. Prefira a ferramenta Edit; com `perl -0pi`, use `\r?\n`.
- **Perl:**
  - em substituições, `$'` vira o "resto do arquivo": cuidado com `R$ '` dentro do replacement;
  - `s{}{}` com chaves desbalanceadas no replacement quebra.
- **`build_runner`:** `dart run build_runner build --delete-conflicting-outputs` mostra um SEVERE de parse em `lib/services/dashcam_storage_quota.dart` (elemento null-aware num set, analisador antigo do `hive_generator`), mas gera os `.g.dart` normalmente. `lib/models/driving_session.g.dart` aparece modificado sem diff de conteúdo (só timestamp): não commitar.
- **Hive em testes de widget:**
  - use caixas em memória (`Hive.openBox(name, bytes: Uint8List(0))`) para os saves não travarem no `FakeAsync`;
  - a persistência real (abrir de novo do disco) fica em testes `test()` com diretório temporário;
  - um adapter "formato antigo" com `override: true` prova a compatibilidade de campos novos.
- **Testes do app inteiro** (`test/support/app_harness.dart`): um teste por arquivo.
- **adb no Windows:**
  - `/c/Users/<user>/AppData/Local/Android/sdk/platform-tools/adb.exe`, com `MSYS_NO_PATHCONV=1`;
  - para `install`, passe o caminho Windows (`cygpath -w`).
- **Proposta completa:** a página do dono, com todas as decisões e diagramas, está em https://claude.ai/artifact/TkPxZw719nUoJ4cjDQZ69g. É privada; se você não conseguir abrir, este arquivo tem o essencial.
