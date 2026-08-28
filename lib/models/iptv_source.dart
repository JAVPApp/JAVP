enum IptvSourceType {
  m3u,
  xtream,

  /// Stalker / Ministra portal (MAG MAC handshake).
  stalker,

  /// Bring-your-own JSON catalog (see CustomCatalogClient).
  custom,
  jellyfin,
  emby,
  plex,

  /// Standalone XMLTV / EPG feed — no channels; attachable to live lists.
  xmltv,
}

extension IptvSourceTypeX on IptvSourceType {
  /// Jellyfin / Emby / Plex — shared [MediaServerClient] path.
  bool get isMediaServer =>
      this == IptvSourceType.jellyfin ||
      this == IptvSourceType.emby ||
      this == IptvSourceType.plex;

  /// M3U / Xtream / Stalker — live channels + EPG.
  bool get isLiveIptv =>
      this == IptvSourceType.m3u ||
      this == IptvSourceType.xtream ||
      this == IptvSourceType.stalker;

  /// Standalone programme guide (no playlist / channels of its own).
  bool get isEpgOnly => this == IptvSourceType.xmltv;

  /// Live lists that pick EPG via the unified Sources picker (off / provider
  /// / URL or file / attached XMLTV).
  ///
  /// Media servers (Plex / Jellyfin / Emby) default to the provider guide and
  /// may attach XMLTV or an inline URL to override matching channels.
  bool get canAttachEpg => isLiveIptv || isMediaServer;

  /// Sources that can contribute channels to the Live tab.
  bool get supportsLive =>
      isLiveIptv || this == IptvSourceType.custom || isMediaServer;
}

class IptvSource {
  const IptvSource({
    required this.id,
    required this.name,
    required this.type,
    required this.createdAt,
    this.playlistUrl,
    this.epgUrl,
    this.epgSourceId,
    this.epgEnabled = true,
    this.serverUrl,
    this.alternateServerUrl,
    this.extraServerUrls = const [],
    this.username,
    this.password,
    this.plexAccountToken,
    this.lastSyncedAt,
    this.lastVodSyncedAt,
    this.channelCount = 0,
    this.vodCount = 0,
    this.catalogVersion = 1,
    this.catalogCapabilities = const [],
    this.catalogItemCount,
    this.enabled = true,
    this.vodEnabled = true,
    this.color,
    this.vastUrl,
  });

  final String id;
  final String name;
  final IptvSourceType type;
  final DateTime createdAt;
  final String? playlistUrl;

  /// Inline XMLTV URL or local file when no [epgSourceId] is attached.
  ///
  /// Live IPTV also falls back to playlist `url-tvg` / Xtream auto-discovery
  /// when this is empty. Media servers fall back to the provider guide.
  final String? epgUrl;

  /// When set, live IPTV / media-server live uses this [IptvSourceType.xmltv]
  /// source for XMLTV (overrides provider guide when a channel matches).
  final String? epgSourceId;

  /// When false, Guide / now-playing skip EPG for this list.
  final bool epgEnabled;
  final String? serverUrl;
  final String? alternateServerUrl;

  /// Extra PMS / panel bases to try after [serverUrl] and [alternateServerUrl].
  ///
  /// Plex account sign-in stores every plex.tv connection here so Drive sync
  /// can reach the server from another network, not only the LAN URL that
  /// happened to work on the device that added it.
  final List<String> extraServerUrls;
  final String? username;
  final String? password;

  /// plex.tv account token used to refresh connection lists. Synced with
  /// sources like the per-server [password] token.
  final String? plexAccountToken;
  final DateTime? lastSyncedAt;

  /// Last full Xtream movies/series list fetch (separate from live sync).
  final DateTime? lastVodSyncedAt;
  final int channelCount;
  final int vodCount;

  /// Custom catalog API version (`1` bulk, `2` query).
  final int catalogVersion;
  final List<String> catalogCapabilities;
  final int? catalogItemCount;

  /// When false, keep the source and its cache but hide it from browse/search
  /// and skip background sync until re-enabled.
  final bool enabled;

  /// Xtream only: when false, skip movies/series catalog pulls and hide that
  /// source's VOD from Catalog / Search (live TV still syncs). Defaults true.
  final bool vodEnabled;

  /// Optional badge / filter tint as `#RRGGBB` (or `#AARRGGBB`). Null = default.
  final String? color;

  /// Optional VAST/VMAP tag URL for VOD ads from this source.
  ///
  /// Set from custom catalog JSON (`vastUrl` / aliases) on sync — not editable
  /// in the Sources UI. The player also honors a per-item override on the title
  /// (`MediaItem.vastUrl`).
  final String? vastUrl;

