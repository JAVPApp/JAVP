import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';

/// Public App Link / landing host for one-click add (`https://javp.app/add?…`).
const kJavpAppLinkHost = 'javp.app';

/// One-click "add source" payload from a `javp://add?…` or
/// `https://javp.app/add?…` deep link.
class JavpSourceAddRequest {
  const JavpSourceAddRequest({
    required this.type,
    required this.url,
    this.name,
    this.epgUrl,
    this.username,
    this.password,
    this.alternateServerUrl,
  });

  final IptvSourceType type;

  /// Catalog / M3U playlist URL, or Xtream / media-server base URL.
  final String url;
  final String? name;
  final String? epgUrl;

  /// Xtream Codes credentials (ignored for custom / M3U).
  final String? username;
  final String? password;
  final String? alternateServerUrl;

  String get typeLabel => switch (type) {
        IptvSourceType.custom => 'JSON catalog',
        IptvSourceType.m3u => 'M3U playlist',
        IptvSourceType.xtream => 'Xtream Codes',
        IptvSourceType.stalker => 'Stalker / Ministra',
        IptvSourceType.jellyfin => 'Jellyfin',
        IptvSourceType.emby => 'Emby',
        IptvSourceType.plex => 'Plex',
        IptvSourceType.xmltv => 'EPG / XMLTV',
      };

  /// Short summary for confirm dialogs (never includes the password).
  String get confirmSummary {
    final buf = StringBuffer('Name: ${name ?? defaultDisplayName}\n\n');
    switch (type) {
      case IptvSourceType.xtream:
        buf.writeln('Server: $url');
        if (alternateServerUrl != null && alternateServerUrl!.isNotEmpty) {
          buf.writeln('Alt DNS: $alternateServerUrl');
        }
        buf.write('Username: ${username ?? ''}');
        break;
      case IptvSourceType.stalker:
        buf.writeln('Portal: $url');
        buf.write('MAC: ${username ?? ''}');
        break;
      case IptvSourceType.m3u:
        buf.write('URL: $url');
        if (epgUrl != null && epgUrl!.isNotEmpty) {
          buf.write('\n\nEPG: $epgUrl');
        }
        break;
      default:
        buf.write('URL: $url');
    }
    return buf.toString();
  }

  String get defaultDisplayName => switch (type) {
        IptvSourceType.custom => 'Custom catalog',
        IptvSourceType.m3u => 'M3U Source',
        IptvSourceType.xtream => 'Xtream Source',
        IptvSourceType.stalker => 'Stalker Source',
        IptvSourceType.xmltv => 'EPG / XMLTV',
        _ => 'Source',
      };

  /// Builds a shareable `javp://add?…` deep link for this request.
  Uri toDeepLink() => buildJavpSourceAddLink(
        type: type,
        url: url,
        name: name,
        epgUrl: epgUrl,
        username: username,
        password: password,
        alternateServerUrl: alternateServerUrl,
      );

  /// Builds a shareable `https://javp.app/add?…` App Link for this request.
  Uri toHttpsLink() => buildJavpSourceAddHttpsLink(
        type: type,
        url: url,
        name: name,
        epgUrl: epgUrl,
        username: username,
        password: password,
        alternateServerUrl: alternateServerUrl,
      );
}

Map<String, String> _addQueryParameters({
  required IptvSourceType type,
  required String url,
  String? name,
  String? epgUrl,
  String? username,
  String? password,
  String? alternateServerUrl,
}) {
  final typeParam = switch (type) {
    IptvSourceType.custom => 'custom',
    IptvSourceType.m3u => 'm3u',
    IptvSourceType.xtream => 'xtream',
    IptvSourceType.stalker => 'stalker',
    _ => throw ArgumentError(
        'Deep links support custom, M3U, Xtream, and Stalker (got $type)',
      ),
  };
  return {
    'type': typeParam,
    'url': url,
    if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
    if (type == IptvSourceType.m3u &&
        epgUrl != null &&
        epgUrl.trim().isNotEmpty)
      'epg': epgUrl.trim(),
    if (type == IptvSourceType.xtream) ...{
      if (username != null && username.trim().isNotEmpty)
        'username': username.trim(),
      if (password != null) 'password': password,
      if (alternateServerUrl != null && alternateServerUrl.trim().isNotEmpty)
        'alt': alternateServerUrl.trim(),
    },
    if (type == IptvSourceType.stalker) ...{
      if (username != null && username.trim().isNotEmpty)
        'mac': username.trim(),
      if (password != null && password.trim().isNotEmpty)
        'serial': password.trim(),
    },
  };
}

