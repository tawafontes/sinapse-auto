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
- **Em `waitingForCar`:** repetir `0100` a cada X s, sem derrubar o socket. **[Haval]** Ainda não se sabe se o adaptador mantém o link com a ignição desligada nem quanto tempo leva para acordar; isso define o X e decide se `waitingForCar` mantém o socket aberto ou se reconecta.
- **Ciclo de vida:** `AppLifecycleState.paused`, sem sessão gravando → solta o link (`disconnect`). Com sessão gravando, o link continua. `resumed` → `connecting`, se a conexão automática estiver ligada.
- Toda transição passa por um único método (`_transition`), registrada num histórico curto que aparece na tela do adaptador.

## 3. Inicialização do link

Ordem baseada na fase 0. No Nivus, todos os comandos responderam em menos de 50 ms, exceto `ATZ` (~1 s):

1. `connect`: começar pelo método salvo (no Nivus, `secure`). Se falhar, cair para as outras duas formas e salvar a que funcionou.
2. `ATZ` (timeout de 2 s) → `ATE0 ATL0 ATS0 ATH0` → `ATSP0` → `ATRV`.
3. `0100`: se responder → `receiving`; se der `NO DATA`/`UNABLE` → `waitingForCar`.
4. No primeiro `receiving` com este adaptador e este carro: ler a cadeia de bitmaps (`0100`, `0120`, `0140`, …) e salvar o **mapa de PIDs suportados** e o protocolo (`ATDPN`). Isso alimenta o "+" e o "Seu carro não informa este dado".

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
- **Timeout por pedido:** 500 ms; o p99 no Nivus foi 171 ms. Três timeouts seguidos → `reconnecting`.
- **[Haval]** Ajustar os períodos pela latência real. Se o carro tiver o PID `5B` (bateria híbrida), ele entra no grupo lento.

### Pendência P1: duas ECUs respondem

No Nivus, todo pedido do modo 01 recebe duas respostas, que com `ATH0` não se distinguem. Opções:
- **(a)** `ATSH7E0`: endereçar só o motor (pedido físico). Isso também **reduz pela metade o tráfego** no barramento e na serial.
- **(b)** `ATH1`: receber o cabeçalho e filtrar `7E8` (motor).

Proposta: começar pela (a), com a (b) como diagnóstico. **[Haval]** Para decidir com dados, sugiro acrescentar à ferramenta da fase 0 um passo de **`ATH1` + `0100` + `010C`**, só leitura, antes da rodada no Haval. Isso mostra quais ECUs respondem e a qual endereço cada uma pertence.

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
  2. ignição desligada (`NO DATA`/`UNABLE`) → `waitingForCar` → ignição ligada → `receiving`;
  3. queda no meio da viagem (`closed`) → backoff 5/15/30/60 → volta;
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
