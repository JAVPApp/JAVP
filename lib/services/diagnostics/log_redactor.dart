/// Strips credentials out of a log line before it reaches memory or disk.
///
/// JAVP prints URLs that carry live secrets: Xtream panels require
/// `…/live/{username}/{password}/{id}.ts`, Jellyfin appends `api_key=`, Plex
/// passes `X-Plex-Token`, and an M3U playlist may be `http://user:pass@host/…`.
/// Because a log file exists to be attached to a bug report, scrubbing happens
/// on the write path instead of at export time, so no unredacted copy is ever
/// persisted to leak later.
///
/// Two layers, because neither is sufficient on its own:
///
/// * shape patterns catch credentials this build has never seen, including
///   percent-encoded ones an exact-value comparison cannot match;
/// * registered values catch secrets in URL shapes these patterns do not know
///   about, which is what keeps a newly added provider safe by default.
class LogRedactor {
  /// The shared instance used by the logger. Tests construct their own so
  /// registered secrets do not leak between cases.
  static final LogRedactor instance = LogRedactor();

  static const String mask = '***';

  /// Shorter values are ignored: a 4-character password matches ordinary words
  /// and would redact the log into uselessness.
  static const int _minSecretLength = 6;

  /// Bounded so a session that rotates tokens cannot grow this without limit.
  static const int _maxSecrets = 64;

  /// Longest first, so a token that contains a shorter secret is masked whole
  /// rather than being left as a partially masked fragment.
  final List<String> _secrets = <String>[];

  /// `…/live/user/pass/1234.ts`, plus the `movie`, `series` and `timeshift`
  /// variants. Both segments go regardless of length, since an Xtream panel
  /// puts nothing but credentials there.
  static final RegExp _pathCredentials = RegExp(
    r'(/(?:live|movie|series|timeshift)/)[^/\s]+/[^/\s?#]+/',
    caseSensitive: false,
  );

  static final RegExp _queryCredentials = RegExp(
    r'''\b(username|password|passwd|pwd|api_key|apikey|access_token|refresh_token|client_secret|client_id|token|auth|X-Plex-Token)=[^&\s"'<>]*''',
    caseSensitive: false,
  );

  static final RegExp _urlUserInfo = RegExp(
    r'([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@\s:]+:[^/@\s]+@',
  );

  /// Header and printed-map forms. The optional `Bearer` is consumed here so
  /// the token after it cannot survive as a leftover fragment.
  static final RegExp _headerCredentials = RegExp(
    r'\b(Authorization|X-Plex-Token|X-Emby-Token|X-MediaBrowser-Token|X-Emby-Authorization)\s*:\s*(?:Bearer\s+)?[^\s,;}\)]+',
    caseSensitive: false,
  );

  static final RegExp _bearer = RegExp(
    r'\bBearer\s+[A-Za-z0-9._~+/=\-]+',
    caseSensitive: false,
  );

  /// Records a live secret so every later appearance is masked, whatever shape
  /// it appears in. Safe to call repeatedly with the same value.
  void registerSecret(String? value) {
    final secret = value?.trim() ?? '';
    if (secret.length < _minSecretLength) return;
    if (_secrets.contains(secret)) return;
    _secrets.add(secret);
    _secrets.sort((a, b) => b.length.compareTo(a.length));
    if (_secrets.length > _maxSecrets) {
      _secrets.removeLast();
    }
  }

  void registerSecrets(Iterable<String?> values) {
    for (final value in values) {
      registerSecret(value);
    }
  }

  /// Drops every registered secret. Used when switching profiles and by tests.
  void forgetSecrets() => _secrets.clear();

  int get secretCount => _secrets.length;

  String scrub(String line) {
    if (line.isEmpty) return line;
    var out = line;
    for (final secret in _secrets) {
      if (out.contains(secret)) {
        out = out.replaceAll(secret, mask);
      }
    }
    if (out.contains('/')) {
      out = out.replaceAllMapped(
        _pathCredentials,
        (m) => '${m[1]}$mask/$mask/',
      );
    }
    if (out.contains('=')) {
      out = out.replaceAllMapped(_queryCredentials, (m) => '${m[1]}=$mask');
    }
    if (out.contains('@')) {
      out = out.replaceAllMapped(_urlUserInfo, (m) => '${m[1]}$mask:$mask@');
    }
    if (out.contains(':')) {
      out = out.replaceAllMapped(_headerCredentials, (m) => '${m[1]}: $mask');
    }
    return out.replaceAll(_bearer, 'Bearer $mask');
  }
}
