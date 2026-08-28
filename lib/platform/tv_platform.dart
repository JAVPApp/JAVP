import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/config/javp_host.dart';

/// Runtime 10-foot / leanback detection.
///
/// Android uses a MethodChannel. Tizen / webOS builds always use the TV shell.
/// On desktop, [LayoutModeResolver] can force TV mode via [forceLayoutMode].
class TvPlatform {
  TvPlatform._();

  static const _channel = MethodChannel('javp/tv_platform');
  static bool? _cachedTv;
  static bool? _cachedEmulator;
  static int? _cachedMemoryClassMb;
  static bool? _layoutModeForced;

  /// Whether this device should use the 10-foot TV UI.
  ///
  /// Prefer this over [isAndroidTv] for new code — it is true on Android TV,
  /// on Samsung Tizen / LG webOS Flutter ports, and when [LayoutModeResolver]
  /// forces TV layout on desktop.
  static bool get isTvShell {
    if (_layoutModeForced != null) return _layoutModeForced!;
    return _cachedTv ?? JavpHost.isSmartTvOs;
  }

  /// Legacy name kept for existing call sites (same as [isTvShell]).
  static bool get isAndroidTv => isTvShell;

  /// Android emulator / AVD (pairing must use adb forward, not raw LAN IP).
  static bool get isEmulator => _cachedEmulator ?? false;

  /// Android `ActivityManager.memoryClass` in MB when known (else null).
  ///
  /// Rough per-app heap guidance used to size the Flutter image cache — not
  /// total device RAM.
  static int? get memoryClassMb => _cachedMemoryClassMb;

  /// Call once during app startup before building the router/shell.
  static Future<bool> ensureInitialized() async {
    if (_cachedTv != null) return _cachedTv!;

    if (JavpHost.isSmartTvOs) {
      _cachedTv = true;
      _cachedEmulator = false;
      return true;
    }

    if (kIsWeb) {
      _cachedTv = false;
      _cachedEmulator = false;
      return false;
    }

    try {
      final results = await Future.wait([
        _channel.invokeMethod<bool>('isAndroidTv'),
        _channel.invokeMethod<bool>('isEmulator'),
        _channel.invokeMethod<int>('memoryClassMb'),
      ]);
      _cachedTv = results[0] as bool? ?? false;
      _cachedEmulator = results[1] as bool? ?? false;
      final mem = results[2] as int?;
      _cachedMemoryClassMb = (mem != null && mem > 0) ? mem : null;
    } catch (_) {
      _cachedTv = false;
      _cachedEmulator = false;
      _cachedMemoryClassMb = null;
    }
    return _cachedTv!;
  }

  /// Force TV shell from [LayoutModeResolver] on desktop.
  ///
  /// Call this before [ensureInitialized] to override the platform detection.
  /// Pass `true` to force TV mode, `null` to revert to platform detection.
  static void forceLayoutMode(bool? forceTv) {
    _layoutModeForced = forceTv;
  }

  /// Test / desktop override. Prefer [ensureInitialized] in production.
  @visibleForTesting
  static void debugOverride(bool? value, {bool? emulator, int? memoryClassMb}) {
    _cachedTv = value;
    if (emulator != null || value == null) {
      _cachedEmulator = value == null ? null : emulator;
    }
    if (memoryClassMb != null || value == null) {
      _cachedMemoryClassMb = value == null ? null : memoryClassMb;
    }
  }

  /// Reset layout mode force for testing.
  @visibleForTesting
  static void debugResetLayoutMode() {
    _layoutModeForced = null;
  }
}
