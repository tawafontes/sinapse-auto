# Diagnóstico do carro e relatórios OBD-II: desenho (implementação futura)

> **Situação (2026-11-15):** **implementado em parte, falta validar no carro.** Já existem a sessão de diagnóstico com a política de comandos (etapa 1), a saúde do veículo com o histórico e o apagar códigos (etapa 2), a bateria, partida e carga (etapa 3) e os monitores de emissões e prontidão (parte da etapa 5). Ainda não começaram: o repouso do adaptador (`dormant`), o modo 06 e as falhas de ignição por cilindro, a matriz de fuel trim, as gravações e o osciloscópio, os outros módulos (UDS) e a exportação. A seção 12 resume o que foi feito e as diferenças em relação a este desenho.
> **Origem:** o arquivo de requisitos do dono (`requisitos_e_relatorios_do_sistema_obd.txt`, RF01 a RF05 e cinco relatórios), adaptado ao adaptador e aos carros que temos de fato.
> **Data:** 2026-11-14.

## 1. Decisões do dono

| # | Decisão |
|---|---|
| 1 | **Ficam de fora os testes ativos** (RF04: acionar atuadores) e a **codificação/As-Built** (relatório 4). O app nunca escreve configuração no carro. |
| 2 | A varredura dos outros módulos (UDS) entra como **experimental e só de leitura**. |
| 3 | **Local:** a tela **Diagnóstico** que já existe. Depois dos cartões de GNSS e sensores, rolando a página para baixo, entra uma área **"Diagnóstico do carro"**. |
| 4 | **Descrições dos códigos:** tabela dos códigos genéricos (P0xxx, P2xxx, U0xxx…) em português. Para os outros, aparece "código do fabricante". |
| 5 | **Não há exportação na primeira versão.** Os relatórios são vistos no app e ficam salvos num histórico. PDF, JSON e CSV ficam para depois; quando chegar a hora, cada pacote novo (`pdf`, `share_plus`) é proposto antes de entrar. |
| 6 | **Bateria do adaptador:** soltar o link depois de **2 minutos** aguardando o carro e religar sozinho (seção 6). |

## 2. Limites reais (por que o escopo não é o do arquivo original)

- **Adaptador.** É o Vgate iCar Pro, um ELM327 v2.3 em Bluetooth Classic, e não o vLinker. O modo BatterySaver de 3 mA do arquivo é recurso da linha vLinker. O consumo do iCar Pro com o carro desligado **ainda não foi medido**; no Nivus ele ficou mais de 4 minutos acordado com o link aberto.
- **OBD-II genérico** (modos 01 a 0A) só alcança as centrais **de emissões**: motor, câmbio e, no Haval PHEV, provavelmente a do híbrido. ABS, airbag, BCM, ar-condicionado e painel só respondem em UDS (ISO 14229), em endereços de cada fabricante. Na VW, passam pelo gateway.
- **MS-CAN** é da Ford. No Nivus e no Haval, o ELM só alcança o CAN de diagnóstico dos pinos 6 e 14.
- **Descrições de códigos de fabricante** (P1xxx, B, C e U1xxx em diante) não existem em tabela pública.
- **Vazão do link.** O Bluetooth 3.0 do ELM dá cerca de 12 respostas por segundo, ou uns 70 valores por segundo em grupos de 6 PIDs. Um diagnóstico completo leva segundos, não milissegundos.

## 3. Escopo

**Entra:**
- **Saúde do veículo:** identificação, centrais, códigos de falha, freeze frame, prontidão e apagar códigos do motor.
- **Bateria, partida e carga.**
- **Emissões:** monitores, modo 06, falhas de ignição e fuel trim.
- **Telemetria gravada e "osciloscópio":** junto com a fase 2, só vista no app.
- **Varredura UDS experimental, só de leitura.**
- **Histórico dos relatórios**, para comparar antes e depois de um conserto.

**Não entra:**
- Testes ativos.
- Codificação, adaptação e As-Built.
- Apagar códigos de qualquer central que não seja a do motor.
- Escrever qualquer coisa num módulo UDS.
- Exportação: fica para uma versão posterior.

## 4. Interface

