/// Public App Link host for pairing (`https://javp.app/pair?…`).
/// Kept local to avoid a cycle with [javp_source_link.dart].
const _kPairAppLinkHost = 'javp.app';

/// LAN device pairing deep link (`javp://pair` / `https://javp.app/pair`).
///
/// The TV/desktop QR prefers the HTTPS App Link so a phone **without** JAVP
/// still opens a browser landing page (install + LAN form). Phones with JAVP
/// open the push/pull UI. Credentials stay on the LAN session.
class JavpPairRequest {
  const JavpPairRequest({
    required this.host,
    required this.port,
    required this.token,
    this.pin,
  });

  /// LAN IPv4 (or `127.0.0.1` when using adb forward).
  final String host;
  final int port;

  /// Full session token (preferred).
  final String token;

  /// Optional short PIN (same session); accepted by the pairing server.
  final String? pin;

  /// Credential used for HTTP Authorization / JSON body.
  String get authSecret => token.isNotEmpty ? token : (pin ?? '');

  Uri toDeepLink() => buildJavpPairLink(
        host: host,
        port: port,
        token: token,
        pin: pin,
      );

  /// Verified App Link / landing page (`https://javp.app/pair?…`).
  Uri toHttpsLink() => buildJavpPairHttpsLink(
        host: host,
        port: port,
        token: token,
        pin: pin,
      );

  /// Browser form on the pairing host (no app required for one-source add).
  Uri toLanBrowserLink() => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: '/pair',
        queryParameters: {
          if (token.isNotEmpty) 't': token,
          if (token.isEmpty && pin != null && pin!.isNotEmpty) 'c': pin!,
        },
      );

  /// Base HTTP origin for the pairing server on the LAN.
  Uri get httpOrigin => Uri(
        scheme: 'http',
        host: host,
        port: port,
      );
}

Map<String, String> _pairQuery({
  required String host,
  required int port,
  required String token,
  String? pin,
}) =>
    {
      'h': host,
      'p': '$port',
      't': token,
      if (pin != null && pin.isNotEmpty) 'c': pin,
    };

/// Builds `javp://pair?h=…&p=…&t=…` (± optional `c` PIN).
Uri buildJavpPairLink({
  required String host,
  required int port,
  required String token,
  String? pin,
}) {
  return Uri(
    scheme: 'javp',
    host: 'pair',
    queryParameters: _pairQuery(
      host: host,
      port: port,
      token: token,
      pin: pin,
    ),
  );
}

/// Builds `https://javp.app/pair?h=…&p=…&t=…` (± optional `c` PIN).
Uri buildJavpPairHttpsLink({
  required String host,
  required int port,
  required String token,
  String? pin,
}) {
  return Uri(
    scheme: 'https',
    host: _kPairAppLinkHost,
    path: '/pair',
    queryParameters: _pairQuery(
      host: host,
      port: port,
      token: token,
      pin: pin,
    ),
  );
}

bool _isPairPath(Uri uri) {
  final path = uri.path;
  final normalized = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  return normalized == '/pair' ||
      normalized == 'pair' ||
      normalized.endsWith('/pair');
}

bool _isJavpAppHost(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == _kPairAppLinkHost || host == 'www.$_kPairAppLinkHost';
}

/// `javp://pair?…`, `https://javp.app/pair?…`, or path-style `/pair?…`
/// when a platform strips the custom scheme (same fallback as `/add`).
bool isJavpPairLink(Uri uri) {
  if (uri.scheme.toLowerCase() == 'javp') {
    final host = uri.host.toLowerCase();
    return host == 'pair' || _isPairPath(uri);
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    return _isJavpAppHost(uri) && _isPairPath(uri);
  }
  // Relative / path-only URIs (GoRouter or stripped scheme).
  if (scheme.isEmpty && uri.host.isEmpty) {
    return _isPairPath(uri);
  }
  return false;
}

/// Parses a pairing deep link. Returns null when invalid / incomplete.
JavpPairRequest? parseJavpPairLink(Uri uri) {
  if (!isJavpPairLink(uri)) return null;
  final q = uri.queryParameters;
  final host = (q['h'] ?? q['host'] ?? q['ip'] ?? '').trim();
  final portRaw = (q['p'] ?? q['port'] ?? '').trim();
  final token = (q['t'] ?? q['token'] ?? '').trim();
  final pin = (q['c'] ?? q['pin'] ?? q['code'] ?? '').trim();
  final port = int.tryParse(portRaw);
  if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
  if (token.isEmpty && pin.isEmpty) return null;
  return JavpPairRequest(
    host: host,
    port: port,
    token: token,
    pin: pin.isEmpty ? null : pin,
  );
}
