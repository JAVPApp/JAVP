import 'package:flutter/painting.dart';

/// Screen corner for the Android TV overlay mini player.
enum TvMiniPlayerCorner { bottomRight, bottomLeft, topRight, topLeft }

/// Default parking order: bottom-right first, then flip horizontally, then up.
const kTvMiniPlayerCornerOrder = [
  TvMiniPlayerCorner.bottomRight,
  TvMiniPlayerCorner.bottomLeft,
  TvMiniPlayerCorner.topRight,
  TvMiniPlayerCorner.topLeft,
];

Alignment tvMiniPlayerAlignment(TvMiniPlayerCorner corner) => switch (corner) {
  TvMiniPlayerCorner.bottomRight => Alignment.bottomRight,
  TvMiniPlayerCorner.bottomLeft => Alignment.bottomLeft,
  TvMiniPlayerCorner.topRight => Alignment.topRight,
  TvMiniPlayerCorner.topLeft => Alignment.topLeft,
};

Rect tvMiniPlayerRectForCorner({
  required TvMiniPlayerCorner corner,
  required Size screen,
  required Size pip,
  required double inset,
}) {
  final left = inset;
  final top = inset;
  final right = screen.width - inset - pip.width;
  final bottom = screen.height - inset - pip.height;
  final origin = switch (corner) {
    TvMiniPlayerCorner.bottomRight => Offset(right, bottom),
    TvMiniPlayerCorner.bottomLeft => Offset(left, bottom),
    TvMiniPlayerCorner.topRight => Offset(right, top),
    TvMiniPlayerCorner.topLeft => Offset(left, top),
  };
  return origin & pip;
}

double tvMiniPlayerOverlapArea(Rect a, Rect b) {
  final hit = a.intersect(b);
  if (hit.isEmpty) return 0;
  return hit.width * hit.height;
}

/// Corner that does not cover [focus], preferring [kTvMiniPlayerCornerOrder].
///
/// [focus] should already include any focus-ring padding. Huge page-level
/// focus (more than [maxFocusScreenFraction] of the screen) is ignored so a
/// FocusScope does not pin the pip to a random corner.
TvMiniPlayerCorner tvMiniPlayerCornerForFocus({
  required Rect focus,
  required Size screen,
  required Size pip,
  required double inset,
  double maxFocusScreenFraction = 0.4,
  double minOverlap = 1,
}) {
  final screenArea = screen.width * screen.height;
  if (screenArea <= 0 || pip.isEmpty) {
    return TvMiniPlayerCorner.bottomRight;
  }
  if (focus.width * focus.height > screenArea * maxFocusScreenFraction) {
    return TvMiniPlayerCorner.bottomRight;
  }

  TvMiniPlayerCorner? firstClear;
  var best = TvMiniPlayerCorner.bottomRight;
  var bestOverlap = double.infinity;
  for (final corner in kTvMiniPlayerCornerOrder) {
    final pipRect = tvMiniPlayerRectForCorner(
      corner: corner,
      screen: screen,
      pip: pip,
      inset: inset,
    );
    final overlap = tvMiniPlayerOverlapArea(pipRect, focus);
    if (overlap < minOverlap) {
      firstClear ??= corner;
    }
    if (overlap < bestOverlap) {
      bestOverlap = overlap;
      best = corner;
    }
  }
  return firstClear ?? best;
}
