/// Live HLS/DVR helpers for joining the sliding-window edge.
///
/// With `force-seekable`, many live feeds expose a rewind window that opens at
/// segment 0 (oldest). Jump-to-live must seek near [duration] instead.
/// Clappr uses the same 3s live-edge tolerance (`duration - 3`).
library;

/// Margin before the reported end so we do not undershoot into underrun.
const Duration kLiveEdgeSeekMargin = Duration(seconds: 3);

/// Seek target near the live edge of a seekable live window.
///
/// Returns `null` when [duration] is unknown or too short to need a seek
/// (true live with no meaningful rewind window).
Duration? liveEdgeSeekTarget(Duration duration) {
  if (duration.inMilliseconds <= 0) return null;
  if (duration <= kLiveEdgeSeekMargin) return null;
  return duration - kLiveEdgeSeekMargin;
}
