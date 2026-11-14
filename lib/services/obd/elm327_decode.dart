/// Reading what an ELM327 says (OBD-II phase 0) — pure functions, no I/O.
///
/// The adapter is set up with echo, linefeeds, spaces and headers off (ATE0
/// ATL0 ATS0 ATH0), so a mode 01 answer looks like `410C1AF8`; a multi-frame CAN
/// answer (the VIN) comes as numbered lines (`014`, `0:490201...`, `1:...`).
/// Both are parsed with or without spaces, since phase 0 also records the raw
/// answers to ATZ/ATI before those settings take effect.
library;

/// The answer lines, without blanks, the `SEARCHING...` notice and the echo of
/// [command] (in case echo was still on).
List<String> responseLines(String raw, {String? command}) {
  final lines = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.toUpperCase().startsWith('SEARCHING')) continue;
    if (command != null && t.replaceAll(' ', '').toUpperCase() == command.toUpperCase()) continue;
    lines.add(t);
  }
  return lines;
}

const _errorWords = ['NO DATA', 'UNABLE TO CONNECT', 'CAN ERROR', 'BUS INIT', 'BUS ERROR', 'STOPPED', '?', 'ERROR', 'BUFFER FULL'];

/// The ELM327 error in [raw], if any (`NO DATA`, `UNABLE TO CONNECT`, `?`…).
String? elmError(String raw) {
  for (final line in responseLines(raw)) {
    final upper = line.toUpperCase();
    for (final word in _errorWords) {
      if (word == '?' ? upper == '?' : upper.contains(word)) return line;
    }
  }
  return null;
}

/// Every data byte in [raw]: hex pairs, with the line numbers of a multi-frame
/// answer (`0:`) and its leading byte-count line dropped.
List<int> responseBytes(String raw, {String? command}) {
  final bytes = <int>[];
  final lines = responseLines(raw, command: command);
  final multiFrame = lines.any((l) => RegExp(r'^[0-9A-F]:').hasMatch(l.toUpperCase()));
  for (var line in lines) {
    line = line.toUpperCase().replaceAll(' ', '');
    if (multiFrame) {
      final m = RegExp(r'^[0-9A-F]:(.*)$').firstMatch(line);
      if (m == null) continue; // the byte-count line ("014")
      line = m.group(1)!;
    }
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(line) || line.length.isOdd) continue;
    for (var i = 0; i < line.length; i += 2) {
      bytes.add(int.parse(line.substring(i, i + 2), radix: 16));
    }
  }
  return bytes;
}

/// The data bytes of a mode 01 answer for [pid]: what follows `41 <pid>`, or
/// `null` when the answer is not that (an error, another PID).
List<int>? mode01Data(String raw, int pid) {
  final bytes = responseBytes(raw);
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0x41 && bytes[i + 1] == pid) return bytes.sublist(i + 2);
  }
  return null;
}

/// The PIDs a "supported PIDs" answer (`0100`, `0120`, … — [base] 0x00, 0x20…)
/// declares: bit 7 of the first byte is PID base+1. `null` when there is no
/// answer for it.
List<int>? supportedPids(String raw, int base) {
  final data = mode01Data(raw, base);
  if (data == null || data.length < 4) return null;
  final pids = <int>[];
  for (var byte = 0; byte < 4; byte++) {
    for (var bit = 0; bit < 8; bit++) {
      if (data[byte] & (0x80 >> bit) != 0) pids.add(base + byte * 8 + bit + 1);
    }
  }
  return pids;
}

/// The 17-character VIN of a `0902` answer: the printable characters after
/// `49 02 <n>`, last 17. `null` when there are not 17.
String? vinFrom(String raw) {
  final bytes = responseBytes(raw);
  final start = () {
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x49 && bytes[i + 1] == 0x02) return i + 3; // skip the record count byte
    }
    return -1;
  }();
  if (start < 0) return null;
  final chars = [
    for (final b in bytes.skip(start))
      if (b >= 0x30 && b <= 0x5A) String.fromCharCode(b),
  ];
  if (chars.length < 17) return null;
  return chars.sublist(chars.length - 17).join();
}

