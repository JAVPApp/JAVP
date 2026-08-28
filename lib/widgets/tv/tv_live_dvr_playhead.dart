import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/player/live_dvr_playhead.dart';

/// 10-foot DVR playhead: same thumb as phone, ←/→ seek when focused.
class TvLiveDvrPlayhead extends StatefulWidget {
  const TvLiveDvrPlayhead({
    super.key,
    required this.progress,
    required this.color,
    required this.label,
    this.liveEdge,
    this.focusNode,
    this.focusable = false,
    this.autofocus = false,
    this.onRewind,
    this.onForward,
    this.onSelect,
  });

  final double progress;
  final Color color;
  final String label;
  final double? liveEdge;
  final FocusNode? focusNode;
  final bool focusable;
  final bool autofocus;
  final VoidCallback? onRewind;
  final VoidCallback? onForward;
  final VoidCallback? onSelect;

  @override
  State<TvLiveDvrPlayhead> createState() => _TvLiveDvrPlayheadState();
}

class _TvLiveDvrPlayheadState extends State<TvLiveDvrPlayhead> {
  FocusNode? _owned;

  FocusNode get _node => widget.focusNode ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _owned = FocusNode(debugLabel: 'tvLiveDvrPlayhead');
    }
    _node.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant TvLiveDvrPlayhead oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _owned)?.removeListener(_onFocus);
      if (widget.focusNode == null && _owned == null) {
        _owned = FocusNode(debugLabel: 'tvLiveDvrPlayhead');
      }
      if (widget.focusNode != null && _owned != null) {
        _owned!.dispose();
        _owned = null;
      }
      _node.addListener(_onFocus);
    }
    if (widget.focusable && widget.autofocus && !oldWidget.autofocus) {
      _node.requestFocus();
    }
    if (!widget.focusable && oldWidget.focusable && _node.hasFocus) {
      _node.unfocus();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _owned?.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      widget.onRewind?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      widget.onForward?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (widget.onSelect == null) return KeyEventResult.ignored;
      widget.onSelect!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusable && _node.hasFocus;
    return Focus(
      focusNode: _node,
      canRequestFocus: widget.focusable,
      skipTraversal: !widget.focusable,
      autofocus: widget.focusable && widget.autofocus,
      onKeyEvent: _onKey,
      child: AnimatedContainer(
        duration: AppMotion.focus,
        curve: AppMotion.ease,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: focused ? Colors.white : Colors.transparent,
            width: 3,
          ),
          color: focused ? Colors.white10 : Colors.transparent,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LiveDvrPlayheadTrack(
              progress: widget.progress,
              color: widget.color,
              liveEdge: widget.liveEdge,
              thumbRadius: focused ? 10 : 8,
              trackHeight: 6,
            ),
            const SizedBox(height: 4),
            Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.color == AppColors.live
                    ? AppColors.live
                    : Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
