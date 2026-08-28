/// What the first few KB of a pasted URL / local file look like.
enum SourceContentKind {
  /// IPTV channel-list M3U (`#EXTM3U` + `#EXTINF`, or basic URL-only, not HLS).
  iptvM3u,

  /// HLS master/media playlist — play as a single stream via Add URL.
  hlsPlaylist,

  /// JAVP custom catalog JSON (v1 dump or v2 descriptor).
  jsonCatalog,

  /// XMLTV-style EPG.
  xmlEpg,

  /// HTML page (login portal, error page, …).
  html,

  /// Xtream Codes API payload or URL (body peek and/or URL shape).
  xtreamCodes,

  /// Unrecognized text / binary.
  unknown,
}

/// Expected slot when adding a source (used for mismatch messaging).
enum SourceContentExpectation {
  m3uPlaylist,
  jsonCatalog,
  xmltvEpg,
}

/// Thrown when a probe finds content that belongs under a different add path.
class SourceKindMismatchException implements Exception {
  const SourceKindMismatchException({
    required this.expected,
    required this.detected,
    required this.message,
    this.softSuggest = false,
  });

  final SourceContentExpectation expected;
  final SourceContentKind detected;
  final String message;

  /// Soft suggestion (e.g. Xtream `get.php` export): show CTA but allow M3U.
  final bool softSuggest;

  /// True when the UI can offer a one-tap switch to JSON catalog.
  bool get canSwitchToJsonCatalog =>
      expected == SourceContentExpectation.m3uPlaylist &&
      detected == SourceContentKind.jsonCatalog;

  /// True when the UI can offer a one-tap switch to M3U playlist.
  bool get canSwitchToM3uPlaylist =>
      expected == SourceContentExpectation.jsonCatalog &&
      detected == SourceContentKind.iptvM3u;

  /// True when the UI can offer a one-tap switch to EPG / XMLTV.
  bool get canSwitchToXmltv =>
      (expected == SourceContentExpectation.m3uPlaylist ||
          expected == SourceContentExpectation.jsonCatalog) &&
      detected == SourceContentKind.xmlEpg;

  /// True when the UI can offer a one-tap switch to Xtream login.
  bool get canSwitchToXtream =>
      expected == SourceContentExpectation.m3uPlaylist &&
      detected == SourceContentKind.xtreamCodes;

  /// Soft Xtream suggest on an otherwise-valid M3U (playlist export).
  bool get allowsContinueAsM3u =>
      softSuggest && canSwitchToXtream;

  @override
  String toString() => message;
}

/// Classify a short text peek (typically ≤4KB) from a URL or local file.
SourceContentKind sniffSourceContent(String peek) {
  final trimmed = peek.trimLeft();
  if (trimmed.isEmpty) return SourceContentKind.unknown;

  // Strip UTF-8 BOM if present.
  final text = trimmed.startsWith('\uFEFF') ? trimmed.substring(1).trimLeft() : trimmed;
  if (text.isEmpty) return SourceContentKind.unknown;

  final lower = text.toLowerCase();

  if (lower.startsWith('<!doctype html') ||
      lower.startsWith('<html') ||
      lower.contains('<html') && lower.contains('<body')) {
    return SourceContentKind.html;
  }

  if (text.startsWith('<') || lower.startsWith('<?xml')) {
    if (lower.contains('<tv') ||
        lower.contains('<programme') ||
        lower.contains('<channel')) {
      return SourceContentKind.xmlEpg;
    }
    if (lower.contains('<html') || lower.contains('<body')) {
      return SourceContentKind.html;
    }
  }

  if (text.startsWith('{') || text.startsWith('[')) {
    if (looksLikeXtreamPlayerApiResponse(text)) {
      return SourceContentKind.xtreamCodes;
    }
    if (_looksLikeJsonCatalog(text)) {
      return SourceContentKind.jsonCatalog;
    }
    return SourceContentKind.unknown;
  }

  if (text.contains('#EXTM3U') || lower.startsWith('#extm3u')) {
    final upper = text.toUpperCase();
    final isHls = upper.contains('#EXT-X-STREAM-INF') ||
        upper.contains('#EXT-X-TARGETDURATION') ||
        upper.contains('#EXT-X-MEDIA-SEQUENCE') ||
        upper.contains('#EXT-X-MAP') ||
        upper.contains('#EXT-X-KEY');
    if (isHls) return SourceContentKind.hlsPlaylist;
    if (upper.contains('#EXTINF')) return SourceContentKind.iptvM3u;
    // Header-only peek — treat as IPTV list (common for huge playlists).
    return SourceContentKind.iptvM3u;
  }

  // Basic M3U: one URL/path per line, no `#EXTM3U` / `#EXTINF`.
  if (looksLikeBasicM3uPlaylist(text)) {
    return SourceContentKind.iptvM3u;
  }

  return SourceContentKind.unknown;
}