A tela **Diagnóstico** (`lib/screens/settings/diagnostics_screen.dart`) segue igual no topo: GNSS, acelerômetro, giroscópio, barômetro e inclinação. Abaixo deles, rolando, entra:

```
── Diagnóstico do carro ───────────────────────────
 [estado do link OBD: ícone + texto, como no painel]

 ▸ Saúde do veículo          último: 12/11 · 2 códigos
 ▸ Bateria, partida e carga  último: 10/11 · bateria ok
 ▸ Emissões e prontidão      último: —
 ▸ Gravações OBD             (fase 2)
 ▸ Outros módulos            experimental

 ▸ Histórico de relatórios   8 relatórios
───────────────────────────────────────────────────
```

- Cada item abre a própria tela. O botão "Executar" fica **desabilitado** sem link (estado ≠ `receiving`) e mostra o motivo: "Conecte o adaptador" ou "Ligue a ignição".
- Durante a execução aparecem o progresso ("Lendo códigos da central 7E8…") e um botão Cancelar.
- O resultado aparece **interpretado**: textos e semáforo verde, amarelo e vermelho. Os dados **brutos** ficam num "Detalhes técnicos" recolhido.
- Todo relatório concluído é salvo automaticamente no histórico.

## 5. Arquitetura

### 5.1 Um só dono do link

O `ObdService` continua sendo o único que fala com o adaptador. Ele ganha uma **sessão de diagnóstico**:

1. `beginDiagnostic()`: pausa o polling rápido e o lento; os widgets mostram o último valor **sem** borda vermelha, porque a pausa é intencional.
2. Envia uma sequência de comandos, com fila própria, tempos-limite próprios (o modo 06 e o UDS respondem mais devagar) e cancelamento.
3. `endDiagnostic()`: restaura os cabeçalhos `ATSH7E0`/`ATH0` e retoma o polling. Isso roda sempre, inclusive em erro ou cancelamento.

Se o link cair no meio, o relatório termina como **incompleto**: guarda o que já leu e mostra uma mensagem.

O diagnóstico não roda durante uma sessão de gravação (o botão explica). Assim, os dados de direção não ficam com buracos.

### 5.2 Escopos de comando (lista de permissões)

Uma camada `DiagnosticCommandPolicy` valida **cada** comando antes de ele ir para o fio. Comando fora da lista lança exceção, e há teste unitário cobrindo isso.

| Escopo | Permitido |
|---|---|
| Leitura OBD | modos `01`, `02`, `03`, `06`, `07`, `09`, `0A`; os `AT` de leitura e de configuração que já usamos (`ATRV`, `ATSH`, `ATH`, `ATCRA`, `ATST`…) |
| UDS só leitura | `3E 00` (TesterPresent), `22` com DIDs da lista F180–F19E, `19 01`/`19 02` (leitura de DTC) e `10 01` (sessão padrão) |
| Escrita | **só `04`** (apagar códigos), endereçado ao motor (`ATSH7E0`), com as travas da seção 7.6 |

Ficam proibidos explicitamente, mesmo que alguém tente acrescentar: `10 02`/`10 03` (sessões de programação e estendida), `11` (reset), `14` (apagar DTC via UDS), `27` (acesso de segurança), `28`, `2E`, `2F`, `31`, `34`–`37` e `85`.

### 5.3 Persistência

- Uma nova caixa Hive, `obdDiagnosticReports`, com os `typeId` a partir do **22**, o próximo livre no registro de `sensor_widget_config.dart`.
- `DiagnosticReport` guarda: id, tipo, data e hora, VIN, odômetro (se o carro tiver), estado (completo, incompleto ou cancelado), as **respostas brutas** de cada comando e o resultado interpretado.
- Guardar o bruto permite **reinterpretar** relatórios antigos quando a tabela de códigos ou a decodificação melhorar.
- O VIN fica completo no aparelho e aparece **mascarado** na tela e em qualquer log (`9BW•••••••••1234`). Os relatórios não entram em git nem em `docs/evidence/` sem mascarar.

### 5.4 Código

