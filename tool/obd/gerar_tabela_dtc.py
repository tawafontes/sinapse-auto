"""Gera assets/obd/dtc_generic_pt.json: descrições em português dos códigos de
falha OBD-II genéricos (SAE J2012 / ISO 15031-6), adaptadas — não tradução
literal — e organizadas por família.

Uso (da raiz do repositório):  py -3 tool/obd/gerar_tabela_dtc.py

O JSON é o que o app lê; este script é a fonte. Para corrigir ou acrescentar
um código, edite aqui e gere de novo. Só entram códigos genéricos (segundo
caractere 0, e as faixas genéricas P2xxx, P34xx–P39xx e U0xxx); os do
fabricante (P1xxx, P30xx–P33xx, B1/B2, C1/C2, U1/U2…) aparecem no app como
"código do fabricante".
"""

import json
from pathlib import Path

codes: dict[str, str] = {}


def add(code: str, text: str) -> None:
    if code in codes:
        raise SystemExit(f"código repetido: {code}")
    codes[code] = text


def p(n: int, prefix: str = "P0") -> str:
    return f"{prefix}{n:03d}"


# Sufixos padrão das famílias de sensores: circuito, faixa/desempenho, sinal
# baixo, sinal alto, intermitente.
FIVE = ["mau funcionamento do circuito", "faixa/desempenho fora do esperado", "sinal baixo", "sinal alto", "sinal intermitente"]
FOUR = FIVE[:4]


def family(base: int, name: str, suffixes=FIVE, prefix: str = "P0") -> None:
    for i, s in enumerate(suffixes):
        add(p(base + i, prefix), f"{name}: {s}")


BANKS = {1: "banco 1", 2: "banco 2"}


def o2(b: int, s: int) -> str:
    return f"Sonda lambda (O2) {BANKS[b]}, sensor {s}"


# ───────────────────────── P00xx: ar/combustível e emissões auxiliares ─────
family(1, "Regulador de volume de combustível", ["circuito de controle aberto", "faixa/desempenho fora do esperado", "circuito de controle com sinal baixo", "circuito de controle com sinal alto"])
add("P0005", "Válvula de corte de combustível A: circuito de controle aberto")
add("P0006", "Válvula de corte de combustível A: circuito de controle com sinal baixo")
add("P0007", "Válvula de corte de combustível A: circuito de controle com sinal alto")
add("P0008", "Sistema de posição do motor (sincronismo virabrequim/comando), banco 1: desempenho")
add("P0009", "Sistema de posição do motor (sincronismo virabrequim/comando), banco 2: desempenho")

for bank, base in ((1, 10), (2, 20)):
    for cam, off in (("A (admissão)", 0), ("B (escape)", 3)):
        add(p(base + off), f"Atuador do comando de válvulas {cam}, {BANKS[bank]}: circuito")
        add(p(base + off + 1), f"Comando de válvulas {cam}, {BANKS[bank]}: ponto avançado demais ou desempenho do sistema")
        add(p(base + off + 2), f"Comando de válvulas {cam}, {BANKS[bank]}: ponto atrasado demais")
add("P0016", "Correlação virabrequim/comando, banco 1, sensor A: fora do esperado (possível correia/corrente de distribuição fora do ponto)")
add("P0017", "Correlação virabrequim/comando, banco 1, sensor B: fora do esperado")
add("P0018", "Correlação virabrequim/comando, banco 2, sensor A: fora do esperado")
add("P0019", "Correlação virabrequim/comando, banco 2, sensor B: fora do esperado")
add("P0026", "Solenoide de controle das válvulas de admissão, banco 1: faixa/desempenho")
add("P0027", "Solenoide de controle das válvulas de escape, banco 1: faixa/desempenho")
add("P0028", "Solenoide de controle das válvulas de admissão, banco 2: faixa/desempenho")
add("P0029", "Solenoide de controle das válvulas de escape, banco 2: faixa/desempenho")

for (b, s), base in {(1, 1): 30, (1, 2): 36, (1, 3): 42, (2, 1): 50, (2, 2): 56, (2, 3): 62}.items():
    add(p(base), f"Aquecedor da {o2(b, s).lower()}: circuito de controle")
    add(p(base + 1), f"Aquecedor da {o2(b, s).lower()}: circuito de controle com sinal baixo")
    add(p(base + 2), f"Aquecedor da {o2(b, s).lower()}: circuito de controle com sinal alto")
