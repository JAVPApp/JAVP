import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/network/transient_network_error.dart';

/// Result of creating a plex.tv PIN for the official link / OAuth-style flow.
class PlexPinRequest {
  const PlexPinRequest({
    required this.id,
    required this.code,
    required this.clientIdentifier,
    required this.authUrl,
  });

  final int id;
  final String code;
  final String clientIdentifier;
  final String authUrl;
}

/// Triggers an immediate PIN re-check (app resume / "I've authorized").
class PlexAuthWake {
  Completer<void>? _waiting;
  bool _pending = false;

  void nudge() {
    _pending = true;
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete();
    }
  }

  Future<void> waitOrTimeout(Duration duration) async {
    if (_pending) {
      _pending = false;
      return;
    }
    final done = Completer<void>();
    _waiting = done;
    final timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      timer.cancel();
      if (identical(_waiting, done)) _waiting = null;
      _pending = false;
    }
  }
}

/// One candidate URI for a PMS (LAN, remote, or relay).
class PlexServerConnection {
  const PlexServerConnection({
    required this.uri,
    required this.local,
    required this.relay,
    this.protocol,
    this.address,
    this.port,
    this.ipv6 = false,
  });

  final String uri;
  final bool local;
  final bool relay;
  final String? protocol;
  final String? address;
  final int? port;
  final bool ipv6;

  factory PlexServerConnection.fromJson(Map<String, dynamic> json) {
    return PlexServerConnection(
      uri: '${json['uri'] ?? ''}',
      local: json['local'] == true,
      relay: json['relay'] == true,
      protocol: json['protocol'] as String?,
      address: json['address'] as String?,
      port: (json['port'] as num?)?.toInt(),
      ipv6: json['IPv6'] == true || json['ipv6'] == true,
    );
  }
}

/// A Plex Media Server listed under the signed-in plex.tv account.
class PlexServerResource {
  const PlexServerResource({
    required this.name,
    required this.machineId,
    required this.accessToken,
    required this.connections,
    this.owned = false,
    this.presence = false,
    this.httpsRequired = false,
    this.product,
    this.platform,
  });

  final String name;
  final String machineId;
  final String accessToken;
  final List<PlexServerConnection> connections;
  final bool owned;
  final bool presence;
  final bool httpsRequired;
  final String? product;
  final String? platform;

  factory PlexServerResource.fromJson(Map<String, dynamic> json) {
    final rawConnections = json['connections'] as List? ?? const [];
    return PlexServerResource(
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Plex Server',
      machineId: '${json['clientIdentifier'] ?? ''}',
      accessToken: '${json['accessToken'] ?? ''}',
      owned: json['owned'] == true,
      presence: json['presence'] == true,
      httpsRequired: json['httpsRequired'] == true,
      product: json['product'] as String?,
      platform: json['platform'] as String?,
      connections: rawConnections
          .whereType<Map>()
          .map(
            (e) => PlexServerConnection.fromJson(Map<String, dynamic>.from(e)),
          )
          .where((c) => c.uri.isNotEmpty)
          .toList(),
    );
  }
}

/// One movie/show row from the plex.tv Discover watchlist.
class PlexWatchlistHit {
  const PlexWatchlistHit({
    required this.ratingKey,
    required this.title,
    required this.isShow,
    this.year,
    this.tmdb,
    this.imdb,
    this.thumbUrl,
    this.listedAt,
  });

  final String ratingKey;
  final String title;
  final bool isShow;
  final int? year;
  final int? tmdb;
  final String? imdb;
  final String? thumbUrl;
  final DateTime? listedAt;
}

