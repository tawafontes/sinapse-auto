# OBD-II fase 1 — rascunho para discussão

> **Status: rascunho.** Não é um plano aprovado, e nenhum código foi escrito. A fase 1 é **tarefa crítica** (CLAUDE.md §12): este texto serve de entrada para a análise do Codex e para a decisão do dono. Parte do conteúdo depende da rodada no **Haval**; esses pontos estão marcados como **[Haval]**.
>
> Base: `HANDOFF-fase-0-e-1.md` (decisões fechadas, seções 3 e 5) e `fase-0-resultados-nivus.md`.

## 1. Peças e onde ficam

```
ObdBridge.kt (nativo, uma thread, um socket)
   ↑ MethodChannel com.synapseauto.synapse_auto/obd
ObdBridge (Dart, interface)  ← FakeObdBridge nos testes (roteirizado a partir das transcrições reais)
   ↑
ObdService  (ChangeNotifier; dono único do link; vive no DrivingSessionHost)
   ├─ estado da conexão (máquina abaixo) ─→ ícone do topo, tela do adaptador, widgets
   ├─ Stream<ObdReading> ─→ DashboardSensorStreams (2ª fonte física)
   └─ "carro respondendo" ─→ início automático de sessão (chave, desligada por padrão)
DashboardSensorStreams.snapshot  (TelemetrySnapshot ganha campos opcionais de veículo)
   → widgets OBD, DrivingSessionRecorder (fase 2), EventDetectionEngine (fase 4)
```

- O `ObdService` é criado no `DrivingSessionHost` (factory) e descartado no `dispose()` dele, **antes** do `sensorService`.
- O `DashboardSensorStreams` recebe o `ObdService` como dependência opcional (`obd: ObdService?`), para os testes atuais continuarem passando sem ele.
- Nenhum outro componente fala com o `ObdBridge`. **Exceção de diagnóstico:** a tela da fase 0. A proposta é que ela passe a usar o link do `ObdService`, num "modo exclusivo" que pausa o polling, em vez de abrir uma conexão própria. Assim ela não briga pelo socket.

## 2. Máquina de estados

| Estado | Entra quando | Ícone | Widgets mostram |
|---|---|---|---|
| `noAdapter` | nenhum endereço salvo | cinza | "Configurar adaptador" |
| `off` | chave de conexão automática desligada ou o usuário tocou em Desconectar | cinza | "OBD desligado" |
| `connecting` | abriu o app / voltou ao app / tocou em Conectar | cinza piscando | "Conectando…" |
| `waitingForCar` | o ELM respondeu (`ATZ`/`ATRV`), mas `0100` dá `NO DATA`/`UNABLE TO CONNECT` | âmbar | "Ligue o carro" |
| `receiving` | `0100` respondeu e o polling está rodando | verde | valor ao vivo ou "Seu carro não informa este dado" |
| `reconnecting(n)` | o socket caiu (`closed`) ou houve N timeouts seguidos | vermelho / piscando | **último valor com a borda em vermelho** (decisão do dono, seção 11) |

- **Backoff:** 5 s → 15 s → 30 s → 60 s (fica em 60 s). Zera ao chegar em `receiving`.
- **Em `waitingForCar`:** repetir `0100` a cada ~3 s, **sem derrubar o socket**. No Nivus (rodada 2), o adaptador e o link Bluetooth ficaram de pé por mais de 4 min com o carro desligado, e as ECUs voltaram a responder menos de 2 s depois de ligar a ignição. **[Haval]** Confirmar o mesmo comportamento.
- **`receiving` ≠ motor ligado:** com só a ignição, as ECUs já respondem. O estado continua `receiving`, e é a rotação (0 rpm) que diz que o motor está parado. O início automático de sessão (seção 7) não deve disparar só com a ignição ligada. **[Haval]** Definir o gatilho com os dados do PHEV, onde a rotação 0 é normal andando no modo EV.
- **Ciclo de vida:** `AppLifecycleState.paused`, sem sessão gravando → solta o link (`disconnect`). Com sessão gravando, o link continua. `resumed` → `connecting`, se a conexão automática estiver ligada.
- Toda transição passa por um único método (`_transition`), registrada num histórico curto que aparece na tela do adaptador.

## 3. Inicialização do link

Ordem baseada na fase 0. No Nivus, todos os comandos responderam em menos de 50 ms, exceto `ATZ` (~1 s):

