/// User-configured proxy for catalog / IPTV / metadata / media servers / torrents.
///
/// Supports HTTP(S) CONNECT proxies and SOCKS5 (provider presets available in
/// Settings → Network). Per-scope [route*] flags choose which traffic uses the
/// proxy. New / unsaved settings route **torrents only**; other categories stay
/// on the normal connection until the user ticks them. Missing flags in older
/// saves follow the same torrent-only default.
enum ProxyType { http, socks5 }

/// Traffic groups that can independently use the configured proxy.
enum ProxyTrafficScope {
  iptv,
  catalogs,
  metadata,
  mediaServers,
  torrents,
  downloads,
}

class ProxySettings {
  const ProxySettings({
    this.enabled = false,
    this.type = ProxyType.http,
    this.host = '',
    this.port = 8080,
    this.username = '',
    this.password = '',
    this.routeIptv = false,
    this.routeCatalogs = false,
    this.routeMetadata = false,
    this.routeMediaServers = false,
    this.routeTorrents = true,
    this.routeDownloads = false,
    this.allowDirectFallback = false,
  });

  final bool enabled;
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  /// M3U playlists, XMLTV EPG, and Xtream API.
  final bool routeIptv;

  /// Custom JSON catalog browse / search.
  final bool routeCatalogs;

  /// SIMKL, Trakt, TMDB, intro segments, and artwork fetches.
  final bool routeMetadata;

  /// Jellyfin, Emby, and Plex clients.
  final bool routeMediaServers;

  /// Torrent peer / tracker traffic (rqbit; SOCKS5 only).
  final bool routeTorrents;

  /// Offline downloads (progressive HTTP(S) and HLS).
  final bool routeDownloads;

  /// When the proxy handshake fails, retry ticked HTTP scopes without it.
  ///
  /// Off by default so a checked category stays on the proxy. Metadata used
  /// to always fall back; that bypass is now opt-in.
  final bool allowDirectFallback;

  static const disabled = ProxySettings();

  /// Documentation-only hosts that must never be used as a live proxy.
  static bool isPlaceholderHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return false;
    const reserved = ['example.com', 'example.org', 'example.net'];
    for (final domain in reserved) {
      if (h == domain || h.endsWith('.$domain')) return true;
    }
    return false;
  }

  bool get isActive =>
      enabled &&
      host.trim().isNotEmpty &&
      !isPlaceholderHost(host) &&
      port > 0 &&
      port <= 65535;

  /// SOCKS5 username/password is only offered when both are set.
  ///
  /// Offering password-auth with a blank password makes many VPN SOCKS
  /// endpoints pick method 0x02 and then reject the handshake.
  bool get hasProxyUserPass =>
      username.trim().isNotEmpty && password.isNotEmpty;

  bool routes(ProxyTrafficScope scope) => switch (scope) {
    ProxyTrafficScope.iptv => routeIptv,
    ProxyTrafficScope.catalogs => routeCatalogs,
    ProxyTrafficScope.metadata => routeMetadata,
    ProxyTrafficScope.mediaServers => routeMediaServers,
    ProxyTrafficScope.torrents => routeTorrents,
    ProxyTrafficScope.downloads => routeDownloads,
  };

  /// Whether [scope] should use this proxy right now.
  bool isActiveFor(ProxyTrafficScope scope) => isActive && routes(scope);

  String get typeLabel => switch (type) {
    ProxyType.http => 'HTTP',
    ProxyType.socks5 => 'SOCKS5',
  };

  String get displayLabel {
    if (!isActive) return 'Off';
    final auth = username.trim().isEmpty ? '' : '${username.trim()}@';
    return '$typeLabel $auth${host.trim()}:$port';
  }

  ProxySettings copyWith({
    bool? enabled,
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
    bool? routeIptv,
    bool? routeCatalogs,
    bool? routeMetadata,
    bool? routeMediaServers,
    bool? routeTorrents,
    bool? routeDownloads,
    bool? allowDirectFallback,
  }) {
    return ProxySettings(
      enabled: enabled ?? this.enabled,
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      routeIptv: routeIptv ?? this.routeIptv,
      routeCatalogs: routeCatalogs ?? this.routeCatalogs,
      routeMetadata: routeMetadata ?? this.routeMetadata,
      routeMediaServers: routeMediaServers ?? this.routeMediaServers,
      routeTorrents: routeTorrents ?? this.routeTorrents,
      routeDownloads: routeDownloads ?? this.routeDownloads,
      allowDirectFallback: allowDirectFallback ?? this.allowDirectFallback,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'type': type.name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'routeIptv': routeIptv,
    'routeCatalogs': routeCatalogs,
    'routeMetadata': routeMetadata,
    'routeMediaServers': routeMediaServers,
    'routeTorrents': routeTorrents,
    'routeDownloads': routeDownloads,
    'allowDirectFallback': allowDirectFallback,
  };

  factory ProxySettings.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String?;
    final type = switch (typeName) {
      'socks5' => ProxyType.socks5,
      _ => ProxyType.http,
    };
    bool route(String key, {required bool fallback}) =>
        json[key] as bool? ?? fallback;
    return ProxySettings(
      enabled: json['enabled'] as bool? ?? false,
      type: type,
      host: json['host'] as String? ?? '',
      port:
          (json['port'] as num?)?.toInt() ??
          (type == ProxyType.socks5 ? 1080 : 8080),
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      routeIptv: route('routeIptv', fallback: false),
      routeCatalogs: route('routeCatalogs', fallback: false),
      routeMetadata: route('routeMetadata', fallback: false),
      routeMediaServers: route('routeMediaServers', fallback: false),
      routeTorrents: route('routeTorrents', fallback: true),
      routeDownloads: route('routeDownloads', fallback: false),
      allowDirectFallback: json['allowDirectFallback'] as bool? ?? false,
    );
  }
}