  /// Whether soft-sync should latch Sources on the coalesced XMLTV reload.
  ///
  /// Custom catalogs qualify when Guide is on and a catalog / inline XMLTV
  /// URL is resolved. Live / media-server lists need Guide on and a resolved
  /// XMLTV URL (inline, attached, or discovered).
  bool contributesMergedXmltv({String? resolvedEpgUrl}) {
    if (!enabled) return false;
    if (type == IptvSourceType.xmltv) {
      final url = epgUrl?.trim();
      return url != null && url.isNotEmpty;
    }
    if (type == IptvSourceType.custom) {
      if (!epgEnabled) return false;
      final resolved = (resolvedEpgUrl ?? epgUrl)?.trim();
      return resolved != null && resolved.isNotEmpty;
    }
    if (!type.canAttachEpg || !epgEnabled) return false;
    final resolved = resolvedEpgUrl?.trim();
    return resolved != null && resolved.isNotEmpty;
  }

  bool get isQueryCatalog =>
      type == IptvSourceType.custom &&
      (catalogVersion >= 2 || catalogCapabilities.isNotEmpty);

  /// True when the catalog advertises remote `GET /search`.
  ///
  /// Simple v1 dumps and v2 bridges that omit `search` from [catalogCapabilities]
  /// are searched via the on-device cache instead of calling `/search`.
  bool get supportsCatalogSearch =>
      type == IptvSourceType.custom &&
      catalogCapabilities.any((c) => c.trim().toLowerCase() == 'search');

  /// Unique server bases to try, [serverUrl] first.
  List<String> get serverUrlCandidates {
    final out = <String>[];
    void add(String? raw) {
      final n = normalizeMediaServerBase(raw);
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }

    add(serverUrl);
    add(alternateServerUrl);
    for (final url in extraServerUrls) {
      add(url);
    }
    return out;
  }

  /// Optional Bearer token for custom JSON catalogs (stored in [password]).
  String? get catalogAuthToken =>
      type == IptvSourceType.custom ? password : null;

  /// Stable endpoint identity for duplicate detection (not the UUID).
  ///
  /// Empty when there is nothing reliable to match — callers must fall back
  /// to id-only comparison in that case.
  String get dedupeKey {
    switch (type) {
      case IptvSourceType.m3u:
      case IptvSourceType.custom:
        final u = normalizeSourceEndpoint(playlistUrl);
        return u.isEmpty ? '' : '${type.name}|$u';
      case IptvSourceType.xmltv:
        final u = normalizeSourceEndpoint(epgUrl);
        return u.isEmpty ? '' : '${type.name}|$u';
      case IptvSourceType.xtream:
      case IptvSourceType.stalker:
      case IptvSourceType.jellyfin:
      case IptvSourceType.emby:
      case IptvSourceType.plex:
        final u = normalizeSourceEndpoint(serverUrl);
        if (u.isEmpty) return '';
        final user = (username ?? '').trim().toLowerCase();
        return '${type.name}|$u|$user';
    }
  }

