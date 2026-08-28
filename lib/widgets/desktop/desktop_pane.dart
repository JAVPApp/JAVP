import 'package:flutter/material.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';

/// Caps how wide a reading surface gets on desktop and tablet rail layouts.
///
/// Shelves want the whole width — more posters is more content. Lists, forms
/// and settings do not: a row whose label sits at x=0 and whose chevron sits
/// 1100px away reads as a phone layout someone stretched. Those surfaces get a
/// centred column instead.
class DesktopPane extends StatelessWidget {
  const DesktopPane({
    super.key,
    required this.child,
    this.maxWidth = AppLayout.paneMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!AdaptiveLayout.useRail(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
