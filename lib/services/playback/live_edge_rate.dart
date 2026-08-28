/// Live HLS/DVR helpers for playback-rate catch-up.
///
/// Playing faster than realtime at the live edge exhausts the last published
/// segment, then media_kit/mpv buffers while waiting for the next one (often
/// surfaced as demuxer "end of segment" / live-edge underrun). Snapping back
/// to 1.0x resumes wall-clock realtime instead of stalling at >1x.
library;

/// True when [rate] should be forced back to realtime.
///
/// [atLiveEdge] means JAVP is on the live mount (not a timeshift/DVR clip).
/// Mid-DVR catch-up at 2x is intentional and must not snap.
bool shouldSnapPlaybackRateToRealtime({
  required bool atLiveEdge,
  required double rate,
}) {
  return atLiveEdge && rate > 1.01;
}

/// Rate to restore when ending a side hold-boost.
///
/// If PlaybackProvider already snapped to 1x at the live edge (or jump-to-live
/// did), do not re-apply a pre-hold catch-up [baseRate] above realtime.
double holdBoostRestoreRate({
  required bool atLiveEdge,
  required double baseRate,
}) {
  if (shouldSnapPlaybackRateToRealtime(
    atLiveEdge: atLiveEdge,
    rate: baseRate,
  )) {
    return 1.0;
  }
  return baseRate;
}

/// Whether desktop Space should arm temporary 2x instead of toggling immediately.
///
/// At the live edge, >1x only waits for the next published segment, so Space
/// stays an instant play/pause. Locked controls also skip the hold.
bool desktopSpaceHoldBoostEnabled({
  required bool locked,
  required bool atLiveEdge,
}) {
  return !locked && !atLiveEdge;
}