add("P0033", "Válvula de alívio (bypass) do turbo: circuito de controle")
add("P0034", "Válvula de alívio (bypass) do turbo: circuito de controle com sinal baixo")
add("P0035", "Válvula de alívio (bypass) do turbo: circuito de controle com sinal alto")
add("P0040", "Sinais das sondas lambda trocados: banco 1 sensor 1 / banco 2 sensor 1")
add("P0041", "Sinais das sondas lambda trocados: banco 1 sensor 2 / banco 2 sensor 2")
add("P0045", "Solenoide de controle de pressão do turbo: circuito aberto")
add("P0046", "Solenoide de controle de pressão do turbo: faixa/desempenho")
add("P0047", "Solenoide de controle de pressão do turbo: sinal baixo")
add("P0048", "Solenoide de controle de pressão do turbo: sinal alto")
add("P0068", "Correlação entre pressão do coletor (MAP), fluxo de ar (MAF) e posição da borboleta: fora do esperado (possível entrada falsa de ar)")
add("P0069", "Correlação entre pressão do coletor (MAP) e pressão barométrica: fora do esperado")
family(70, "Sensor de temperatura do ar ambiente")
for base, valve, bank in ((75, "admissão", 1), (78, "escape", 1), (81, "admissão", 2), (84, "escape", 2)):
    add(p(base), f"Solenoide de controle das válvulas de {valve}, {BANKS[bank]}: circuito")
    add(p(base + 1), f"Solenoide de controle das válvulas de {valve}, {BANKS[bank]}: sinal baixo")
    add(p(base + 2), f"Solenoide de controle das válvulas de {valve}, {BANKS[bank]}: sinal alto")
add("P0087", "Pressão da linha/sistema de combustível baixa demais")
add("P0088", "Pressão da linha/sistema de combustível alta demais")
add("P0089", "Regulador de pressão de combustível 1: desempenho")
add("P0090", "Regulador de pressão de combustível 1: circuito de controle")
add("P0091", "Regulador de pressão de combustível 1: circuito de controle com sinal baixo")
add("P0092", "Regulador de pressão de combustível 1: circuito de controle com sinal alto")
add("P0093", "Sistema de combustível: vazamento grande detectado")
add("P0094", "Sistema de combustível: vazamento pequeno detectado")
family(95, "Sensor de temperatura do ar de admissão 2")

# ───────────────────────── P01xx: medição de ar e combustível ──────────────
family(100, "Sensor de fluxo de massa de ar (MAF)")
family(105, "Sensor de pressão absoluta do coletor (MAP) / pressão barométrica")
family(110, "Sensor de temperatura do ar de admissão (IAT)")
family(115, "Sensor de temperatura do líquido de arrefecimento (ECT)")
family(120, "Sensor de posição da borboleta/pedal A")
add("P0125", "Temperatura do líquido de arrefecimento insuficiente para o controle em malha fechada")
add("P0126", "Temperatura do líquido de arrefecimento insuficiente para funcionamento estável")
add("P0127", "Temperatura do ar de admissão alta demais")
add("P0128", "Termostato: líquido de arrefecimento abaixo da temperatura de regulagem (válvula termostática aberta ou sensor)")
add("P0129", "Pressão barométrica baixa demais")

for (b, s), base in {(1, 1): 130, (1, 2): 136, (1, 3): 142, (2, 1): 150, (2, 2): 156, (2, 3): 162}.items():
    name = o2(b, s)
    add(p(base), f"{name}: mau funcionamento do circuito")
    add(p(base + 1), f"{name}: tensão baixa")
    add(p(base + 2), f"{name}: tensão alta")
    add(p(base + 3), f"{name}: resposta lenta")
    add(p(base + 4), f"{name}: sem atividade detectada")
    add(p(base + 5), f"Aquecedor da {name.lower()}: mau funcionamento do circuito")

for bank, base in ((1, 170), (2, 173)):
    add(p(base), f"Correção de combustível (fuel trim), {BANKS[bank]}: mau funcionamento")
    add(p(base + 1), f"Mistura pobre demais, {BANKS[bank]} (possível entrada falsa de ar, pressão de combustível baixa, injetores ou MAF)")
    add(p(base + 2), f"Mistura rica demais, {BANKS[bank]} (possível injetor vazando, pressão de combustível alta ou sonda)")
family(176, "Sensor de composição do combustível (teor de etanol)", FOUR)
family(180, "Sensor de temperatura do combustível A")
family(185, "Sensor de temperatura do combustível B")
family(190, "Sensor de pressão da linha de combustível")
family(195, "Sensor de temperatura do óleo do motor")

# ───────────────────────── P02xx: injetores, turbo ─────────────────────────
add("P0200", "Circuito dos injetores: mau funcionamento")
for n in range(1, 13):
    add(p(200 + n), f"Injetor do cilindro {n}: mau funcionamento do circuito")
