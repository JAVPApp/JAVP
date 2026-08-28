import 'package:flutter/material.dart';
import 'package:javp/theme/app_tokens.dart';

/// Presents [child] as a popover next to where the user clicked.
///
/// A bottom sheet is the right answer for a thumb and the wrong one for a
/// mouse: the pointer is already at the item, so the menu belongs there rather
/// than 600px away at the bottom edge of a wide window. Content is shared with
/// the touch sheet so the two can't drift apart.
Future<T?> showAnchoredMenuSurface<T>({
  required BuildContext context,
  required Offset globalPosition,
  required WidgetBuilder builder,
  double width = 320,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black26,
    builder: (dialogContext) => _AnchoredSurface(
      anchor: globalPosition,
      width: width,
      child: Builder(builder: builder),
    ),
  );
}

class _AnchoredSurface extends StatelessWidget {
  const _AnchoredSurface({
    required this.anchor,
    required this.width,
    required this.child,
  });

  final Offset anchor;
  final double width;
  final Widget child;

  /// Keeps the popover clear of the window edges.
  static const _margin = 12.0;

  @override
  Widget build(BuildContext context) {
    final view = MediaQuery.sizeOf(context);
    final maxHeight = view.height - _margin * 2;
    final panelWidth = width.clamp(240.0, view.width - _margin * 2);

    // Flip to the other side of the pointer when there is no room after it.
    final left = anchor.dx + panelWidth + _margin > view.width
        ? (anchor.dx - panelWidth).clamp(_margin, view.width - panelWidth - _margin)
        : anchor.dx.clamp(_margin, view.width - panelWidth - _margin);

    return Stack(
      children: [
        Positioned(
          left: left,
          top: _margin,
          bottom: _margin,
          width: panelWidth,
          child: Align(
            // Sit near the click vertically without ever leaving the window.
            alignment: Alignment(
              0,
              ((anchor.dy / view.height) * 2 - 1).clamp(-1.0, 1.0),
            ),
            child: Material(
              color: AppColors.surface,
              elevation: 12,
              borderRadius: AppRadius.lgAll,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SingleChildScrollView(child: child),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