/// True when [peek] looks like a basic (URL-only) M3U playlist.
///
/// Used by [sniffSourceContent] and the M3U probe fallback when providers omit
/// `#EXTM3U` / `#EXTINF`.
bool looksLikeBasicM3uPlaylist(String peek) {
  final lines = peek
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
  if (lines.isEmpty) return false;

  var entryCount = 0;
  for (final line in lines) {
    if (looksLikeM3uPlaylistEntry(line)) {
      entryCount++;
    }
  }
  // Accept a single-station radio list; require most non-comment lines to match
  // so random prose / logs are not treated as playlists.
  return entryCount >= 1 && entryCount * 2 >= lines.length;
}

/// True when [line] looks like a media URL or path in an M3U playlist.
bool looksLikeM3uPlaylistEntry(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.startsWith('#')) return false;

  final lower = trimmed.toLowerCase();
  const schemes = [
    'http://',
    'https://',
    'rtsp://',
    'rtspt://',
    'rtmp://',
    'rtp://',
    'udp://',
    'mms://',
    'mmsh://',
    'file://',
  ];
  for (final scheme in schemes) {
    if (lower.startsWith(scheme)) return true;
  }

  // Absolute Unix / UNC / Windows drive paths.
  if (trimmed.startsWith('/') || trimmed.startsWith(r'\\')) return true;
  if (trimmed.length >= 3 &&
      ((trimmed.codeUnitAt(0) >= 65 && trimmed.codeUnitAt(0) <= 90) ||
          (trimmed.codeUnitAt(0) >= 97 && trimmed.codeUnitAt(0) <= 122)) &&
      trimmed[1] == ':' &&
      (trimmed[2] == '\\' || trimmed[2] == '/')) {
    return true;
  }

  // Relative media paths (common in local library playlists).
  const mediaExts = [
    '.m3u8',
    '.mp4',
    '.mkv',
    '.ts',
    '.mp3',
    '.aac',
    '.flac',
    '.m4a',
    '.avi',
    '.mov',
    '.webm',
    '.mpg',
    '.mpeg',
    '.wmv',
    '.flv',
  ];
  for (final ext in mediaExts) {
    if (lower.endsWith(ext)) return true;
  }

  // Path-like relative entry without a known extension.
  if (trimmed.contains('/') || trimmed.contains('\\')) return true;

  return false;
}

/// True when [peek] looks like an Xtream `player_api.php` JSON auth payload.
bool looksLikeXtreamPlayerApiResponse(String peek) {
  final trimmed = peek.trimLeft();
  if (trimmed.startsWith('\uFEFF')) {
    return looksLikeXtreamPlayerApiResponse(trimmed.substring(1));
  }
  if (!trimmed.startsWith('{')) return false;
  final lower = trimmed.toLowerCase();
  if (!RegExp(r'"user_info"\s*:').hasMatch(lower)) return false;
  return RegExp(r'"server_info"\s*:').hasMatch(lower) ||
      RegExp(r'"auth"\s*:').hasMatch(lower) ||
      RegExp(r'"username"\s*:').hasMatch(lower);
}

