import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:javp/services/input/gamepad_events.dart';
import 'package:javp/services/input/xinput_reader.dart';

/// Returns true when the action was consumed.
typedef GamepadHandler = bool Function(GamepadAction action);

/// Polls a controller and routes its actions to whoever is on top.
///
/// Handlers form a stack so the player can take over the pad while it is open
/// and hand it back on exit, without either side knowing about the other.
class GamepadService extends ChangeNotifier {
  GamepadService._();

  static final GamepadService instance = GamepadService._();

  /// 60Hz would be wasted on menu navigation; this still feels immediate.
  static const pollInterval = Duration(milliseconds: 24);

  final GamepadDecoder _decoder = GamepadDecoder();
  final List<GamepadHandler> _handlers = <GamepadHandler>[];

  XInputReader? _reader;
  Timer? _timer;
  Duration _clock = Duration.zero;
  bool _connected = false;

  /// True once a controller has been seen, so the UI can switch to a
  /// focus-first presentation only when there is something to drive it.
  bool get hasController => _connected;

  /// Set by tests that drive [debugFeed]: a live poll timer would outlive the
  /// test body and trip Flutter's pending-timer check (on Windows, where XInput
  /// really opens).
  @visibleForTesting
  static bool debugPollingDisabled = false;

  /// Starts polling. Safe to call when no controller (or no XInput) exists.
  void start() {
    if (_timer != null || debugPollingDisabled) return;
    _reader ??= XInputReader.open();
    if (_reader == null) return;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _decoder.reset();
  }

  void _tick() {
    final sample = _reader?.poll();
    if (sample == null) {
      if (_connected) {
        _connected = false;
        _decoder.reset();
        notifyListeners();
      }
      return;
    }
    if (!_connected) {
      _connected = true;
      notifyListeners();
    }
    _clock += pollInterval;
    for (final action in _decoder.decode(sample, _clock)) {
      dispatch(action);
    }
  }

  /// Pushes [handler] to the top of the stack; call [removeHandler] when done.
  void addHandler(GamepadHandler handler) => _handlers.add(handler);

  void removeHandler(GamepadHandler handler) => _handlers.remove(handler);

  /// Offers [action] to handlers from the top down until one consumes it.
  @visibleForTesting
  bool dispatch(GamepadAction action) {
    for (final handler in _handlers.reversed.toList(growable: false)) {
      try {
        if (handler(action)) return true;
      } catch (e) {
        debugPrint('Gamepad handler failed: $e');
      }
    }
    return false;
  }

  /// Feeds a synthetic sample so tests can drive the decoder end to end.
  @visibleForTesting
  void debugFeed(GamepadSample sample, {Duration? at}) {
    _clock = at ?? (_clock + pollInterval);
    if (!_connected) {
      _connected = true;
      notifyListeners();
    }
    for (final action in _decoder.decode(sample, _clock)) {
      dispatch(action);
    }
  }

  @visibleForTesting
  void debugReset() {
    stop();
    _handlers.clear();
    _decoder.reset();
    _clock = Duration.zero;
    _connected = false;
  }

  @override
  void dispose() {
    stop();
    _reader?.dispose();
    _reader = null;
    super.dispose();
  }
}
