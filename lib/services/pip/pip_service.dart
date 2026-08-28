import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/services/platform/desktop_window_service.dart';

/// Picture-in-Picture bridge.
///
/// - Android: native `javp/pip` MethodChannel
/// - Desktop: compact always-on-top video window (Windows/Linux/macOS)
class PipService extends ChangeNotifier {
  PipService() : _ownsChannel = true {
    _channel.setMethodCallHandler(_onMethodCall);
    unawaited(_probeSupport());
  }

  /// Test double that skips platform probing.
  @visibleForTesting
  PipService.debug({
    bool supported = true,
    bool inPip = false,
    bool desktopMode = false,
    bool autoEnterEnabled = false,
  }) : _supported = supported,
       _inPip = inPip,
       _desktopMode = desktopMode,
       _autoEnterEnabled = autoEnterEnabled,
       _ownsChannel = false {
    _finishReady();
  }

  static const _channel = MethodChannel('javp/pip');

  /// Force the Android MethodChannel path in tests (this host is Linux).
  @visibleForTesting
  static bool? debugForceAndroidChannel;

  bool _supported = false;
  bool _inPip = false;
  bool _desktopMode = false;
  bool _autoEnterEnabled = false;
  bool _disposed = false;
  final bool _ownsChannel;
  void Function(String action)? onPipAction;

  bool get isSupported => _supported;
  bool get isInPip => _inPip;
  bool get usesDesktopMiniWindow => _desktopMode;

  /// Home / recents should auto-enter Android system PiP.
  bool get autoEnterEnabled => _autoEnterEnabled;

  /// How long to defer AFK pause after [AppLifecycleState.paused].
  ///
  /// Android reports `onPause` before `onPictureInPictureModeChanged`. Auto-enter
  /// needs a longer beat so Home / recents can claim the session.
  Duration get backgroundSettleDelay => autoEnterEnabled
      ? const Duration(milliseconds: 800)
      : const Duration(milliseconds: 400);

  /// Completes after the first support probe (or immediately for [PipService.debug]).
  Future<void> get ready => _ready.future;
  final Completer<void> _ready = Completer<void>();

  Future<void> _probeSupport() async {
    if (kIsWeb) {
      _supported = false;
      _finishReady();
      return;
    }
    final forceAndroid = debugForceAndroidChannel == true;
    if (!forceAndroid && isDesktopPlatform) {
      _desktopMode = true;
      _supported = true;
      _inPip = DesktopWindowService.instance.isMiniPlayer;
      notifyListeners();
      _finishReady();
      return;
    }
    if (!forceAndroid && defaultTargetPlatform != TargetPlatform.android) {
      _supported = false;
      _finishReady();
      return;
    }
    await _probeAndroid(retries: 1);
    _finishReady();
  }

  Future<void> _probeAndroid({int retries = 0}) async {
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
      _inPip = await _channel.invokeMethod<bool>('isInPip') ?? false;
      if (_disposed) return;
      notifyListeners();
    } on MissingPluginException {
      if (retries > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await _probeAndroid(retries: retries - 1);
        return;
      }
      _supported = false;
    } on PlatformException {
      _supported = false;
    }
  }

  void _finishReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'onPipChanged':
        final active = call.arguments == true;
        if (_inPip == active) return null;
        _inPip = active;
        notifyListeners();
        return null;
      case 'onPipAction':
        final action = call.arguments as String?;
        if (action != null) onPipAction?.call(action);
        return null;
      default:
        return null;
    }
  }

  Future<bool> enter({
    int aspectX = 16,
    int aspectY = 9,
    bool playing = true,
  }) async {
    if (!_supported) return false;
    if (_desktopMode) {
      final ok = await DesktopWindowService.instance.enterMiniPlayer(
        aspectX: aspectX.toDouble(),
        aspectY: aspectY.toDouble(),
      );
      if (ok) {
        _inPip = true;
        notifyListeners();
      }
      return ok;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('enter', {
        'aspectX': aspectX,
        'aspectY': aspectY,
        'playing': playing,
      });
      // Mark in-PiP immediately so AFK pause cannot win the onPause race.
      if (ok == true && !_inPip) {
        _inPip = true;
        if (!_disposed) notifyListeners();
      }
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Exit desktop mini-window (no-op on Android system PiP).
  Future<void> exitDesktopMini() async {
    if (!_desktopMode || !_inPip) return;
    await DesktopWindowService.instance.exitMiniPlayer();
    _inPip = false;
    notifyListeners();
  }

  /// When [enabled], Home / gesture-away auto-enters PiP (Android 8+;
  /// seamless auto-enter on Android 12+). Desktop uses explicit PiP only.
  Future<void> setAutoEnter({
    required bool enabled,
    int aspectX = 16,
    int aspectY = 9,
    bool playing = true,
  }) async {
    if (!_supported || _desktopMode) return;
    _autoEnterEnabled = enabled;
    try {
      await _channel.invokeMethod<void>('setAutoEnter', {
        'enabled': enabled,
        'aspectX': aspectX,
        'aspectY': aspectY,
        'playing': playing,
      });
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  Future<void> setPlaying(bool playing) async {
    if (!_supported || _desktopMode) return;
    try {
      await _channel.invokeMethod<void>('setPlaying', {'playing': playing});
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  Future<void> setAspectRatio({
    required int aspectX,
    required int aspectY,
  }) async {
    if (!_supported || _desktopMode) return;
    try {
      await _channel.invokeMethod<void>('setAspectRatio', {
        'aspectX': aspectX,
        'aspectY': aspectY,
      });
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  @override
  void dispose() {
    _disposed = true;
    onPipAction = null;
    if (_ownsChannel) {
      _channel.setMethodCallHandler(null);
    }
    _finishReady();
    super.dispose();
  }
}
