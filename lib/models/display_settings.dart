import 'package:javp/models/media_item.dart';
import 'package:javp/platform/layout_mode.dart';

/// Poster / cover layout for on-demand movies and series shelves.
enum MoviesCoverOrientation {
  /// Classic 2:3 poster.
  vertical,

  /// Widescreen 16:9 thumb.
  horizontal,

  /// One uniform format per shelf/grid from available artwork (no mixed sizes).
  auto,
}

/// UI preferences for browsing the library (not playback).
class DisplaySettings {
  const DisplaySettings({
    this.moviesCoverOrientation = MoviesCoverOrientation.vertical,
    this.showMusicTab = false,
    this.layoutMode = LayoutModePreference.auto,
  });

  static const defaults = DisplaySettings();

  /// Vertical (poster), horizontal (backdrop-style), or auto per shelf.
  final MoviesCoverOrientation moviesCoverOrientation;

  /// Optional sixth shell destination for live radio. Off by default; Library
  /// still opens `/music`.
  final bool showMusicTab;

  /// Desktop/TV layout preference (desktop OSes only).
  ///
  /// Auto uses heuristics (SteamOS, gamescope, etc.). Can be overridden by
  /// `JAVP_UI` environment variable or dart-define.
  final LayoutModePreference layoutMode;

  /// Forced cover orientation, or `null` when [MoviesCoverOrientation.auto].
  ///
  /// When null, resolve a single aspect for the shelf/list via
  /// [resolveMoviesCoverPortrait] so tiles stay uniform.
  bool? get moviesCoverPortrait {
    switch (moviesCoverOrientation) {
      case MoviesCoverOrientation.vertical:
        return true;
      case MoviesCoverOrientation.horizontal:
        return false;
      case MoviesCoverOrientation.auto:
        return null;
    }
  }

  /// Single aspect for uniform grids when auto cannot inspect the full set.
  ///
  /// Defaults to portrait (classic posters) when orientation is auto.
  bool get moviesCoverGridPortrait => moviesCoverPortrait ?? true;

  /// Uniform portrait decision for a shelf or list.
  ///
  /// Forced vertical/horizontal always win. Auto picks portrait when any
  /// non-live item has poster art; otherwise landscape — every tile shares
  /// that size (artwork still follows [MediaItem.artUrlFor]).
  bool resolveMoviesCoverPortrait(Iterable<MediaItem> items) {
    final forced = moviesCoverPortrait;
    if (forced != null) return forced;
    var sawVod = false;
    for (final item in items) {
      if (item.isLive) continue;
      sawVod = true;
      if (item.prefersPortraitArt) return true;
    }
    // No VOD rows → portrait default; VOD without posters → landscape.
    return !sawVod;
  }

  DisplaySettings copyWith({
    MoviesCoverOrientation? moviesCoverOrientation,
    bool? showMusicTab,
    LayoutModePreference? layoutMode,
  }) {
    return DisplaySettings(
      moviesCoverOrientation:
          moviesCoverOrientation ?? this.moviesCoverOrientation,
      showMusicTab: showMusicTab ?? this.showMusicTab,
      layoutMode: layoutMode ?? this.layoutMode,
    );
  }

  Map<String, dynamic> toJson() => {
    'moviesCoverOrientation': moviesCoverOrientation.name,
    'showMusicTab': showMusicTab,
    'layoutMode': layoutMode.name,
  };

  factory DisplaySettings.fromJson(Map<String, dynamic> json) {
    final name = json['moviesCoverOrientation'] as String?;
    final orientation = MoviesCoverOrientation.values.firstWhere(
      (o) => o.name == name,
      orElse: () => MoviesCoverOrientation.vertical,
    );
    final layoutName = json['layoutMode'] as String?;
    final layout = LayoutModePreference.values.firstWhere(
      (l) => l.name == layoutName,
      orElse: () => LayoutModePreference.auto,
    );
    return DisplaySettings(
      moviesCoverOrientation: orientation,
      showMusicTab: json['showMusicTab'] as bool? ?? false,
      layoutMode: layout,
    );
  }
}
