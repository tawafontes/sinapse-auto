# OBD-II fase 0 — resultados no VW Nivus 2021 (referência, carro a combustão)

> Duas rodadas em 13/11/2026 com a ferramenta da fase 0 (Configurações → Diagnóstico → Teste do adaptador OBD-II), no Samsung Galaxy S23 Ultra e no Vgate iCar Pro (ELM327 v2.3, BT 3.0). **Não é o carro-alvo:** o Haval H6 PHEV19 ainda vai ser testado. Este registro vale para o adaptador, a ponte nativa e o app, e serve como segundo "carro falso" para os testes da fase 1.
>
> - **Rodada 1 (21:40):** sequência + 5 min contínuos rodando (0 a 63 km/h).
> - **Rodada 2 (22:30):** sequência com o passo novo de cabeçalhos, roteiro de ignição desligada e ligada, e queda proposital do adaptador (puxado da tomada no meio da leitura contínua).
>
> As transcrições originais ficam em `scratchpad/obd-phase0/` (`phase0_20261113_214050.txt` e `phase0_20261113_223033.txt`), fora do git. Neste documento o VIN aparece mascarado.

## 1. Antes da rodada 1: bug corrigido na ponte nativa

Na primeira tentativa (18:57), **todas** as conexões falharam antes de abrir o socket:

```
falha ao conectar: permission: ... Need android.permission.BLUETOOTH_SCAN permission ... BluetoothAdapterServiceBinder.cancelDiscovery()
```

No Android 12+, `BluetoothAdapter.cancelDiscovery()` exige `BLUETOOTH_SCAN`. O app não tem essa permissão, de propósito: ele não faz varredura. A correção em `ObdBridge.kt` (commit `4afce3d`) tornou a chamada opcional, ignorando o `SecurityException`. Com isso, a conexão abriu de primeira nas duas rodadas.

## 2. Adaptador, conexão e protocolo

| Item | Resultado |
|---|---|
| Conexão | método **`secure`** (`createRfcommSocketToServiceRecord`): 1,98 s na rodada 1 (adaptador frio), **0,45 s** na rodada 2 e **0,80 s** ao reconectar depois da queda |
| Adaptador | `ELM327 v2.3`; `AT@1` = "OBDII to RS232 Interpreter"; `ATZ` em ~1 s |
| Protocolo | `ATSP0` (busca) → `0100` resolveu em ~290 ms; `ATDP` = ISO 15765-4 (CAN 11/500); `ATDPN` = `A6` |
| VIN | `9BW…MP…` (17 caracteres, legível; WMI `9BW` = VW do Brasil; ano `M` = 2021) |
| DTCs | `0101`: luz de injeção apagada, 0 códigos; `03`/`07` vazios; `0A` → `NO DATA` (modo não suportado) |

## 3. Duas ECUs respondem — identificadas pela rodada 2

Todo pedido do modo 01 enviado ao endereço funcional (`7DF`, o padrão) recebe **duas respostas**. Com `ATH0` não dá para distinguir uma da outra, e **a ordem muda entre rodadas**. O passo de cabeçalhos (`ATH1`) mostrou quem é quem:

| CAN id | ECU | Bitmap `0100` | PIDs `01–20` |
|---|---|---|---|
| **`7E8`** | **motor** | `BE3EB813` | `01 03 04 05 06 07 0B 0C 0D 0E 0F 11 13 14 15 1C 1F 20` |
| `7E9` | 2ª ECU (provavelmente o câmbio) | `98188001` | `01 04 05 0C 0D 11 20` |

- **Endereçar só o motor funciona:** depois de `ATSH7E0`, o `010C` recebeu **uma** resposta, só do `7E8`, em 51 ms.
- **Correção da análise da rodada 1:** a ferramenta decodifica só a **primeira** resposta. Na rodada 1, a primeira foi a do `7E9`, e o mapa saiu com 12 PIDs, sem MAP. A conclusão de que o carro "não tem MAF nem MAP" **estava errada**. Na rodada 2, a primeira foi a do `7E8`, e o mapa saiu com 23 PIDs.
- **Mapa real do motor (`7E8`)**, juntando `0100`, `0120` e `0140`: `01 03 04 05 06 07 0B 0C 0D 0E 0F 11 13 14 15 1C 1F 20 40 41 42 43 49`.

| Interesse | Suporte no motor (`7E8`) |
|---|---|
| `0C` rotação · `05` temperatura do motor · `04` carga · `42` tensão do módulo | ✅ os quatro sensores da fase 1 |
| `0D` velocidade · `11` acelerador · `43` carga absoluta · `49` pedal D | ✅ |
| **`0B` MAP** · `0F` temperatura do ar de admissão · `06`/`07` ajuste de combustível · `14`/`15` sondas lambda · `0E` avanço | ✅ → consumo por MAP (fase 2) **é viável** neste carro |
| `10` MAF | ❌ |
| `2F` nível do tanque · `51` tipo de combustível · `5B` bateria híbrida | ❌ |

