import 'package:flutter/material.dart';

/// [ScaffoldMessenger] that never queues snackbars.
///
/// Material's default messenger keeps every [showSnackBar] call in a FIFO
/// list. Desktop cannot swipe them away, so a burst of notices (downloads,
/// sync, copy) traps the user behind a stack they cannot skip. Each new
/// snackbar replaces whatever is showing; [isShowingSnackBar] lets Escape
/// dismiss the current one.
class AppScaffoldMessenger extends ScaffoldMessenger {
  const AppScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => AppScaffoldMessengerState();
}

class AppScaffoldMessengerState extends ScaffoldMessengerState {
  var _generation = 0;
  var _visible = false;

  bool get isShowingSnackBar => _visible;

  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    clearSnackBars();
    final generation = ++_generation;
    _visible = true;
    final controller = super.showSnackBar(
      snackBar,
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
    controller.closed.then((_) {
      if (mounted && generation == _generation) {
        _visible = false;
      }
    });
    return controller;
  }
}
