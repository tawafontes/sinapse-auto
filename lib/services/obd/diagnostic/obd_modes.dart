/// Decoding the OBD-II answers the diagnostic reports read (SAE J1979 /
/// ISO 15031-5) — pure functions on one ECU's reassembled message (see
/// `canMessages`), no I/O.
library;

/// A `P0123`-style code from its two bytes: the top two bits pick the letter
/// (P powertrain, C chassis, B body, U network).
String dtcFromBytes(int a, int b) {
  const letters = ['P', 'C', 'B', 'U'];
  return '${letters[a >> 6]}${(a >> 4) & 0x3}${(a & 0xF).toRadixString(16).toUpperCase()}'
      '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

/// The codes in a mode 03/07/0A message (`43`/`47`/`4A`, then on CAN a count
/// byte, then two bytes per code). `null` when [message] is not that answer.
List<String>? dtcsFromMessage(List<int> message, int mode) {
  if (message.isEmpty || message[0] != mode + 0x40) return null;
  var data = message.sublist(1);
  // CAN answers carry a count byte first: an odd length.
  if (data.length.isOdd) data = data.sublist(1);
  return [
    for (var i = 0; i + 1 < data.length; i += 2)
      if (data[i] != 0 || data[i + 1] != 0) dtcFromBytes(data[i], data[i + 1]),
  ];
}

/// A negative response (`7F <service> <code>`): the code, else `null`.
int? negativeResponse(List<int> message, int service) =>
    message.length >= 3 && message[0] == 0x7F && message[1] == service ? message[2] : null;

/// One readiness monitor: whether the car has it and whether its test ran.
class ObdMonitor {
  const ObdMonitor(this.key, this.name, {required this.supported, required this.complete});

  final String key;
  final String name;
  final bool supported;
  final bool complete;

  Map<String, Object?> toJson() => {'key': key, 'name': name, 'supported': supported, 'complete': complete};

  factory ObdMonitor.fromJson(Map<String, Object?> j) =>
      ObdMonitor(j['key'] as String, j['name'] as String, supported: j['supported'] as bool, complete: j['complete'] as bool);
}

/// PID 01 ("since the codes were cleared") or PID 41 ("this drive cycle").
class MonitorStatus {
  const MonitorStatus({this.mil, this.dtcCount, required this.compression, required this.monitors});

  /// The check-engine light; `null` on PID 41, which does not carry it.
  final bool? mil;
  final int? dtcCount;

  /// Diesel (compression ignition) monitors, else spark ignition.
  final bool compression;
  final List<ObdMonitor> monitors;

  Iterable<ObdMonitor> get supported => monitors.where((m) => m.supported);
  Iterable<ObdMonitor> get incomplete => supported.where((m) => !m.complete);

  Map<String, Object?> toJson() => {
        'mil': mil,
        'dtcCount': dtcCount,
        'compression': compression,
        'monitors': [for (final m in monitors) m.toJson()],
      };

  factory MonitorStatus.fromJson(Map<String, Object?> j) => MonitorStatus(
        mil: j['mil'] as bool?,
        dtcCount: j['dtcCount'] as int?,
        compression: j['compression'] as bool,
        monitors: [for (final m in j['monitors'] as List) ObdMonitor.fromJson((m as Map).cast<String, Object?>())],
      );
}

/// The monitors of PID 01 (or 41, [thisCycle]) from its four data bytes:
/// A the light and the code count, B the three continuous monitors (bits 0–2
/// supported, 4–6 incomplete) and the ignition type (bit 3), C the other
/// monitors supported, D incomplete.
MonitorStatus? monitorStatus(List<int> d, {bool thisCycle = false}) {
  if (d.length < 4) return null;
  final b = d[1], c = d[2], dd = d[3];
  final compression = b & 0x08 != 0;
  ObdMonitor bit(String key, String name, int supportedByte, int incompleteByte, int bitNo) => ObdMonitor(
        key,
        name,
        supported: supportedByte & (1 << bitNo) != 0,
        complete: incompleteByte & (1 << bitNo) == 0,
      );
  final continuous = [
    ObdMonitor('misfire', 'Falhas de ignição', supported: b & 0x01 != 0, complete: b & 0x10 == 0),
    ObdMonitor('fuel', 'Sistema de combustível', supported: b & 0x02 != 0, complete: b & 0x20 == 0),
    ObdMonitor('components', 'Componentes', supported: b & 0x04 != 0, complete: b & 0x40 == 0),
  ];
  final others = compression
      ? [
          bit('nmhcCatalyst', 'Catalisador NMHC', c, dd, 0),
          bit('noxScr', 'NOx / SCR', c, dd, 1),
          bit('boost', 'Pressão do turbo', c, dd, 3),
          bit('exhaustSensor', 'Sensor de gases de escape', c, dd, 5),
          bit('pmFilter', 'Filtro de partículas', c, dd, 6),
          bit('egr', 'EGR e/ou VVT', c, dd, 7),
        ]
      : [
          bit('catalyst', 'Catalisador', c, dd, 0),
          bit('heatedCatalyst', 'Catalisador aquecido', c, dd, 1),
          bit('evap', 'Sistema evaporativo (EVAP)', c, dd, 2),
          bit('secondaryAir', 'Ar secundário', c, dd, 3),
          bit('acRefrigerant', 'Gás do ar-condicionado', c, dd, 4),
          bit('o2Sensor', 'Sonda lambda', c, dd, 5),
          bit('o2Heater', 'Aquecedor da sonda lambda', c, dd, 6),
          bit('egr', 'EGR e/ou VVT', c, dd, 7),
        ];
  return MonitorStatus(
    mil: thisCycle ? null : d[0] & 0x80 != 0,
    dtcCount: thisCycle ? null : d[0] & 0x7F,
    compression: compression,
    monitors: [...continuous, ...others],
  );
}

/// The mode 01 data after `41 <pid>` in [message], else `null`.
List<int>? mode01FromMessage(List<int> message, int pid) =>
    message.length >= 2 && message[0] == 0x41 && message[1] == pid ? message.sublist(2) : null;

/// The mode 02 (freeze frame) data after `42 <pid> <frame>`, else `null`.
List<int>? mode02FromMessage(List<int> message, int pid) =>
    message.length >= 3 && message[0] == 0x42 && message[1] == pid ? message.sublist(3) : null;

/// The records of a mode 09 message for [infoType] (`49 <type> <count>`,
/// then the data), or `null`.
List<int>? mode09FromMessage(List<int> message, int infoType) =>
    message.length >= 3 && message[0] == 0x49 && message[1] == infoType ? message.sublist(3) : null;

String _ascii(Iterable<int> bytes) => String.fromCharCodes(bytes.where((b) => b >= 0x20 && b < 0x7F)).trim();

/// The VIN in a `0902` message: its 17 printable characters.
String? vinFromMessage(List<int> message) {
  final data = mode09FromMessage(message, 0x02);
  if (data == null) return null;
  final text = _ascii(data);
  return text.length >= 17 ? text.substring(text.length - 17) : null;
}

/// The calibration ids in a `0904` message: 16 characters each.
List<String> calibrationIds(List<int> message) {
  final data = mode09FromMessage(message, 0x04);
  if (data == null) return const [];
  return [
    for (var i = 0; i + 16 <= data.length; i += 16)
      if (_ascii(data.sublist(i, i + 16)).isNotEmpty) _ascii(data.sublist(i, i + 16)),
  ];
}

/// The calibration verification numbers in a `0906` message: 4 bytes each.
List<String> calibrationVerificationNumbers(List<int> message) {
  final data = mode09FromMessage(message, 0x06);
  if (data == null) return const [];
  return [
    for (var i = 0; i + 4 <= data.length; i += 4)
      data.sublist(i, i + 4).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(),
  ];
}

/// The ECU's name in a `090A` message (`ECM-EngineControl`), NULs dropped.
String? ecuName(List<int> message) {
  final data = mode09FromMessage(message, 0x0A);
  if (data == null) return null;
  final parts = [
    for (final part in String.fromCharCodes(data.map((b) => b >= 0x20 && b < 0x7F ? b : 0)).split('\u0000'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' ').replaceAll(' -', '-').replaceAll('- ', '-');
}

/// A known ECU id, in words.
String ecuRole(int id) => switch (id) {
      0x7E8 => 'Motor',
      0x7E9 => 'Câmbio',
      _ => 'Central ${id.toRadixString(16).toUpperCase()}',
    };

/// The maker of the car, from the VIN's first three characters (WMI).
String? manufacturerFromVin(String vin) {
  if (vin.length < 3) return null;
  const wmi = {
    '9BW': 'Volkswagen (Brasil)',
    'WVW': 'Volkswagen (Alemanha)',
    'WVG': 'Volkswagen (Alemanha)',
    '3VW': 'Volkswagen (México)',
    '8AW': 'Volkswagen (Argentina)',
    '9BG': 'Chevrolet (Brasil)',
    '9BD': 'Fiat (Brasil)',
    '9BF': 'Ford (Brasil)',
    '93H': 'Honda (Brasil)',
    '9BR': 'Toyota (Brasil)',
    '93Y': 'Renault (Brasil)',
    '9BH': 'Hyundai (Brasil)',
    '9BM': 'Mercedes-Benz (Brasil)',
    '935': 'Citroën (Brasil)',
    '936': 'Peugeot (Brasil)',
    '988': 'Jeep (Brasil)',
    '8AJ': 'Toyota (Argentina)',
    '8AP': 'Fiat (Argentina)',
    'LGW': 'Great Wall / GWM (China)',
  };
  return wmi[vin.substring(0, 3).toUpperCase()];
}

/// The VIN as the screens show it: the maker's three characters and the last
/// four, the rest hidden (`9BW•••••••••••1234`).
String maskVin(String vin) {
  if (vin.length < 8) return vin;
  return '${vin.substring(0, 3)}${'•' * (vin.length - 7)}${vin.substring(vin.length - 4)}';
}

/// What the freeze frame and the usage block read, with their names and units.
const freezeFramePids = <int, (String, String)>{
  0x04: ('Carga do motor', '%'),
  0x05: ('Temperatura do motor', '°C'),
  0x06: ('Correção de mistura curta (banco 1)', '%'),
  0x07: ('Correção de mistura longa (banco 1)', '%'),
  0x0B: ('Pressão no coletor', 'kPa'),
  0x0C: ('Rotação', 'rpm'),
  0x0D: ('Velocidade', 'km/h'),
  0x0F: ('Temperatura de admissão', '°C'),
  0x10: ('Fluxo de ar (MAF)', 'g/s'),
  0x11: ('Borboleta', '%'),
  0x2F: ('Nível de combustível', '%'),
  0x42: ('Tensão do módulo', 'V'),
  0x46: ('Temperatura ambiente', '°C'),
};

/// The usage PIDs: distances (km) and times (minutes) around the codes.
const usagePids = <int, (String, String)>{
  0xA6: ('Odômetro', 'km'),
  0x21: ('Distância com a luz de injeção acesa', 'km'),
  0x31: ('Distância desde que os códigos foram apagados', 'km'),
  0x30: ('Aquecimentos desde que os códigos foram apagados', ''),
  0x4D: ('Tempo com a luz de injeção acesa', 'min'),
  0x4E: ('Tempo desde que os códigos foram apagados', 'min'),
};

/// A usage PID's value from its data bytes.
double? usageValue(int pid, List<int> d) {
  if (d.isEmpty) return null;
  return switch (pid) {
    0xA6 when d.length >= 4 => ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) / 10,
    0x21 || 0x31 || 0x4D || 0x4E when d.length >= 2 => (d[0] * 256 + d[1]).toDouble(),
    0x30 => d[0].toDouble(),
    _ => null,
  };
}
