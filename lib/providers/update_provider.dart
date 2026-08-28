import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/config/distribution.dart';
import 'package:javp/models/app_update_info.dart';
import 'package:javp/platform/desktop_bootstrap.dart';
import 'package:javp/services/platform/desktop_tray_service.dart';
import 'package:javp/services/update/app_update_service.dart';
import 'package:javp/services/update/update_channel.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:javp/compat/window_manager.dart';

enum UpdateStatus {
  idle,
  checking,
  available,
  upToDate,
  downloading,
  readyToInstall,
  installing,
  error,
}

class UpdateProvider extends ChangeNotifier {
  UpdateProvider({AppUpdateService? service})
    : _service = service ?? AppUpdateService();

  final AppUpdateService _service;

  UpdateStatus status = UpdateStatus.idle;
  AppUpdateInfo? available;
  PackageInfo? packageInfo;
  String? error;
  double downloadProgress = 0;
  File? downloadedFile;
  bool forceRequired = false;

  UpdateChannel get channel => _service.channel;

  /// Self-update needs a distribution that allows it (not Play) and a platform
  /// that can install (Android APK / desktop zip).
  bool get supportsInAppUpdates =>
      Distribution.enablesSelfUpdate && _service.supportsInAppUpdates;

  bool get isWindowsTarget =>
      _service.installTarget == UpdateInstallTarget.windowsZip;

  bool get isLinuxTarget =>
      _service.installTarget == UpdateInstallTarget.linuxZip;

  bool get isMacosTarget =>
      _service.installTarget == UpdateInstallTarget.macosZip;

  bool get isAndroidApkTarget =>
      _service.installTarget == UpdateInstallTarget.androidApk;

  bool get isDesktopZipTarget => _service.isDesktopZipTarget;

  String get currentLabel {
    final info = packageInfo;
    if (info == null) return '…';
    final version = '${info.version} (${info.buildNumber})';
    if (channel.isDev) return '$version · dev';
    return version;
  }

  int get currentVersionCode {
    final raw = int.tryParse(packageInfo?.buildNumber ?? '') ?? 0;
    return AppUpdateInfo.comparableVersionCode(raw);
  }

  String get currentVersionName => packageInfo?.version ?? '';

  Future<void> loadPackageInfo() async {
    packageInfo = await _service.currentPackage();
    await _service.resolveChannel();
    await _syncDesktopWindowTitle();
    notifyListeners();
  }

  /// Keep the native title bar in sync with the running build (desktop only).
  Future<void> _syncDesktopWindowTitle() async {
    if (!isDesktopPlatform || packageInfo == null) return;
    final version = packageInfo!.version;
    final title = channel.isDev ? 'JAVP $version (dev)' : 'JAVP $version';
    try {
      await windowManager.setTitle(title);
    } catch (e) {
      debugPrint('Desktop window title failed: $e');
    }
  }

  Future<AppUpdateInfo?> check({
    bool manual = false,
    bool ignoreSkipped = false,

    /// Cold-start / explicit refresh: always hit the network. The 12h
    /// throttle only applies to opportunistic background checks.
    bool force = false,
  }) async {
    if (!supportsInAppUpdates) {
      available = null;
      forceRequired = false;
      status = UpdateStatus.idle;
      error = null;
      notifyListeners();
      return null;
    }

    if (!manual && !force && !await _service.shouldAutoCheck()) {
      return available;
    }

    status = UpdateStatus.checking;
    error = null;
    notifyListeners();

    try {
      packageInfo ??= await _service.currentPackage();
      await _service.resolveChannel();
      final currentCode = int.tryParse(packageInfo!.buildNumber) ?? 0;
      final latest = await _service.checkForUpdate(
        ignoreSkipped: manual || ignoreSkipped,
      );
      await _service.markCheckedNow();

      if (latest == null) {
        available = null;
        forceRequired = false;
        downloadedFile = null;
        status = UpdateStatus.upToDate;
        await _service.clearDownloadedPackage();
        notifyListeners();
        return null;
      }

      available = latest;
      forceRequired = latest.isRequiredFor(currentVersionCode: currentCode);
      final cached = await _service.cachedDownloadedPackage(latest.versionCode);
      if (cached != null) {
        downloadedFile = cached;
        status = UpdateStatus.readyToInstall;
      } else {
        downloadedFile = null;
        status = UpdateStatus.available;
      }
      notifyListeners();
      return latest;
    } catch (e) {
      error = e.toString();
      status = UpdateStatus.error;
      notifyListeners();
      if (manual) rethrow;
      return null;
    }
  }