/// A readable value for the PIDs phase 0 displays live, or `null`.
String? describeMode01(String raw, int pid) {
  final d = mode01Data(raw, pid);
  if (d == null || d.isEmpty) return null;
  int a() => d[0];
  int ab() => d.length >= 2 ? d[0] * 256 + d[1] : d[0];
  return switch (pid) {
    0x04 => 'carga ${(a() * 100 / 255).toStringAsFixed(0)}%',
    0x05 => 'motor ${a() - 40} °C',
    0x0C => 'rotação ${(ab() / 4).toStringAsFixed(0)} rpm',
    0x0D => 'velocidade ${a()} km/h',
    0x0F => 'admissão ${a() - 40} °C',
    0x10 => 'MAF ${(ab() / 100).toStringAsFixed(2)} g/s',
    0x11 => 'acelerador ${(a() * 100 / 255).toStringAsFixed(0)}%',
    0x2F => 'combustível ${(a() * 100 / 255).toStringAsFixed(0)}%',
    0x42 => 'módulo ${(ab() / 1000).toStringAsFixed(2)} V',
    0x51 => 'tipo de combustível ${a()}',
    0x5B => 'bateria híbrida ${(a() * 100 / 255).toStringAsFixed(0)}%',
    0x01 => 'luz de injeção ${a() & 0x80 != 0 ? 'ACESA' : 'apagada'}, ${a() & 0x7F} código(s)',
    _ => null,
  };
}

/// The diagnostic trouble codes of a mode 03/07/0A answer ([responseByte]
/// 0x43/0x47/0x4A), as `P0123`-style codes.
List<String> troubleCodes(String raw, int responseByte) {
  final bytes = responseBytes(raw);
  final i = bytes.indexOf(responseByte);
  if (i < 0) return const [];
  var data = bytes.sublist(i + 1);
  // CAN answers carry a count byte first; pre-CAN ones do not. Pairs of zeros
  // are padding either way.
  if (data.length.isOdd) data = data.sublist(1);
  const letters = ['P', 'C', 'B', 'U'];
  final codes = <String>[];
  for (var j = 0; j + 1 < data.length; j += 2) {
    final a = data[j];
    final b = data[j + 1];
    if (a == 0 && b == 0) continue;
    codes.add('${letters[a >> 6]}${(a >> 4) & 0x3}${(a & 0xF).toRadixString(16).toUpperCase()}'
        '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}');
  }
  return codes;
}

/// How many data bytes a mode 01 PID answers with (SAE J1979), for the PIDs
/// this app reads or may read. `null` for a PID not listed: a multi-PID answer
/// cannot be walked past it.
int? mode01DataLength(int pid) {
  if (pid % 0x20 == 0) return 4; // the "supported PIDs" bitmaps
  return switch (pid) {
    0x01 || 0x41 || 0x4F || 0x50 => 4,
    0x03 || 0x0C || 0x10 || 0x1F || 0x21 || 0x22 || 0x23 || 0x31 || 0x32 || 0x42 || 0x43 || 0x44 || 0x4D || 0x4E => 2,
    >= 0x14 && <= 0x1B => 2,
    >= 0x3C && <= 0x3F => 2,
    0x04 || 0x05 || 0x06 || 0x07 || 0x08 || 0x09 || 0x0A || 0x0B || 0x0D || 0x0E || 0x0F || 0x11 || 0x1C || 0x2C || 0x2D || 0x2E || 0x2F || 0x30 || 0x33 => 1,
    >= 0x45 && <= 0x4C => 1,
    0x51 || 0x52 || 0x5A || 0x5B || 0x5C => 1,
    _ => null,
  };
}