add("P0213", "Injetor de partida a frio 1: mau funcionamento")
add("P0214", "Injetor de partida a frio 2: mau funcionamento")
add("P0215", "Solenoide de corte do motor: mau funcionamento")
add("P0216", "Controle do ponto de injeção: mau funcionamento do circuito")
add("P0217", "Superaquecimento do motor")
add("P0218", "Superaquecimento da transmissão")
add("P0219", "Rotação do motor acima do limite")
family(220, "Sensor de posição da borboleta/pedal B")
family(225, "Sensor de posição da borboleta/pedal C")
add("P0230", "Bomba de combustível: circuito primário com mau funcionamento")
add("P0231", "Bomba de combustível: circuito secundário com sinal baixo")
add("P0232", "Bomba de combustível: circuito secundário com sinal alto")
add("P0233", "Bomba de combustível: circuito secundário intermitente")
add("P0234", "Sobrepressão do turbo (overboost)")
family(235, "Sensor de pressão do turbo A", FOUR)
add("P0239", "Sensor de pressão do turbo B: mau funcionamento do circuito")
add("P0240", "Sensor de pressão do turbo B: faixa/desempenho")
add("P0241", "Sensor de pressão do turbo B: sinal baixo")
add("P0242", "Sensor de pressão do turbo B: sinal alto")
family(243, "Solenoide da válvula wastegate do turbo A", ["mau funcionamento", "faixa/desempenho", "sinal baixo", "sinal alto"])
family(247, "Solenoide da válvula wastegate do turbo B", ["mau funcionamento", "faixa/desempenho", "sinal baixo", "sinal alto"])
for n in range(1, 13):
    base = 261 + 3 * (n - 1)
    add(p(base), f"Injetor do cilindro {n}: circuito com sinal baixo")
    add(p(base + 1), f"Injetor do cilindro {n}: circuito com sinal alto")
    add(p(base + 2), f"Cilindro {n}: falha de contribuição/equilíbrio")
add("P0298", "Temperatura do óleo do motor alta demais")
add("P0299", "Pressão do turbo abaixo do esperado (underboost)")

# ───────────────────────── P03xx: ignição e falhas de ignição ──────────────
add("P0300", "Falha de ignição (misfire) aleatória ou em vários cilindros")
for n in range(1, 13):
    add(p(300 + n), f"Falha de ignição (misfire) no cilindro {n}")
add("P0313", "Falha de ignição detectada com nível de combustível baixo")
add("P0314", "Falha de ignição em um único cilindro (não identificado)")
add("P0315", "Variação do sistema de posição do virabrequim não aprendida")
add("P0316", "Falha de ignição detectada na partida (primeiras 1.000 rotações)")
family(320, "Sinal de rotação para a ignição/distribuidor", ["mau funcionamento do circuito", "faixa/desempenho", "sem sinal", "sinal intermitente"])
for bank, base in ((1, 325), (2, 330)):
    family(base, f"Sensor de detonação {bank} ({BANKS[bank]})")
family(335, "Sensor de posição do virabrequim A")
family(340, "Sensor de posição do comando de válvulas A, banco 1")
family(345, "Sensor de posição do comando de válvulas A, banco 2")
add("P0350", "Bobina de ignição: circuito primário/secundário com mau funcionamento")
for n, letter in enumerate("ABCDEFGHIJKL", start=1):
    add(p(350 + n), f"Bobina de ignição {letter} (cilindro {n}): circuito primário/secundário com mau funcionamento")
family(365, "Sensor de posição do comando de válvulas B, banco 1")
add("P0380", "Vela aquecedora (diesel) A: mau funcionamento do circuito")
add("P0381", "Lâmpada indicadora da vela aquecedora (diesel): mau funcionamento do circuito")
family(385, "Sensor de posição do virabrequim B")
family(390, "Sensor de posição do comando de válvulas B, banco 2")

