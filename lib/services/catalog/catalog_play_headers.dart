/// Playback HTTP headers for catalog `playUrl` (not catalog-fetch auth).
///
/// Catalog JSON may set a map (`httpHeaders` / `headers` / `playHeaders` /
/// `playHttpHeaders`) and/or a dedicated User-Agent (`userAgent` /
/// `user-agent` / `ua`). Later maps overlay earlier ones; User-Agent is
/// stored as the canonical `User-Agent` key.
Map<String, String> catalogPlaybackHeadersFromJson(
  Map<String, dynamic>? map, {
  Map<String, String> inherit = const {},
}) {
  var out = Map<String, String>.from(inherit);
  if (map == null) return out;

  final raw =
      map['httpHeaders'] ??
      map['headers'] ??
      map['playHeaders'] ??
      map['playHttpHeaders'];
  if (raw is Map) {
    out = mergePlaybackHeaders(out, _stringMap(raw));
  }

  final ua = catalogUserAgentFieldFromJson(map);
  if (ua != null) {
    out = mergePlaybackHeaders(out, const {}, userAgent: ua);
  }
  return out;
}

String? catalogUserAgentFieldFromJson(Map<String, dynamic> map) {
  for (final key in const ['userAgent', 'user-agent', 'ua', 'User-Agent']) {
    final v = map[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// Value of `User-Agent` in [headers], any capitalization.
String? userAgentFromHttpHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return null;
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == 'user-agent') {
      final v = e.value.trim();
      if (v.isNotEmpty) return v;
    }
  }
  return null;
}

/// Overlay [overlay] onto [base]. Optional [userAgent] wins over both maps.
Map<String, String> mergePlaybackHeaders(
  Map<String, String> base,
  Map<String, String> overlay, {
  String? userAgent,
}) {
  final out = Map<String, String>.from(base);
  overlay.forEach((k, v) {
    final key = k.trim();
    final val = v.trim();
    if (key.isEmpty || val.isEmpty) return;
    if (key.toLowerCase() == 'user-agent') {
      out.removeWhere((ek, _) => ek.toLowerCase() == 'user-agent');
      out['User-Agent'] = val;
    } else {
      out[key] = val;
    }
  });
  final ua = userAgent?.trim();
  if (ua != null && ua.isNotEmpty) {
    out.removeWhere((ek, _) => ek.toLowerCase() == 'user-agent');
    out['User-Agent'] = ua;
  }
  return out;
}

Map<String, String> _stringMap(Map<dynamic, dynamic> raw) {
  final out = <String, String>{};
  raw.forEach((key, value) {
    final k = '$key'.trim();
    final v = '$value'.trim();
    if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
  });
  return out;
}