bool _looksLikeJsonCatalog(String text) {
  // Cheap structural signals — avoid full jsonDecode on multi-MB peeks that
  // may be truncated mid-token.
  final lower = text.toLowerCase();
  if (RegExp(r'"items"\s*:').hasMatch(lower) ||
      RegExp(r'"entries"\s*:').hasMatch(lower) ||
      RegExp(r'"media"\s*:').hasMatch(lower)) {
    return true;
  }
  // v2 descriptor-only root.
  if (RegExp(r'"capabilities"\s*:').hasMatch(lower) &&
      (RegExp(r'"version"\s*:').hasMatch(lower) ||
          RegExp(r'"name"\s*:').hasMatch(lower))) {
    return true;
  }
  // Bare item array / single item shape.
  if (RegExp(r'"playurl"\s*:').hasMatch(lower) ||
      RegExp(r'"streamurl"\s*:').hasMatch(lower)) {
    return true;
  }
  if (RegExp(r'"title"\s*:').hasMatch(lower) &&
      (RegExp(r'"url"\s*:').hasMatch(lower) ||
          RegExp(r'"kind"\s*:').hasMatch(lower))) {
    return true;
  }
  return false;
}

/// English fallback messages used when throwing from the library layer.
String mismatchMessageFor({
  required SourceContentExpectation expected,
  required SourceContentKind detected,
}) {
  switch ((expected, detected)) {
    case (SourceContentExpectation.m3uPlaylist, SourceContentKind.jsonCatalog):
      return 'This URL looks like a JSON catalog, not an M3U playlist.';
    case (SourceContentExpectation.m3uPlaylist, SourceContentKind.hlsPlaylist):
      return 'This looks like a single HLS stream. Use Add URL instead of an M3U source.';
    case (SourceContentExpectation.m3uPlaylist, SourceContentKind.xmlEpg):
      return 'This URL looks like an EPG (XMLTV), not an M3U playlist.';
    case (SourceContentExpectation.m3uPlaylist, SourceContentKind.html):
      return 'This URL returned a web page, not an M3U playlist.';
    case (SourceContentExpectation.m3uPlaylist, SourceContentKind.xtreamCodes):
      return 'This looks like an Xtream Codes URL. Add it as Xtream for categories, VOD, and EPG.';
    case (SourceContentExpectation.jsonCatalog, SourceContentKind.iptvM3u):
      return 'This URL looks like an M3U playlist, not a JSON catalog.';
    case (SourceContentExpectation.jsonCatalog, SourceContentKind.hlsPlaylist):
      return 'This looks like a single HLS stream, not a JSON catalog.';
    case (SourceContentExpectation.jsonCatalog, SourceContentKind.xmlEpg):
      return 'This URL looks like an EPG (XMLTV), not a JSON catalog.';
    case (SourceContentExpectation.jsonCatalog, SourceContentKind.html):
      return 'This URL returned a web page, not a JSON catalog.';
    case (SourceContentExpectation.jsonCatalog, SourceContentKind.xtreamCodes):
      return 'This looks like an Xtream Codes URL, not a JSON catalog.';
    case (SourceContentExpectation.xmltvEpg, SourceContentKind.iptvM3u):
      return 'This URL looks like an M3U playlist, not an EPG / XMLTV guide.';
    case (SourceContentExpectation.xmltvEpg, SourceContentKind.jsonCatalog):
      return 'This URL looks like a JSON catalog, not an EPG / XMLTV guide.';
    case (SourceContentExpectation.xmltvEpg, SourceContentKind.hlsPlaylist):
      return 'This looks like a single HLS stream, not an EPG / XMLTV guide.';
    case (SourceContentExpectation.xmltvEpg, SourceContentKind.html):
      return 'This URL returned a web page, not an EPG / XMLTV guide.';
    case (SourceContentExpectation.xmltvEpg, SourceContentKind.xtreamCodes):
      return 'This looks like an Xtream Codes URL, not an EPG / XMLTV guide.';
    default:
      return switch (expected) {
        SourceContentExpectation.m3uPlaylist =>
          'This URL does not look like an M3U playlist.',
        SourceContentExpectation.jsonCatalog =>
          'This URL does not look like a JSON catalog.',
        SourceContentExpectation.xmltvEpg =>
          'This URL does not look like an EPG / XMLTV guide.',
      };
  }
}
