import 'package:flutter/foundation.dart';
import 'package:javp/config/distribution.dart';
import 'package:javp/config/javp_host.dart';
import 'package:javp/platform/desktop_ui.dart';

/// Feature gates so Smart TV / web ports can ship core watching without
/// Android-only native plugins (rqbit torrents, Cast, APK updater, etc.).
abstract final class AppCapabilities {
  /// Full media_kit / libmpv stack (Android / desktop native today).
  static bool get usesMediaKit => !kIsWeb && JavpHost.isAndroid;

  /// `video_player` (+ platform impl) used on Tizen / webOS / Flutter web.
  static bool get usesVideoPlayerBackend => kIsWeb || JavpHost.isSmartTvOs;

  /// Embedded librqbit (Android + Windows/Linux/macOS). Off on web / Smart TV.
  ///
  /// [JavpHost.isAndroid] is a compile-time TV-port switch that defaults to
  /// true on desktop, so this must not use it — catalogs key off the real
  /// `javp_platform` (`windows` / `linux` / …) plus this capability.
  static bool get torrents => !kIsWeb && !JavpHost.isSmartTvOs;

  /// Google Cast SDK (Android phone / Android TV only).
  static bool get chromecast =>
      !kIsWeb && !JavpHost.isSmartTvOs && !DesktopUi.enabled;

  /// DLNA + AirPlay over the LAN (Android + desktop).
  static bool get lanCast => !kIsWeb && !JavpHost.isSmartTvOs;

  /// Any send-to-TV protocol.
  static bool get castToDevice => chromecast || lanCast;

  static bool get pictureInPicture => !kIsWeb && JavpHost.isAndroid;

  static bool get localFilePicker => !kIsWeb && JavpHost.isAndroid;

  static bool get selfUpdate =>
      !kIsWeb && JavpHost.isAndroid && Distribution.enablesSelfUpdate;

  /// Google Drive profile sync (Android Sign-In, web GIS, or desktop loopback).
  static bool get googleDriveSync =>
      kIsWeb || JavpHost.isAndroid || DesktopUi.enabled;

  /// Alias kept for older call sites — same as [googleDriveSync].
  static bool get googlePlaySignIn => googleDriveSync;

  static bool get localNotifications => !kIsWeb && JavpHost.isAndroid;

  /// Phone → TV LAN QR pairing (`dart:io` HttpServer).
  static bool get sourcePairingServer => !kIsWeb;

  /// Phone → TV / desktop LAN QR remote for search / channel / paste.
  static bool get phoneRemote => sourcePairingServer;

  /// Downloads / DVR-to-disk (filesystem heavy).
  static bool get offlineDownloads => !kIsWeb && JavpHost.isAndroid;

  /// Two live panes (media_kit only). Gated off Smart TV / video_player ports.
  ///
  /// Temporarily `false`: dual-live is too buggy to ship. Restore to
  /// `usesMediaKit` once the second decoder and TV chrome are solid
  /// (`docs/roadmap.md` Mid).
  static bool get multiView => false;
}
