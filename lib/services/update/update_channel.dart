/// Sideload update channel on updater.javp.app.
///
/// Orthogonal to [Distribution]: Play builds never self-update; sideload builds
/// track either stable (`/latest.json`) or Dev (`/dev/latest.json`).
///
/// Compile-time: `--dart-define=JAVP_UPDATE_CHANNEL=dev`
/// Runtime fallback: Android package id ending in `.dev` (sideloadDev flavor).
enum UpdateChannel {
  stable,
  dev;

  static const envKey = 'JAVP_UPDATE_CHANNEL';
  static const publicBaseDefault = 'https://updater.javp.app';

  /// Channel from dart-define (defaults to stable when unset).
  static UpdateChannel get current =>
      parse(const String.fromEnvironment(envKey, defaultValue: 'stable'));

  /// Channel when `JAVP_UPDATE_CHANNEL` was baked in; `null` when unset so
  /// callers can fall back to the Android `.dev` package id (sideloadDev).
  ///
  /// Matches [AppUpdateService.resolveChannel]: an empty define is not treated
  /// as stable until the package name is checked.
  static UpdateChannel? get bakedOrNull {
    const baked = String.fromEnvironment(envKey, defaultValue: '');
    if (baked.trim().isEmpty) return null;
    return parse(baked);
  }

  static UpdateChannel parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'dev':
      case 'development':
        return UpdateChannel.dev;
      case 'stable':
      case 'main':
      case '':
        return UpdateChannel.stable;
      default:
        return UpdateChannel.stable;
    }
  }

  String get id => name;

  String get displayName => id;

  bool get isDev => this == UpdateChannel.dev;

  String manifestUrl({String publicBase = publicBaseDefault}) {
    final base = publicBase.replaceAll(RegExp(r'/+$'), '');
    return switch (this) {
      UpdateChannel.stable => '$base/latest.json',
      UpdateChannel.dev => '$base/dev/latest.json',
    };
  }

  /// Android product flavor that publishes/installs this channel.
  String get androidFlavor => switch (this) {
    UpdateChannel.stable => 'sideload',
    UpdateChannel.dev => 'sideloadDev',
  };
}
