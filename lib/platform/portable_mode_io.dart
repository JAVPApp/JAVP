import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

/// Test override. `true` / `false` skips detection; `null` uses env + marker.
bool? debugPortableOverride;

/// Test override for `JAVP_PORTABLE` and install-dir env (LOCALAPPDATA, …).
Map<String, String>? debugPortableEnvOverride;

/// Test override for the directory that contains the executable.
String? debugPortableExeDirectoryOverride;

void debugResetPortableMode() {
  debugPortableOverride = null;
  debugPortableEnvOverride = null;
  debugPortableExeDirectoryOverride = null;
  _enabled = false;
}

bool _enabled = false;

/// Whether this process redirected app data next to the executable.
bool get isPortableMode => _enabled;

const _falsey = {'0', 'false', 'no', 'off'};
const _truthy = {'1', 'true', 'yes', 'on'};

/// Inno Setup default: `%LOCALAPPDATA%\Programs\JAVP`.
///
/// The in-app updater overlays the portable zip onto that folder, including
/// the `portable` marker. Install-dir always wins so the setup.exe app keeps
/// using AppData.
String _canonWin(String path) {
  var value = path.trim().replaceAll('\\', '/').toLowerCase();
  while (value.contains('//')) {
    value = value.replaceAll('//', '/');
  }
  if (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

bool looksLikeWindowsInstallDir(String exeDirectory, Map<String, String> env) {
  final dir = _canonWin(exeDirectory);
  if (dir.contains('/windowsapps/')) return true;

  final localAppData = env['LOCALAPPDATA']?.trim();
  if (localAppData != null && localAppData.isNotEmpty) {
    final installed = _canonWin('$localAppData/Programs/JAVP');
    if (dir == installed) return true;
  }

  for (final key in ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432']) {
    final root = env[key]?.trim();
    if (root == null || root.isEmpty) continue;
    final prefix = _canonWin(root);
    final under = dir == prefix || dir.startsWith('$prefix/');
    if (under && dir.split('/').last == 'javp') return true;
  }
  return false;
}

String portableDataRoot(String exeDirectory) => p.join(exeDirectory, 'data');

String portableMarkerPath(String exeDirectory) =>
    p.join(exeDirectory, 'portable');

bool resolvePortableMode({
  required Map<String, String> env,
  required String exeDirectory,
  bool Function(String path)? fileExists,
}) {
  final exists = fileExists ?? (path) => File(path).existsSync();
  // Windows install layout, even when this helper is unit-tested on Linux.
  if (looksLikeWindowsInstallDir(exeDirectory, env)) {
    return false;
  }
  final raw = env['JAVP_PORTABLE']?.trim().toLowerCase();
  if (raw != null && raw.isNotEmpty) {
    if (_falsey.contains(raw)) return false;
    if (_truthy.contains(raw)) return true;
  }
  return exists(portableMarkerPath(exeDirectory)) ||
      exists(p.join(exeDirectory, 'portable.txt'));
}

/// Redirects [path_provider] (and Windows SharedPreferences) into `data/`.
void registerPortablePathProviderIfNeeded() {
  if (kIsWeb) return;
  if (debugPortableOverride == false) {
    _enabled = false;
    return;
  }

  final env = debugPortableEnvOverride ?? Platform.environment;
  final exeDir =
      debugPortableExeDirectoryOverride ??
      File(Platform.resolvedExecutable).parent.path;
  final enabled =
      debugPortableOverride ??
      resolvePortableMode(env: env, exeDirectory: exeDir);
  _enabled = enabled;
  if (!enabled) return;

  final portable = PortablePathProvider(portableDataRoot(exeDir));
  PathProviderPlatform.instance = portable;
  _retargetWindowsSharedPreferences(portable);
}

void _retargetWindowsSharedPreferences(PortablePathProvider portable) {
  if (!Platform.isWindows) return;
  final store = SharedPreferencesStorePlatform.instance;
  if (store is SharedPreferencesWindows) {
    // The plugin keeps its own PathProviderWindows and does not read
    // PathProviderPlatform.instance. This field is the supported hook.
    // ignore: invalid_use_of_visible_for_testing_member
    store.pathProvider = PortableWindowsPathProvider(portable);
  }
}

/// [path_provider] paths under `<exe>/data/…`.
class PortablePathProvider extends PathProviderPlatform {
  PortablePathProvider(this.root);

  final String root;

  Future<String> _ensure(String sub) async {
    final dir = Directory(p.join(root, sub));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  @override
  Future<String?> getTemporaryPath() => _ensure('tmp');

  @override
  Future<String?> getApplicationSupportPath() => _ensure('support');

  @override
  Future<String?> getApplicationDocumentsPath() => _ensure('documents');

  @override
  Future<String?> getApplicationCachePath() => _ensure('cache');

  @override
  Future<String?> getLibraryPath() => _ensure('library');

  @override
  Future<String?> getDownloadsPath() => _ensure('downloads');

  @override
  Future<String?> getExternalStoragePath() => _ensure('documents');

  @override
  Future<List<String>?> getExternalCachePaths() async => [await _ensure('cache')];

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [await _ensure('documents')];
}

/// [SharedPreferencesWindows] keeps its own [PathProviderWindows], not the
/// [PathProviderPlatform.instance] used by `package:path_provider`.
class PortableWindowsPathProvider extends PathProviderWindows {
  PortableWindowsPathProvider(this._inner);

  final PortablePathProvider _inner;

  @override
  Future<String?> getTemporaryPath() => _inner.getTemporaryPath();

  @override
  Future<String?> getApplicationSupportPath() =>
      _inner.getApplicationSupportPath();

  @override
  Future<String?> getApplicationDocumentsPath() =>
      _inner.getApplicationDocumentsPath();

  @override
  Future<String?> getApplicationCachePath() => _inner.getApplicationCachePath();

  @override
  Future<String?> getDownloadsPath() => _inner.getDownloadsPath();
}