  Future<void> skipAvailable() async {
    final update = available;
    if (update == null || forceRequired) return;
    await _service.skipVersion(update.versionCode);
    available = null;
    downloadedFile = null;
    status = UpdateStatus.idle;
    await _service.clearDownloadedPackage();
    notifyListeners();
  }

  Future<File> download() async {
    _assertSelfUpdateAllowed();
    final update = available;
    if (update == null) {
      throw StateError('No update available');
    }

    status = UpdateStatus.downloading;
    downloadProgress = 0;
    error = null;
    notifyListeners();

    try {
      var lastPct = -1;
      var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
      final file = await _service.downloadUpdate(
        update,
        onProgress: (received, total) {
          if (total == null || total <= 0) {
            downloadProgress = 0;
          } else {
            downloadProgress = (received / total).clamp(0.0, 1.0);
          }
          // Rebuild at most ~1% / 120ms so the huge markdown changelog
          // is not re-parsed on every HTTP chunk (that froze the window).
          final pct = (downloadProgress * 100).round();
          final now = DateTime.now();
          if (pct == lastPct &&
              now.difference(lastNotify) < const Duration(milliseconds: 120)) {
            return;
          }
          lastPct = pct;
          lastNotify = now;
          notifyListeners();
        },
      );
      downloadedFile = file;
      downloadProgress = 1;
      status = UpdateStatus.readyToInstall;
      await _service.rememberDownloadedPackage(
        versionCode: update.versionCode,
        file: file,
      );
      notifyListeners();
      return file;
    } catch (e) {
      error = e.toString();
      status = UpdateStatus.error;
      notifyListeners();
      rethrow;
    }
  }

  /// Hook so tests can observe the quit instead of taking the process down.
  @visibleForTesting
  static void Function(int code) exitApp = exit;

  Future<void> install() async {
    _assertSelfUpdateAllowed();
    var file = downloadedFile;
    file ??= await download();
    try {
      // Paint "Installing…" before zip decode — unpacking a desktop zip on
      // the UI isolate used to freeze Flutter into a blank window.
      status = UpdateStatus.installing;
      error = null;
      notifyListeners();
      await Future<void>.delayed(Duration.zero);
      await _service.installUpdate(file);
      final path = file.path.toLowerCase();
      final waitsForExit =
          isDesktopZipTarget &&
          !path.endsWith('.exe') &&
          !path.endsWith('.appimage');
      if (waitsForExit) {
        // The helper is waiting on this process before it can replace the
        // running binary, so quitting is the last step of the install.
        // Brief yield so Windows helper trampolines can finish spawning.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (isWindowsDesktop) {
          // windowManager.destroy() is PostQuitMessage and deadlocks with
          // tray setPreventClose, leaving javp.exe locked so the helper
          // cannot replace it. Use the same exit path as Quit.
          await DesktopTrayService.instance.quitApp();
          return;
        }
        exitApp(0);
        return;
      }
      // Android APK / opened .exe / AppImage: OpenFilex returns once the
      // system installer is launched, not when the user finishes. Hand
      // control back so dismissing that UI does not leave us stuck on
      // "Installing…" and force a re-download.
      status = UpdateStatus.readyToInstall;
      notifyListeners();
    } catch (e) {
      error = e.toString();
      // Keep a verified download so retry can re-open the installer.
      status = downloadedFile != null
          ? UpdateStatus.readyToInstall
          : UpdateStatus.error;
      notifyListeners();
      rethrow;
    }
  }

  /// Call when the app returns to the foreground during an Android APK
  /// install. OpenFilex cannot tell us the user dismissed the installer, so
  /// if we are still painting "Installing…" after resume, recover.
  void onAppResumed() {
    if (!isAndroidApkTarget) return;
    if (status != UpdateStatus.installing) return;
    if (downloadedFile == null) return;
    status = UpdateStatus.readyToInstall;
    notifyListeners();
  }

  void _assertSelfUpdateAllowed() {
    if (!Distribution.enablesSelfUpdate) {
      throw StateError('Self-update is disabled on the Play Store build');
    }
    if (!_service.supportsInAppUpdates) {
      throw StateError('In-app updates are not supported on this platform');
    }
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }
}
