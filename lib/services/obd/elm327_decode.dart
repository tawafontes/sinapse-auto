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
