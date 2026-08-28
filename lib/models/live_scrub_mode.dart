import 'package:javp/l10n/app_localizations.dart';

/// How the live player scrubber maps its 0…1 range.
enum LiveScrubMode {
  /// Rolling catchup window (`now - window` → live edge).
  timeline,

  /// Current EPG programme start → live edge (programme end once it finishes).
  program,
}

extension LiveScrubModeX on LiveScrubMode {
  String localizedLabel(AppLocalizations l10n) => switch (this) {
    LiveScrubMode.timeline => l10n.scrubModeTimeline,
    LiveScrubMode.program => l10n.scrubModeProgramme,
  };

  String localizedSubtitle(AppLocalizations l10n) => switch (this) {
    LiveScrubMode.timeline => l10n.rollingCatchupWindow,
    LiveScrubMode.program => l10n.currentEpgProgrammeLength,
  };

  String get label => switch (this) {
    LiveScrubMode.timeline => 'Timeline',
    LiveScrubMode.program => 'Programme',
  };

  String get storageValue => name;

  static LiveScrubMode fromStorage(
    String? raw, {
    LiveScrubMode fallback = LiveScrubMode.timeline,
  }) {
    if (raw == null || raw.isEmpty) return fallback;
    return LiveScrubMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => fallback,
    );
  }

  /// Unset preference: Programme on Android TV, Timeline on phone / desktop.
  static LiveScrubMode defaultFor({required bool androidTv}) =>
      androidTv ? LiveScrubMode.program : LiveScrubMode.timeline;
}