```
lib/services/obd/diagnostic/
  diagnostic_session.dart     fila, cancelamento, restauração do link
  diagnostic_policy.dart      lista de permissões (5.2)
  obd_modes.dart              decodificação dos modos 02/03/06/07/09/0A
  uds_read.dart               3E/22/19, decodificação ISO-TP de respostas longas
  dtc_catalog.dart            lê assets/obd/dtc_generic_pt.json (já gerado; 7.1)
  reports/                    um builder por relatório (seção 7)
lib/models/diagnostic_report.dart (+ .g.dart)
lib/screens/settings/diagnostics/   telas de cada relatório e do histórico
```

## 6. Economia da bateria do adaptador (RF05)

**Hoje:** com o carro desligado, o link fica aberto em `waitingForCar`, testando o carro de tempos em tempos. O adaptador não dorme.

**Proposta:**
1. Depois de **2 minutos** em `waitingForCar`, com tensão < 12,9 V e rotação 0, o serviço **fecha o socket** e passa a um estado novo, `dormant` ("Adaptador em repouso").
2. Ele religa sozinho quando:
   - o app volta ao primeiro plano;
   - começa uma sessão;
   - o usuário toca em Conectar;
   - ou, em segundo plano com uma gravação ativa, a cada N minutos (N a medir, para que a própria tentativa não mantenha o adaptador acordado).
3. **A medir no carro:**
   - Se o iCar Pro dorme sozinho com o socket fechado, e em quanto tempo.
   - O consumo com o socket aberto e fechado: amperímetro em série no pino 16, ou queda de tensão numa noite.
   - Quanto tempo uma reconexão leva até o primeiro dado.
4. O ícone da barra superior ganha a cor do estado `dormant`: cinza com um "z". Não há borda vermelha nos widgets, porque não é falha.

## 7. Relatórios

### 7.1 Saúde do veículo (relatório 1, RF01 e RF02 nas centrais OBD)

| Bloco | Comandos | Mostra |
|---|---|---|
| Identificação | `0902` VIN, WMI → fabricante; `0904` CALID, `0906` CVN e `090A` nome de cada central; `ATRV` | VIN mascarado, fabricante, centrais encontradas (`7E8`, `7E9`…) com nome e calibração, tensão |
| Uso | `01A6` odômetro, `0121` distância com a luz de injeção acesa, `0131` distância desde o último apagamento, `0130` aquecimentos, `014D`/`014E` tempos | Só o que o carro declarar no bitmap |
| Códigos | `03` armazenados, `07` pendentes e `0A` permanentes, de cada central. Feito com o pedido funcional (`7DF`) e cabeçalhos ligados (`ATH1`), para saber de qual central veio cada código | Lista por central: código, descrição, tipo e uma gravidade simples (luz de injeção acesa, ou código que vira armazenado → vermelho; pendente → amarelo) |
| Freeze frame | `0202` (que código o gerou), seguido de `02xx00` para os PIDs suportados no quadro 0 | O instantâneo do momento da falha: rotação, carga, temperatura, velocidade, fuel trim |
| Prontidão | `0101` (luz de injeção, número de códigos, monitores) | Resumo; o detalhe fica no relatório 7.3 |

**Descrições: tabela pronta.** [`assets/obd/dtc_generic_pt.json`](../../assets/obd/dtc_generic_pt.json) tem **777 códigos genéricos**: as descrições da SAE J2012/ISO 15031-6 adaptadas para o português, com dicas curtas onde ajudam ("verifique a tampa do tanque", "possível entrada falsa de ar"). A fonte é o gerador [`tool/obd/gerar_tabela_dtc.py`](../../tool/obd/gerar_tabela_dtc.py), organizado por família; não se edita o JSON à mão. Para gerar de novo: `py -3 tool/obd/gerar_tabela_dtc.py`.

Cobertura:
- **P00xx–P07xx**, completos nas famílias principais: sensores, sondas, injetores, ignição, catalisador, EVAP, marcha lenta, tensão, módulo e transmissão. Inclui `P0176`–`P0179`, do sensor de etanol, e `P0213`/`P0214`, da partida a frio do flex antigo.
- **P0Axx**, da propulsão híbrida: bateria de alta tensão, inversor, DC-DC e intertravamento.
- **P2xxx** mais comuns: borboleta eletrônica, mistura, sondas travadas e bobinas.
- **U0xxx**, de rede: perda de comunicação com os módulos e dados inválidos.

