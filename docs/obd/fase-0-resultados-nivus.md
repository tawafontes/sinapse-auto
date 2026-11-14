# OBD-II fase 0 — resultados no VW Nivus 2021 (referência, carro a combustão)

> Rodada em 13/11/2026 com a ferramenta da fase 0 (Configurações → Diagnóstico → Teste do adaptador OBD-II), no Samsung Galaxy S23 Ultra e no Vgate iCar Pro (ELM327 v2.3, BT 3.0). **Não é o carro-alvo:** o Haval H6 PHEV19 ainda vai ser testado. Este registro vale para o adaptador, a ponte nativa e o app, e serve como segundo "carro falso" para os testes da fase 1.
>
> A transcrição original fica em `scratchpad/obd-phase0/phase0_20261113_214050.txt`, fora do git. Neste documento o VIN aparece mascarado.

## 1. Antes da rodada: bug corrigido na ponte nativa

Na primeira tentativa (18:57), **todas** as conexões falharam antes de abrir o socket:

```
falha ao conectar: permission: ... Need android.permission.BLUETOOTH_SCAN permission ... BluetoothAdapterServiceBinder.cancelDiscovery()
```

No Android 12+, `BluetoothAdapter.cancelDiscovery()` exige `BLUETOOTH_SCAN`. O app não tem essa permissão, de propósito: ele não faz varredura. A correção em `ObdBridge.kt` tornou a chamada opcional, ignorando o `SecurityException`. Com isso, a conexão abriu de primeira.

## 2. Resultados

| Item | Resultado |
|---|---|
| Conexão | método **`secure`** (`createRfcommSocketToServiceRecord`), **1,98 s**; nenhuma queda em ~5,5 min |
| Adaptador | `ELM327 v2.3`; `AT@1` = "OBDII to RS232 Interpreter"; `ATZ` em ~1 s |
| Tensão (`ATRV`) | 13,3 V com o motor ligado |
| Protocolo | `ATSP0` (busca) → `0100` resolveu em 292 ms; `ATDP` = ISO 15765-4 (CAN 11/500); `ATDPN` = `A6` |
| VIN | `9BW…MP…` (17 caracteres, legível; WMI `9BW` = VW do Brasil; ano `M` = 2021) |
| DTCs | `0101`: luz de injeção apagada, 0 códigos; `03`/`07` vazios; `0A` → `NO DATA` |
| **ECUs** | **duas ECUs respondem** a todo pedido do modo 01 (provavelmente motor e câmbio). Com `ATH0` não dá para saber qual é qual; os valores diferem um pouco (ex.: rpm `0F92` e `0F8C`) |

### PIDs do modo 01 suportados

`01 04 05 0C 0D 11 20 40 41 42 43 49` (os bitmaps `20`/`40` só encadeiam)

| Interesse | Suporte |
|---|---|
| `0C` rotação · `05` temperatura do motor · `04` carga · `42` tensão do módulo | ✅ os quatro sensores da fase 1 |
| `0D` velocidade · `11` acelerador · `43` carga absoluta · `49` pedal D | ✅ |
| `10` MAF · `0B` MAP | ❌ **nenhum dos dois** → consumo por MAF/MAP (fase 2) não funciona neste carro |
| `2F` nível do tanque · `51` tipo de combustível · `5B` bateria híbrida | ❌ |

### Tempo

| Medida | Valor |
|---|---|
| 20× `010C` | mín. 51 ms, média 70 ms, máx. 120 ms |
| Leitura contínua (5 min, um PID por pedido) | 3.539 respostas em 300 s = **11,8/s**; latência média 73 ms, p50 66, p95 129, p99 171, máx. 256 ms |
| **Multi-PID** | `010C0D` → 63 ms; **`010C0D050411` (6 PIDs) → 61 ms**, resposta multi-frame (ISO-TP) das duas ECUs |
| Erros na leitura contínua | nenhum: nenhum `NO DATA`, `STOPPED`, `CAN ERROR` ou timeout |

O multi-PID custa o mesmo que um PID sozinho. Com até 6 PIDs por pedido (limite do ELM em CAN), o rendimento sobe ~5×.

### Faixas observadas (motor ligado o tempo todo)

| Sinal | Faixa |
|---|---|
| Velocidade | 0 a 63 km/h |
| Rotação | 774 a 3.109 rpm; **nunca 0** (combustão; em marcha lenta, ~980 rpm) |
| Temperatura do motor | 54 → 87 °C (aquecimento visível) |
| `0142` | 13,66 V, coerente com o `ATRV` |

## 3. O que esta rodada **não** respondeu

- **Ignição desligada:** só houve um "Verificar carro", com o motor ligado. Ainda não se sabe se o Vgate dorme, se `0100` vira `NO DATA` ou `UNABLE TO CONNECT`, nem quanto tempo leva para voltar a responder. Isso é necessário para o estado "aguardando o carro" e para a reconexão.
- **Notas do passageiro:** não foram marcadas.
- **PHEV:** nada sobre rotação 0 no modo EV, nem sobre o momento em que o motor a combustão liga. Só o Haval responde isso.
- **Qual ECU é o motor:** ver a pendência P1 no rascunho da fase 1.

## 4. Próximas rodadas

1. **Nivus, ignição desligada** (opcional, ~10 min): o comportamento de sono do adaptador independe do carro.
2. **Haval H6 PHEV19:** a sequência completa, o roteiro de ignição desligada e ligada (incluindo acessórios sem READY) e 5 min contínuos passando por modo EV e pela partida do motor a combustão, com as notas marcadas.