**A sequência inteira roda a cada conexão e a cada reconexão.** No Nivus, o adaptador que perdeu a energia voltou com os padrões de fábrica: eco, espaços e endereçamento funcional.

1. `connect`: começar pelo método salvo (no Nivus, `secure`). Se falhar, cair para as outras duas formas e salvar a que funcionou.
2. `ATZ` (timeout de 2 s) → `ATE0 ATL0 ATS0 ATH0` → `ATSP0` → `ATRV` (timeout de ≥ 1 s: com o carro desligado ele leva até ~500 ms).
3. `0100` no endereço funcional: se responder → descobrir o motor; se der `NO DATA`/`UNABLE` → `waitingForCar`.
4. **Descobrir o motor:** `ATH1` + `0100`, guardar o CAN id que respondeu com o maior bitmap (no Nivus, `7E8`), depois `ATSH` no endereço físico correspondente (`7E0`) e `ATH0`. Se o carro não aceitar o endereçamento físico, ficar no funcional e filtrar por `ATH1`.
5. No primeiro `receiving` com este adaptador e este carro: ler a cadeia de bitmaps (`0100`, `0120`, `0140`, …) **já endereçada ao motor** e salvar o **mapa de PIDs suportados** e o protocolo (`ATDPN`). Isso alimenta o "+" e o "Seu carro não informa este dado". No Nivus, sem o endereçamento, a primeira resposta veio da ECU errada, e o mapa saiu com 12 PIDs em vez de 23.

## 4. Polling

Plano inicial (o Nivus mostrou ~65 ms por pedido, com 1 ou 6 PIDs):

| Grupo | PIDs | Pedido | Período |
|---|---|---|---|
| Rápido | `0C` rotação, `04` carga (+ `0D`, `11` se suportados) | **um** multi-PID (`010C04…`) | ~500 ms (2 Hz, decisão do dono) |
| Lento | `05` temperatura, `42` tensão do módulo | um multi-PID | 5 s |
| Muito lento | `ATRV` | comando AT | 10 s |

- O snapshot já é limitado a ~5 Hz na cadência do GPS (`snapshotGpsCadenceGap`), então 2 Hz no rápido fica bem abaixo desse limite e deixa folga no adaptador e na bateria.
- **Multi-PID** só com PIDs que o mapa marca como suportados, no máximo 6 por pedido. Se o carro recusar o multi-PID, a resposta não traz todos os PIDs pedidos; nesse caso, cair para um PID por pedido e salvar essa limitação.
- **Fila:** os comandos são serializados no Dart (um pedido em voo por vez), e os pedidos do usuário (tela de diagnóstico) passam na frente do polling.
- **Timeout por pedido:** 500 ms; o p99 no Nivus foi 171 ms. **Três timeouts seguidos → `reconnecting`.** É essa a detecção principal de queda: no Nivus, com o adaptador puxado, o socket só acusou `Broken pipe` 6 s depois; antes disso, os pedidos simplesmente ficaram sem resposta. Com 3 × 500 ms, a queda aparece em ~1,5 s.
- **[Haval]** Ajustar os períodos pela latência real. Se o carro tiver o PID `5B` (bateria híbrida), ele entra no grupo lento.

### P1: duas ECUs respondem — resolvido

No Nivus, todo pedido do modo 01 recebe duas respostas (`7E8` motor e `7E9`), e a ordem muda entre rodadas. Com **`ATSH7E0`** só o motor respondeu (rodada 2). Decisão do dono: endereçar só o motor, o que também **reduz pela metade o tráfego** no barramento e na serial. Como o motor é descoberto, ver a seção 3, passo 4. **[Haval]** Confirmar os endereços.

## 5. Ponte nativa

- O `exchange` atual consulta o `available()` a cada 2 ms. No Nivus a latência ficou boa (p50 66 ms), então **não é preciso** trocar por um leitor contínuo na fase 1. A troca fica para quando houver evidência contrária.
- Mudanças propostas:
  - (i) `connect` aceita o método preferido;
  - (ii) `send` devolve se a resposta veio por timeout, o que já acontece;
  - (iii) avisar ao Dart que o link caiu (evento pelo canal), em vez de deixar o Dart descobrir no próximo `send`.

## 6. `TelemetrySnapshot` e `DashboardSensorStreams`

- Campos novos, todos opcionais (`null` = sem dado):
  - `engineRpm` (double?);
  - `engineCoolantC` (double?);
  - `engineLoadPercent` (double?);
  - `vehicleVoltage` (double?, do `ATRV`, ou do `0142` como reserva);
  - `obdLinkState` (enum, para os widgets mostrarem o estado sem consultar o serviço).