Como o app usa a tabela:
1. O código está na tabela → mostra a descrição.
2. O código é de faixa genérica mas não está na tabela → mostra o **sistema** (campo `sistemas`, pelos três primeiros caracteres), por exemplo "Código genérico de Ignição e falhas de ignição (sem descrição na tabela)".
3. O código é de faixa do fabricante (campo `faixasDoFabricante`: P1, P30–P33, B1/B2, C1/C2, U1/U2) → "Código do fabricante: consulte a concessionária ou um scanner da marca".

Os códigos B0 e C0, genéricos de carroceria e chassi, ficam para quando a varredura UDS (7.5) os trouxer. No OBD genérico, as centrais de emissões não os reportam.

Quando a tela de saúde for implementada, o arquivo entra em `flutter: assets:` no `pubspec.yaml`. Hoje ele ainda não vai para o APK.

### 7.2 Bateria, partida e carga (relatório 5)

O relatório é um assistente em três passos, sempre com o carro parado:

1. **Repouso.** Motor desligado há pelo menos 1 hora, se o usuário souber; uma leitura de `ATRV`. Faixas: ≥ 12,6 V carregada; 12,4 V cerca de 75 %; 12,2 V cerca de 50 %; < 12,0 V descarregada.
2. **Partida.** O usuário toca em "Vou dar a partida" e dá a partida em até 15 s. O serviço lê `ATRV` no ritmo máximo, só ele, sem PIDs: estimativa de 15 a 30 amostras/s, **a medir**. Para quando a tensão sobe acima de 13 V ou depois de 10 s. Mostra a curva, o **mínimo durante o arranque** (≥ 9,6 V ok; 9,0–9,6 V atenção; < 9,0 V bateria fraca ou problema no motor de partida) e o tempo de recuperação.
3. **Carga.** Motor em marcha lenta por 30 s, e depois a 2.000 rpm por 10 s, se o usuário quiser. Mostra a média e a oscilação da tensão (`ATRV` + `0142`). Faixa normal: 13,2–14,8 V. Uma oscilação acima de ~0,5 V em regime estável recebe alerta.

**Nivus:** é provável que tenha alternador inteligente, que baixa a tensão na desaceleração e na bateria cheia. Por isso o laudo não acusa falha com 12,8–13,2 V em regime, só avisa.

**Híbridos e PHEV** (propulsão `hybrid` ou `plugInHybrid` em Meu veículo, como o Haval H6 PHEV): o motor a combustão parte pelo motor-gerador de alta tensão. A bateria de 12 V não alimenta motor de partida: liga os módulos e fecha os contatores da bateria de alta tensão. Quem a carrega é o **conversor DC-DC**, não um alternador. O assistente troca os três passos por:

1. **Repouso:** igual ao dos carros a combustão. A bateria de 12 V de um híbrido costuma ser menor (às vezes AGM), então o limite de "descarregada" é o mesmo, mas o laudo lembra que **é ela que impede o carro de ficar READY**.
2. **Ativação (READY), no lugar da partida.** O usuário toca em "Vou ligar o carro" e aperta o botão de partida. O serviço lê `ATRV` no ritmo máximo até 10 s depois do READY, e mostra:
   - a **queda** quando os módulos acordam e os contatores fecham (esperado: pequena, > 11,5 V; < 11,0 V aponta bateria de 12 V fraca);
   - o **salto** quando o DC-DC entra, para cerca de 13,5–14,5 V (faixa a confirmar no Haval) em até ~2 s;
   - DC-DC que não sobe em 5 s gera alerta vermelho ("o conversor DC-DC não está carregando a bateria de 12 V"), e o relatório cruza com o código `P0A94`, se houver.
3. **Carga em funcionamento:** em READY, primeiro só elétrico, por 30 s. Em seguida, se o usuário quiser, com o motor a combustão funcionando (forçado pelo modo de recarga ou HEV do carro). Mostra a média e a oscilação. Uma **queda > 1 V** no instante em que o motor a combustão entra recebe alerta: num híbrido sadio, a partida dele não deveria aparecer na rede de 12 V.

Nos híbridos e PHEV não há "mínimo durante o arranque" (não existe arranque de 12 V). A rotação 0 com tensão em 13,5 V e o carro em READY **é normal** e não indica falha. O laudo usa os mesmos rótulos (Repouso, Ativação e Carga) para que o histórico compare relatórios do mesmo carro.

