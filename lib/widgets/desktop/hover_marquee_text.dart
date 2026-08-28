import 'package:flutter/material.dart';
import 'package:javp/widgets/desktop/desktop_hover_tile.dart';

/// Single-line title that ellipsizes at rest and marquees when the pointer
/// hovers a [DesktopHoverTile] and the text does not fit.
class HoverMarqueeText extends StatelessWidget {
  const HoverMarqueeText({
    super.key,
    required this.text,
    this.style,
    this.maxLines = 1,
  });

  final String text;
  final TextStyle? style;

  /// Lines used while idle (ellipsis). Hover always marquees on one line.
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final hovered = DesktopHoverScope.hoveredOf(context);
    final resolved = style ?? DefaultTextStyle.of(context).style;
    if (!hovered) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: resolved,
      );
    }
    return _HoverMarquee(text: text, style: resolved);
  }
}

class _HoverMarquee extends StatefulWidget {
  const _HoverMarquee({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_HoverMarquee> createState() => _HoverMarqueeState();
}

class _HoverMarqueeState extends State<_HoverMarquee>
    with SingleTickerProviderStateMixin {
  static const _pixelsPerSecond = 36.0;
  static const _endGap = 32.0;

  late final AnimationController _controller;
  double _overflow = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _HoverMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _armed = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _configure(double boxWidth, double textWidth, bool reduceMotion) {
    final overflow = textWidth - boxWidth;
    if (reduceMotion || overflow <= 1) {
      _armed = false;
      if (_overflow != 0) {
        _overflow = 0;
        _controller.stop();
        _controller.value = 0;
      }
      return;
    }
    final travel = overflow + _endGap;
    final duration = Duration(
      milliseconds: (travel / _pixelsPerSecond * 1000).round().clamp(
        1800,
        10000,
      ),
    );
    if (_armed && _controller.duration == duration) return;
    _armed = true;
    _overflow = overflow;
    _controller.duration = duration;
    _controller.value = 0;
    Future<void>.delayed(hoverMarqueeStartDelay, () {
      if (!mounted || !_armed) return;
      _controller.repeat();
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout();
        final textWidth = painter.size.width;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _configure(maxWidth, textWidth, reduce);
        });

        if (reduce || maxWidth <= 0 || textWidth <= maxWidth + 1) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        final lineHeight = painter.size.height;
        return SizedBox(
          width: maxWidth,
          height: lineHeight,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final dx = _controller.value * (_overflow + _endGap);
                return Transform.translate(
                  offset: Offset(-dx, 0),
                  child: child,
                );
              },
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: lineHeight,
                maxHeight: lineHeight,
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  style: widget.style,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pause before a truncated title starts scrolling on hover.
const hoverMarqueeStartDelay = Duration(milliseconds: 450);
