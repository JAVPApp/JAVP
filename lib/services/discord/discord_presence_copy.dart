import 'package:flutter/widgets.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/providers/locale_controller.dart';

/// Localized copy for Discord Rich Presence status lines.
///
/// Kept free of Flutter widgets so the mapper stays unit-testable. The service
/// builds this from [AppLocalizations] for the user's effective UI locale.
class DiscordPresenceCopy {
  const DiscordPresenceCopy({
    required this.browsingDetails,
    required this.browsingState,
    required this.playing,
    required this.paused,
    required this.live,
    required this.livePaused,
    required this.catchup,
    required this.catchupPaused,
    required this.liveTvFallback,
    required this.privateWatching,
    required this.privateListening,
    required this.privateLiveTv,
    required this.episodeWithStatus,
    required this.episodeWithTitleStatus,
  });

  /// English fallback used by unit tests and before locale is ready.
  static const english = DiscordPresenceCopy(
    browsingDetails: 'Browsing library',
    browsingState: 'JAVP',
    playing: 'Playing',
    paused: 'Paused',
    live: 'Live',
    livePaused: 'Live · Paused',
    catchup: 'Catch-up',
    catchupPaused: 'Catch-up · Paused',
    liveTvFallback: 'Live TV',
    privateWatching: 'Watching something',
    privateListening: 'Listening to something',
    privateLiveTv: 'Watching live TV',
    episodeWithStatus: _englishEpisodeStatus,
    episodeWithTitleStatus: _englishEpisodeTitleStatus,
  );

  final String browsingDetails;

  /// Brand name under browsing details (not localized).
  final String browsingState;
  final String playing;
  final String paused;
  final String live;
  final String livePaused;
  final String catchup;
  final String catchupPaused;
  final String liveTvFallback;
  final String privateWatching;
  final String privateListening;
  final String privateLiveTv;
  final String Function(String code, String status) episodeWithStatus;
  final String Function(String code, String title, String status)
  episodeWithTitleStatus;

  factory DiscordPresenceCopy.fromL10n(AppLocalizations l10n) {
    return DiscordPresenceCopy(
      browsingDetails: l10n.discordPresenceBrowsing,
      browsingState: 'JAVP',
      playing: l10n.discordPresencePlaying,
      paused: l10n.discordPresencePaused,
      live: l10n.discordPresenceLive,
      livePaused: l10n.discordPresenceLivePaused,
      catchup: l10n.discordPresenceCatchup,
      catchupPaused: l10n.discordPresenceCatchupPaused,
      liveTvFallback: l10n.discordPresenceLiveTvFallback,
      privateWatching: l10n.discordPresencePrivateWatching,
      privateListening: l10n.discordPresencePrivateListening,
      privateLiveTv: l10n.discordPresencePrivateLiveTv,
      episodeWithStatus: l10n.discordPresenceEpisodeStatus,
      episodeWithTitleStatus: l10n.discordPresenceEpisodeTitleStatus,
    );
  }

  /// Resolve copy for [languageCode], falling back to English when unsupported.
  factory DiscordPresenceCopy.forLanguageCode(String languageCode) {
    final locale = LocaleController.supportedLocales.firstWhere(
      (l) => l.languageCode == languageCode,
      orElse: () => const Locale('en'),
    );
    return DiscordPresenceCopy.fromL10n(lookupAppLocalizations(locale));
  }

  static String _englishEpisodeStatus(String code, String status) =>
      '$code · $status';

  static String _englishEpisodeTitleStatus(
    String code,
    String title,
    String status,
  ) => '$code · $title · $status';
}
