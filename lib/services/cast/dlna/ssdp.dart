/// Parse an SSDP HTTP-like datagram into header map (lowercased names).
Map<String, String> parseSsdpHeaders(String packet) {
  final out = <String, String>{};
  final lines = packet.split(RegExp(r'\r?\n'));
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) break;
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final name = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    if (name.isNotEmpty) out[name] = value;
  }
  return out;
}

bool ssdpLooksLikeMediaRenderer(Map<String, String> headers) {
  final st = headers['st'] ?? '';
  final nt = headers['nt'] ?? '';
  final usn = headers['usn'] ?? '';
  final hay = '$st $nt $usn'.toLowerCase();
  return hay.contains('mediarenderer') ||
      hay.contains('avtransport') ||
      hay.contains('schemas-upnp-org:device:media');
}

Uri? resolveUpnpUrl(Uri base, String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return base.resolve(trimmed);
}