/// Builds `javp://add?type=…&url=…` for websites, QR codes, and sharing.
Uri buildJavpSourceAddLink({
  required IptvSourceType type,
  required String url,
  String? name,
  String? epgUrl,
  String? username,
  String? password,
  String? alternateServerUrl,
}) {
  return Uri(
    scheme: 'javp',
    host: 'add',
    queryParameters: _addQueryParameters(
      type: type,
      url: url,
      name: name,
      epgUrl: epgUrl,
      username: username,
      password: password,
      alternateServerUrl: alternateServerUrl,
    ),
  );
}

/// Builds `https://javp.app/add?type=…&url=…` (verified Android App Link).
Uri buildJavpSourceAddHttpsLink({
  required IptvSourceType type,
  required String url,
  String? name,
  String? epgUrl,
  String? username,
  String? password,
  String? alternateServerUrl,
}) {
  return Uri(
    scheme: 'https',
    host: kJavpAppLinkHost,
    path: '/add',
    queryParameters: _addQueryParameters(
      type: type,
      url: url,
      name: name,
      epgUrl: epgUrl,
      username: username,
      password: password,
      alternateServerUrl: alternateServerUrl,
    ),
  );
}

/// Whether [uri] is a JAVP deep link (must not be treated as a GoRouter path).
bool isJavpDeepLink(Uri uri) => uri.scheme.toLowerCase() == 'javp';

/// Return URL after plex.tv PIN approval (`javp://plex-auth`).
bool isJavpPlexAuthLink(Uri uri) {
  if (!isJavpDeepLink(uri)) return false;
  final host = uri.host.toLowerCase();
  final path = _normalizedPath(uri);
  return host == 'plex-auth' ||
      path == '/plex-auth' ||
      path == 'plex-auth' ||
      path.endsWith('/plex-auth');
}

/// Canonical forward URL for plex.tv OAuth redirect back into the app.
const kPlexAuthForwardUrl = 'javp://plex-auth';

bool _isAddPath(Uri uri) {
  final path = _normalizedPath(uri);
  return path == '/add' || path == 'add' || path.endsWith('/add');
}

bool _isJavpAppHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == kJavpAppLinkHost || host == 'www.$kJavpAppLinkHost';
}

/// `javp://add…`, `https://javp.app/add?…`, or path-style `/add?…`
/// (some platforms strip the custom scheme).
///
/// Other `https://…/add` hosts are not treated as add links so media VIEW
/// intents keep their normal path.
bool isJavpAddSourceLink(Uri uri) {
  if (isJavpDeepLink(uri)) {
    final host = uri.host.toLowerCase();
    // `javp://add?…` uses host "add" with an empty path (go_router may use `/`).
    return host == 'add' || _isAddPath(uri);
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    return _isJavpAppHost(uri) && _isAddPath(uri);
  }

  // Relative / path-only URIs (GoRouter or stripped scheme).
  if (scheme.isEmpty && uri.host.isEmpty) {
    return _isAddPath(uri);
  }

  return false;
}

/// Cold/warm opens that should override the platform default route.
bool isExternalDeepLink(Uri uri) =>
    isJavpDeepLink(uri) ||
    isJavpAddSourceLink(uri) ||
    isJavpPairLink(uri) ||
    isExternalMediaScheme(uri);

/// Media VIEW intents (content/file/magnet/http) — kept here so app.dart has
/// one gate for "not an in-app path".
bool isExternalMediaScheme(Uri uri) {
  if (isJavpAddSourceLink(uri)) return false;
  if (isJavpPairLink(uri)) return false;
  switch (uri.scheme.toLowerCase()) {
    case 'content':
    case 'file':
    case 'magnet':
      return true;
    case 'http':
    case 'https':
      return uri.host.isNotEmpty;
    default:
      return false;
  }
}

