/// Whether the player loading overlay should paint.
///
/// Minimize / texture reparent can miss `buffering=false`. Once the engine is
/// playing without buffering, drop the overlay even if [awaitingInitialPlayback]
/// stuck — otherwise the spinner sits on after playback has started.
///
/// Pause must not show the badge: libmpv `paused-for-cache` and video_player
/// `isBuffering` often go true while idle, which used to paint "Loading…".
bool playerLoadingOverlayVisible({
  required bool hasError,
  required bool opening,
  required bool retuning,
  required bool resolvingTorrent,
  required bool awaitingInitialPlayback,
  required bool dvrBusy,
  required bool seekBusy,
  required bool engineBuffering,
  required bool enginePlaying,
}) {
  if (hasError) return false;
  if (opening || retuning || resolvingTorrent || dvrBusy || seekBusy) {
    return true;
  }
  if (!enginePlaying) {
    return awaitingInitialPlayback;
  }
  return engineBuffering;
}
