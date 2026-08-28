import 'package:flutter/foundation.dart';

import 'desktop_ui_io.dart' if (dart.library.html) 'desktop_ui_web.dart'
    as platform;

/// Whether to build the pointer-and-keyboard (desktop) variant of the UI.
///
/// Kept free of plugin imports so widgets and tests can read it cheaply.
class DesktopUi {
  DesktopUi._();

  /// Test override. Prefer leaving null in production code.
  @visibleForTesting
  static bool? debugOverride;

  /// Layout mode override from [LayoutModeResolver].
  ///
  /// When set to `false`, forces desktop UI off even on desktop OSes (TV mode).
  /// When `null`, uses the platform default.
  static bool? layoutModeOverride;

  static bool get enabled {
    final override = debugOverride;
    if (override != null) return override;

    final layoutOverride = layoutModeOverride;
    if (layoutOverride != null) return layoutOverride;

    if (kIsWeb) return false;
    return platform.isDesktopPlatform;
  }

  /// Whether this is a desktop OS (regardless of layout mode).
  ///
  /// Use this when you need to know the actual platform, not the UI mode.
  static bool get isDesktopOs {
    if (kIsWeb) return false;
    return platform.isDesktopPlatform;
  }

  /// Width at which the desktop shell shows labels beside rail icons.
  static const railExtendedBreakpoint = 1180.0;
}
