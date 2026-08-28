/// Compile-time host OS for this binary.
///
/// Set with `--dart-define=JAVP_HOST=android|tizen|webos`.
/// Defaults to [JavpHostKind.android] so existing Android builds are unchanged.
enum JavpHostKind {
  android,
  tizen,
  webos,
}

/// Which OS this binary was built for.
abstract final class JavpHost {
  static const String _raw = String.fromEnvironment(
    'JAVP_HOST',
    defaultValue: 'android',
  );

  static JavpHostKind get current => switch (_raw.toLowerCase()) {
        'tizen' => JavpHostKind.tizen,
        'webos' => JavpHostKind.webos,
        _ => JavpHostKind.android,
      };

  static bool get isAndroid => current == JavpHostKind.android;

  static bool get isTizen => current == JavpHostKind.tizen;

  static bool get isWebOs => current == JavpHostKind.webos;

  /// Samsung Tizen or LG webOS smart-TV Flutter ports.
  static bool get isSmartTvOs => isTizen || isWebOs;

  static String get label => switch (current) {
        JavpHostKind.android => 'Android',
        JavpHostKind.tizen => 'Tizen',
        JavpHostKind.webos => 'webOS',
      };
}
