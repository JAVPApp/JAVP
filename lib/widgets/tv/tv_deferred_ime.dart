import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/widgets/tv/tv_back_gate.dart';

/// Values to pass through to a [TextField] so TV D-pad focus does not open
/// the IME until OK / Select (or a tap).
class TvDeferredImeHandle {
  const TvDeferredImeHandle({
    required this.focusNode,
    required this.readOnly,
    required this.onTap,
  });

  final FocusNode focusNode;
  final bool readOnly;
  final VoidCallback onTap;
}

/// On Android TV / leanback, focusing a text field must not open the keyboard.
/// The IME captures D-pad, so the cursor cannot move to the next section.
///
/// OK / Select (or a tap) opens the IME; Back / unfocus closes it and leaves
/// the field focused so Down can continue.
class TvDeferredIme extends StatefulWidget {
  const TvDeferredIme({
    super.key,
    required this.builder,
    this.focusNode,
    this.enabled = true,
  });

  final Widget Function(BuildContext context, TvDeferredImeHandle handle)
  builder;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  State<TvDeferredIme> createState() => _TvDeferredImeState();
}

class _TvDeferredImeState extends State<TvDeferredIme> {
  FocusNode? _owned;
  KeyEventResult Function(FocusNode, KeyEvent)? _chained;
  bool _editing = false;

  FocusNode get _node => widget.focusNode ?? _owned!;

  bool get _defer => TvPlatform.isAndroidTv;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _owned = FocusNode(debugLabel: 'tvDeferredIme');
    }
    _attach(_node);
  }

  @override
  void didUpdateWidget(covariant TvDeferredIme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _detach(oldWidget.focusNode ?? _owned);
      if (widget.focusNode == null && _owned == null) {
        _owned = FocusNode(debugLabel: 'tvDeferredIme');
      }
      if (widget.focusNode != null && _owned != null) {
        _owned!.dispose();
        _owned = null;
      }
      _attach(_node);
    }
  }

  @override
  void dispose() {
    _detach(_node);
    _owned?.dispose();
    super.dispose();
  }

  void _attach(FocusNode? node) {
    if (node == null) return;
    _chained = node.onKeyEvent;
    node.onKeyEvent = _onKey;
    node.addListener(_onFocus);
  }

  void _detach(FocusNode? node) {
    if (node == null) return;
    node.removeListener(_onFocus);
    if (node.onKeyEvent == _onKey) {
      node.onKeyEvent = _chained;
    }
    _chained = null;
  }

  void _onFocus() {
    if (!_node.hasFocus && _editing) {
      _endEditing();
    }
  }

  void _beginEditing() {
    if (!_defer || !widget.enabled || _editing) return;
    setState(() => _editing = true);
  }

  void _endEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  TraversalDirection? _directionFor(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_defer && (event is KeyDownEvent || event is KeyRepeatEvent)) {
      final key = event.logicalKey;
      if (!_editing) {
        if (isTvSelectKey(key)) {
          if (event is KeyDownEvent) _beginEditing();
          return KeyEventResult.handled;
        }
        final dir = _directionFor(key);
        if (dir != null) {
          _node.focusInDirection(dir);
          return KeyEventResult.handled;
        }
      } else if (event is KeyDownEvent && isTvBackKey(key)) {
        _endEditing();
        return KeyEventResult.handled;
      }
    }
    return _chained?.call(node, event) ?? KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.builder(
      context,
      TvDeferredImeHandle(
        focusNode: _node,
        readOnly: _defer && !_editing,
        onTap: _beginEditing,
      ),
    );
    if (!_defer) return field;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: field,
    );
  }
}
