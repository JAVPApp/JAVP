import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:javp/models/app_update_info.dart';
import 'package:javp/services/update/update_channel.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_io.dart' if (dart.library.html) 'app_update_web.dart'
    as platform;

export 'app_update_io.dart' if (dart.library.html) 'app_update_web.dart'
    show UpdateInstallTarget;

typedef DownloadProgress = void Function(int received, int? total);

/// Fetches `latest.json` from the public deploy host and installs updates.
class AppUpdateService {
  AppUpdateService({
    http.Client? httpClient,
    UpdateChannel? channel,
    String? manifestUrl,
    List<String>? preferredAbis,
    List<String>? preferredPackages,
    platform.UpdateInstallTarget? installTarget,
  }) : _channelOverride = channel,
       _manifestUrlOverride = manifestUrl,
       preferredAbis = preferredAbis ?? platform.detectPreferredAbis(),
       preferredPackages = preferredPackages ?? platform.detectPreferredPackages(),
       installTarget = installTarget ?? platform.detectInstallTarget(),
       _http = httpClient ?? http.Client();

  static const defaultManifestUrl = 'https://updater.javp.app/latest.json';
  static const _lastCheckKey = 'app_update_last_check_ms';
  static const _skippedCodeKey = 'app_update_skipped_version_code';
  static const _cachedPackagePathKey = 'app_update_cached_package_path';
  static const _cachedPackageCodeKey = 'app_update_cached_package_version_code';

  /// Written next to `javp.exe` after a successful Windows zip apply.
  static const appliedPackageStampName = '.javp-applied-sha256';

  final http.Client _http;
  final UpdateChannel? _channelOverride;
  final String? _manifestUrlOverride;
  final List<String> preferredAbis;
  final List<String> preferredPackages;
  final platform.UpdateInstallTarget installTarget;
  UpdateChannel? _resolvedChannel;

  @visibleForTesting
  String? appliedPackageStampPath;

  UpdateChannel get channel =>
      _resolvedChannel ?? _channelOverride ?? UpdateChannel.current;

  String get manifestUrl => _manifestUrlOverride ?? channel.manifestUrl();

  bool get supportsInAppUpdates =>
      installTarget == platform.UpdateInstallTarget.androidApk ||
      installTarget == platform.UpdateInstallTarget.windowsZip ||
      installTarget == platform.UpdateInstallTarget.linuxZip ||
      installTarget == platform.UpdateInstallTarget.macosZip;

  bool get isDesktopZipTarget =>
      installTarget == platform.UpdateInstallTarget.windowsZip ||
      installTarget == platform.UpdateInstallTarget.linuxZip ||
      installTarget == platform.UpdateInstallTarget.macosZip;

  Future<PackageInfo> currentPackage() => PackageInfo.fromPlatform();

  Future<UpdateChannel> resolveChannel() async {
    if (_channelOverride != null) {
      _resolvedChannel = _channelOverride;
      return _channelOverride!;
    }
    if (_resolvedChannel != null) return _resolvedChannel!;

    const baked = String.fromEnvironment(
      UpdateChannel.envKey,
      defaultValue: '',
    );
    if (baked.trim().isNotEmpty) {
      _resolvedChannel = UpdateChannel.parse(baked);
      return _resolvedChannel!;
    }

    final info = await currentPackage();
    if (info.packageName.endsWith('.dev')) {
      _resolvedChannel = UpdateChannel.dev;
    } else {
      _resolvedChannel = UpdateChannel.stable;
    }
    return _resolvedChannel!;
  }

  Future<int> currentVersionCode() async {
    final info = await currentPackage();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  Future<String> userAgent() async {
    await resolveChannel();
    final info = await currentPackage();
    final build = info.buildNumber.trim();
    final version = build.isEmpty ? info.version : '${info.version}+$build';
    return 'JAVP/$version (${platform.platformLabel}; ${channel.id})';
  }

  Future<AppUpdateInfo?> fetchLatest() async {
    await resolveChannel();
    final url = manifestUrl;
    final response = await _http.get(
      Uri.parse(url),
      headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
        'User-Agent': await userAgent(),
      },
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) {
      throw platform.httpException(
        'Update check failed (${response.statusCode})',
        Uri.parse(url),
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Update manifest is not a JSON object');
    }
    return AppUpdateInfo.fromJson(decoded);
  }

  Future<AppUpdateInfo?> checkForUpdate({bool ignoreSkipped = false}) async {
    if (!supportsInAppUpdates) return null;

    final latest = await fetchLatest();
    if (latest == null) return null;

    switch (installTarget) {
      case platform.UpdateInstallTarget.windowsZip:
      case platform.UpdateInstallTarget.linuxZip:
      case platform.UpdateInstallTarget.macosZip:
        if (latest.resolvePackage(preferredKeys: preferredPackages) == null) {
          return null;
        }
      case platform.UpdateInstallTarget.androidApk:
        if (latest.apkUrl.isEmpty && latest.apks.isEmpty) return null;
      case platform.UpdateInstallTarget.unsupported:
        return null;
    }

    final currentCode = await currentVersionCode();
    if (!latest.isNewerThan(currentVersionCode: currentCode)) return null;

    if (installTarget == platform.UpdateInstallTarget.windowsZip &&
        await _packageAlreadyApplied(latest)) {
      return null;
    }

    if (!ignoreSkipped &&
        !latest.isRequiredFor(currentVersionCode: currentCode)) {
      final skipped = await skippedVersionCode();
      if (skipped == latest.versionCode) return null;
    }
    return latest;
  }

  Future<bool> _packageAlreadyApplied(AppUpdateInfo latest) async {
    final pkg = latest.resolvePackage(preferredKeys: preferredPackages);
    final expected = pkg?.sha256?.trim().toLowerCase();
    if (expected == null || expected.isEmpty) return false;
    return platform.checkAppliedStamp(
      stampPath: appliedPackageStampPath ?? '',
      expectedSha256: expected,
    );
  }

  Future<void> markCheckedNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<bool> shouldAutoCheck({
    Duration interval = const Duration(hours: 12),
  }) async {
    if (!supportsInAppUpdates) return false;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastCheckKey);
    if (last == null) return true;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed >= interval.inMilliseconds;
  }

  Future<int?> skippedVersionCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_skippedCodeKey);
  }

  Future<void> skipVersion(int versionCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_skippedCodeKey, versionCode);
  }

  Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_skippedCodeKey);
  }

  Future<void> rememberDownloadedPackage({
    required int versionCode,
    required dynamic file,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedPackagePathKey, platform.getFilePath(file));
    await prefs.setInt(_cachedPackageCodeKey, versionCode);
  }

  Future<void> clearDownloadedPackage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedPackagePathKey);
    await prefs.remove(_cachedPackageCodeKey);
  }

  Future<dynamic> cachedDownloadedPackage(int versionCode) async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getInt(_cachedPackageCodeKey);
    final path = prefs.getString(_cachedPackagePathKey)?.trim();
    if (code != versionCode || path == null || path.isEmpty) return null;
    return platform.getCachedFile(path);
  }

  Future<dynamic> downloadUpdate(
    AppUpdateInfo update, {
    DownloadProgress? onProgress,
  }) async {
    return platform.downloadUpdate(
      update: update,
      installTarget: installTarget,
      preferredAbis: preferredAbis,
      preferredPackages: preferredPackages,
      userAgent: await userAgent(),
      client: _http,
      onProgress: onProgress,
    );
  }

  Future<void> installUpdate(dynamic downloaded) async {
    await platform.installUpdate(
      downloaded: downloaded,
      installTarget: installTarget,
    );
  }

  void close() => _http.close();
}
