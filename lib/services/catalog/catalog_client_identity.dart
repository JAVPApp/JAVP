import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:javp/config/javp_host.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/services/catalog/catalog_client_gate.dart';

/// Snapshot of this binary for catalog `platforms` / `requires` / `min_version`.
CatalogClientProfile catalogClientProfileForDevice({String? appVersion}) {
  return CatalogClientProfile(
    appVersion: appVersion,
    platform: catalogClientPlatformToken(),
    device: catalogClientDeviceToken(),
    capabilities: [
      if (AppCapabilities.torrents) 'torrents',
      if (AppCapabilities.offlineDownloads) 'downloads',
    ],
  );
}

String catalogClientPlatformToken() {
  if (kIsWeb) return 'web';
  if (JavpHost.isTizen) return 'tizen';
  if (JavpHost.isWebOs) return 'webos';
  // Avoid touching dart:io [Platform] on web — even behind [kIsWeb] some
  // stub paths still throw `_Namespace` when the getter is evaluated.
  try {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
  } catch (_) {
    return 'web';
  }
  return 'android';
}

String catalogClientDeviceToken() {
  if (TvPlatform.isTvShell) return 'tv';
  if (DesktopUi.enabled) return 'desktop';
  return 'mobile';
}
