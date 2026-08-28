// Client identity and compatibility gates for the Custom Catalog API.
//
// Catalogs may declare [CatalogClientGate] on the **root**, on named
// `sources[]`, and on individual items / play variants. Missing fields are
// optional (any client). When a profile is omitted (tests, unknown
// PackageInfo), version / platform / capability checks are skipped — same
// as catalog `min_version` today.

/// Running JAVP client, passed into catalog parse and HTTP.
class CatalogClientProfile {
  const CatalogClientProfile({
    this.appVersion,
    this.platform,
    this.device,
    this.capabilities = const [],
  });

  /// Pubspec-style version (`0.4.3+57`, `0.4.3-dev+56`).
  final String? appVersion;

  /// OS / host token: `android`, `windows`, `linux`, `macos`, `ios`,
  /// `tizen`, `webos`, `web`.
  final String? platform;

  /// Form factor: `tv`, `desktop`, `mobile`.
  final String? device;

  /// Feature tokens this binary actually has (`torrents`, `downloads`, …).
  final List<String> capabilities;

  bool hasCapability(String token) {
    final want = normalizeCatalogCapability(token);
    if (want.isEmpty) return false;
    for (final cap in capabilities) {
      if (normalizeCatalogCapability(cap) == want) return true;
    }
    return false;
  }

  /// Query params appended to catalog HTTP (`javp_*` to avoid colliding with
  /// bridge `version` / `platform` keys).
  Map<String, String> get queryParameters {
    final caps = capabilities
        .map(normalizeCatalogCapability)
        .where((e) => e.isNotEmpty)
        .toSet()
        .join(',');
    return {
      if ((appVersion ?? '').trim().isNotEmpty)
        'javp_version': appVersion!.trim(),
      if ((platform ?? '').trim().isNotEmpty) 'javp_platform': platform!.trim(),
      if ((device ?? '').trim().isNotEmpty) 'javp_device': device!.trim(),
      if (caps.isNotEmpty) 'javp_capabilities': caps,
    };
  }

  Map<String, String> get httpHeaders {
    return {
      if ((appVersion ?? '').trim().isNotEmpty)
        'X-JAVP-Version': appVersion!.trim(),
      if ((platform ?? '').trim().isNotEmpty)
        'X-JAVP-Platform': platform!.trim(),
      if ((device ?? '').trim().isNotEmpty) 'X-JAVP-Device': device!.trim(),
      if (capabilities.isNotEmpty)
        'X-JAVP-Capabilities': capabilities
            .map(normalizeCatalogCapability)
            .where((e) => e.isNotEmpty)
            .toSet()
            .join(','),
    };
  }
}

/// Named backend inside a catalog (`sources[]` on the descriptor).
class CatalogNamedSource {
  const CatalogNamedSource({
    required this.id,
    this.name,
    this.gate = const CatalogClientGate(),
  });

  final String id;
  final String? name;
  final CatalogClientGate gate;
}

/// Allow-list constraints. Empty lists / null min version = no restriction.
class CatalogClientGate {
  const CatalogClientGate({
    this.minVersion,
    this.platforms = const [],
    this.requires = const [],
  });

  final String? minVersion;

  /// OS / form-factor tokens. Any match allows. Empty = all clients.
  final List<String> platforms;

  /// Client capabilities that must all be present (`torrents`, …).
  final List<String> requires;

  bool get isEmpty =>
      (minVersion == null || minVersion!.trim().isEmpty) &&
      platforms.isEmpty &&
      requires.isEmpty;

  factory CatalogClientGate.fromJson(Map<String, dynamic> map) {
    return CatalogClientGate(
      minVersion: catalogMinVersionFromJson(map),
      platforms: catalogStringListFromJson(map['platforms'] ?? map['platform']),
      requires: catalogStringListFromJson(
        map['requires'] ?? map['require'] ?? map['needs'],
      ),
    );
  }
}

/// Reads optional `min_version` / `minVersion` from a catalog object.
String? catalogMinVersionFromJson(Map<String, dynamic> map) {
  final raw = map['min_version'] ?? map['minVersion'];
  if (raw == null) return null;
  final text = '$raw'.trim();
  return text.isEmpty ? null : text;
}

/// Item / variant pointer at a named catalog `sources[]` id.
String? catalogSourceKeyFromJson(Map<String, dynamic> map) {
  final raw = map['source'] ?? map['catalogSource'] ?? map['catalog_source'];
  if (raw == null) return null;
  final text = '$raw'.trim();
  return text.isEmpty ? null : text;
}

List<CatalogNamedSource> catalogNamedSourcesFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <CatalogNamedSource>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    final id = '${map['id'] ?? map['key'] ?? map['name'] ?? ''}'.trim();
    if (id.isEmpty) continue;
    final name = (map['name'] as String?)?.trim();
    out.add(
      CatalogNamedSource(
        id: id,
        name: (name == null || name.isEmpty) ? null : name,
        gate: CatalogClientGate.fromJson(map),
      ),
    );
  }
  return out;
}

