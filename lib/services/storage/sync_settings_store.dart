import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/services/diagnostics/log_redactor.dart';

/// Per-profile sync configuration.
///
/// Kept in secure storage because WebDAV passwords and Google tokens can live
/// here. Each profile on this device can point at a different folder / WebDAV
/// / Drive account. A legacy device-level `sync_settings` key is copied onto
/// existing profiles once so upgrades keep syncing.
class SyncSettingsStore {
  SyncSettingsStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  static const legacyKey = 'sync_settings';

  final FlutterSecureStorage _secure;

  String _key(String profileId) => 'profile.$profileId.sync_settings';

  Future<SyncSettings> load(String profileId) async {
    try {
      final raw = await _secure.read(key: _key(profileId));
      if (raw != null && raw.isNotEmpty) {
        return _decode(raw);
      }
      final legacy = await _secure.read(key: legacyKey);
      if (legacy != null && legacy.isNotEmpty) {
        await _secure.write(key: _key(profileId), value: legacy);
        return _decode(legacy);
      }
      return SyncSettings.disabled;
    } catch (_) {
      return SyncSettings.disabled;
    }
  }

  /// Copies the pre-per-profile key onto every [profileIds] entry that has no
  /// own settings yet, then drops the legacy key.
  Future<void> migrateLegacy(Iterable<String> profileIds) async {
    try {
      final legacy = await _secure.read(key: legacyKey);
      if (legacy == null || legacy.isEmpty) return;
      for (final id in profileIds) {
        final existing = await _secure.read(key: _key(id));
        if (existing == null || existing.isEmpty) {
          await _secure.write(key: _key(id), value: legacy);
        }
      }
      await _secure.delete(key: legacyKey);
    } catch (_) {
      // Secure storage unavailable — load() still falls back to the legacy key.
    }
  }

  Future<void> save(String profileId, SyncSettings settings) async {
    await _secure.write(
      key: _key(profileId),
      value: jsonEncode(settings.toJson()),
    );
  }

  Future<void> delete(String profileId) async {
    try {
      await _secure.delete(key: _key(profileId));
    } catch (_) {}
  }

  SyncSettings _decode(String raw) {
    final settings = SyncSettings.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    LogRedactor.instance.registerSecrets([
      settings.password,
      settings.googleClientSecret,
      settings.googleAccessToken,
      settings.googleRefreshToken,
    ]);
    return settings;
  }
}
