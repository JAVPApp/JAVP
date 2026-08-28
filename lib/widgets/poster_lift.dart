import 'package:flutter/material.dart';
import 'package:javp/theme/app_tokens.dart';

/// Overlay child that grows a poster from its own center.
///
/// [OverlayPortal] lays its overlay child out with tight full-screen
/// constraints. A bare [SizedBox] / [AnimatedScale] then expands to the
/// screen, so the card zooms from the overlay center and looks huge.
/// [OverflowBox] keeps the scaled widget at the captured tile size so
/// [CompositedTransformFollower] can pin it to the real poster.
class PosterLiftFollower extends StatelessWidget {
  const PosterLiftFollower({
    super.key,
    required this.link,
    required this.size,
    required this.scale,
    required this.child,
  });

  final LayerLink link;
  final Size size;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: size.width,
        maxWidth: size.width,
        minHeight: size.height,
        maxHeight: size.height,
        child: AnimatedScale(
          scale: scale,
          alignment: Alignment.center,
          duration: AppMotion.of(context, AppMotion.normal),
          curve: AppMotion.ease,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Poster + title as one card: surface fill, clipped corners, padded meta so
/// long titles marquee inside the card instead of overflowing the shelf.
class PosterCardShell extends StatelessWidget {
  const PosterCardShell({
    super.key,
    required this.poster,
    required this.meta,
    this.radius = 12,
    this.expandPoster = false,
  });

  final Widget poster;
  final Widget meta;
  final double radius;
  final bool expandPoster;

  @override
  Widget build(BuildContext context) {
    final posterChild = ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      child: poster,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: AppColors.surfaceHigh,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: expandPoster ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (expandPoster) Expanded(child: posterChild) else posterChild,
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: meta,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
