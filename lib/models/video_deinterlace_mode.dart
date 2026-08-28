import 'package:javp/l10n/app_localizations.dart';

/// libmpv `--deinterlace` for interlaced live (1080i / 576i).
enum VideoDeinterlaceMode { auto, always, off }

extension VideoDeinterlaceModeX on VideoDeinterlaceMode {
  String get storageValue => name;

  /// Value for `mpv_set_property_string("deinterlace", …)`.
  String get mpvValue => switch (this) {
    VideoDeinterlaceMode.auto => 'auto',
    VideoDeinterlaceMode.always => 'yes',
    VideoDeinterlaceMode.off => 'no',
  };

  String localizedLabel(AppLocalizations l10n) => switch (this) {
    VideoDeinterlaceMode.auto => l10n.auto,
    VideoDeinterlaceMode.always => l10n.deinterlaceAlways,
    VideoDeinterlaceMode.off => l10n.off,
  };

  String localizedSubtitle(AppLocalizations l10n) => switch (this) {
    VideoDeinterlaceMode.auto => l10n.deinterlaceAutoSubtitle,
    VideoDeinterlaceMode.always => l10n.deinterlaceAlwaysSubtitle,
    VideoDeinterlaceMode.off => l10n.deinterlaceOffSubtitle,
  };

  static VideoDeinterlaceMode fromStorage(String? raw) {
    if (raw == null || raw.isEmpty) return VideoDeinterlaceMode.auto;
    return VideoDeinterlaceMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => VideoDeinterlaceMode.auto,
    );
  }
}