- Os dados OBD entram pelo caminho **limitado** (`emitThrottled`), como o GPS.
- **Validade:** cada valor guarda o horário em que foi lido. Se passar de ~3 s sem atualização (ou o link cair), o valor **continua** no snapshot, marcado como velho, e o widget o mostra com a borda em vermelho (decisão do dono, seção 11). Nenhum widget mostra um valor velho como se fosse ao vivo.
- **Vida do link independente do snapshot:** o `ObdService` conecta ao abrir o app, mesmo sem ninguém ouvindo o snapshot. O polling só roda com alguém ouvindo ou com uma sessão gravando. Ponto para o Codex: confirmar que isso não cria um segundo pipeline (o serviço só produz leituras, e quem monta o snapshot continua sendo o `DashboardSensorStreams`).

## 7. Interface

- **Configurações → Veículo → Adaptador OBD-II:**
  - escolher o aparelho pareado (a permissão `BLUETOOTH_CONNECT` é pedida aqui);
  - chave de conexão automática;
  - Conectar/Desconectar;
  - estado atual e histórico curto;
  - protocolo, versão do ELM e PIDs suportados.
- **Ícone OBD na barra do topo,** ao lado do REC, com os estados da seção 2. Um toque abre a tela do adaptador.
- **Widgets no "+":**
  - Rotação (estilo novo **conta-giros**, `DisplayStyle` 10);
  - Temperatura do motor;
  - Bateria (V);
  - Carga (%).
  - `SensorType` ocupa os bytes 6–9; os metadados e as cores ficam nos mapas existentes. Os widgets ficam sempre no painel e mostram o estado quando não há dado.
- **Chave "Iniciar sessão quando o carro ligar"** (desligada por padrão): na transição para `receiving`, se não houver sessão gravando, inicia uma.

## 8. Persistência (Hive)

- O endereço do adaptador, o método de conexão, a chave de conexão automática e a de início de sessão vão para preferências novas ou para o `AppSettings` existente. A decisão sai da revisão do registro de typeIds (próximo livre: 22).
- Mapa de PIDs suportados e protocolo, guardados por adaptador e VIN (hash), para não repetir a cadeia de bitmaps a cada conexão.
- Na fase 1 **nada** é gravado por sessão; isso é fase 2.

## 9. Testes

- `FakeObdBridge` que reproduz **as transcrições reais** (Nivus; depois o Haval), com cenários:
  1. adaptador desligado (`connect_failed`);
  2. ignição desligada (`NO DATA`/`UNABLE`) → `waitingForCar` → ignição ligada → `receiving` (o roteiro da rodada 2 do Nivus);
  3. queda no meio da viagem, como no Nivus: pedidos sem resposta → `reconnecting` em ~1,5 s → backoff 5/15/30/60 → o adaptador volta **com os padrões de fábrica** (eco/espaços) → a inicialização completa roda de novo → `receiving`;
  3b. duas ECUs respondendo em ordem variável: o mapa de PIDs e os valores vêm só do motor;
  4. timeouts em série;
  5. carro que recusa o multi-PID;
  6. PIDs não suportados → "Seu carro não informa este dado";
  7. app em segundo plano, com e sem sessão gravando.
- Testes dos widgets em cada estado e do snapshot com e sem `ObdService`.
- Validação no carro (CLAUDE.md §8): Haval e, se possível, Nivus.

## 10. Ordem sugerida de implementação

1. Ponte nativa (método preferido, evento de queda) + `ObdService` com a máquina de estados + `FakeObdBridge` + testes.
2. Polling com multi-PID e o mapa de suportados.
3. Campos no `TelemetrySnapshot` e integração no `DashboardSensorStreams`.
4. Tela do adaptador e ícone do topo.
5. Widgets e o conta-giros.
6. Início automático de sessão.
7. Revisão do Codex → ajustes → validação no carro → commit.

## 11. Decisões do dono (13/11/2026)