Map<String, CatalogClientGate> catalogNamedSourceGates(
  Iterable<CatalogNamedSource> sources,
) {
  return {for (final source in sources) source.id: source.gate};
}

/// Throws [CatalogMinVersionException] when [appVersion] is older than [minVersion].
///
/// Missing / empty [minVersion] is a no-op (field is optional). When the catalog
/// declares a minimum but [appVersion] is unknown, the check is skipped so a
/// missing PackageInfo cannot block every catalog.
void ensureCatalogMinVersion({String? minVersion, String? appVersion}) {
  final required = minVersion?.trim() ?? '';
  if (required.isEmpty || !_looksLikeJavpVersion(required)) return;
  final current = appVersion?.trim() ?? '';
  if (current.isEmpty) return;
  if (compareJavpVersions(current, required) < 0) {
    throw CatalogMinVersionException(minVersion: required, appVersion: current);
  }
}

/// Throws [CatalogUnsupportedException] when the catalog root is not for this
/// client (platforms / requires). [min_version] is handled separately.
void ensureCatalogClientSupported({
  required CatalogClientGate gate,
  CatalogClientProfile? profile,
}) {
  if (gate.isEmpty || profile == null) return;
  final mismatch = catalogClientMismatch(gate, profile);
  if (mismatch == null) return;
  throw CatalogUnsupportedException(
    platforms: gate.platforms,
    requires: gate.requires,
    clientPlatform: profile.platform,
    clientDevice: profile.device,
    reason: mismatch,
  );
}

/// Why [gate] rejects [profile], or null when allowed / not enough identity.
enum CatalogClientMismatch { version, platform, capability }

CatalogClientMismatch? catalogClientMismatch(
  CatalogClientGate gate,
  CatalogClientProfile? profile,
) {
  if (gate.isEmpty) return null;
  if (profile == null) return null;

  final min = gate.minVersion?.trim() ?? '';
  if (min.isNotEmpty && _looksLikeJavpVersion(min)) {
    final current = profile.appVersion?.trim() ?? '';
    if (current.isNotEmpty && compareJavpVersions(current, min) < 0) {
      return CatalogClientMismatch.version;
    }
  }

  if (gate.platforms.isNotEmpty) {
    final tokens = catalogClientMatchTokens(profile);
    if (tokens.isNotEmpty) {
      final allowed = gate.platforms
          .map(normalizeCatalogPlatform)
          .where((e) => e.isNotEmpty)
          .toSet();
      if (allowed.isNotEmpty && allowed.intersection(tokens).isEmpty) {
        if (!torrentAndroidGateAllowsDesktop(gate, profile, allowed)) {
          return CatalogClientMismatch.platform;
        }
      }
    }
  }

  for (final raw in gate.requires) {
    final need = normalizeCatalogCapability(raw);
    if (need.isEmpty || !knownCatalogCapabilities.contains(need)) continue;
    if (!profile.hasCapability(need)) {
      return CatalogClientMismatch.capability;
    }
  }
  return null;
}

bool catalogClientAllows(
  CatalogClientGate gate,
  CatalogClientProfile? profile,
) {
  return catalogClientMismatch(gate, profile) == null;
}

/// Old catalogs gated magnets to `platforms: ["android"]` because the torrent
/// engine was Android-only. Desktop now has librqbit — honor `requires:
/// torrents` on Windows/Linux/macOS instead of dropping every magnet.
bool torrentAndroidGateAllowsDesktop(
  CatalogClientGate gate,
  CatalogClientProfile profile,
  Set<String> allowedPlatforms,
) {
  if (!profile.hasCapability('torrents')) return false;
  final needsTorrents = gate.requires.any(
    (raw) => normalizeCatalogCapability(raw) == 'torrents',
  );
  if (!needsTorrents) return false;
  if (!allowedPlatforms.contains('android')) return false;
  // Don't open TV-only / webOS lists just because desktop has torrents.
  if (allowedPlatforms.contains('tizen') ||
      allowedPlatforms.contains('webos') ||
      allowedPlatforms.contains('tv') ||
      allowedPlatforms.contains('android_tv')) {
    return false;
  }
  final platform = normalizeCatalogPlatform(profile.platform);
  return platform == 'windows' || platform == 'linux' || platform == 'macos';
}

/// Combined OS + form-factor tokens for allow-list matching.
Set<String> catalogClientMatchTokens(CatalogClientProfile profile) {
  final out = <String>{};
  void add(String? raw) {
    final token = normalizeCatalogPlatform(raw);
    if (token.isNotEmpty) out.add(token);
  }

  add(profile.platform);
  add(profile.device);
  final platform = normalizeCatalogPlatform(profile.platform);
  final device = normalizeCatalogPlatform(profile.device);
  if (platform.isNotEmpty && device.isNotEmpty) {
    add('${platform}_$device');
  }
  return out;
}

