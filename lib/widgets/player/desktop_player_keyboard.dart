import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// True for Ctrl / Alt / Meta chords so app shortcuts (Ctrl+K search) win.
bool desktopPlayerKeyHasModifier(KeyEvent event) {
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.control ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.meta ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.alt ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight) {
    return true;
  }
  return HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isAltPressed;
}

/// Desktop player shortcuts that work without clicking the picture first.
///
/// [Focus.onKeyEvent] only runs while [focusNode] is the primary focus.
/// Opening a channel from the list (or a dummy parent [Focus] winning
/// autofocus) leaves Space / J / L / arrows dead until a click. A
/// [HardwareKeyboard] handler keeps those keys alive for the expanded
/// session, except while typing or a dialog/sheet is on top.
class DesktopPlayerKeyboard extends StatefulWidget {
  const DesktopPlayerKeyboard({
    super.key,
    required this.focusNode,
    required this.onKeyEvent,
    required this.child,
    this.absorbKeys = true,
  });

  final FocusNode focusNode;
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKeyEvent;
  final Widget child;

  /// When false (desktop PiP), let the PiP chrome own keys.
  final bool absorbKeys;

  @override
  State<DesktopPlayerKeyboard> createState() => _DesktopPlayerKeyboardState();
}

class _DesktopPlayerKeyboardState extends State<DesktopPlayerKeyboard> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimFocus());
  }

  @override
  void didUpdateWidget(covariant DesktopPlayerKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.absorbKeys && !oldWidget.absorbKeys) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimFocus());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  void _claimFocus() {
    if (!mounted || !widget.absorbKeys) return;
    final node = widget.focusNode;
    if (node.canRequestFocus && !node.hasFocus) {
      node.requestFocus();
    }
  }

  bool _shouldDeferToOverlayOrText() {
    if (!mounted) return true;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return true;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx != null &&
        ctx.findAncestorStateOfType<EditableTextState>() != null) {
      return true;
    }
    return false;
  }

  KeyEventResult _dispatch(FocusNode node, KeyEvent event) {
    if (!widget.absorbKeys) return KeyEventResult.ignored;
    if (_shouldDeferToOverlayOrText()) return KeyEventResult.ignored;
    if (desktopPlayerKeyHasModifier(event)) return KeyEventResult.ignored;
    return widget.onKeyEvent(node, event);
  }

  bool _onHardwareKey(KeyEvent event) {
    // Focus.onKeyEvent already runs while we have primary focus.
    if (widget.focusNode.hasFocus) return false;
    return _dispatch(widget.focusNode, event) == KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.absorbKeys,
      onKeyEvent: _dispatch,
      child: widget.child,
    );
  }
}