1. **P1 aprovado:** endereçar só o motor (`ATSH7E0`), com `ATH1` como diagnóstico. O passo de cabeçalhos (`ATH1` → `0100`/`010C` → `ATSH7E0` → `010C` → `ATSH7DF` → `ATH0`) já foi acrescentado ao fim da sequência da fase 0, para as próximas rodadas (Nivus e Haval).
2. **A tela da fase 0 será eliminada** quando os elementos da fase 1 estiverem funcionando e validados no carro. Até lá ela continua como está, e não precisa ganhar o "modo exclusivo" da seção 1. A tela do adaptador da fase 1 assume o diagnóstico.
3. **Polling rápido a 2 Hz** (rotação e carga a cada ~500 ms), não 4 Hz.
4. **Durante `reconnecting`** (e em qualquer falha do link com dado anterior), o widget mostra o **último valor** com a **borda em vermelho**, indicando falha ou alerta. Isso substitui o "último valor esmaecido" da seção 2 e muda a regra de validade da seção 6: o valor não vai para `null` depois de 3 s; ele continua no snapshot, marcado como velho (`obdStale`/horário da leitura), e é o widget que pinta a borda.

## 12. Implementação (14/11/2026) — tudo o que não depende do Haval

> Implementado sem a análise prévia do Codex, por decisão do dono ("a auditoria será feita depois"). **Falta a revisão independente** (CLAUDE.md §12) e a validação no carro (§8).

| Commit | O quê |
|---|---|
| `ba0ffd6` | `ObdService` (máquina de estados, inicialização a cada conexão, descoberta do motor, mapa de PIDs, polling, backoff), `ObdPreferences`, decodificação multi-PID/ISO-TP/cabeçalhos e o **`FakeObdCar`** (Nivus simulado a partir das transcrições) |
| `67fd5bd` | Integração: `DrivingSessionHost` dono do serviço, ciclo de vida (segundo plano), `DashboardSensorStreams` (2ª fonte), campos do veículo no `TelemetrySnapshot`, início automático de sessão |
| `7a3a49a` | Widgets: `SensorType` 6–9 (rotação, temperatura, bateria, carga), `DisplayStyle` 10 (conta-giros) e 11 (valor ao vivo); borda vermelha com o último valor; marcação no "+" |
| `f3d6e87` | Tela Veículo → Adaptador OBD-II, ícone no topo, pausa do serviço durante a ferramenta da fase 0; correção do início automático |

**Testes:** 14 do serviço (`test/obd_service_test.dart`), 5 dos widgets (`test/obd_widgets_test.dart`) e 2 com o app real sobre o Nivus simulado (`test/session_host/obd_phase1_app_test.dart`, `obd_adapter_screen_app_test.dart`). Suíte completa: 1.605 testes passando.

### Onde a implementação se afastou do rascunho

1. **Polling enquanto há link**, não só "com alguém ouvindo". O app só mantém o link em primeiro plano ou com uma sessão gravando, então a diferença prática é nenhuma, e o código fica mais simples.
2. **Sem cache do mapa de PIDs** (§8). Reler o mapa custa ~3 pedidos (~300 ms) por conexão, e guardar algo por VIN exigiria guardar o VIN ou um hash estável dele. Fica para quando houver motivo.
3. **Ponte nativa sem mudanças** (§5). Ela já tenta o método `secure` primeiro (o que funcionou no Nivus), e a queda é detectada pela falta de resposta, então o evento de queda nativo não é necessário.
4. **Gatilho do início automático:** rotação > 0 **ou** velocidade OBD > 0, uma vez a cada vez que o carro liga (rearmado só quando o carro para de responder). No PHEV, andar no modo EV (0 rpm) dispara pela velocidade. **[Haval]** Confirmar no carro.
5. **Sensores OBD fora do painel inicial e da seleção inicial** (`obdSensorTypes`): sem adaptador, só diriam "Configurar adaptador".
6. **Campos no `TelemetrySnapshot`:** `obdLinkState`, `engineRpm`, `engineLoadPercent`, `engineCoolantC` e `vehicleVoltage`, só com valores ao vivo. Os widgets leem o último valor do serviço, via `DashboardSensorStreams.obd`, só para exibição.
7. **A borda vermelha** usa o mecanismo central de alerta do card (`alertColor`), o mesmo do horizonte artificial, que pisca. Se o dono preferir a borda vermelha fixa, sem piscar, é uma mudança pequena no `DashboardTile`.

### O que ainda depende do Haval

- O comportamento de ignição e READY do PHEV, e se o gatilho de início automático funciona no modo EV.
- Endereços das ECUs, mapa de PIDs e se o multi-PID é aceito. O serviço já se adapta a cada um desses (descobre o motor, lê o mapa e cai para um PID por pedido).
- Bateria híbrida (`5B`) como widget, se o Haval tiver esse PID.
- Validação real em segundo plano (a conexão Bluetooth com a tela desligada e a sessão gravando).
