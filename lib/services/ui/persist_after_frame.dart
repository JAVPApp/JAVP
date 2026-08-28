import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Runs [write] after the current frame paints.
///
/// Controlled [Switch] / [SwitchListTile] widgets only flip when their `value`
/// rebuilds. [ChangeNotifier.notifyListeners] marks them dirty, but awaiting
/// SharedPreferences in the same turn still continues (via microtasks) *before*
/// the frame — so the thumb looks stuck even when notify runs first. Defer disk
/// I/O until after paint.
///
/// A short timer fallback covers unit tests / headless runs with no vsync so
/// callers that `await` this never hang.
Future<void> persistAfterFrame(FutureOr<void> Function() write) {
  final done = Completer<void>();
  var started = false;

  Future<void> run() async {
    if (started) return;
    started = true;
    try {
      await write();
      if (!done.isCompleted) done.complete();
    } catch (e, st) {
      if (!done.isCompleted) done.completeError(e, st);
    }
  }

  final scheduler = SchedulerBinding.instance;
  scheduler.addPostFrameCallback((_) {
    unawaited(run());
  });
  scheduler.scheduleFrame();
  Timer(const Duration(milliseconds: 64), () {
    unawaited(run());
  });
  return done.future;
}