## 4. Tempo

| Medida | Valor |
|---|---|
| 20× `010C` | rodada 1: mín. 51, média 70, máx. 120 ms · rodada 2: mín. 53, média 71, máx. 170 ms |
| Leitura contínua (rodada 1, 5 min, um PID por pedido) | 3.539 respostas em 300 s = **11,8/s**; latência média 73 ms, p50 66, p95 129, p99 171, máx. 256 ms; nenhum erro |
| **Multi-PID** | `010C0D` → 63 ms; **`010C0D050411` (6 PIDs) → 61 ms**, resposta multi-frame (ISO-TP) das duas ECUs |

O multi-PID custa o mesmo que um PID sozinho. Com até 6 PIDs por pedido (limite do ELM em CAN), o rendimento sobe ~5×.

### Faixas observadas (rodada 1, motor ligado o tempo todo)

| Sinal | Faixa |
|---|---|
| Velocidade | 0 a 63 km/h |
| Rotação | 774 a 3.109 rpm; nunca 0 com o motor ligado (marcha lenta ~980 rpm) |
| Temperatura do motor | 54 → 87 °C |
| `0142` | 13,66 V, coerente com o `ATRV` |

## 5. Ignição (rodada 2)

O "Verificar carro" envia `ATRV` (adaptador) e `0100` (ECU).

| Estado | `ATRV` | `0100` | Link Bluetooth |
|---|---|---|---|
| Ignição ligada, motor parado (sequência) | 11,7 V | responde; `010C` = 0 rpm | de pé |
| **Desligado** (logo após) | 11,7 V, ~300 ms | **`NO DATA`** (~260 ms) | de pé |
| **Desligado há ~4 min** | 11,8 V, ~300 ms | `NO DATA` | **de pé: nem o adaptador nem o link dormiram** |
| Só ignição, sem partida | 11,6 V | responde em 83 ms (< 2 s depois de ligar) | de pé |
| Motor ligado | **13,3 V** (alternador) | responde | de pé |
| Desligou o motor | 12,1 V → 12,0 V em 30 s, 450–500 ms | **`NO DATA` na hora** e 30 s depois | de pé |

Conclusões:
- Com o carro desligado, o adaptador **continua alimentado e respondendo**, e o link Bluetooth **não cai**. O estado "aguardando o carro" mantém o socket aberto e só repete `0100`.
- `0100` respondendo **não** significa motor ligado: com só a ignição, as ECUs já respondem. Para saber se o motor gira, olhar a **rotação** (`010C` = 0) ou, num carro a combustão, a **tensão** (≥ ~13 V com o alternador).
- Com o carro desligado, o `ATRV` fica bem mais lento (300–500 ms, contra ~30 ms com o motor ligado): provavelmente economia de energia do adaptador. O tempo-limite do `ATRV` precisa considerar isso.

## 6. Queda do adaptador (rodada 2)

Adaptador puxado da tomada OBD com a leitura contínua rodando e o motor ligado:

| t (s) | Evento |
|---|---|
| ~666 | adaptador desconectado |
| 666 → 672 | 3 pedidos seguidos **sem resposta** (`SEM PROMPT`, tempo-limite de 2 s cada). O socket não acusa erro |
| 672 | o 4º pedido falha na escrita: `IOException: Broken pipe` → a ponte fecha o socket (`closed`) |
| ~700 | adaptador de volta; Conectar manual → conectado em **803 ms** |
| depois | as respostas voltam **com espaços** (`41 0C 0F 5A`): o adaptador reiniciou com os padrões de fábrica, e a ferramenta não refez a configuração |

Conclusões para a fase 1:
- **A queda é detectada pela falta de resposta, não por um erro do socket:** o `Broken pipe` só veio 6 s depois. Com tempo-limite de 500 ms e 3 falhas seguidas, o app detecta a queda em ~1,5 s.
- **Toda (re)conexão refaz a inicialização completa** (`ATZ`, `ATE0 ATL0 ATS0 ATH0`, `ATSP0`/`ATSH7E0`…). Um adaptador que perdeu a energia volta com eco, espaços e endereçamento funcional; sem a inicialização, o endereçamento só ao motor se perde e o `7E9` volta a se misturar.
- A reconexão é rápida (< 1 s): o backoff de 5/15/30/60 s está folgado.

## 7. O que ainda falta (Haval)

- **PHEV:** rotação 0 no modo EV e o momento em que o motor a combustão liga, com as notas marcadas.
- Mapa de PIDs e ECUs do Haval (o passo de cabeçalhos já está na sequência). Ver se há `5B` (bateria híbrida), MAF/MAP e `51`.
- No Haval, a tensão pode não servir para saber se o "motor está ligado": no modo READY o conversor DC-DC também carrega a bateria de 12 V. Lá o que vale é a rotação.
