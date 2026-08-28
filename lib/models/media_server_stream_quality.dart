import 'package:javp/l10n/app_localizations.dart';

/// Preferred max bitrate / resolution for Jellyfin, Emby, and Plex streams.
enum MediaServerStreamQuality {
  /// Direct play / original file (no server transcode).
  original,
  /// ~20 Mbps, 1080p.
  high,
  /// ~8 Mbps, 720p.
  medium,
  /// ~3 Mbps, 480p.
  low,
  /// ~1.5 Mbps, 360p.
  dataSaver,
}

extension MediaServerStreamQualityX on MediaServerStreamQuality {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        MediaServerStreamQuality.original => l10n.qualityOriginal,
        MediaServerStreamQuality.high => l10n.qualityHigh1080,
        MediaServerStreamQuality.medium => l10n.qualityMedium720,
        MediaServerStreamQuality.low => l10n.qualityLow480,
        MediaServerStreamQuality.dataSaver => l10n.qualityDataSaver360,
      };

  String localizedSubtitle(AppLocalizations l10n) => switch (this) {
        MediaServerStreamQuality.original => l10n.qualityOriginalSubtitle,
        MediaServerStreamQuality.high => '~20 Mbps',
        MediaServerStreamQuality.medium => '~8 Mbps',
        MediaServerStreamQuality.low => '~3 Mbps',
        MediaServerStreamQuality.dataSaver => '~1.5 Mbps',
      };

  String get label => switch (this) {
        MediaServerStreamQuality.original => 'Original',
        MediaServerStreamQuality.high => 'High (1080p)',
        MediaServerStreamQuality.medium => 'Medium (720p)',
        MediaServerStreamQuality.low => 'Low (480p)',
        MediaServerStreamQuality.dataSaver => 'Data saver (360p)',
      };

  String get subtitle => switch (this) {
        MediaServerStreamQuality.original =>
          'Direct play when possible — best quality, more bandwidth',
        MediaServerStreamQuality.high => '~20 Mbps',
        MediaServerStreamQuality.medium => '~8 Mbps',
        MediaServerStreamQuality.low => '~3 Mbps',
        MediaServerStreamQuality.dataSaver => '~1.5 Mbps',
      };

  /// Max video bitrate in kbps, or null for original/direct.
  int? get maxBitrateKbps => switch (this) {
        MediaServerStreamQuality.original => null,
        MediaServerStreamQuality.high => 20000,
        MediaServerStreamQuality.medium => 8000,
        MediaServerStreamQuality.low => 3000,
        MediaServerStreamQuality.dataSaver => 1500,
      };

  /// Plex `videoResolution` query value.
  String? get plexVideoResolution => switch (this) {
        MediaServerStreamQuality.original => null,
        MediaServerStreamQuality.high => '1920x1080',
        MediaServerStreamQuality.medium => '1280x720',
        MediaServerStreamQuality.low => '854x480',
        MediaServerStreamQuality.dataSaver => '640x360',
      };

  /// Next lower transcoder preset, or null when already at [dataSaver].
  MediaServerStreamQuality? get lowerQuality {
    final values = MediaServerStreamQuality.values;
    final i = values.indexOf(this);
    if (i < 0 || i >= values.length - 1) return null;
    return values[i + 1];
  }

  static MediaServerStreamQuality fromName(String? name) {
    if (name == null || name.isEmpty) {
      return MediaServerStreamQuality.original;
    }
    return MediaServerStreamQuality.values.asNameMap()[name] ??
        MediaServerStreamQuality.original;
  }
}