# ───────────────────────── P04xx: emissões auxiliares ──────────────────────
add("P0400", "Recirculação dos gases de escape (EGR): fluxo com mau funcionamento")
add("P0401", "Recirculação dos gases de escape (EGR): fluxo insuficiente")
add("P0402", "Recirculação dos gases de escape (EGR): fluxo excessivo")
add("P0403", "Recirculação dos gases de escape (EGR): circuito de controle")
add("P0404", "Recirculação dos gases de escape (EGR): faixa/desempenho do circuito")
add("P0405", "Sensor A da EGR: sinal baixo")
add("P0406", "Sensor A da EGR: sinal alto")
add("P0407", "Sensor B da EGR: sinal baixo")
add("P0408", "Sensor B da EGR: sinal alto")
add("P0409", "Sensor A da EGR: mau funcionamento do circuito")
add("P0410", "Sistema de injeção de ar secundário: mau funcionamento")
add("P0411", "Sistema de injeção de ar secundário: fluxo incorreto")
add("P0412", "Válvula de comutação A do ar secundário: circuito")
add("P0413", "Válvula de comutação A do ar secundário: circuito aberto")
add("P0414", "Válvula de comutação A do ar secundário: circuito em curto")
add("P0415", "Válvula de comutação B do ar secundário: circuito")
add("P0416", "Válvula de comutação B do ar secundário: circuito aberto")
add("P0417", "Válvula de comutação B do ar secundário: circuito em curto")
add("P0418", "Relé A da bomba de ar secundário: circuito")
add("P0419", "Relé B da bomba de ar secundário: circuito")
for bank, base in ((1, 420), (2, 430)):
    b = BANKS[bank]
    add(p(base), f"Eficiência do catalisador abaixo do limite, {b}")
    add(p(base + 1), f"Eficiência do catalisador de aquecimento (pré-catalisador) abaixo do limite, {b}")
    add(p(base + 2), f"Eficiência do catalisador principal abaixo do limite, {b}")
    add(p(base + 3), f"Eficiência do catalisador aquecido abaixo do limite, {b}")
    add(p(base + 4), f"Temperatura do catalisador aquecido abaixo do limite, {b}")
    family(base + 5, f"Sensor de temperatura do catalisador, {b}", FOUR)
    add(p(base + 9), f"Aquecedor do catalisador, {b}: circuito de controle")
add("P0440", "Sistema de controle de emissões evaporativas (EVAP/cânister): mau funcionamento")
add("P0441", "EVAP: fluxo de purga incorreto")
add("P0442", "EVAP: vazamento pequeno detectado")
add("P0443", "EVAP: válvula de purga do cânister, circuito")
add("P0444", "EVAP: válvula de purga do cânister, circuito aberto")
add("P0445", "EVAP: válvula de purga do cânister, circuito em curto")
add("P0446", "EVAP: controle do respiro (vent), circuito")
add("P0447", "EVAP: controle do respiro (vent), circuito aberto")
add("P0448", "EVAP: controle do respiro (vent), circuito em curto")
add("P0449", "EVAP: válvula/solenoide do respiro (vent), circuito")
family(450, "EVAP: sensor de pressão")
add("P0455", "EVAP: vazamento grande detectado (verifique a tampa do tanque)")
add("P0456", "EVAP: vazamento muito pequeno detectado")
add("P0457", "EVAP: vazamento detectado (tampa do tanque solta ou ausente)")
add("P0458", "EVAP: válvula de purga, circuito com sinal baixo")
add("P0459", "EVAP: válvula de purga, circuito com sinal alto")
family(460, "Sensor de nível de combustível A")
family(465, "EVAP: sensor de fluxo de purga")
family(470, "Sensor de pressão do escape")
family(475, "Válvula de controle de pressão do escape")
add("P0480", "Eletroventilador 1: circuito de controle")
add("P0481", "Eletroventilador 2: circuito de controle")
add("P0482", "Eletroventilador 3: circuito de controle")
add("P0483", "Eletroventilador: falha na verificação de plausibilidade")
add("P0484", "Eletroventilador: sobrecorrente no circuito")
add("P0485", "Eletroventilador: circuito de alimentação/terra")
add("P0491", "Ar secundário: fluxo insuficiente, banco 1")
add("P0492", "Ar secundário: fluxo insuficiente, banco 2")
add("P0496", "EVAP: fluxo de purga alto (purga sem comando)")
add("P0497", "EVAP: fluxo de purga baixo")
add("P0498", "EVAP: controle do respiro (vent), sinal baixo")
add("P0499", "EVAP: controle do respiro (vent), sinal alto")

