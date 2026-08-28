import 'package:flutter/widgets.dart';

/// Page metrics shared by every screen and by the persistent chrome above the
/// router (the mini player dock).
///
/// [AdaptiveLayout] answers "how big should a tile be on this device".
/// This answers "where does content start and stop", which is what makes
/// screens read as one app instead of a pile of individually tuned pages.
///
/// The dock is hosted above the `Router`, so it cannot see a screen's own
/// paddings. Both sides reading [gutter] from here is what keeps the mini
/// player's artwork on the same vertical line as the posters above it.
class AppLayout {
  AppLayout._();

  /// Horizontal inset between page content and the edge of the content area.
  ///
  /// Shelves, poster grids, section headers and the mini player dock all use
  /// this, so everything shares one left/right line.
  static const gutter = 16.0;

  /// Extra inset for Android TV / leanback overscan (title-safe margin).
  ///
  /// Many sets still crop a few percent of the framebuffer; keep chrome and
  /// focus rings inside this band.
  static const tvOverscan = 24.0;

  /// Widest a reading surface (lists, forms, settings) grows before it centres.
  ///
  /// Shelves and poster grids deliberately stay full-bleed — more width is
  /// more content there. See [DesktopPane].
  static const paneMaxWidth = 960.0;

  /// Space to leave under the last row of a scroll view.
  ///
  /// Covers the mini player dock (66) plus breathing room, so the final poster
  /// or list tile is never pinned behind it.
  static const dockedBottomInset = 88.0;

  /// Corner PIP on Android TV: 16:9 video, title, hint, and overscan.
  static const tvMiniPlayerClearance = 280.0;

  /// Bottom inset for scroll views. Grows while the TV corner mini player is up
  /// so the last row can scroll clear of it.
  static double scrollBottomInset({required bool tvMiniPlayerVisible}) =>
      tvMiniPlayerVisible ? tvMiniPlayerClearance : dockedBottomInset;

  /// [SectionHeader] block: gutter-aligned, with air above each new section.
  static const sectionHeaderPadding = EdgeInsets.fromLTRB(
    gutter,
    18,
    gutter,
    8,
  );

  /// Horizontal shelf (`ListView`, `scrollDirection: Axis.horizontal`).
  static const shelfPadding = EdgeInsets.symmetric(horizontal: gutter);

  /// Scrollable page content that starts under an app bar and ends at the dock.
  static EdgeInsets pagePadding({
    double top = 8,
    double bottom = dockedBottomInset,
  }) => EdgeInsets.fromLTRB(gutter, top, gutter, bottom);
}
