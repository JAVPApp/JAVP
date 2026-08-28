import 'package:flutter/widgets.dart';
import 'package:javp/l10n/app_localizations.dart';

/// How the video plane fills the player.
///
/// [fit] letterboxes. [fill] stretches. [zoom] crops. [ratio16x9] / [ratio4x3]
/// force a display aspect (useful for mis-tagged IPTV streams).
enum VideoAspectMode { fit, fill, zoom, ratio16x9, ratio4x3 }

extension VideoAspectModeX on VideoAspectMode {
  String get storageValue => name;

  BoxFit get boxFit => switch (this) {
    VideoAspectMode.fit ||
    VideoAspectMode.ratio16x9 ||
    VideoAspectMode.ratio4x3 => BoxFit.contain,
    VideoAspectMode.fill => BoxFit.fill,
    VideoAspectMode.zoom => BoxFit.cover,
  };

  /// Forced container aspect, or null to use the decoded frame.
  double? get forcedAspectRatio => switch (this) {
    VideoAspectMode.ratio16x9 => 16 / 9,
    VideoAspectMode.ratio4x3 => 4 / 3,
    _ => null,
  };

  String localizedLabel(AppLocalizations l10n) => switch (this) {
    VideoAspectMode.fit => l10n.aspectFit,
    VideoAspectMode.fill => l10n.aspectFill,
    VideoAspectMode.zoom => l10n.aspectZoom,
    VideoAspectMode.ratio16x9 => l10n.aspect16x9,
    VideoAspectMode.ratio4x3 => l10n.aspect4x3,
  };

  static VideoAspectMode fromStorage(String? raw) {
    if (raw == null || raw.isEmpty) return VideoAspectMode.fit;
    return VideoAspectMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => VideoAspectMode.fit,
    );
  }

  /// Where to paint a stretched texture ([BoxFit.fill]) inside [viewport].
  ///
  /// Changing media_kit [Video.fit] recreates the native view. Layout the
  /// texture in Flutter instead so aspect toggles do not hitch playback.
  Rect destinationRect(Size viewport, {required double contentAspect}) {
    if (viewport.isEmpty ||
        !viewport.width.isFinite ||
        !viewport.height.isFinite) {
      return Offset.zero & viewport;
    }
    final safe = contentAspect > 0 ? contentAspect : 16 / 9;
    switch (this) {
      case VideoAspectMode.fill:
        return Offset.zero & viewport;
      case VideoAspectMode.fit:
        return containRect(viewport, safe);
      case VideoAspectMode.zoom:
        return coverRect(viewport, safe);
      case VideoAspectMode.ratio16x9:
        return containRect(viewport, 16 / 9);
      case VideoAspectMode.ratio4x3:
        return containRect(viewport, 4 / 3);
    }
  }

  /// Letterbox [aspect] (width/height) inside [viewport].
  static Rect containRect(Size viewport, double aspect) {
    final view = viewport.width / viewport.height;
    if (view > aspect) {
      final width = viewport.height * aspect;
      return Rect.fromLTWH(
        (viewport.width - width) / 2,
        0,
        width,
        viewport.height,
      );
    }
    final height = viewport.width / aspect;
    return Rect.fromLTWH(
      0,
      (viewport.height - height) / 2,
      viewport.width,
      height,
    );
  }

  /// Crop [aspect] so it covers [viewport].
  static Rect coverRect(Size viewport, double aspect) {
    final view = viewport.width / viewport.height;
    if (view > aspect) {
      final height = viewport.width / aspect;
      return Rect.fromLTWH(
        0,
        (viewport.height - height) / 2,
        viewport.width,
        height,
      );
    }
    final width = viewport.height * aspect;
    return Rect.fromLTWH(
      (viewport.width - width) / 2,
      0,
      width,
      viewport.height,
    );
  }
}
