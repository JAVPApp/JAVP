/// Native HLS DVR — seek inside a live playlist's sliding window.
///
/// Matches Clappr `HlsjsPlayback` (`hlsMinimumDvrSize`, live-edge tolerance):
/// a live `.m3u8` is DVR-capable when the playable region is long enough that
/// showing a seek bar is useful. Short live playlists (a few segments) stay
/// live-only. mpv/`force-seekable` maps oldest → 0 and live → [duration].
library;

import 'package:javp/services/playback/live_edge_seek.dart';

/// Clappr `hlsMinimumDvrSize` default (seconds).
const Duration kHlsMinimumDvrSize = Duration(seconds: 60);

/// HLS playlist URL (not a muxed `.ts` file).
bool looksLikeHlsPlaylistUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  if (path.endsWith('.ts') || path.endsWith('.m2ts') || path.endsWith('.mts')) {
    return false;
  }
  final lower = url.toLowerCase();
  return lower.contains('.m3u8') ||
      lower.contains('m3u8?') ||
      lower.contains('/m3u8');
}

/// Whether a live HLS mount should expose Clappr-style DVR seeking.
bool hlsNativeDvrEnabled({
  required bool isLive,
  required String playUrl,
  required Duration playableDuration,
}) {
  if (!isLive) return false;
  if (!looksLikeHlsPlaylistUrl(playUrl)) return false;
  return playableDuration >= kHlsMinimumDvrSize;
}

/// Clappr: assume live when [position] is within 3s of [duration].
bool hlsNativeDvrAtLiveEdge({
  required Duration position,
  required Duration duration,
}) {
  if (duration.inMilliseconds <= 0) return true;
  final behind = duration - position;
  return behind <= kLiveEdgeSeekMargin;
}

/// How far [position] sits behind the playlist live edge.
Duration hlsNativeDvrDelay({
  required Duration position,
  required Duration duration,
}) {
  final behind = duration - position;
  return behind.isNegative ? Duration.zero : behind;
}

/// 0 = oldest segment, 1 = live edge.
double hlsNativeDvrProgress({
  required Duration position,
  required Duration duration,
}) {
  final ms = duration.inMilliseconds;
  if (ms <= 0) return 1;
  return (position.inMilliseconds / ms).clamp(0.0, 1.0);
}

/// Whether [target] still sits inside the current playlist window.
bool hlsNativeDvrContains({
  required DateTime target,
  required DateTime now,
  required Duration window,
}) {
  if (window < kHlsMinimumDvrSize) return false;
  final behind = now.difference(target);
  if (behind.isNegative) return true;
  return behind <= window;
}

/// Wall-clock [target] → position in the 0…[window] playlist.
///
/// `null` means jump to live (within [kLiveEdgeSeekMargin] of now).
/// [Duration.zero] is the oldest available segment.
Duration? hlsNativeDvrSeekPosition({
  required DateTime target,
  required DateTime now,
  required Duration window,
}) {
  if (window.inMilliseconds <= 0) return null;
  final behind = now.difference(target);
  if (behind <= kLiveEdgeSeekMargin) return null;
  if (behind >= window) return Duration.zero;
  return window - behind;
}