# ───────────────────────── P05xx: velocidade, marcha lenta, entradas ───────
add("P0500", "Sensor de velocidade do veículo A: mau funcionamento")
add("P0501", "Sensor de velocidade do veículo A: faixa/desempenho")
add("P0502", "Sensor de velocidade do veículo A: sinal baixo")
add("P0503", "Sensor de velocidade do veículo A: sinal intermitente/errático/alto")
add("P0505", "Sistema de controle da marcha lenta: mau funcionamento")
add("P0506", "Marcha lenta: rotação abaixo do esperado")
add("P0507", "Marcha lenta: rotação acima do esperado (possível entrada falsa de ar)")
add("P0508", "Controle da marcha lenta: circuito com sinal baixo")
add("P0509", "Controle da marcha lenta: circuito com sinal alto")
add("P0510", "Interruptor de borboleta fechada: mau funcionamento")
add("P0512", "Solicitação de partida: circuito")
add("P0513", "Chave do imobilizador inválida")
add("P0515", "Sensor de temperatura da bateria: circuito")
add("P0516", "Sensor de temperatura da bateria: sinal baixo")
add("P0517", "Sensor de temperatura da bateria: sinal alto")
family(520, "Sensor/interruptor de pressão do óleo do motor", FOUR)
add("P0524", "Pressão do óleo do motor baixa demais — pare o motor e verifique o nível")
family(530, "Sensor de pressão do gás do ar-condicionado A", FOUR)
add("P0534", "Ar-condicionado: perda de carga de gás refrigerante")
add("P0544", "Sensor de temperatura dos gases de escape, banco 1 sensor 1: circuito")
add("P0545", "Sensor de temperatura dos gases de escape, banco 1 sensor 1: sinal baixo")
add("P0546", "Sensor de temperatura dos gases de escape, banco 1 sensor 1: sinal alto")
family(550, "Sensor de pressão da direção hidráulica")
add("P0555", "Sensor de pressão do servofreio: circuito")
add("P0560", "Tensão do sistema elétrico: mau funcionamento")
add("P0561", "Tensão do sistema elétrico: instável")
add("P0562", "Tensão do sistema elétrico: baixa (bateria ou carga)")
add("P0563", "Tensão do sistema elétrico: alta (regulador de carga)")
add("P0564", "Controle de velocidade de cruzeiro: entrada multifunção A, circuito")
add("P0571", "Interruptor do freio A: circuito")
add("P0572", "Interruptor do freio A: sinal baixo")
add("P0573", "Interruptor do freio A: sinal alto")
add("P0597", "Aquecedor da válvula termostática: circuito de controle aberto")
add("P0598", "Aquecedor da válvula termostática: circuito de controle com sinal baixo")
add("P0599", "Aquecedor da válvula termostática: circuito de controle com sinal alto")

# ───────────────────────── P06xx: módulo de controle e saídas ──────────────
for code, text in {
    600: "Linha de comunicação serial: mau funcionamento",
    601: "Módulo de controle: erro de checksum da memória interna",
    602: "Módulo de controle: erro de programação",
    603: "Módulo de controle: erro na memória mantida (KAM)",
    604: "Módulo de controle: erro na memória RAM",
    605: "Módulo de controle: erro na memória ROM",
    606: "Módulo de controle: falha do processador",
    607: "Módulo de controle: desempenho",
    608: "Módulo de controle: saída do sensor de velocidade A",
    609: "Módulo de controle: saída do sensor de velocidade B",
    610: "Módulo de controle: erro nas opções do veículo",
    611: "Módulo de controle dos injetores: desempenho",
    612: "Módulo de controle dos injetores: controle do relé",
    613: "Processador do módulo da transmissão (TCM)",
    614: "Incompatibilidade entre módulo do motor (ECM) e da transmissão (TCM)",
    615: "Relé de partida: circuito",
    616: "Relé de partida: sinal baixo",
    617: "Relé de partida: sinal alto",
    620: "Alternador: circuito de controle",
    621: "Alternador: circuito da lâmpada (terminal L)",
    622: "Alternador: circuito de campo (terminal F)",
    625: "Alternador: terminal de campo com sinal baixo",
    626: "Alternador: terminal de campo com sinal alto",
    627: "Bomba de combustível A: circuito de controle aberto",
    628: "Bomba de combustível A: circuito de controle com sinal baixo",
    629: "Bomba de combustível A: circuito de controle com sinal alto",
    630: "VIN não programado ou incompatível no módulo do motor",
    633: "Chave do imobilizador não programada no módulo do motor",
    638: "Atuador da borboleta, banco 1: faixa/desempenho",
    639: "Atuador da borboleta, banco 2: faixa/desempenho",
    641: "Tensão de referência dos sensores A: circuito aberto",
    642: "Tensão de referência dos sensores A: baixa",
    643: "Tensão de referência dos sensores A: alta",
    645: "Relé da embreagem do compressor do ar-condicionado: circuito de controle",
    646: "Relé da embreagem do compressor do ar-condicionado: sinal baixo",
    647: "Relé da embreagem do compressor do ar-condicionado: sinal alto",
    650: "Lâmpada de injeção (MIL): circuito de controle",
    651: "Tensão de referência dos sensores B: circuito aberto",
    652: "Tensão de referência dos sensores B: baixa",
    653: "Tensão de referência dos sensores B: alta",
    654: "Saída de rotação do motor: circuito",
    655: "Saída da lâmpada de motor quente: circuito",
    657: "Tensão de alimentação dos atuadores A: circuito aberto",
    658: "Tensão de alimentação dos atuadores A: baixa",
    659: "Tensão de alimentação dos atuadores A: alta",
    660: "Válvula de geometria variável do coletor de admissão, banco 1: circuito aberto",
    661: "Válvula de geometria variável do coletor de admissão, banco 1: sinal baixo",
    662: "Válvula de geometria variável do coletor de admissão, banco 1: sinal alto",
    685: "Relé de alimentação do módulo do motor: circuito de controle aberto",
    686: "Relé de alimentação do módulo do motor: sinal baixo",
    687: "Relé de alimentação do módulo do motor: sinal alto",
    688: "Relé de alimentação do módulo do motor: circuito de leitura aberto",
    689: "Relé de alimentação do módulo do motor: leitura baixa",
    690: "Relé de alimentação do módulo do motor: leitura alta",
    691: "Eletroventilador 1: circuito de controle com sinal baixo",
    692: "Eletroventilador 1: circuito de controle com sinal alto",
    693: "Eletroventilador 2: circuito de controle com sinal baixo",
    694: "Eletroventilador 2: circuito de controle com sinal alto",
    697: "Tensão de referência dos sensores C: circuito aberto",
    698: "Tensão de referência dos sensores C: baixa",
    699: "Tensão de referência dos sensores C: alta",
}.items():
    add(p(code), text)