String normalizeCatalogPlatform(String? raw) {
  final t = (raw ?? '').trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  return switch (t) {
    '' => '',
    'win' || 'windows' => 'windows',
    'mac' || 'osx' || 'macos' => 'macos',
    'iphone' || 'ipad' || 'ios' => 'ios',
    'samsung' || 'tizen' => 'tizen',
    'lg' || 'web_os' || 'webos' => 'webos',
    'androidtv' || 'android_tv' || 'firetv' || 'fire_tv' => 'android_tv',
    'leanback' || '10foot' || '10_foot' || 'tv' => 'tv',
    'phone' || 'tablet' || 'mobile' => 'mobile',
    _ => t,
  };
}

String normalizeCatalogCapability(String? raw) {
  final t = (raw ?? '').trim().toLowerCase();
  return switch (t) {
    '' => '',
    'torrent' || 'torrents' || 'p2p' || 'magnet' || 'magnets' => 'torrents',
    'download' || 'downloads' || 'offline' => 'downloads',
    _ => t,
  };
}

/// Capabilities this client actually enforces. Unknown `requires` tokens are
/// ignored so a future bridge feature cannot hide an entire catalog on older
/// JAVP builds (same idea as an unparseable `min_version`).
const knownCatalogCapabilities = {'torrents', 'downloads'};

bool playUrlRequiresTorrents(String url) {
  final trimmed = url.trim();
  if (trimmed.toLowerCase().startsWith('magnet:')) return true;
  // http(s)://…/file.torrent?token=… and local paths both count.
  final uri = Uri.tryParse(trimmed);
  final path =
      (uri != null && (uri.hasScheme || uri.path.isNotEmpty)
              ? uri.path
              : trimmed)
          .toLowerCase();
  return path.endsWith('.torrent');
}

/// Catalog root asked for a newer JAVP than this install.
class CatalogMinVersionException implements Exception {
  const CatalogMinVersionException({
    required this.minVersion,
    required this.appVersion,
  });

  final String minVersion;
  final String appVersion;

  @override
  String toString() =>
      'This catalog requires JAVP $minVersion or later (this app is $appVersion). '
      'Update JAVP to continue.';
}

/// Catalog root is not available on this device / without a required capability.
class CatalogUnsupportedException implements Exception {
  const CatalogUnsupportedException({
    this.platforms = const [],
    this.requires = const [],
    this.clientPlatform,
    this.clientDevice,
    this.reason = CatalogClientMismatch.platform,
  });

  final List<String> platforms;
  final List<String> requires;
  final String? clientPlatform;
  final String? clientDevice;
  final CatalogClientMismatch reason;

  @override
  String toString() {
    if (reason == CatalogClientMismatch.capability) {
      final need = requires
          .map(normalizeCatalogCapability)
          .where((e) => e.isNotEmpty)
          .toSet();
      if (need.contains('torrents')) {
        return 'This catalog needs torrent playback, which is not available '
            'on this device.';
      }
      if (need.isNotEmpty) {
        return 'This catalog needs ${need.join(', ')}, which is not available '
            'on this device.';
      }
    }
    final where = [
      if ((clientPlatform ?? '').isNotEmpty) clientPlatform,
      if ((clientDevice ?? '').isNotEmpty) clientDevice,
    ].join(' ');
    if (where.isNotEmpty) {
      return 'This catalog is not available on this device ($where).';
    }
    return 'This catalog is not available on this device.';
  }
}

final _javpVersionPattern = RegExp(r'^\d+(\.\d+)*(-[0-9A-Za-z.-]+)?(\+\d+)?$');

bool _looksLikeJavpVersion(String raw) =>
    _javpVersionPattern.hasMatch(raw.trim());

/// Compares pubspec-style versions (`0.4.3`, `0.4.3+57`, `0.4.2-dev+56`).
///
/// Returns negative if [a] < [b], zero if equal, positive if [a] > [b].
/// Core `major.minor.patch` decides first. A `+build` on [b] is compared only
/// when cores match. Pre-release suffixes (`-dev`) are ignored so a 0.4.3-dev
/// install satisfies `min_version: "0.4.3"`.
int compareJavpVersions(String a, String b) {
  final left = _parseJavpVersion(a);
  final right = _parseJavpVersion(b);
  final n = left.parts.length > right.parts.length
      ? left.parts.length
      : right.parts.length;
  for (var i = 0; i < n; i++) {
    final av = i < left.parts.length ? left.parts[i] : 0;
    final bv = i < right.parts.length ? right.parts[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  if (right.build != null) {
    return (left.build ?? 0).compareTo(right.build!);
  }
  return 0;
}

class _JavpVersion {
  const _JavpVersion({required this.parts, this.build});
  final List<int> parts;
  final int? build;
}

_JavpVersion _parseJavpVersion(String raw) {
  var s = raw.trim();
  int? build;
  final plus = s.indexOf('+');
  if (plus >= 0) {
    build = int.tryParse(s.substring(plus + 1).trim());
    s = s.substring(0, plus);
  }
  final dash = s.indexOf('-');
  if (dash >= 0) s = s.substring(0, dash);
  final parts = s
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList(growable: false);
  return _JavpVersion(parts: parts.isEmpty ? const [0] : parts, build: build);
}

List<String> catalogStringListFromJson(Object? raw) {
  if (raw is List) {
    return raw
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return raw
        .split(RegExp(r'[,|/]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  return const [];
}