  IptvSource copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    String? playlistUrl,
    String? epgUrl,
    bool clearEpgUrl = false,
    String? epgSourceId,
    bool clearEpgSourceId = false,
    bool? epgEnabled,
    String? serverUrl,
    String? alternateServerUrl,
    bool clearAlternateServerUrl = false,
    List<String>? extraServerUrls,
    String? username,
    String? password,
    String? plexAccountToken,
    bool clearPlexAccountToken = false,
    DateTime? lastSyncedAt,
    DateTime? lastVodSyncedAt,
    int? channelCount,
    int? vodCount,
    int? catalogVersion,
    List<String>? catalogCapabilities,
    int? catalogItemCount,
    bool? enabled,
    bool? vodEnabled,
    String? color,
    bool clearColor = false,
    String? vastUrl,
    bool clearVastUrl = false,
  }) {
    return IptvSource(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type,
      createdAt: createdAt ?? this.createdAt,
      playlistUrl: playlistUrl ?? this.playlistUrl,
      epgUrl: clearEpgUrl ? null : (epgUrl ?? this.epgUrl),
      epgSourceId: clearEpgSourceId ? null : (epgSourceId ?? this.epgSourceId),
      epgEnabled: epgEnabled ?? this.epgEnabled,
      serverUrl: serverUrl ?? this.serverUrl,
      alternateServerUrl: clearAlternateServerUrl
          ? null
          : (alternateServerUrl ?? this.alternateServerUrl),
      extraServerUrls: extraServerUrls ?? this.extraServerUrls,
      username: username ?? this.username,
      password: password ?? this.password,
      plexAccountToken: clearPlexAccountToken
          ? null
          : (plexAccountToken ?? this.plexAccountToken),
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastVodSyncedAt: lastVodSyncedAt ?? this.lastVodSyncedAt,
      channelCount: channelCount ?? this.channelCount,
      vodCount: vodCount ?? this.vodCount,
      catalogVersion: catalogVersion ?? this.catalogVersion,
      catalogCapabilities: catalogCapabilities ?? this.catalogCapabilities,
      catalogItemCount: catalogItemCount ?? this.catalogItemCount,
      enabled: enabled ?? this.enabled,
      vodEnabled: vodEnabled ?? this.vodEnabled,
      color: clearColor ? null : (color ?? this.color),
      vastUrl: clearVastUrl ? null : (vastUrl ?? this.vastUrl),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'createdAt': createdAt.toIso8601String(),
    'playlistUrl': playlistUrl,
    'epgUrl': epgUrl,
    'epgSourceId': epgSourceId,
    'epgEnabled': epgEnabled,
    'serverUrl': serverUrl,
    'alternateServerUrl': alternateServerUrl,
    if (extraServerUrls.isNotEmpty) 'extraServerUrls': extraServerUrls,
    'username': username,
    'password': password,
    if (plexAccountToken != null && plexAccountToken!.isNotEmpty)
      'plexAccountToken': plexAccountToken,
    'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    'lastVodSyncedAt': lastVodSyncedAt?.toIso8601String(),
    'channelCount': channelCount,
    'vodCount': vodCount,
    'catalogVersion': catalogVersion,
    'catalogCapabilities': catalogCapabilities,
    'catalogItemCount': catalogItemCount,
    'enabled': enabled,
    'vodEnabled': vodEnabled,
    'color': color,
    'vastUrl': vastUrl,
  };

  factory IptvSource.fromJson(Map<String, dynamic> json) {
    final source = tryFromJson(json);
    if (source == null) {
      throw FormatException('Unknown IPTV source type: ${json['type']}');
    }
    return source;
  }

  /// Returns null for removed/unknown source types (e.g. legacy `anizone`).
  static IptvSource? tryFromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String?;
    final type = typeName == null
        ? null
        : IptvSourceType.values.asNameMap()[typeName];
    if (type == null) return null;
    return IptvSource(
      id: json['id'] as String,
      name: json['name'] as String,
      type: type,
      createdAt: DateTime.parse(json['createdAt'] as String),
      playlistUrl: json['playlistUrl'] as String?,
      epgUrl: json['epgUrl'] as String?,
      epgSourceId: json['epgSourceId'] as String?,
      epgEnabled: json['epgEnabled'] as bool? ?? true,
      serverUrl: json['serverUrl'] as String?,
      alternateServerUrl: json['alternateServerUrl'] as String?,
      extraServerUrls: _readStringList(json['extraServerUrls']),
      username: json['username'] as String?,
      password: json['password'] as String?,
      plexAccountToken: json['plexAccountToken'] as String?,
      lastSyncedAt: json['lastSyncedAt'] == null
          ? null
          : DateTime.tryParse(json['lastSyncedAt'] as String),
      lastVodSyncedAt: json['lastVodSyncedAt'] == null
          ? null
          : DateTime.tryParse(json['lastVodSyncedAt'] as String),
      channelCount: (json['channelCount'] as num?)?.toInt() ?? 0,
      vodCount: (json['vodCount'] as num?)?.toInt() ?? 0,
      catalogVersion: (json['catalogVersion'] as num?)?.toInt() ?? 1,
      catalogCapabilities:
          (json['catalogCapabilities'] as List?)?.map((e) => '$e').toList() ??
          const [],
      catalogItemCount: (json['catalogItemCount'] as num?)?.toInt(),
      enabled: json['enabled'] as bool? ?? true,
      vodEnabled: json['vodEnabled'] as bool? ?? true,
      color: _readOptionalColor(json['color']),
      vastUrl: _readOptionalHttpUrl(json['vastUrl'] ?? json['vast']),
    );
  }
}

String? _readOptionalColor(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _readStringList(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final entry in raw) {
    final n = normalizeMediaServerBase('$entry');
    if (n.isNotEmpty && !out.contains(n)) out.add(n);
  }
  return out;
}

String? _readOptionalHttpUrl(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return trimmed;
}

/// Strip trailing slashes from a media-server / panel base URL.
String normalizeMediaServerBase(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Normalize a playlist / server / EPG URL for [IptvSource.dedupeKey].
String normalizeSourceEndpoint(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) {
    return trimmed.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final port = uri.hasPort ? ':${uri.port}' : '';
  // Keep query (M3U get.php panels) but drop obvious secrets.
  final filtered = Map<String, String>.from(uri.queryParameters)
    ..removeWhere((k, _) {
      final key = k.toLowerCase();
      return key == 'password' ||
          key == 'pass' ||
          key == 'pwd' ||
          key == 'token' ||
          key == 'access_token' ||
          key == 'auth';
    });
  final query = filtered.isEmpty
      ? ''
      : '?${Uri(queryParameters: filtered).query}';
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}'
      '$port$path$query';
}