### 7.3 Emissões e prontidão (relatório 2)

- **Monitores:** `0101` dá o estado desde o último apagamento; `0141` dá o ciclo atual. É uma tabela por monitor (catalisador, sonda lambda, aquecedor da sonda, EVAP, EGR/VVT, falhas de ignição, combustível, componentes) com "suportado / completo / incompleto" e o aviso "Pronto para inspeção" ou "Rode X km em ciclo misto".
- **Modo 06** (resultados dos testes de bordo, no formato CAN): o bitmap `0600` traz os MIDs suportados; em seguida, cada MID devolve os resultados, cada um com TID, unidade e escala, valor, mínimo e máximo. O app mostra uma lista com aprovado ou reprovado e barra de margem. É preciso implementar a **tabela de unidades e escalas** do J1979 (Unit and Scaling IDs).
- **Falhas de ignição por cilindro:** MIDs `A2` em diante (cilindro 1…), quando o carro reportar; muitos carros reportam só o total ou nada. A contagem atual e a média aparecem por cilindro.
- **Matriz de fuel trim:** STFT e LTFT (PIDs `06`/`07`, que o Nivus tem) em faixas de rotação × carga. Sai das **gravações da fase 2**, e não de uma leitura pontual: precisa de pelo menos alguns minutos de direção. Uma célula com |STFT + LTFT| > 10 % fica amarela, e > 20 % fica vermelha.

### 7.4 Gravações OBD e osciloscópio (relatório 3)

Faz parte da **fase 2**:
- Os sinais OBD vão para a gravação da sessão.
- O "osciloscópio" reaproveita os gráficos de sessão que já existem: o usuário escolhe de 1 a 4 sinais e o app os sobrepõe na linha do tempo da sessão.
- Exportação em CSV fica para depois (decisão 5). Parquet foi descartado.

### 7.5 Outros módulos, experimental (RF01 e RF02 além das emissões)

- **Varredura:** para cada endereço candidato, faz `ATSH<id>` e `ATCRA<id+8>`, envia `3E 00` com tempo-limite curto (~150 ms) e considera presente quem responder `7E 00`.
  - Os candidatos ficam numa lista por fabricante. Para a VW: a faixa 7xx usada pelos módulos acessíveis via gateway, a pesquisar. Para o Haval: a descobrir.
  - Também há uma varredura ampla opcional, de `700` a `7F7` (cerca de 250 ids × 150 ms ≈ 40 s).
- **Identificação** de quem responder: `22 F187` (peça), `F189` (software), `F18C` (série) e `F190` (VIN), se houver.
- **Códigos:** `19 02 FF` (por máscara de estado). Mostra o código bruto, no formato UDS de 3 bytes, convertido para P/B/C/U, e a descrição "código do fabricante".
- **Sem apagar e sem escrita.** A tela traz o rótulo **"Experimental: pode não encontrar todos os módulos"**.
- O resultado também vai para o histórico, o que ajuda a construir as listas por fabricante.

### 7.6 Apagar códigos (modo 04)

Fica dentro do relatório de saúde, como botão **"Apagar códigos do motor"**.

**Travas,** conferidas por comando logo antes do envio:
- velocidade 0;
- rotação 0 (motor desligado);
- ignição ligada (a central responde);
- sessão de gravação parada.

**Antes de apagar:**
1. Um relatório de saúde completo é salvo automaticamente, para que os códigos e o freeze frame **não se percam**.
2. Um diálogo explica que:
   - a luz apaga, mas volta se o defeito continuar;
   - os monitores de prontidão voltam a "incompleto", e o carro pode não passar na inspeção até rodar alguns ciclos;
   - em alguns carros, as adaptações de marcha lenta e de fuel trim recomeçam.
3. O usuário confirma digitando ou segurando o botão. Um toque só não basta.

**Depois de apagar:** um novo relatório confere o resultado. Os dois ficam ligados no histórico como "antes e depois".

## 8. Histórico

- Fica em lista por data, com filtro por tipo e por veículo (pelo VIN).
- Ao abrir um relatório, aparece o que foi lido. "Comparar com…" mostra lado a lado dois relatórios do mesmo tipo e VIN: códigos novos e resolvidos, monitores, tensões.
- Excluir é individual ou em seleção múltipla, como na tela de gravações da dashcam.
- **Limite:** 200 relatórios; os mais antigos saem primeiro, mas os marcados com estrela não saem.

