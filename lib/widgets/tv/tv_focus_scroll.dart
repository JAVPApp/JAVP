import 'dart:ui' show clampDouble;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Typical gap between compact shelf posters ([ListView.separated] width).
const tvFocusScrollPeekGap = 10.0;

/// Max fraction of the viewport reserved so the next tile can peek in.
const tvFocusScrollPeekMaxViewportFraction = 0.35;

/// Extra pixels beyond the focused item so the next poster is already visible.
///
/// Flutter's default D-pad path uses [ScrollPositionAlignmentPolicy.keepVisibleAtEnd]
/// with alignment 1.0, which pins the focused tile to the trailing edge. The
/// next movie/series stays off-screen until you land on it. One-item peek
/// (capped so full-width rows cannot jump a whole page) matches 10-foot rows.
double tvFocusScrollPeek({
  required double itemExtent,
  required double viewportExtent,
  double gap = tvFocusScrollPeekGap,
}) {
  if (itemExtent <= 0 || viewportExtent <= 0) return 0;
  final oneItem = itemExtent + gap;
  final cap = viewportExtent * tvFocusScrollPeekMaxViewportFraction;
  if (oneItem <= cap) return oneItem;
  return cap;
}

/// Local paint rect expanded toward the trailing/leading edge so
/// [RenderAbstractViewport.getOffsetToReveal] leaves [peek] of room.
Rect tvPeekRevealRect(
  Rect bounds, {
  required Axis axis,
  required AxisDirection axisDirection,
  required ScrollPositionAlignmentPolicy alignmentPolicy,
  required double alignment,
  required double peek,
}) {
  if (peek <= 0) return bounds;
  final policy = tvEffectiveAlignmentPolicy(axisDirection, alignmentPolicy);
  final padEnd = switch (policy) {
    ScrollPositionAlignmentPolicy.keepVisibleAtEnd => true,
    ScrollPositionAlignmentPolicy.keepVisibleAtStart => false,
    ScrollPositionAlignmentPolicy.explicit => alignment >= 0.5,
  };
  // Reverse axes grow toward the local origin; "end" is left/top there.
  final endIsLeadingLocal =
      axisDirection == AxisDirection.left || axisDirection == AxisDirection.up;
  final padPositiveLocal = padEnd != endIsLeadingLocal;
  if (axis == Axis.horizontal) {
    return padPositiveLocal
        ? Rect.fromLTRB(
            bounds.left,
            bounds.top,
            bounds.right + peek,
            bounds.bottom,
          )
        : Rect.fromLTRB(
            bounds.left - peek,
            bounds.top,
            bounds.right,
            bounds.bottom,
          );
  }
  return padPositiveLocal
      ? Rect.fromLTRB(
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom + peek,
        )
      : Rect.fromLTRB(
          bounds.left,
          bounds.top - peek,
          bounds.right,
          bounds.bottom,
        );
}

/// Same start/end flip Flutter applies for reverse [AxisDirection]s.
ScrollPositionAlignmentPolicy tvEffectiveAlignmentPolicy(
  AxisDirection axisDirection,
  ScrollPositionAlignmentPolicy alignmentPolicy,
) {
  if (axisDirection != AxisDirection.up &&
      axisDirection != AxisDirection.left) {
    return alignmentPolicy;
  }
  return switch (alignmentPolicy) {
    ScrollPositionAlignmentPolicy.explicit => alignmentPolicy,
    ScrollPositionAlignmentPolicy.keepVisibleAtEnd =>
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ScrollPositionAlignmentPolicy.keepVisibleAtStart =>
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
  };
}

/// [ReadingOrderTraversalPolicy] that peeks the next horizontal tile.
FocusTraversalPolicy tvReadingOrderTraversalPolicy() =>
    ReadingOrderTraversalPolicy(
      requestFocusCallback: tvTraversalRequestFocusCallback,
    );

/// Drop-in for [FocusTraversalPolicy.requestFocusCallback].
void tvTraversalRequestFocusCallback(
  FocusNode node, {
  ScrollPositionAlignmentPolicy? alignmentPolicy,
  double? alignment,
  Duration? duration,
  Curve? curve,
}) {
  node.requestFocus();
  final ctx = node.context;
  if (ctx == null) return;
  tvEnsureVisibleWithPeek(
    ctx,
    alignmentPolicy: alignmentPolicy ?? ScrollPositionAlignmentPolicy.explicit,
    alignment: alignment ?? 1.0,
    duration: duration ?? Duration.zero,
    curve: curve ?? Curves.ease,
  );
}

