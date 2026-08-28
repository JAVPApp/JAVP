/// What ← / → do over fullscreen live playback.
///
/// Big Picture layering: ← opens the channel overlay (one more ← steps into
/// categories), → opens the same overlay on recently watched. Multi-view keeps
/// the arrows for pane focus, and while the OK quick-access bar is focused the
/// arrows belong to its buttons.
enum TvLiveDpadAction {
  openChannels,
  openRecents,
  transportFocus,
  focusPrimaryPane,
  focusSecondaryPane,
}

TvLiveDpadAction tvLiveHorizontalAction({
  required bool towardsLeft,
  required bool multiViewActive,
  required bool transportFocused,
}) {
  if (multiViewActive) {
    return towardsLeft
        ? TvLiveDpadAction.focusPrimaryPane
        : TvLiveDpadAction.focusSecondaryPane;
  }
  if (transportFocused) return TvLiveDpadAction.transportFocus;
  return towardsLeft
      ? TvLiveDpadAction.openChannels
      : TvLiveDpadAction.openRecents;
}

/// What Back does over live playback. One level at a time: nested settings,
/// then a side overlay, then the info / OK chrome, then multi-view, then leave.
enum TvLiveBackAction {
  popSettingsPage,
  closeOverlay,
  hideChrome,
  exitMultiView,
  leaveWatch,
}

TvLiveBackAction tvLiveBackAction({
  required bool overlayOpen,
  required bool chromeVisible,
  required bool settingsNested,
  required bool multiViewActive,
}) {
  if (overlayOpen && settingsNested) return TvLiveBackAction.popSettingsPage;
  if (overlayOpen) return TvLiveBackAction.closeOverlay;
  if (chromeVisible) return TvLiveBackAction.hideChrome;
  if (multiViewActive) return TvLiveBackAction.exitMultiView;
  return TvLiveBackAction.leaveWatch;
}

/// Info OSD is up: the OK transport menu, or the zap / program bar.
bool tvLiveChromeIsVisible({
  required bool overlayIsInfo,
  required bool infoActionsOpen,
}) => overlayIsInfo || infoActionsOpen;

/// First OK-menu target: Play on the transport row. The DVR playhead stays
/// above and is reached with Up.
bool tvLiveInfoMenuFocusPlayhead({required bool canLiveDvr}) {
  // [canLiveDvr] only means a playhead exists above transport, not first focus.
  return canLiveDvr && false;
}

/// True when D-pad should move between OK-menu chips instead of zap / layers.
///
/// Channel± hardware keys still zap; G / M / P stay keyboard extras.
bool tvLiveMenuOwnsDpad({
  required bool infoActionsOpen,
  required bool panelOpen,
}) => infoActionsOpen && !panelOpen;

/// Pause before retuning after CH± / ↑↓ so the info bar can show the next
/// channel while the current stream keeps playing. Further presses reset this.
const tvLiveZapDebounce = Duration(milliseconds: 500);

/// How long the OK transport menu stays up with no remote input.
const tvLiveInfoMenuIdleHide = Duration(seconds: 8);

/// Zap / program bar with no OK menu — shorter than [tvLiveInfoMenuIdleHide].
const tvLiveInfoFlashHide = Duration(seconds: 5);

/// What CH± / ↑↓ do over fullscreen live playback.
///
/// First press with chrome hidden reveals the player bar. The next press
/// (or a hold that started while chrome was already up) zaps.
enum TvLiveVerticalZapAction { revealChrome, zap }

TvLiveVerticalZapAction tvLiveVerticalZapAction({
  required bool chromeVisible,
}) => chromeVisible
    ? TvLiveVerticalZapAction.zap
    : TvLiveVerticalZapAction.revealChrome;
