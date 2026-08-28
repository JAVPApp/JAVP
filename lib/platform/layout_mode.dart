import 'package:flutter/foundation.dart';

import 'layout_mode_io.dart' if (dart.library.html) 'layout_mode_web.dart'
    as env;
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';

/// User preference for desktop vs TV layout on desktop OSes.
enum LayoutModePreference {
  /// Detect based on environment and heuristics.
  auto,

  /// Force the pointer-and-keyboard desktop shell.
  desktop,

  /// Force the 10-foot / leanback TV shell.
  tv,
}

/// Resolved runtime layout mode.
enum LayoutMode {
  desktop,
  tv,
}

/// Resolves and applies the layout mode for desktop OSes.
///
/// Resolution order:
/// 1. `JAVP_UI` environment variable (`tv` | `desktop` | `auto`)
/// 2. `--dart-define=JAVP_UI=...` compile-time constant
/// 3. Persisted user preference (from DisplaySettings)
/// 4. Auto heuristics (Steam Deck, gamescope Game Mode)
/// 5. Default to desktop on Windows/Linux/macOS
abstract final class LayoutModeResolver {
  /// Compile-time override via `--dart-define=JAVP_UI=tv|desktop|auto`.
  static const _dartDefine = String.fromEnvironment('JAVP_UI');

  static LayoutMode? _resolved;
  static LayoutModePreference? _activePreference;

  /// The resolved layout mode. Call [resolve] first during startup.
  static LayoutMode get current => _resolved ?? LayoutMode.desktop;

  /// The preference that produced [current] (for UI display).
  static LayoutModePreference get activePreference =>
      _activePreference ?? LayoutModePreference.auto;

  /// Whether the layout was forced by env/dart-define (not changeable at runtime).
  static bool get isEnvForced {
    final parsed = _parseEnvOrDefine();
    return parsed != null && parsed != LayoutModePreference.auto;
  }

  /// Resolve and apply the layout mode. Call once at startup before building
  /// the shell. Returns the resolved mode.
  ///
  /// [persistedPreference] comes from DisplaySettings.layoutMode.
  static Future<LayoutMode> resolve({
    LayoutModePreference? persistedPreference,
  }) async {
    final envOverride = _parseEnvOrDefine();
    if (envOverride != null && envOverride != LayoutModePreference.auto) {
      _activePreference = envOverride;
      _resolved = envOverride == LayoutModePreference.tv
          ? LayoutMode.tv
          : LayoutMode.desktop;
      _apply(_resolved!);
      return _resolved!;
    }

    final preference =
        envOverride ?? persistedPreference ?? LayoutModePreference.auto;
    _activePreference = preference;

    if (preference == LayoutModePreference.desktop) {
      _resolved = LayoutMode.desktop;
      _apply(_resolved!);
      return _resolved!;
    }

    if (preference == LayoutModePreference.tv) {
      _resolved = LayoutMode.tv;
      _apply(_resolved!);
      return _resolved!;
    }

    final autoResult = await _detectAuto();
    _resolved = autoResult;
    _apply(_resolved!);
    return _resolved!;
  }

  /// Re-apply after the user changes Settings without restarting.
  static Future<LayoutMode> applyPreference(
    LayoutModePreference preference,
  ) async {
    if (isEnvForced) return current;
    return resolve(persistedPreference: preference);
  }

  static void _apply(LayoutMode mode) {
    if (mode == LayoutMode.tv) {
      DesktopUi.layoutModeOverride = false;
      TvPlatform.forceLayoutMode(true);
    } else {
      DesktopUi.layoutModeOverride = null;
      TvPlatform.forceLayoutMode(null);
    }
  }

  static LayoutModePreference? _parseEnvOrDefine() {
    if (kIsWeb) return null;

    final envValue = env.javpUiEnv?.toLowerCase();
    if (envValue != null && envValue.isNotEmpty) {
      return _parsePreference(envValue);
    }

    if (_dartDefine.isNotEmpty) {
      return _parsePreference(_dartDefine.toLowerCase());
    }

    return null;
  }

  static LayoutModePreference? _parsePreference(String value) {
    return switch (value) {
      'tv' => LayoutModePreference.tv,
      'desktop' => LayoutModePreference.desktop,
      'auto' => LayoutModePreference.auto,
      _ => null,
    };
  }

  /// High-confidence only: Steam Deck flag or gamescope Game Mode — never
  /// “big monitor alone”. Bare SteamOS desktop session stays desktop UI;
  /// Game Mode launchers set `JAVP_UI=tv`.
  static Future<LayoutMode> _detectAuto() async {
    if (kIsWeb) return LayoutMode.desktop;

    if (env.steamDeck == '1') {
      return LayoutMode.tv;
    }

    if (env.isGamescopeSession) {
      return LayoutMode.tv;
    }

    return LayoutMode.desktop;
  }

  @visibleForTesting
  static void debugOverride(
    LayoutMode? mode, {
    LayoutModePreference? preference,
  }) {
    _resolved = mode;
    _activePreference = preference;
    if (mode != null) {
      _apply(mode);
    }
  }

  @visibleForTesting
  static void debugReset() {
    _resolved = null;
    _activePreference = null;
    DesktopUi.layoutModeOverride = null;
    TvPlatform.forceLayoutMode(null);
  }
}