/// Like [Scrollable.ensureVisible], but horizontal ancestors keep ~1 tile of
/// trailing/leading peek. Vertical ancestors keep Flutter's default policy so
/// Left/Right on a shelf does not yank the catalog down.
void tvEnsureVisibleWithPeek(
  BuildContext context, {
  ScrollPositionAlignmentPolicy alignmentPolicy =
      ScrollPositionAlignmentPolicy.explicit,
  double alignment = 1.0,
  Duration duration = Duration.zero,
  Curve curve = Curves.ease,
}) {
  RenderObject? targetRenderObject;
  var current = context;
  var scrollable = Scrollable.maybeOf(current);
  while (scrollable != null) {
    final object = current.findRenderObject();
    if (object != null && object.attached) {
      if (scrollable.position.axis == Axis.horizontal) {
        _ensureHorizontalVisibleWithPeek(
          scrollable.position,
          object,
          alignmentPolicy: alignmentPolicy,
          alignment: alignment,
          duration: duration,
          curve: curve,
        );
      } else {
        scrollable.position.ensureVisible(
          object,
          alignment: alignment,
          alignmentPolicy: alignmentPolicy,
          duration: duration,
          curve: curve,
          targetRenderObject: targetRenderObject,
        );
      }
    }
    targetRenderObject ??= object;
    current = scrollable.context;
    scrollable = Scrollable.maybeOf(current);
  }
}

void _ensureHorizontalVisibleWithPeek(
  ScrollPosition position,
  RenderObject object, {
  required ScrollPositionAlignmentPolicy alignmentPolicy,
  required double alignment,
  required Duration duration,
  required Curve curve,
}) {
  final viewport = RenderAbstractViewport.maybeOf(object);
  if (viewport == null) return;

  final peek = tvFocusScrollPeek(
    itemExtent: object.paintBounds.width,
    viewportExtent: position.viewportDimension,
  );
  final rect = tvPeekRevealRect(
    object.paintBounds,
    axis: Axis.horizontal,
    axisDirection: position.axisDirection,
    alignmentPolicy: alignmentPolicy,
    alignment: alignment,
    peek: peek,
  );
  final policy = tvEffectiveAlignmentPolicy(
    position.axisDirection,
    alignmentPolicy,
  );

  double target;
  switch (policy) {
    case ScrollPositionAlignmentPolicy.explicit:
      target = viewport
          .getOffsetToReveal(
            object,
            alignment,
            rect: rect,
            axis: Axis.horizontal,
          )
          .offset;
      target = clampDouble(
        target,
        position.minScrollExtent,
        position.maxScrollExtent,
      );
    case ScrollPositionAlignmentPolicy.keepVisibleAtEnd:
      target = viewport
          .getOffsetToReveal(object, 1.0, rect: rect, axis: Axis.horizontal)
          .offset;
      target = clampDouble(
        target,
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target < position.pixels) target = position.pixels;
    case ScrollPositionAlignmentPolicy.keepVisibleAtStart:
      target = viewport
          .getOffsetToReveal(object, 0.0, rect: rect, axis: Axis.horizontal)
          .offset;
      target = clampDouble(
        target,
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target > position.pixels) target = position.pixels;
  }

  if (target == position.pixels) return;
  if (duration == Duration.zero) {
    position.jumpTo(target);
    return;
  }
  position.animateTo(target, duration: duration, curve: curve);
}

/// Jump a vertical TV list back to offset 0 after focus [ensureVisible].
///
/// The first focusable sits below a non-focusable header (rail “JAVP”, Home
/// blurb, source instructions). Default alignment pins that control to the
/// top of the viewport; Up then has nowhere to go. Repeat next frames so we
/// win the [FocusableActionDetector] ensureVisible race.
void tvRevealScrollTop(ScrollController scroll) {
  void jump() {
    if (!scroll.hasClients) return;
    scroll.jumpTo(0);
  }

  jump();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    jump();
    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
  });
}
