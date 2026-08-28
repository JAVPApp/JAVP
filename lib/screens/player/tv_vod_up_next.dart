// Pure helpers for the TV VOD “Up next” end-of-episode card.

const tvVodUpNextNearEndWindow = Duration(seconds: 25);
const tvVodUpNextCountdownSeconds = 15;

/// Whether the couch Up-next card should appear over the playing episode.
bool tvVodShouldShowUpNext({
  required bool dismissed,
  required bool isEpisode,
  required bool hasNextEpisode,
  required bool creditsActive,
  required Duration position,
  required Duration duration,
  Duration nearEndWindow = tvVodUpNextNearEndWindow,
}) {
  if (dismissed || !isEpisode || !hasNextEpisode) return false;
  if (creditsActive) return true;
  if (duration <= Duration.zero) return false;
  final remaining = duration - position;
  return remaining > Duration.zero && remaining <= nearEndWindow;
}