## 9. Testes

- **`FakeObdCar`:** ganha códigos configuráveis por central (armazenados, pendentes e permanentes), freeze frame, monitores, modo 06 (incluindo falhas de ignição por cilindro), resposta ao `04` (que zera os códigos e os monitores), CALID/CVN/nome e uma central UDS simulada (por exemplo, `710`/`77A`) com DIDs e `19 02`. A curva de partida também é simulada (`ATRV` cai para 10,1 V e recupera), e um modo PHEV simula a ativação: queda pequena, depois o salto do DC-DC para 14,0 V, com uma variante de DC-DC que não sobe.
- **Unidade:** decodificação de cada modo, a política de comandos (tudo o que é proibido é rejeitado), as travas do `04` e a tabela de unidades do modo 06.
- **App (AppHarness):** do botão Executar ao relatório salvo no histórico; link caindo no meio (relatório incompleto e polling retomado); cancelamento; o fluxo de apagar com as travas.
- **No carro:**
  - **Nivus:** com o código provocado pela desconexão de um sensor, se o dono aceitar, ou com códigos que já existam.
  - **Haval:** a varredura UDS e o relatório de bateria.

## 10. Ordem de implementação

Cada etapa é entregue e validada no carro antes da próxima:

1. **Sessão de diagnóstico e política de comandos:** a base, com testes.
2. **Saúde do veículo** e histórico, incluindo apagar códigos.
3. **Bateria, partida e carga.**
4. **Economia da bateria do adaptador** (`dormant`), depois de medir o consumo.
5. **Emissões:** monitores, modo 06 e falhas de ignição. A matriz de fuel trim espera a fase 2.
6. **Gravações e osciloscópio:** com a fase 2.
7. **Outros módulos**, experimental.
8. **Mais tarde:** exportação em PDF, JSON e CSV, com pacotes novos propostos antes.

## 11. A medir e em aberto

- O consumo do iCar Pro com o socket aberto e fechado, e se ele dorme sozinho.
- A taxa máxima de `ATRV` durante a partida.
- Se o Nivus responde ao `01A6` (odômetro) e ao modo 06, e quais MIDs tem.
- Quais centrais o Haval expõe no OBD genérico (motor? câmbio DHT? central híbrida?) e em UDS.
- Os endereços UDS alcançáveis no Nivus através do gateway sem sessão estendida.
- **Haval PHEV:** a tensão do DC-DC em READY, o tempo até ele entrar e se a partida do motor a combustão aparece na rede de 12 V.

## 12. O que foi implementado (2026-11-15)

**Telas.** Em Configurações → Diagnóstico, rolando para baixo, aparece o cartão **"Diagnóstico do carro"** com o estado do link e os itens:
- Saúde do veículo;
- Bateria, partida e carga;
- Emissões e prontidão;
- Gravações OBD e Outros módulos, desabilitados com "em breve";
- Histórico de relatórios.

Cada relatório tem "Executar" (desabilitado, com o motivo, sem link), progresso, Cancelar e o resultado com semáforo. Os dados brutos ficam em "Detalhes técnicos"; ali, a resposta do `0902` aparece oculta, porque é o VIN em hexadecimal.

**Código.**
- `lib/services/obd/obd_service.dart`: a sessão de diagnóstico.
  - `runDiagnostic()` entrega um `DiagnosticLink` ao relatório. O relatório roda **dentro do laço do próprio link**, na próxima volta do polling ou da espera pelo carro, de modo que o serviço continua sendo o único dono do adaptador.
  - Ao terminar, `_restoreAddressing()` repõe `ATAR`, `ATH0` e o endereçamento do motor: `ATSH7E0` no Nivus, `ATSH7DF` + `ATCRA7E8` no Haval.
  - Enquanto o relatório roda, os widgets mantêm o último valor sem borda vermelha.
  - Se o link cai, o relatório vira **incompleto**, guarda o que já leu e o serviço reconecta normalmente.
