/// Which channel this binary was built for.
///
/// Set at compile time with `--dart-define=JAVP_DISTRIBUTION=sideload|play|msstore`.
/// Defaults to [AppDistribution.sideload] so local `flutter run` matches the
/// public APK / desktop installer channel when the define is omitted.
enum AppDistribution {
  /// Self-hosted APKs from updater.javp.app (in-app update install allowed).
  /// Desktop: zip / Inno Setup / winget sideload.
  sideload,

  /// Google Play / Play App Signing (no self-update; Play handles updates).
  play,

  /// Microsoft Store MSIX (no self-update; Store handles updates).
  msstore,
}

/// Compile-time distribution channel for this build.
abstract final class Distribution {
  static const String _raw = String.fromEnvironment(
    'JAVP_DISTRIBUTION',
    defaultValue: 'sideload',
  );

  static AppDistribution get current => switch (_raw) {
        'play' => AppDistribution.play,
        'msstore' || 'microsoftStore' || 'windowsStore' =>
          AppDistribution.msstore,
        _ => AppDistribution.sideload,
      };

  static bool get isPlayStore => current == AppDistribution.play;

  static bool get isMicrosoftStore => current == AppDistribution.msstore;

  static bool get isSideload => current == AppDistribution.sideload;

  /// True for any store-managed channel (Play or Microsoft Store).
  static bool get isStoreManaged => isPlayStore || isMicrosoftStore;

  /// Sideload builds may check updater.javp.app and install packages.
  /// Store builds must not — the store owns updates.
  static bool get enablesSelfUpdate => isSideload;

  static String get label => switch (current) {
        AppDistribution.sideload => 'Sideload',
        AppDistribution.play => 'Google Play',
        AppDistribution.msstore => 'Microsoft Store',
      };
}