/// The data bytes of each of [requested] PIDs in one mode 01 answer — single
/// or multi-PID (`010C040D11`), single or multi-frame (ISO-TP numbered lines),
/// with or without spaces. Walks `41 <pid> <data> <pid> <data> …` from the
/// first `41`, so with headers off only the first ECU's answer counts: phase 1
/// addresses the engine alone (ATSH7E0) precisely so there is only one. A PID
/// the ECU left out (unsupported) is simply absent from the result; trailing
/// padding (`55`, `AA`, `00`) stops the walk.
Map<int, List<int>> mode01Values(String raw, Iterable<int> requested, {String? command}) {
  final wanted = requested.toSet();
  final bytes = responseBytes(raw, command: command);
  final start = bytes.indexOf(0x41);
  final values = <int, List<int>>{};
  if (start < 0) return values;
  var i = start + 1;
  while (i < bytes.length) {
    final pid = bytes[i];
    if (!wanted.contains(pid) || values.containsKey(pid)) break;
    final length = mode01DataLength(pid);
    if (length == null || i + 1 + length > bytes.length) break;
    values[pid] = bytes.sublist(i + 1, i + 1 + length);
    i += 1 + length;
  }
  return values;
}

/// The physical value of a mode 01 PID from its data bytes, in the unit the
/// app shows: rpm, %, °C, km/h, V. `null` for a PID this app does not convert.
double? mode01Physical(int pid, List<int> d) {
  if (d.isEmpty) return null;
  final a = d[0];
  final ab = d.length >= 2 ? d[0] * 256 + d[1] : d[0];
  return switch (pid) {
    0x0C => ab / 4,
    0x04 || 0x11 || 0x2F || 0x5B => a * 100 / 255,
    0x05 || 0x0F || 0x46 => (a - 40).toDouble(),
    0x0D => a.toDouble(),
    0x42 => ab / 1000,
    _ => null,
  };
}

/// The adapter's own battery reading (`ATRV` → `13.3V`), or `null`.
double? adapterVoltage(String raw) {
  for (final line in responseLines(raw, command: 'ATRV')) {
    final m = RegExp(r'^(\d+(?:\.\d+)?)\s*V$', caseSensitive: false).firstMatch(line);
    if (m != null) return double.parse(m.group(1)!);
  }
  return null;
}

/// The single-frame answers of an 11-bit CAN reply with headers on (ATH1 ATS0),
/// by CAN id: `7E8064100BE3EB813` → `0x7E8: [41 00 BE 3E B8 13]`. Lines that
/// are not a single frame (a multi-frame part, an error) are skipped — only
/// used to find which ECU is the engine, from its `0100` answer.
Map<int, List<int>> canSingleFrames(String raw) {
  final frames = <int, List<int>>{};
  for (final line in responseLines(raw)) {
    final t = line.toUpperCase().replaceAll(' ', '');
    if (!RegExp(r'^[0-9A-F]{3}[0-9A-F]{4,}$').hasMatch(t) || (t.length - 3).isOdd) continue;
    final id = int.parse(t.substring(0, 3), radix: 16);
    final payload = [for (var i = 3; i < t.length; i += 2) int.parse(t.substring(i, i + 2), radix: 16)];
    final pci = payload.first;
    if (pci >> 4 != 0) continue; // not a single frame
    final length = pci & 0x0F;
    if (length == 0 || payload.length < 1 + length) continue;
    frames.putIfAbsent(id, () => payload.sublist(1, 1 + length));
  }
  return frames;
}

/// Which ECU is the engine, from a headers-on `0100` answer: the 11-bit CAN id
/// (0x7E8–0x7EF) whose bitmap declares the most PIDs (on the Nivus, 7E8 with 18
/// against 7E9 with 7), lowest id on a tie. `null` when no such answer.
int? engineEcuFrom(String raw) {
  int? best;
  var bestCount = -1;
  final frames = canSingleFrames(raw);
  for (final id in frames.keys.toList()..sort()) {
    if (id < 0x7E8 || id > 0x7EF) continue;
    final data = frames[id]!;
    if (data.length < 6 || data[0] != 0x41 || data[1] != 0x00) continue;
    var count = 0;
    for (final b in data.sublist(2, 6)) {
      for (var bit = 0; bit < 8; bit++) {
        if (b & (1 << bit) != 0) count++;
      }
    }
    if (count > bestCount) {
      best = id;
      bestCount = count;
    }
  }
  return best;
}
