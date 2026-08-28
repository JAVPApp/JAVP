import 'package:flutter/services.dart';

/// Android Wi-Fi multicast lock so SSDP / mDNS packets are not dropped.
class LanMulticastLock {
  static const _channel = MethodChannel('javp/lan_multicast');

  static Future<void> acquire() async {
    try {
      await _channel.invokeMethod<void>('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}
