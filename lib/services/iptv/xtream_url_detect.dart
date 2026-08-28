/// Shape of an Xtream-style URL pasted into the M3U (or generic URL) field.
enum XtreamUrlShape {
  /// `player_api.php` / `panel_api.php` — JSON API, not an M3U playlist.
  playerApi,

  /// `get.php` / `playlist.php` with credentials — valid M3U export, but
  /// Xtream login is usually better (categories / VOD / EPG).
  playlistExport,

  /// `/live|movie|series/{user}/{pass}/…` stream path.
  streamPath,

  /// Panel / DNS URL with `username` + `password` query params.
  credentialsQuery,
}

/// Credentials and base URL extracted from a pasted Xtream-style URL.
class DetectedXtreamUrl {
  const DetectedXtreamUrl({
    required this.inputUrl,
    required this.baseUrl,
    required this.shape,
    this.username,
    this.password,
  });

  /// Original pasted string (trimmed).
  final String inputUrl;

  /// Panel base suitable for [IptvSource.serverUrl] (no trailing slash).
  final String baseUrl;

  final XtreamUrlShape shape;
  final String? username;
  final String? password;

  /// True when importing this URL as M3U will not work (API / stream / bare
  /// panel login URL).
  ///
  /// Playlist exports (`get.php`) stay allowlisted so intentional M3U use is
  /// not hard-blocked — the UI still suggests switching to Xtream.
  bool get blocksM3uImport =>
      shape == XtreamUrlShape.playerApi ||
      shape == XtreamUrlShape.streamPath ||
      shape == XtreamUrlShape.credentialsQuery;

  bool get hasCredentials =>
      (username?.isNotEmpty ?? false) && (password?.isNotEmpty ?? false);
}

/// Detects common Xtream Codes URL patterns and extracts base + credentials.
///
/// Returns null when [raw] does not look like Xtream (or is not http/https).
DetectedXtreamUrl? tryDetectXtreamUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;

  final pathLower = uri.path.toLowerCase();
  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  final user = _queryCredential(uri, const ['username', 'user', 'login']);
  final pass = _queryCredential(uri, const ['password', 'pass', 'pwd']);

  if (_endsWithPhp(pathLower, 'player_api.php') ||
      _endsWithPhp(pathLower, 'panel_api.php')) {
    return DetectedXtreamUrl(
      inputUrl: trimmed,
      baseUrl: _baseFromPhpEndpoint(uri),
      shape: XtreamUrlShape.playerApi,
      username: user,
      password: pass,
    );
  }

  if (_endsWithPhp(pathLower, 'get.php') ||
      _endsWithPhp(pathLower, 'playlist.php')) {
    if (user != null && pass != null) {
      return DetectedXtreamUrl(
        inputUrl: trimmed,
        baseUrl: _baseFromPhpEndpoint(uri),
        shape: XtreamUrlShape.playlistExport,
        username: user,
        password: pass,
      );
    }
  }

  final stream = _matchStreamPath(segments);
  if (stream != null) {
    return DetectedXtreamUrl(
      inputUrl: trimmed,
      baseUrl: _baseBeforeSegment(uri, stream.index),
      shape: XtreamUrlShape.streamPath,
      username: stream.user,
      password: stream.pass,
    );
  }

  // Portal / DNS links: `http://host:port/?username=&password=` (or `/c/`).
  if (user != null && pass != null && _looksLikePanelPath(pathLower, segments)) {
    return DetectedXtreamUrl(
      inputUrl: trimmed,
      baseUrl: _originBase(uri),
      shape: XtreamUrlShape.credentialsQuery,
      username: user,
      password: pass,
    );
  }

  return null;
}

bool _endsWithPhp(String pathLower, String fileName) {
  return pathLower == '/$fileName' ||
      pathLower == fileName ||
      pathLower.endsWith('/$fileName');
}

bool _looksLikePanelPath(String pathLower, List<String> segments) {
  if (pathLower.isEmpty || pathLower == '/') return true;
  if (pathLower == '/c' || pathLower == '/c/' || pathLower.endsWith('/c/')) {
    return true;
  }
  // Single short path segment (e.g. `/portal`) with credentials in query.
  return segments.length <= 1;
}

String? _queryCredential(Uri uri, List<String> keys) {
  for (final key in keys) {
    final value = uri.queryParameters[key];
    if (value != null && value.isNotEmpty) return value;
  }
  // Case-insensitive fallback — some panels mix casing.
  final lower = {
    for (final e in uri.queryParameters.entries) e.key.toLowerCase(): e.value,
  };
  for (final key in keys) {
    final value = lower[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String _baseFromPhpEndpoint(Uri uri) {
  final path = uri.path;
  final slash = path.lastIndexOf('/');
  final dir = slash <= 0 ? '' : path.substring(0, slash);
  return _joinOrigin(uri, dir);
}

String _baseBeforeSegment(Uri uri, int segmentIndex) {
  final kept = uri.pathSegments
      .where((s) => s.isNotEmpty)
      .take(segmentIndex)
      .toList(growable: false);
  final dir = kept.isEmpty ? '' : '/${kept.join('/')}';
  return _joinOrigin(uri, dir);
}

String _originBase(Uri uri) => _joinOrigin(uri, '');

String _joinOrigin(Uri uri, String path) {
  final normalized = path.replaceAll(RegExp(r'/+$'), '');
  final authority = uri.hasPort
      ? '${uri.host}:${uri.port}'
      : uri.host;
  if (normalized.isEmpty) {
    return '${uri.scheme}://$authority';
  }
  final withSlash = normalized.startsWith('/') ? normalized : '/$normalized';
  return '${uri.scheme}://$authority$withSlash';
}

({int index, String user, String pass})? _matchStreamPath(
  List<String> segments,
) {
  for (var i = 0; i < segments.length - 2; i++) {
    final kind = segments[i].toLowerCase();
    if (kind != 'live' && kind != 'movie' && kind != 'series') continue;
    final user = segments[i + 1];
    final pass = segments[i + 2];
    if (user.isEmpty || pass.isEmpty) continue;
    // Require a stream id (or file) after credentials so `/live` alone
    // does not match.
    if (i + 3 >= segments.length) continue;
    return (index: i, user: user, pass: pass);
  }
  return null;
}