/// plex.tv account helpers: PIN auth, server list, connection probe.
///
/// Library browsing still goes through [PlexClient] with a concrete PMS URL
/// + per-server token once a connection is chosen.
class PlexAccountClient {
  PlexAccountClient({
    http.Client? httpClient,
    this.product = 'JAVP',
    this.productVersion = '0.1.0',
    this.deviceName = 'JAVP Android',
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String product;
  final String productVersion;
  final String deviceName;

  static const _pinsUrl = 'https://plex.tv/api/v2/pins';
  static const _resourcesUrl = 'https://plex.tv/api/v2/resources';
  static const _discoverUrl = 'https://discover.provider.plex.tv';
  static const watchlistPageSize = 100;
  static const watchlistMaxItems = 500;

  Map<String, String> _headers({
    required String clientIdentifier,
    String? token,
  }) {
    return {
      'Accept': 'application/json',
      'X-Plex-Product': product,
      'X-Plex-Version': productVersion,
      'X-Plex-Client-Identifier': clientIdentifier,
      'X-Plex-Device': deviceName,
      'X-Plex-Device-Name': deviceName,
      'X-Plex-Platform': 'Android',
      'X-Plex-Provides': 'player',
      if (token != null && token.isNotEmpty) 'X-Plex-Token': token,
    };
  }

  /// Creates a strong PIN and [app.plex.tv/auth] URL (official player allow flow).
  ///
  /// Do not pass a custom-scheme `forwardUrl` — that often breaks plex.tv auth
  /// and drops the user on the normal website with no allow prompt.
  Future<PlexPinRequest> createPin(String clientIdentifier) async {
    final uri = Uri.parse(
      _pinsUrl,
    ).replace(queryParameters: {'strong': 'true'});
    final response = await _http.post(
      uri,
      headers: _headers(clientIdentifier: clientIdentifier),
    );
    if (response.statusCode >= 400) {
      throw Exception('Plex PIN failed (${response.statusCode})');
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final id = (map['id'] as num?)?.toInt();
    final code = map['code'] as String?;
    if (id == null || code == null || code.isEmpty) {
      throw Exception('Plex PIN response incomplete');
    }
    // plex.tv expects OAuth params in the URL hash fragment.
    final fragmentQuery = Uri(
      queryParameters: {
        'clientID': clientIdentifier,
        'code': code,
        'context[device][product]': product,
      },
    ).query;

    return PlexPinRequest(
      id: id,
      code: code,
      clientIdentifier: clientIdentifier,
      authUrl: 'https://app.plex.tv/auth#?$fragmentQuery',
    );
  }

  /// Polls until plex.tv returns an account [authToken], or [isCancelled].
  ///
  /// [wake] nudges (e.g. app resumed) trigger an immediate check.
  /// Transient network errors while the app is backgrounded are retried.
  Future<String> waitForAuthToken(
    PlexPinRequest pin, {
    Duration pollInterval = const Duration(seconds: 1),
    Duration timeout = const Duration(minutes: 15),
    bool Function()? isCancelled,
    PlexAuthWake? wake,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() == true) {
        throw Exception('Plex sign-in cancelled');
      }
      try {
        final token = await _checkPin(pin);
        if (token != null) return token;
      } catch (e) {
        // Background → browser often aborts in-flight sockets; keep polling.
        if (!isTransientNetworkError(e)) rethrow;
      }
      if (wake != null) {
        await wake.waitOrTimeout(pollInterval);
      } else {
        await Future<void>.delayed(pollInterval);
      }
      if (isCancelled?.call() == true) {
        throw Exception('Plex sign-in cancelled');
      }
    }
    throw Exception('Plex sign-in timed out');
  }

  /// Single PIN status check — used after resume / "I've authorized".
  Future<String?> checkPin(PlexPinRequest pin) => _checkPin(pin);

  Future<String?> _checkPin(PlexPinRequest pin) async {
    final uri = Uri.parse(
      '$_pinsUrl/${pin.id}',
    ).replace(queryParameters: {'code': pin.code});
    final response = await _http.get(
      uri,
      headers: _headers(clientIdentifier: pin.clientIdentifier),
    );
    if (response.statusCode >= 400) {
      throw Exception('Plex PIN check failed (${response.statusCode})');
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final token = map['authToken'] as String?;
    if (token != null && token.isNotEmpty) return token;
    return null;
  }

  /// Lists PMS devices for the account (owned + shared).
  Future<List<PlexServerResource>> listServers(
    String accountToken, {
    required String clientIdentifier,
  }) async {
    final uri = Uri.parse(
      _resourcesUrl,
    ).replace(queryParameters: {'includeHttps': '1', 'includeRelay': '1'});
    final response = await _http.get(
      uri,
      headers: _headers(
        clientIdentifier: clientIdentifier,
        token: accountToken,
      ),
    );
    if (response.statusCode >= 400) {
      throw Exception('Plex servers failed (${response.statusCode})');
    }
    final decoded = jsonDecode(response.body);
    final List rawList;
    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map) {
      rawList =
          (decoded['MediaContainer'] is Map
                  ? (decoded['MediaContainer'] as Map)['Device']
                  : decoded['Device'])
              as List? ??
          const [];
    } else {
      rawList = const [];
    }

    final servers = <PlexServerResource>[];
    for (final entry in rawList) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final provides = '${map['provides'] ?? ''}';
      final product = '${map['product'] ?? ''}';
      final isServer =
          provides.contains('server') ||
          product.toLowerCase().contains('plex media server');
      if (!isServer) continue;
      final resource = PlexServerResource.fromJson(map);
      if (resource.machineId.isEmpty || resource.accessToken.isEmpty) continue;
      if (resource.connections.isEmpty) continue;
      servers.add(resource);
    }

    servers.sort((a, b) {
      if (a.owned != b.owned) return a.owned ? -1 : 1;
      if (a.presence != b.presence) return a.presence ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return servers;
  }

  /// Tries connections in preference order until `/identity` succeeds.
  Future<String> resolveReachableUrl(
    PlexServerResource server, {
    required String clientIdentifier,
    Duration perAttemptTimeout = const Duration(seconds: 4),
  }) async {
    final ordered = orderedConnectionUris(server);
    if (ordered.isEmpty) {
      throw Exception('No connections listed for ${server.name}');
    }

    Object? lastError;
    for (final base in ordered) {
      try {
        final uri = Uri.parse('$base/identity');
        final response = await _http
            .get(
              uri,
              headers: _headers(
                clientIdentifier: clientIdentifier,
                token: server.accessToken,
              ),
            )
            .timeout(perAttemptTimeout);
        if (response.statusCode < 400) return base;
        lastError = 'HTTP ${response.statusCode}';
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception(
      'Could not reach ${server.name}'
      '${lastError == null ? '' : ' ($lastError)'}',
    );
  }

  /// Connection URIs in local → remote → relay order, trailing slashes stripped.
  static List<String> orderedConnectionUris(PlexServerResource server) {
    return [
      for (final connection in orderedConnections(server))
        normalizeMediaServerBase(connection.uri),
    ].where((uri) => uri.isNotEmpty).toList();
  }

  /// Best remote (non-LAN) URI for Drive sync: prefer non-relay HTTPS.
  static String? preferredRemoteUri(PlexServerResource server) {
    final ordered = orderedConnections(server);
    for (final connection in ordered) {
      if (!connection.local && !connection.relay) {
        final uri = normalizeMediaServerBase(connection.uri);
        if (uri.isNotEmpty) return uri;
      }
    }
    for (final connection in ordered) {
      if (!connection.local) {
        final uri = normalizeMediaServerBase(connection.uri);
        if (uri.isNotEmpty) return uri;
      }
    }
    return null;
  }

  static List<PlexServerConnection> orderedConnections(
    PlexServerResource server,
  ) {
    final list = [...server.connections];
    int rank(PlexServerConnection c) {
      // Lower is better.
      var score = 0;
      if (c.relay) score += 40;
      if (!c.local) score += 20;
      if (c.ipv6) score += 5;
      if (server.httpsRequired && c.protocol == 'http') score += 30;
      if (!server.httpsRequired && c.protocol == 'https' && c.local) {
        // Prefer http on LAN when https is not required (certs).
        score += 2;
      }
      return score;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    return list;
  }

  /// Movies and shows on the signed-in plex.tv watchlist (Discover).
  Future<List<PlexWatchlistHit>> fetchWatchlist(
    String accountToken, {
    required String clientIdentifier,
  }) async {
    final token = accountToken.trim();
    if (token.isEmpty) return const [];
    final out = <PlexWatchlistHit>[];
    var start = 0;
    while (out.length < watchlistMaxItems) {
      final remaining = watchlistMaxItems - out.length;
      final size = remaining < watchlistPageSize
          ? remaining
          : watchlistPageSize;
      final uri = Uri.parse('$_discoverUrl/library/sections/watchlist/all')
          .replace(
            queryParameters: {
              'includeCollections': '0',
              'includeExternalMedia': '1',
              'X-Plex-Container-Start': '$start',
              'X-Plex-Container-Size': '$size',
            },
          );
      final response = await _http.get(
        uri,
        headers: {
          ..._headers(clientIdentifier: clientIdentifier, token: token),
          'X-Plex-Provider-Version': '6.5.0',
          'X-Plex-Model': 'hosted',
          'Origin': 'https://watch.plex.tv',
          'Referer': 'https://watch.plex.tv/',
        },
      );
      if (response.statusCode >= 400) {
        throw Exception('Plex watchlist failed (${response.statusCode})');
      }
      final page = _parseWatchlistPage(response.body);
      if (page.isEmpty) break;
      out.addAll(page);
      if (page.length < size) break;
      start += page.length;
    }
    return out;
  }

  List<PlexWatchlistHit> _parseWatchlistPage(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final map = Map<String, dynamic>.from(decoded);
    final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
    final list = container['Metadata'] as List? ?? const [];
    final out = <PlexWatchlistHit>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final hit = _watchlistHitFromMeta(Map<String, dynamic>.from(raw));
      if (hit != null) out.add(hit);
    }
    return out;
  }

  PlexWatchlistHit? _watchlistHitFromMeta(Map<String, dynamic> m) {
    var type = '${m['type'] ?? ''}';
    var ratingKey = '${m['ratingKey'] ?? ''}'.trim();
    var title = (m['title'] as String?)?.trim() ?? '';
    var year = (m['year'] as num?)?.toInt();
    var thumb = m['thumb'] as String? ?? m['art'] as String?;
    if (type == 'episode') {
      ratingKey = '${m['grandparentRatingKey'] ?? ratingKey}'.trim();
      title = (m['grandparentTitle'] as String?)?.trim() ?? title;
      thumb =
          (m['grandparentThumb'] as String?) ??
          (m['parentThumb'] as String?) ??
          thumb;
      type = 'show';
    }
    if (ratingKey.isEmpty || title.isEmpty) return null;
    if (type != 'movie' && type != 'show') return null;

    int? tmdb;
    String? imdb;
    final guids = m['Guid'] as List? ?? const [];
    for (final g in guids) {
      if (g is! Map) continue;
      final id = '${g['id'] ?? ''}';
      if (id.startsWith('tmdb://')) {
        tmdb = int.tryParse(id.replaceFirst('tmdb://', ''));
      } else if (id.startsWith('imdb://')) {
        imdb = id.replaceFirst('imdb://', '');
      }
    }

    final added =
        (m['watchlistedAt'] as num?)?.toInt() ??
        (m['addedAt'] as num?)?.toInt();
    DateTime? listedAt;
    if (added != null && added > 0) {
      listedAt = added > 20000000000
          ? DateTime.fromMillisecondsSinceEpoch(added, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(added * 1000, isUtc: true);
    }

    final thumbUrl = (thumb == null || thumb.isEmpty)
        ? null
        : (thumb.startsWith('http') ? thumb : null);

    return PlexWatchlistHit(
      ratingKey: ratingKey,
      title: title,
      isShow: type == 'show',
      year: year,
      tmdb: tmdb,
      imdb: imdb,
      thumbUrl: thumbUrl,
      listedAt: listedAt,
    );
  }

  void close() => _http.close();
}

/// Snapshot fields so Drive sync can reach this PMS from another network.
class PlexStoredConnections {
  const PlexStoredConnections({
    required this.serverUrl,
    this.alternateServerUrl,
    this.extraServerUrls = const [],
  });

  final String serverUrl;
  final String? alternateServerUrl;
  final List<String> extraServerUrls;

  factory PlexStoredConnections.fromResource(
    PlexServerResource server, {
    String? reachableUrl,
  }) {
    final ordered = PlexAccountClient.orderedConnectionUris(server);
    final primary = normalizeMediaServerBase(reachableUrl);
    final serverUrl = primary.isNotEmpty
        ? primary
        : (ordered.isNotEmpty ? ordered.first : '');
    final remote = PlexAccountClient.preferredRemoteUri(server);
    final extras = <String>[
      for (final uri in ordered)
        if (uri != serverUrl && uri != remote) uri,
    ];
    return PlexStoredConnections(
      serverUrl: serverUrl,
      alternateServerUrl: (remote != null && remote != serverUrl)
          ? remote
          : null,
      extraServerUrls: extras,
    );
  }
}