- `lib/services/obd/diagnostic/`:
  - `diagnostic_policy.dart`: a lista de permissões (5.2), conferida em cada comando;
  - `obd_modes.dart`: decodificação dos modos 01 (monitores), 02, 03/07/0A e 09;
  - `dtc_catalog.dart`: a tabela de 777 códigos, que agora entra no APK pelo `pubspec.yaml`;
  - `diagnostic_report_repository.dart`: o histórico;
  - `report_runner.dart`: cancelamento, progresso e o fim da execução;
  - `reports/`: saúde, bateria e emissões.
- `lib/models/diagnostic_report.dart`: o envelope do relatório.
- `lib/screens/settings/diagnostics/`: as telas.
- `elm327_decode.dart` ganhou `canMessages()`, que remonta o ISO-TP por central com os cabeçalhos ligados.

**Diferenças em relação ao desenho:**
- **Persistência (5.3).** A caixa `obd_diagnostic_reports` é **sem tipo** e guarda cada relatório como texto JSON, em vez de um adaptador Hive com `typeId` 22. Assim o formato pode crescer sem gerador de código. O `typeId` 22 continua livre.
- **Gravação de viagem (5.1).** As **leituras** rodam mesmo com uma sessão gravando: levam poucos segundos, e com "Iniciar sessão quando o carro ligar" o carro ligado quase sempre está gravando. Só o **apagar códigos** exige a gravação parada, como em 7.6.
- **Confirmação do apagar (7.6).** É um botão que se **segura por 2 s**; um toque não basta.
- **Endereço do apagar.** O `04` vai **só ao motor**, endereçado fisicamente (`ATSH7E0`). Se a central recusar (o Haval recusa o modo 01 físico e pode recusar o 04 também), nada é apagado e o app explica; não há tentativa funcional, que apagaria também as outras centrais.
- **Comparação (8).** Cada relatório se compara sozinho com o anterior do mesmo tipo e do mesmo VIN (códigos novos e resolvidos). Depois de apagar, a comparação é com o relatório de antes, e os dois ficam ligados ("Ver o relatório de antes/depois de apagar"). Ainda não há a escolha livre "Comparar com…".
- **Bateria.** Cada passo salva o relatório de novo, com o mesmo id, para que sair no meio não perca o que já foi feito. O relatório da bateria, feito com o carro desligado, usa o último VIN lido.
- **Emissões.** Só os monitores (`0101`/`0141`) e o uso desde o apagamento. O modo 06 fica para a próxima etapa.

**Testes.**
- `test/obd_diagnostic_test.dart`: a política, a decodificação, a tabela, os limites da bateria, cada relatório contra o carro simulado (Nivus e Haval), link caindo, cancelamento e o limite de 200 relatórios do histórico.
- `test/session_host/obd_diagnostic_reports_app_test.dart`: o fluxo no app real, do Executar ao apagar com o botão segurado, mais o histórico, as emissões e a bateria.

**A validar no carro:**
- Nivus: o relatório de saúde, com os nomes das centrais e o CALID/CVN.
- Haval: se o motor aceita o `04` físico; o salto do DC-DC na ativação e a faixa de tensão dele.
- O ritmo real de `ATRV` durante a partida.

**Validado no Haval H6 PHEV (2026-11-16 e 2026-11-18):**
- Saúde: 6 centrais responderam (7E8–7EF), nenhuma com código; VIN, CALID, CVN e nome das centrais lidos; o endereçamento volta sozinho para o polling depois do relatório.
- Emissões: todos os monitores do motor completos ("Pronto para inspeção"); no ciclo atual, incompletos logo após ligar (normal).
- Ativação (READY): queda para 12,0–12,3 V e DC-DC a 13,3 V em menos de 1 s, repetido duas vezes. Tocar com o carro já ligado (≥ 13 V) agora avisa, para em 3 leituras e mantém a medida boa anterior (antes, sobrescrevia com "não percebi").
- Carga: só elétrico 13,3–13,4 V; com o motor a combustão 13,6 V estável de 1.018 a 1.760 rpm.
- `ATRV` rende ~8–10 leituras/s com o polling suspenso.
- Pendentes: Repouso após horas desligado; o `04` físico (o carro não tinha códigos); pausas curtas de ~1,5 s em que o carro não responde (vistas em 16/11) — conferir se o relatório as tolera.
