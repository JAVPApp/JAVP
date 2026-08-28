import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Never [notifyListeners] while the widget tree is locked (build / layout).
///
/// That is the try/catch equivalent for UI freezes caused by
/// `setState() or markNeedsBuild() called during build`. A thrown FlutterError
/// is already caught — the hitch still happens. Deferring the notify does not.
///
/// Does **not** move CPU off the UI isolate. Tight loops still need
/// [yieldUiIfDue] / isolates (see `ui_isolate.dart`).
mixin DeferNotifyIfBuilding on ChangeNotifier {
  bool _deferNotifyScheduled = false;

  bool get notifyListenersDisposed;

  /// Extra gate (e.g. quiet mode). Not applied to [notifyListenersIgnoringGate].
  bool get allowNotifyListeners => true;

  void onBeforeNotifyListeners() {}

  bool _phaseAllowsNotify() {
    try {
      final phase = SchedulerBinding.instance.schedulerPhase;
      return phase == SchedulerPhase.idle ||
          phase == SchedulerPhase.postFrameCallbacks;
    } catch (_) {
      return true;
    }
  }

  @override
  void notifyListeners() {
    if (notifyListenersDisposed || !allowNotifyListeners) return;
    _notifyNowOrDefer(gated: true);
  }

  /// Pierce quiet / other gates; still never notify during build.
  void notifyListenersIgnoringGate() {
    if (notifyListenersDisposed) return;
    _notifyNowOrDefer(gated: false);
  }

  void _notifyNowOrDefer({required bool gated}) {
    if (notifyListenersDisposed) return;
    if (gated && !allowNotifyListeners) return;
    if (_phaseAllowsNotify()) {
      onBeforeNotifyListeners();
      super.notifyListeners();
      return;
    }
    if (_deferNotifyScheduled) return;
    _deferNotifyScheduled = true;
    void fire() {
      _deferNotifyScheduled = false;
      if (notifyListenersDisposed) return;
      if (gated && !allowNotifyListeners) return;
      onBeforeNotifyListeners();
      super.notifyListeners();
    }

    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => fire());
    } catch (_) {
      fire();
    }
  }
}
