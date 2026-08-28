import 'package:javp/l10n/app_localizations.dart';

/// Pages shared by phone [PlayerSettingsPanel] and TV [TvPlayerSettingsOverlay].
///
/// The two shells stay separate (touch sheet vs D-pad overlay). This enum is
/// the model so a new row is not added in only one chrome.
enum PlayerSettingsPage {
  root,
  audio,
  subs,
  video,
  quality,
  msQuality,
  versions,
  speed,
  sleep,
  scrub,
  boost,
  aspect,
  deinterlace,
}

/// Title for a settings page. TV uses shorter audio / scrub labels.
String playerSettingsPageTitle(
  PlayerSettingsPage page,
  AppLocalizations l10n, {
  bool tv = false,
}) {
  return switch (page) {
    PlayerSettingsPage.root => l10n.navSettings,
    PlayerSettingsPage.audio => tv ? l10n.audio : l10n.audioTrack,
    PlayerSettingsPage.subs => l10n.subtitles,
    PlayerSettingsPage.video => l10n.adaptiveQuality,
    PlayerSettingsPage.quality ||
    PlayerSettingsPage.msQuality => l10n.streamQuality,
    PlayerSettingsPage.versions => l10n.version,
    PlayerSettingsPage.speed => l10n.playbackSpeed,
    PlayerSettingsPage.sleep => l10n.sleepTimer,
    PlayerSettingsPage.scrub => tv ? l10n.liveScrubber : l10n.scrubber,
    PlayerSettingsPage.boost => l10n.volumeBoost,
    PlayerSettingsPage.aspect => l10n.videoAspect,
    PlayerSettingsPage.deinterlace => l10n.deinterlace,
  };
}

/// Adaptive video-track row. [compact] matches the older TV list (`720p · kbps`).
String playerVideoTrackLabel({
  required String id,
  required String autoLabel,
  required String offLabel,
  required String Function(String id) trackNumber,
  int? height,
  int? bitrate,
  String? title,
  bool compact = false,
}) {
  if (id == 'auto') return autoLabel;
  if (id == 'no') return offLabel;
  final trimmed = title?.trim();
  String? res;
  if (height != null && height > 0) {
    if (!compact && height >= 2160) {
      res = '4K';
    } else if (!compact && height >= 1440) {
      res = '1440p';
    } else if (!compact && height >= 1080) {
      res = '1080p';
    } else if (!compact && height >= 720) {
      res = '720p';
    } else {
      res = '${height}p';
    }
  }
  final br = (bitrate != null && bitrate > 0)
      ? '${(bitrate / 1000).round()} kbps'
      : null;
  final parts = <String>[
    if (res != null) res,
    if (trimmed != null && trimmed.isNotEmpty && trimmed != res) trimmed,
    if (br != null) br,
  ];
  if (parts.isEmpty) return trackNumber(id);
  return parts.join(' · ');
}
