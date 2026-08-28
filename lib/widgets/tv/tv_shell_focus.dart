import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Horizontal gap (no overlap) still treated as "next to" a shelf header action.
const tvHeaderActionMaxHorizontalGap = 200.0;

/// How far below a header action a poster may sit and still reach it with Up.
const tvHeaderActionMaxBelowGap = 280.0;

/// Max |center.dy| delta for sibling header actions (Favorite ↔ See all).
const tvHeaderActionMaxSameBandCenterDy = 40.0;

/// Whether a shelf header action (Favorite / See all) should join D-pad
/// traversal from the widget currently focused at [from].
///
/// Those controls sit between poster rows. Flutter's directional policy then
/// prefers them over the next row whenever nothing overlaps horizontally.
/// Keep them off the path unless [from] is in the same band (sibling actions),
/// just below (Up from a nearby / last poster), or this action is the only
/// way Down (next shelf still loading / not built).
bool tvHeaderActionAcceptsFocusFrom(
  Rect from,
  Rect self, {
  bool hasContentBelow = true,
  bool hasNeighborToTheRight = true,
}) {
  final hOverlap =
      math.min(from.right, self.right) - math.max(from.left, self.left);
  final hGap = hOverlap >= 0
      ? 0.0
      : math.max(from.left, self.left) - math.min(from.right, self.right);
  final selfBelow = self.center.dy > from.center.dy;

  if (hGap > tvHeaderActionMaxHorizontalGap && hasNeighborToTheRight) {
    // Far from this control, and the row still continues — skip, unless
    // nothing else exists below (loading / unbuilt shelf).
    return !hasContentBelow && selfBelow;
  }

  if ((from.center.dy - self.center.dy).abs() <=
      tvHeaderActionMaxSameBandCenterDy) {
    return true;
  }

  final vOverlap =
      math.min(from.bottom, self.bottom) - math.max(from.top, self.top);
  final vGap = vOverlap >= 0
      ? 0.0
      : math.max(from.top, self.top) - math.min(from.bottom, self.bottom);

  final fromBelow = from.center.dy > self.center.dy;
  if (fromBelow && vGap <= tvHeaderActionMaxBelowGap) return true;

  return !hasContentBelow && selfBelow;
}

/// Walk nested [FocusScopeNode]s to the leaf that should receive D-pad focus.
///
/// The TV content pane hosts a Navigator [FocusScope]. Requesting focus on
/// that scope shows no ring, so the next Right looks like it is required to
/// reach Watch live / a poster. Return null when only scopes remain so the
/// shell can pick a real control instead.
FocusNode? tvLeafContentFocus(FocusNode? node) {
  var current = node;
  while (current is FocusScopeNode) {
    final child = current.focusedChild;
    if (child == null || identical(child, current)) return null;
    current = child;
  }
  if (current == null) return null;
  if (!current.canRequestFocus || current.skipTraversal) return null;
  return current;
}
