/// Stable media_kit video-plane size so HLS quality switches do not rebuild
/// the Flutter texture.
library;

import 'package:javp/services/playback/android_tv_video_surface.dart';

/// Largest coded size in [sizes], even dimensions.
///
/// Rows with only height (no width) are treated as 16:9.
({int width, int height})? largestVideoSize(
  Iterable<({int? width, int? height})> sizes,
) {
  ({int width, int height})? best;
  var bestPixels = 0;
  var maxHeight = 0;
  for (final size in sizes) {
    final w = size.width ?? 0;
    final h = size.height ?? 0;
    if (h > maxHeight) maxHeight = h;
    if (w <= 0 || h <= 0) continue;
    final pixels = w * h;
    if (pixels > bestPixels) {
      bestPixels = pixels;
      best = (width: w, height: h);
    }
  }
  if (best != null) return _evenSize(best.width, best.height);
  if (maxHeight <= 0) return null;
  final width = _evenAtLeast2(((maxHeight * 16) / 9).round());
  return (width: width, height: _evenAtLeast2(maxHeight));
}

/// Texture size that never shrinks mid-session.
///
/// media_kit [VideoOutput] unregisters the Flutter texture when
/// `video-out-params` changes. Pinning the plane (and refusing to shrink
/// on a 1080→360 HLS pick) keeps mpv scaling into the same surface.
({int width, int height})? pinVideoOutputSize({
  int? pinnedWidth,
  int? pinnedHeight,
  int? incomingWidth,
  int? incomingHeight,
  bool capTo1080p = false,
}) {
  var incoming = _validSize(incomingWidth, incomingHeight);
  if (incoming != null && capTo1080p) {
    incoming =
        capAndroidTvVideoSurface(incoming.width, incoming.height) ?? incoming;
  }
  final pinned = _validSize(pinnedWidth, pinnedHeight);
  if (incoming == null) return pinned;
  incoming = _evenSize(incoming.width, incoming.height);
  if (pinned == null) return incoming;
  if (incoming.width <= pinned.width && incoming.height <= pinned.height) {
    return pinned;
  }
  return incoming;
}

({int width, int height})? _validSize(int? width, int? height) {
  if (width == null || height == null) return null;
  if (width <= 0 || height <= 0) return null;
  return (width: width, height: height);
}

({int width, int height}) _evenSize(int width, int height) {
  return (width: _evenAtLeast2(width), height: _evenAtLeast2(height));
}

int _evenAtLeast2(int value) {
  if (value < 2) return 2;
  return value & ~1;
}