/// Parses pasted text that may be a `javp://add` / `https://javp.app/add`
/// share link (used by Add Source form URL fields and TV pairing paste).
///
/// Returns null when [raw] is empty, not a URI, or not a valid add link.
JavpSourceAddRequest? parseJavpSourceAddLinkText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  return parseJavpSourceAddLink(uri);
}

/// Parses `javp://add?type=custom|m3u|xtream&url=…&…`
/// (also accepts `https://javp.app/add?…` and path-style `/add?…`).
///
/// Returns null when the link is not an add-source request or is invalid.
JavpSourceAddRequest? parseJavpSourceAddLink(Uri uri) {
  if (!isJavpAddSourceLink(uri)) return null;

  final q = uri.queryParameters;
  final typeRaw = (q['type'] ?? q['kind'] ?? '').trim().toLowerCase();
  final type = switch (typeRaw) {
    'custom' || 'json' || 'catalog' => IptvSourceType.custom,
    'm3u' || 'm3u8' || 'playlist' => IptvSourceType.m3u,
    'xtream' || 'xc' || 'xui' || 'xtream-codes' || 'xtreamcodes' =>
      IptvSourceType.xtream,
    'stalker' || 'ministra' || 'mag' || 'portal' => IptvSourceType.stalker,
    _ => null,
  };
  if (type == null) return null;

  final name = (q['name'] ?? q['title'] ?? '').trim();

  if (type == IptvSourceType.xtream) {
    final url = (q['url'] ??
            q['server'] ??
            q['serverUrl'] ??
            q['host'] ??
            q['dns'] ??
            '')
        .trim();
    if (!_isAllowedHttpUrl(url)) return null;

    final username =
        (q['username'] ?? q['user'] ?? q['login'] ?? '').trim();
    final password = (q['password'] ?? q['pass'] ?? q['pwd'] ?? '');
    if (username.isEmpty || password.isEmpty) return null;

    final alt = (q['alt'] ??
            q['alternate'] ??
            q['alternateServerUrl'] ??
            q['alternateUrl'] ??
            q['altDns'] ??
            q['alt_dns'] ??
            q['dns2'] ??
            '')
        .trim();
    if (alt.isNotEmpty && !_isAllowedHttpUrl(alt)) return null;

    return JavpSourceAddRequest(
      type: type,
      url: url,
      name: name.isEmpty ? null : name,
      username: username,
      password: password,
      alternateServerUrl: alt.isEmpty ? null : alt,
    );
  }

  if (type == IptvSourceType.stalker) {
    final url = (q['url'] ??
            q['portal'] ??
            q['server'] ??
            q['serverUrl'] ??
            q['host'] ??
            '')
        .trim();
    if (!_isAllowedHttpUrl(url)) return null;

    final mac = (q['mac'] ??
            q['username'] ??
            q['user'] ??
            '')
        .trim();
    if (mac.isEmpty) return null;

    final serial = (q['serial'] ?? q['password'] ?? q['pass'] ?? q['sn'] ?? '')
        .trim();

    return JavpSourceAddRequest(
      type: type,
      url: url,
      name: name.isEmpty ? null : name,
      username: mac,
      password: serial.isEmpty ? null : serial,
    );
  }

  final url = (q['url'] ??
          q['catalog'] ??
          q['playlist'] ??
          q['playlistUrl'] ??
          '')
      .trim();
  if (!_isAllowedHttpUrl(url)) return null;

  final epg = (q['epg'] ?? q['epgUrl'] ?? '').trim();

  return JavpSourceAddRequest(
    type: type,
    url: url,
    name: name.isEmpty ? null : name,
    epgUrl: type == IptvSourceType.m3u && epg.isNotEmpty ? epg : null,
  );
}

String _normalizedPath(Uri uri) =>
    uri.path.toLowerCase().replaceAll(RegExp(r'/+$'), '');

bool _isAllowedHttpUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return false;
  final scheme = u.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}