# ───────────────────────── P07xx: transmissão ──────────────────────────────
add("P0700", "Sistema de controle da transmissão: falha registrada no módulo da transmissão (leia os códigos do TCM)")
add("P0701", "Sistema de controle da transmissão: faixa/desempenho")
add("P0702", "Sistema de controle da transmissão: falha elétrica")
add("P0703", "Interruptor do freio/conversor de torque B: circuito")
add("P0704", "Interruptor do pedal de embreagem: circuito de entrada")
family(705, "Sensor de posição da alavanca de câmbio (PRNDL) A")
family(710, "Sensor de temperatura do fluido da transmissão A")
family(715, "Sensor de rotação de entrada/turbina A", ["mau funcionamento do circuito", "faixa/desempenho", "sem sinal", "sinal intermitente"])
add("P0719", "Interruptor do freio/conversor de torque B: sinal baixo")
family(720, "Sensor de rotação de saída da transmissão", ["mau funcionamento do circuito", "faixa/desempenho", "sem sinal", "sinal intermitente"])
add("P0724", "Interruptor do freio/conversor de torque B: sinal alto")
family(725, "Entrada de rotação do motor na transmissão", ["mau funcionamento do circuito", "faixa/desempenho", "sem sinal", "sinal intermitente"])
add("P0729", "Relação incorreta na 6ª marcha")
add("P0730", "Relação de marcha incorreta")
for n in range(1, 6):
    add(p(730 + n), f"Relação incorreta na {n}ª marcha")
add("P0736", "Relação incorreta na marcha à ré")
SOL = ["mau funcionamento", "desempenho ou travado desligado", "travado ligado", "falha elétrica", "intermitente"]
family(740, "Embreagem do conversor de torque", SOL)
family(745, "Solenoide de controle de pressão A", SOL)
for letter, base in zip("ABCDE", (750, 755, 760, 765, 770)):
    family(base, f"Solenoide de troca de marcha {letter}", SOL)
add("P0780", "Falha na troca de marcha")
add("P0781", "Falha na troca 1ª→2ª")
add("P0782", "Falha na troca 2ª→3ª")
add("P0783", "Falha na troca 3ª→4ª")
add("P0784", "Falha na troca 4ª→5ª")
add("P0850", "Interruptor de estacionamento/neutro: circuito de entrada")

# ───────────────────────── P0Axx: propulsão híbrida ────────────────────────
for code, text in {
    "P0A09": "Conversor DC/DC: circuito de estado com sinal baixo",
    "P0A0A": "Sistema de alta tensão: circuito de intertravamento (interlock)",
    "P0A0F": "Motor a combustão não pegou (sistema híbrido)",
    "P0A1F": "Módulo de controle da bateria de alta tensão (BECM)",
    "P0A3F": "Motor elétrico A: sensor de posição, circuito",
    "P0A40": "Motor elétrico A: sensor de posição, faixa/desempenho",
    "P0A78": "Inversor do motor elétrico A: desempenho",
    "P0A7A": "Inversor do gerador: desempenho",
    "P0A7F": "Bateria de alta tensão: deterioração",
    "P0A80": "Bateria de alta tensão: substituir o conjunto (células degradadas)",
    "P0A93": "Inversor: desempenho do sistema de arrefecimento",
    "P0A94": "Conversor DC/DC: desempenho (carga da bateria de 12 V)",
    "P0AA6": "Bateria de alta tensão: falha de isolamento",
}.items():
    add(code, text)

# ───────────────────────── P2xxx genéricos ─────────────────────────────────
for bank, base in ((1, 96), (2, 98)):
    add(p(base, "P2"), f"Correção de combustível pós-catalisador pobre demais, {BANKS[bank]}")
    add(p(base + 1, "P2"), f"Correção de combustível pós-catalisador rica demais, {BANKS[bank]}")
