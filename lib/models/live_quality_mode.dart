import 'package:javp/l10n/app_localizations.dart';

/// Global rule for picking a live SD/HD/4K variant when opening a channel.
enum LiveQualityMode {
  /// Best available via [ChannelQuality.compareVariants] (UHD when the
  /// display is 4K-capable, else FHD → HD → SD). Catchup/DVR uses a
  /// family sibling when needed. Default — no first-tune prompt.
  auto,

  /// Prompt once per channel family until the user picks (or cancels to Auto).
  ask,
}

extension LiveQualityModeX on LiveQualityMode {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
        LiveQualityMode.auto => l10n.liveQualityAuto,
        LiveQualityMode.ask => l10n.liveQualityAsk,
      };

  String localizedSubtitle(AppLocalizations l10n) => switch (this) {
        LiveQualityMode.auto => l10n.liveQualityAutoSubtitle,
        LiveQualityMode.ask => l10n.liveQualityAskSubtitle,
      };

  String get storageValue => name;

  static LiveQualityMode fromStorage(String? raw) {
    return LiveQualityMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => LiveQualityMode.auto,
    );
  }
}
