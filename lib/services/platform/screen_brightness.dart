import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Per-window screen brightness (Android). No-op on other platforms.
///
/// Does not need `WRITE_SETTINGS` — only the activity window is changed.
class ScreenBrightness {
  ScreenBrightness._();

  static const _channel = MethodChannel('javp/display');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Current window brightness in 0…1, or null when using the system value.
  static Future<double?> get() async {
    if (!isSupported) return null;
    try {
      final value = await _channel.invokeMethod<double>('getBrightness');
      if (value == null || value < 0) return null;
      return value.clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  /// Set window brightness to 0…1. Pass null to restore the system value.
  static Future<void> set(double? value) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setBrightness', {
        'value': value == null ? -1.0 : value.clamp(0.0, 1.0),
      });
    } catch (_) {}
  }
}
