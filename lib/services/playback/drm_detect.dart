/// Detect DRM (Widevine / PlayReady / FairPlay / CENC) in manifests, catalog
/// metadata, M3U Kodi props, and libmpv error text.
///
/// JAVP cannot decrypt these streams. Callers should fail with
/// [UnsupportedDrmException] and offer an external player.
library;

/// Well-known DRM family, when we can tell them apart.
enum DrmKind {
  widevine,
  playready,
  fairplay,

  /// CENC / ClearKey / unknown commercial DRM.
  cenc,
}

/// Stable English fallback shown in logs and as [PlaybackProvider.error]
/// when l10n is not available (the player overlay localizes this).
const drmProtectedUserMessage =
    'This stream is DRM-protected and cannot be played in JAVP.';

/// Internal header persisted on catalog / M3U rows. Stripped before HTTP.
const drmHintHeader = 'X-Javp-Drm';

class UnsupportedDrmException implements Exception {
  const UnsupportedDrmException({this.kind, this.playUrl});

  final DrmKind? kind;
  final String? playUrl;

  @override
  String toString() => drmProtectedUserMessage;
}

/// Widevine UUID (`edef8ba9-79d6-4ace-a3c8-27dcd51d21ed`).
const _widevineUuid = 'edef8ba9-79d6-4ace-a3c8-27dcd51d21ed';

/// PlayReady UUID.
const _playreadyUuid = '9a04f079-9840-4286-ab92-e65be0885f95';

/// FairPlay UUID.
const _fairplayUuid = '94ce86fb-07ff-4f43-adb8-93d2fa968ca2';

/// W3C ClearKey UUID — still not playable in libmpv.
const _clearkeyUuid = 'e2719d58-a985-b3c9-781a-b030af78d30e';

/// HLS `METHOD=` values that need a CDM (not AES-128).
final _hlsCdmMethods = RegExp(
  r'METHOD\s*=\s*(SAMPLE-AES(?:-CTR|-CENC)?|ISO-23001-7)\b',
  caseSensitive: false,
);

final _keyFormatDrm = RegExp(
  r'KEYFORMAT\s*=\s*"?(com\.widevine|com\.microsoft\.playready|'
  r'com\.apple\.streamingkeydelivery|urn:uuid:(?:'
  r'edef8ba9-79d6-4ace-a3c8-27dcd51d21ed|'
  r'9a04f079-9840-4286-ab92-e65be0885f95|'
  r'94ce86fb-07ff-4f43-adb8-93d2fa968ca2|'
  r'e2719d58-a985-b3c9-781a-b030af78d30e))',
  caseSensitive: false,
);

/// Map a short token (`widevine`, `com.widevine.alpha`, UUID, …) to a kind.
DrmKind? drmKindFromToken(String? raw) {
  final t = (raw ?? '').trim().toLowerCase();
  if (t.isEmpty || t == 'none' || t == 'clear' || t == 'false' || t == '0') {
    return null;
  }
  if (t.contains('widevine') || t.contains(_widevineUuid)) {
    return DrmKind.widevine;
  }
  if (t.contains('playready') || t.contains(_playreadyUuid)) {
    return DrmKind.playready;
  }
  if (t.contains('fairplay') ||
      t.contains('streamingkeydelivery') ||
      t.contains(_fairplayUuid)) {
    return DrmKind.fairplay;
  }
  if (t.contains('clearkey') ||
      t.contains('cenc') ||
      t.contains('cbcs') ||
      t.contains('drm') ||
      t == 'true' ||
      t == '1' ||
      t.contains(_clearkeyUuid)) {
    return DrmKind.cenc;
  }
  return DrmKind.cenc;
}

/// Catalog JSON `drm` / `licenseUrl` / `drmScheme`.
DrmKind? drmKindFromCatalogJson(Map<dynamic, dynamic> map) {
  final drmRaw = map['drm'];
  if (drmRaw is Map) {
    final nested = Map<dynamic, dynamic>.from(drmRaw);
    return drmKindFromToken(
          '${nested['scheme'] ?? nested['type'] ?? nested['drmScheme'] ?? ''}',
        ) ??
        drmKindFromCatalogJson(nested);
  }
  final scheme = drmKindFromToken(
    '${drmRaw ?? map['drmScheme'] ?? map['protection'] ?? ''}',
  );
  if (scheme != null) return scheme;
  for (final key in const [
    'licenseUrl',
    'drmLicenseUrl',
    'license_url',
    'licenseKey',
    'drmLicenseKey',
  ]) {
    final value = '${map[key] ?? ''}'.trim();
    if (value.isNotEmpty && value != 'false' && value != '0') {
      return drmKindFromToken(value) ?? DrmKind.widevine;
    }
  }
  return null;
}