add("P2088", "Atuador do comando de válvulas A (admissão), banco 1: circuito de controle com sinal baixo")
add("P2089", "Atuador do comando de válvulas A (admissão), banco 1: circuito de controle com sinal alto")
add("P2090", "Atuador do comando de válvulas B (escape), banco 1: circuito de controle com sinal baixo")
add("P2091", "Atuador do comando de válvulas B (escape), banco 1: circuito de controle com sinal alto")
for code, text in {
    "P2100": "Motor do atuador da borboleta: circuito aberto",
    "P2101": "Motor do atuador da borboleta: faixa/desempenho",
    "P2102": "Motor do atuador da borboleta: sinal baixo",
    "P2103": "Motor do atuador da borboleta: sinal alto",
    "P2104": "Atuador da borboleta: marcha lenta forçada (modo de emergência)",
    "P2105": "Atuador da borboleta: motor desligado à força (modo de emergência)",
    "P2106": "Atuador da borboleta: potência limitada (modo de emergência)",
    "P2107": "Módulo do atuador da borboleta: falha do processador",
    "P2108": "Módulo do atuador da borboleta: desempenho",
    "P2110": "Atuador da borboleta: rotação limitada (modo de emergência)",
    "P2111": "Atuador da borboleta: travado aberto",
    "P2112": "Atuador da borboleta: travado fechado",
    "P2118": "Motor do atuador da borboleta: corrente fora da faixa",
    "P2119": "Corpo de borboleta: faixa/desempenho (sujeira ou desgaste)",
}.items():
    add(code, text)
family(120, "Sensor de posição da borboleta/pedal D", prefix="P2")
family(125, "Sensor de posição da borboleta/pedal E", prefix="P2")
family(130, "Sensor de posição da borboleta/pedal F", prefix="P2")
add("P2135", "Sensores de posição da borboleta A/B: correlação de tensão")
add("P2138", "Sensores de posição do pedal D/E: correlação de tensão")
for bank, base in ((1, 177), (2, 179)):
    add(p(base, "P2"), f"Mistura pobre demais fora da marcha lenta, {BANKS[bank]}")
    add(p(base + 1, "P2"), f"Mistura rica demais fora da marcha lenta, {BANKS[bank]}")
add("P2181", "Sistema de arrefecimento: desempenho")
for bank, base in ((1, 187), (2, 189)):
    add(p(base, "P2"), f"Mistura pobre demais em marcha lenta, {BANKS[bank]}")
    add(p(base + 1, "P2"), f"Mistura rica demais em marcha lenta, {BANKS[bank]}")
for (b, s), base in {(1, 1): ("P2", 195), (2, 1): ("P2", 197), (1, 2): ("P2", 270), (2, 2): ("P2", 272)}.items():
    prefix, n = base
    add(p(n, prefix), f"{o2(b, s)}: sinal travado em pobre")
    add(p(n + 1, prefix), f"{o2(b, s)}: sinal travado em rico")
add("P2279", "Vazamento no sistema de admissão de ar (entrada falsa de ar)")
add("P2293", "Regulador de pressão de combustível 2: desempenho")
for n, letter in enumerate("ABCDEFGHIJKL"):
    base = 300 + 3 * n
    add(p(base, "P2"), f"Bobina de ignição {letter}: circuito de controle primário com sinal baixo")
    add(p(base + 1, "P2"), f"Bobina de ignição {letter}: circuito de controle primário com sinal alto")
    add(p(base + 2, "P2"), f"Bobina de ignição {letter}: circuito secundário")
add("P2401", "EVAP: bomba de detecção de vazamento, circuito de controle com sinal baixo")
add("P2402", "EVAP: bomba de detecção de vazamento, circuito de controle com sinal alto")
add("P2422", "EVAP: válvula do respiro (vent) travada fechada")
add("P2440", "Válvula de comutação do ar secundário, banco 1: travada aberta")
add("P2610", "Módulo do motor: desempenho do temporizador interno de motor desligado")
add("P2635", "Bomba de combustível A: vazão baixa/desempenho")
add("P2A00", f"{o2(1, 1)}: faixa/desempenho do circuito")
add("P2A03", f"{o2(2, 1)}: faixa/desempenho do circuito")

