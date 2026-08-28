/// Fire TV / Android TV Flutter texture budget for media_kit.
///
/// media_kit on Android ignores [VideoControllerConfiguration.width]/[height]
/// and sizes the OpenGL surface to the coded frame. A 4K VOD plane composited
/// through Flutter Skia saturates cheap sticks (AFTKM and similar). Cap the
/// output to 1080p while keeping the source aspect so letterboxing stays in
/// the [Video] widget, not inside the texture.
library;

/// Largest Flutter video plane we will composite on the TV shell.
const androidTvVideoSurfaceMaxWidth = 1920;
const androidTvVideoSurfaceMaxHeight = 1080;

/// Even [width]×[height] that fits in the 1080p budget, or `null` when the
/// coded size is already within budget (or unknown).
({int width, int height})? capAndroidTvVideoSurface(int width, int height) {
  if (width <= 0 || height <= 0) return null;
  if (width <= androidTvVideoSurfaceMaxWidth &&
      height <= androidTvVideoSurfaceMaxHeight) {
    return null;
  }
  final scaleW = androidTvVideoSurfaceMaxWidth / width;
  final scaleH = androidTvVideoSurfaceMaxHeight / height;
  final scale = scaleW < scaleH ? scaleW : scaleH;
  final outW = _evenAtLeast2((width * scale).round());
  final outH = _evenAtLeast2((height * scale).round());
  if (outW >= width && outH >= height) return null;
  return (width: outW, height: outH);
}

int _evenAtLeast2(int value) {
  if (value < 2) return 2;
  return value & ~1;
}