/// `#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha`
DrmKind? drmKindFromKodiprop(String line) {
  final trimmed = line.trim();
  final upper = trimmed.toUpperCase();
  if (!upper.startsWith('#KODIPROP:')) return null;
  final value = trimmed.substring('#KODIPROP:'.length);
  final lower = value.toLowerCase();
  if (lower.contains('license_type') ||
      lower.contains('license_key') ||
      lower.contains('widevine') ||
      lower.contains('playready') ||
      lower.contains('fairplay') ||
      lower.contains('clearkey')) {
    return drmKindFromToken(value);
  }
  return null;
}

/// Headers to persist on a [MediaItem] so live/VOD caches remember DRM.
Map<String, String> drmHintHeadersFor(DrmKind kind) => {
  drmHintHeader: kind.name,
};

Map<String, String> withoutDrmHintHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return const {};
  final out = <String, String>{};
  headers.forEach((key, value) {
    if (key.toLowerCase() == drmHintHeader.toLowerCase()) return;
    out[key] = value;
  });
  return out;
}

bool headersIndicateDrm(Map<String, String>? headers) =>
    drmKindFromHeaders(headers) != null;

DrmKind? drmKindFromHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return null;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == drmHintHeader.toLowerCase()) {
      return drmKindFromToken(entry.value);
    }
  }
  return null;
}

/// HLS playlist or DASH MPD text (first ~64KB is enough).
DrmKind? detectDrmInManifest(String body) {
  if (body.isEmpty) return null;
  final sample = body.length > 65536 ? body.substring(0, 65536) : body;
  final lower = sample.toLowerCase();

  if (_hlsCdmMethods.hasMatch(sample) || _keyFormatDrm.hasMatch(sample)) {
    if (lower.contains('widevine') || lower.contains(_widevineUuid)) {
      return DrmKind.widevine;
    }
    if (lower.contains('playready') || lower.contains(_playreadyUuid)) {
      return DrmKind.playready;
    }
    if (lower.contains('fairplay') ||
        lower.contains('streamingkeydelivery') ||
        lower.contains(_fairplayUuid)) {
      return DrmKind.fairplay;
    }
    return DrmKind.cenc;
  }

  // DASH ContentProtection / PSSH. AES-128 HLS must not match.
  final hasPssh = lower.contains('cenc:pssh') || lower.contains('<pssh');
  final hasContentProtection = lower.contains('contentprotection');
  if (hasContentProtection || hasPssh) {
    if (lower.contains(_widevineUuid) || lower.contains('widevine')) {
      return DrmKind.widevine;
    }
    if (lower.contains(_playreadyUuid) || lower.contains('playready')) {
      return DrmKind.playready;
    }
    if (lower.contains(_fairplayUuid) || lower.contains('fairplay')) {
      return DrmKind.fairplay;
    }
    if (hasPssh ||
        lower.contains(_clearkeyUuid) ||
        lower.contains('clearkey') ||
        RegExp(
          r'schemeiduri\s*=\s*"[^"]*uuid:',
          caseSensitive: false,
        ).hasMatch(sample)) {
      return DrmKind.cenc;
    }
  }
  return null;
}

bool looksLikeDashUrl(String url) {
  final lower = url.toLowerCase();
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? lower;
  if (path.endsWith('.mpd')) return true;
  if (lower.contains('.mpd?') || lower.contains('/mpd/')) return true;
  if (lower.contains('format=mpd') || lower.contains('type=mpd')) return true;
  // Avoid "dashboard".
  if (RegExp(r'[/._-]dash[/._-]|[/._-]dash$').hasMatch(lower)) return true;
  return false;
}

/// libmpv / FFmpeg messages after a CDM stream actually reaches the engine.
bool looksLikePlayerDrmError(String message) {
  final m = message.toLowerCase();
  if (m.trim().isEmpty) return false;
  if (m.contains(drmProtectedUserMessage.toLowerCase())) return true;
  const needles = [
    'widevine',
    'playready',
    'fairplay',
    'sample-aes',
    'failed to decrypt',
    'no key available',
    'no decryption key',
    'missing decryption key',
    'unsupported encryption',
    'encryption scheme',
    'cenc',
    'cbcs',
    'clearkey',
  ];
  for (final n in needles) {
    if (m.contains(n)) return true;
  }
  // Word "drm" — avoid matching random identifiers.
  return RegExp(r'(^|[^a-z])drm([^a-z]|$)').hasMatch(m);
}

bool isProtectedErrorMessage(String? error) {
  if (error == null || error.trim().isEmpty) return false;
  return looksLikePlayerDrmError(error);
}

String surfacePlayerError(Object error) {
  if (error is UnsupportedDrmException) return drmProtectedUserMessage;
  final raw = error.toString();
  if (looksLikePlayerDrmError(raw)) return drmProtectedUserMessage;
  return raw;
}
