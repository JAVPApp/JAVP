import 'package:flutter/widgets.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';

/// Shared phone / tablet / desktop layout decisions.
///
/// Tablets get the navigation rail and denser grids without enabling
/// [DesktopUi] mouse chrome (hover tiles, right-click menus, shortcuts).
class AdaptiveLayout {
  AdaptiveLayout._();

  /// Material tablet convention: shortest side at least this wide.
  static const tabletShortestSide = 600.0;

  /// Collapsed rail content width (icons only).
  static const railCollapsedWidth = 76.0;

  /// Extended rail content width (icons + labels).
  static const railExtendedWidth = 208.0;

  /// Phone shelf poster widths.
  static const phonePortraitWidth = 118.0;
  static const phoneLandscapeWidth = 220.0;

  /// Tablet / rail shelf poster widths.
  static const railPortraitWidth = 148.0;
  static const railLandscapeWidth = 280.0;

  /// Test override for [useRail]. Prefer leaving null in production code.
  @visibleForTesting
  static bool? debugUseRailOverride;

  /// Whether the shell should show a left navigation rail.
  ///
  /// True on desktop, or on non-TV devices whose shortest side is tablet-sized.
  static bool useRail(BuildContext context) {
    final override = debugUseRailOverride;
    if (override != null) return override;
    if (DesktopUi.enabled) return true;
    if (TvPlatform.isAndroidTv) return false;
    return MediaQuery.sizeOf(context).shortestSide >= tabletShortestSide;
  }

  /// Total width of the rail + divider when [useRail] is active.
  static double railWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final extended = width >= DesktopUi.railExtendedBreakpoint;
    return (extended ? railExtendedWidth : railCollapsedWidth) + 1;
  }

  /// Main content width after subtracting the nav rail when present.
  static double contentWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return useRail(context) ? (width - railWidth(context)).clamp(0.0, width) : width;
  }

  /// Poster grid columns for Search / category browse.
  ///
  /// Prefer [contentWidth] so a nav rail does not steal a column of posters.
  static int posterGridColumns(double width) {
    if (width >= 1400) return 8;
    if (width >= 1200) return 7;
    if (width >= 1000) return 6;
    if (width >= 820) return 5;
    if (width >= 620) return 4;
    return 3;
  }

  /// Live / catalog category card columns (phone, tablet, desktop).
  ///
  /// Uses content width so the nav rail does not inflate the count, and
  /// targets ~220–260px tiles on wide screens instead of two giant cards.
  static int liveCategoryColumns(BuildContext context) {
    final width = contentWidth(context);
    if (width >= 1400) return 5;
    if (width >= 1100) return 4;
    if (width >= 820) return 3;
    if (width >= 520) return 2;
    return 2;
  }

  /// Live channel row columns (TV Live tab, category channel lists).
  ///
  /// Phones stay single-column in portrait and landscape. Desktop / tablet
  /// rail and Android TV / leanback scale with [contentWidth] so wide 10-foot
  /// layouts get 2–4 [MediaTile] rows per line without fighting D-pad focus.
  static int liveChannelColumns(BuildContext context) {
    if (!TvPlatform.isAndroidTv && !useRail(context)) return 1;

    final width = contentWidth(context);
    if (width >= 1500) return 4;
    if (width >= 1100) return 3;
    if (width >= 700) return 2;
    return 1;
  }

  /// Fixed-height channel grid (~72px rows) matching list [MediaTile] density.
  static SliverGridDelegate liveChannelGridDelegate(
    BuildContext context, {
    double mainAxisExtent = 72,
  }) {
    final isTv = TvPlatform.isAndroidTv;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: liveChannelColumns(context),
      mainAxisExtent: mainAxisExtent,
      // Breathing room for TV focus rings / desktop hover chrome between cells.
      crossAxisSpacing: isTv ? 8 : 6,
      mainAxisSpacing: isTv ? 6 : 2,
    );
  }

  /// Width / height for category tiles. Rail/desktop uses compact rows.
  static double liveCategoryAspectRatio(BuildContext context) {
    if (TvPlatform.isAndroidTv) return 4.8;
    if (useRail(context)) return 4.4;
    return 2.8;
  }

  /// Compact shelf tile width (portrait or landscape).
  static double compactTileWidth(BuildContext context, {required bool portrait}) {
    final rail = useRail(context);
    if (portrait) {
      return rail ? railPortraitWidth : phonePortraitWidth;
    }
    return rail ? railLandscapeWidth : phoneLandscapeWidth;
  }

  /// Grid cell width/height for Search / category browse (image + title).
  static double posterGridChildAspectRatio({required bool portrait}) =>
      portrait ? 0.55 : 1.35;

  /// Height of a compact horizontal shelf (poster + gap + label block).
  static double compactShelfHeight(
    BuildContext context, {
    required bool portrait,
    bool withProgress = false,
  }) {
    final tileW = compactTileWidth(context, portrait: portrait);
    final posterH = tileW / (portrait ? 2 / 3 : 16 / 9);
    // +2 slack: TV focus padding / fractional text scale otherwise overflow.
    final labels = MediaQuery.textScalerOf(context).scale(
      withProgress ? 48.0 : 34.0,
    );
    return posterH + 6 + labels + 2;
  }
}