# ───────────────────────── U0xxx: rede de comunicação ──────────────────────
for code, text in {
    "U0001": "Rede CAN de alta velocidade: falha de comunicação",
    "U0002": "Rede CAN de alta velocidade: desempenho",
    "U0073": "Barramento de comunicação A do módulo desligado (bus off)",
    "U0074": "Barramento de comunicação B do módulo desligado (bus off)",
    "U0100": "Perda de comunicação com o módulo do motor (ECM/PCM) A",
    "U0101": "Perda de comunicação com o módulo da transmissão (TCM)",
    "U0102": "Perda de comunicação com o módulo da caixa de transferência",
    "U0103": "Perda de comunicação com o módulo da alavanca de câmbio",
    "U0104": "Perda de comunicação com o módulo do controle de cruzeiro",
    "U0105": "Perda de comunicação com o módulo dos injetores",
    "U0107": "Perda de comunicação com o módulo do atuador da borboleta",
    "U0109": "Perda de comunicação com o módulo da bomba de combustível",
    "U0110": "Perda de comunicação com o módulo do motor elétrico A",
    "U0111": "Perda de comunicação com o módulo da bateria de alta tensão A",
    "U0112": "Perda de comunicação com o módulo da bateria de alta tensão B",
    "U0115": "Perda de comunicação com o módulo do motor (ECM) B",
    "U0121": "Perda de comunicação com o módulo do ABS",
    "U0122": "Perda de comunicação com o módulo de controle de estabilidade",
    "U0123": "Perda de comunicação com o sensor de guinada (yaw rate)",
    "U0124": "Perda de comunicação com o sensor de aceleração lateral",
    "U0126": "Perda de comunicação com o sensor de ângulo do volante",
    "U0128": "Perda de comunicação com o módulo do freio de estacionamento",
    "U0129": "Perda de comunicação com o módulo do sistema de freios",
    "U0131": "Perda de comunicação com o módulo da direção elétrica/assistida",
    "U0140": "Perda de comunicação com o módulo da carroceria (BCM)",
    "U0151": "Perda de comunicação com o módulo dos airbags",
    "U0155": "Perda de comunicação com o painel de instrumentos",
    "U0164": "Perda de comunicação com o módulo do ar-condicionado",
    "U0167": "Perda de comunicação com o módulo do imobilizador",
    "U0184": "Perda de comunicação com o rádio/central multimídia",
    "U0293": "Perda de comunicação com o módulo de controle da propulsão híbrida",
    "U0300": "Incompatibilidade de software entre módulos",
    "U0401": "Dados inválidos recebidos do módulo do motor (ECM/PCM) A",
    "U0402": "Dados inválidos recebidos do módulo da transmissão (TCM)",
    "U0415": "Dados inválidos recebidos do módulo do ABS",
    "U0422": "Dados inválidos recebidos do módulo da carroceria (BCM)",
    "U0428": "Dados inválidos recebidos do sensor de ângulo do volante",
}.items():
    add(code, text)

# ───────────────────────── sistemas (para códigos sem descrição) ───────────
systems = {
    "P00": "Medição de ar e combustível e controle auxiliar de emissões",
    "P01": "Medição de ar e combustível",
    "P02": "Medição de ar e combustível (injetores)",
    "P03": "Ignição e falhas de ignição",
    "P04": "Controles auxiliares de emissões",
    "P05": "Velocidade do veículo, marcha lenta e entradas auxiliares",
    "P06": "Módulo de controle e saídas auxiliares",
    "P07": "Transmissão",
    "P08": "Transmissão",
    "P09": "Transmissão",
    "P0A": "Propulsão híbrida/elétrica",
    "P0B": "Propulsão híbrida/elétrica",
    "P0C": "Propulsão híbrida/elétrica",
    "P20": "Medição de ar e combustível e controle auxiliar de emissões",
    "P21": "Medição de ar e combustível e controle auxiliar de emissões",
    "P22": "Medição de ar e combustível e controle auxiliar de emissões",
    "P23": "Ignição e falhas de ignição",
    "P24": "Controles auxiliares de emissões",
    "P25": "Entradas auxiliares",
    "P26": "Módulo de controle e saídas auxiliares",
    "P27": "Transmissão",
    "P28": "Transmissão",
    "P29": "Medição de ar e combustível e controle auxiliar de emissões",
    "P2A": "Medição de ar e combustível e controle auxiliar de emissões",
    "P34": "Desativação de cilindros",
    "U00": "Rede de comunicação (elétrica)",
    "U01": "Rede de comunicação (perda de comunicação)",
    "U02": "Rede de comunicação (perda de comunicação)",
    "U03": "Rede de comunicação (software)",
    "U04": "Rede de comunicação (dados inválidos)",
}

out = {
    "versao": 1,
    "nota": "Descrições adaptadas em português dos códigos OBD-II genéricos (SAE J2012/ISO 15031-6). "
    "Gerado por tool/obd/gerar_tabela_dtc.py — não edite à mão.",
    "faixasDoFabricante": ["P1", "P30", "P31", "P32", "P33", "B1", "B2", "C1", "C2", "U1", "U2"],
    "sistemas": systems,
    "codigos": dict(sorted(codes.items())),
}

target = Path(__file__).resolve().parents[2] / "assets" / "obd" / "dtc_generic_pt.json"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
print(f"{len(codes)} códigos -> {target}")
