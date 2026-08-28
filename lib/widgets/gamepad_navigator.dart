import 'package:flutter/material.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/services/input/gamepad_events.dart';
import 'package:javp/services/input/gamepad_service.dart';

/// Lets a controller drive the browse UI: sticks and D-pad move focus, A
/// activates, B goes back.
///
/// This is the bottom of the handler stack, so anything with its own mapping
/// (the player) gets first refusal. Once a pad is connected the subtree
/// switches to directional navigation, which is what makes focus visible and
/// stops traversal from wandering into off-screen widgets.
class GamepadNavigator extends StatefulWidget {
  const GamepadNavigator({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<GamepadNavigator> createState() => _GamepadNavigatorState();
}

class _GamepadNavigatorState extends State<GamepadNavigator> {
  GamepadService get _pad => GamepadService.instance;

  @override
  void initState() {
    super.initState();
    if (!DesktopUi.enabled) return;
    _pad.addHandler(_handle);
    _pad.addListener(_onConnectionChanged);
    _pad.start();
  }

  @override
  void dispose() {
    if (DesktopUi.enabled) {
      _pad.removeHandler(_handle);
      _pad.removeListener(_onConnectionChanged);
    }
    super.dispose();
  }

  void _onConnectionChanged() {
    if (mounted) setState(() {});
  }

  bool _handle(GamepadAction action) {
    switch (action) {
      case GamepadAction.up:
        return _move(TraversalDirection.up);
      case GamepadAction.down:
        return _move(TraversalDirection.down);
      case GamepadAction.left:
        return _move(TraversalDirection.left);
      case GamepadAction.right:
        return _move(TraversalDirection.right);
      case GamepadAction.activate:
        return _activate();
      case GamepadAction.back:
      case GamepadAction.view:
        return _back();
      default:
        return false;
    }
  }

  bool _move(TraversalDirection direction) {
    final primary = FocusManager.instance.primaryFocus;
    // A scope (or nothing) holding focus means the app has been driven by mouse
    // so far: the first press should adopt a control rather than move from one.
    final onAControl =
        primary != null && primary is! FocusScopeNode && primary.context != null;
    if (!onAControl) return FocusScope.of(context).nextFocus();
    return primary.focusInDirection(direction);
  }

  bool _activate() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    // maybeInvoke returns the action's own result, which is null for a plain
    // callback, so "did it run" has to be answered by looking it up first.
    if (Actions.maybeFind<ActivateIntent>(focusContext) == null) return false;
    Actions.maybeInvoke(focusContext, const ActivateIntent());
    return true;
  }

  bool _back() {
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    navigator.pop();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!DesktopUi.enabled) return widget.child;
    // The MediaQuery is always in the tree, even before a controller shows up:
    // adding a widget here later would remount everything below it, dropping
    // focus, scroll positions and the player's own state on the first press.
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        navigationMode: _pad.hasController
            ? NavigationMode.directional
            : mq.navigationMode,
      ),
      child: widget.child,
    );
  }
}
