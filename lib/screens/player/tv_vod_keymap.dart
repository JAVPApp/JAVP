/// What OK / Select should do for TV VOD chrome.
enum TvVodSelectAction {
  /// Open the quick-access action bar.
  openQuickAccess,

  /// Let focusable quick-access buttons handle Select.
  deferToActions,
}

/// Big Picture rule: OK opens the menu; play/pause stays on media keys.
TvVodSelectAction tvVodSelectAction({required bool quickAccessOpen}) {
  return quickAccessOpen
      ? TvVodSelectAction.deferToActions
      : TvVodSelectAction.openQuickAccess;
}

/// What Back does over VOD playback. One level at a time so the route does
/// not pop to Home while the OK menu / a side panel is still open.
enum TvVodBackAction {
  closePanel,
  dismissUpNext,
  closeQuickAccess,
  hideChrome,
  leavePlayer,
}

TvVodBackAction tvVodBackAction({
  required bool panelOpen,
  required bool upNextVisible,
  required bool quickAccessOpen,
  required bool chromeVisible,
}) {
  if (panelOpen) return TvVodBackAction.closePanel;
  if (upNextVisible) return TvVodBackAction.dismissUpNext;
  // One Back dismisses the whole OSD (OK menu + seek bar). A second Back
  // leaves the player. Closing only the chips left the info bar up.
  if (quickAccessOpen || chromeVisible) return TvVodBackAction.hideChrome;
  return TvVodBackAction.leavePlayer;
}

/// Whether leaving the TV fullscreen player should keep the session playing
/// (mini player) instead of stopping.
///
/// Live Big Picture (`/tv/watch`): keep the channel going.
/// VOD (`/player`): stop — a movie under Catalog is awkward on a remote.
bool tvLeaveFullscreenKeepsSession({required bool isLive}) => isLive;

/// True when D-pad should move between OK-menu chips instead of seek / episodes.
bool tvVodMenuOwnsDpad({required bool quickAccessOpen}) => quickAccessOpen;
