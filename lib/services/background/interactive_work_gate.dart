import 'dart:async';

/// Tracks user-facing work so background sync / prefetch can yield sockets
/// and CPU while the user is browsing.
///
/// Call [run] around category loads, title details, Live group fills, search,
/// and playback URL resolution. Background loops call [yieldToInteractive]
/// between units of work. HTTP going through [PrioritizedHttpClient] treats
/// requests inside [run] as interactive (via a zone flag).
class InteractiveWorkGate {
  InteractiveWorkGate({
    this.maxBackgroundHttp = 2,
    this.yieldMaxWait = const Duration(seconds: 2),
  });

  /// Simultaneous background (non-[run]) HTTP requests when nobody is browsing.
  /// Drops to 0 while [isBusy] so a category / details GET is not queued
  /// behind a full catalog dump.
  final int maxBackgroundHttp;

  /// How long a background loop will wait for browse work before continuing,
  /// so a stuck or long-running interactive burst cannot starve sync forever.
  final Duration yieldMaxWait;

  static const _zoneKey = #javpInteractiveHttp;

  /// True when the current zone was entered via [run].
  static bool get inInteractiveZone => Zone.current[_zoneKey] == true;

  int _depth = 0;
  int _backgroundHttp = 0;
  final List<Completer<void>> _idleWaiters = [];
  final List<Completer<void>> _backgroundSlotWaiters = [];

  bool get isBusy => _depth > 0;

  int get backgroundHttpActive => _backgroundHttp;

  Future<T> run<T>(Future<T> Function() action) {
    return runZoned(() async {
      _depth++;
      if (_depth == 1) {
        _wakeBackgroundWaiters();
      }
      try {
        return await action();
      } finally {
        _depth--;
        if (_depth == 0) {
          _notifyIdle();
          _wakeBackgroundWaiters();
        }
      }
    }, zoneValues: {_zoneKey: true});
  }

  Future<void> waitUntilIdle() {
    if (_depth == 0) return Future<void>.value();
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  /// Background loops call this between categories / pages / ingest chunks.
  Future<void> yieldToInteractive() async {
    if (_depth == 0) return;
    try {
      await waitUntilIdle().timeout(yieldMaxWait);
    } on TimeoutException {
      // Browse is still busy — continue so sync still makes progress.
    }
  }

  /// Slot for a non-interactive HTTP request. Waits while the user is browsing
  /// (or while [maxBackgroundHttp] background requests are already in flight).
  Future<void> acquireBackgroundHttp() async {
    while (true) {
      final cap = _depth > 0 ? 0 : maxBackgroundHttp;
      if (_backgroundHttp < cap) {
        _backgroundHttp++;
        return;
      }
      final slot = Completer<void>();
      _backgroundSlotWaiters.add(slot);
      if (_depth > 0) {
        await Future.any<void>([waitUntilIdle(), slot.future]);
      } else {
        await slot.future;
      }
    }
  }

  void releaseBackgroundHttp() {
    if (_backgroundHttp > 0) _backgroundHttp--;
    _wakeBackgroundWaiters();
  }

  void _notifyIdle() {
    final waiters = List<Completer<void>>.from(_idleWaiters);
    _idleWaiters.clear();
    for (final c in waiters) {
      if (!c.isCompleted) c.complete();
    }
  }

  void _wakeBackgroundWaiters() {
    if (_backgroundSlotWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.from(_backgroundSlotWaiters);
    _backgroundSlotWaiters.clear();
    for (final c in waiters) {
      if (!c.isCompleted) c.complete();
    }
  }
}
