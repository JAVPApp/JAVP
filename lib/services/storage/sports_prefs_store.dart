import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:javp/services/diagnostics/log_redactor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-global TheSportsDB API key. Follow lists live in [LibraryStore]
/// so they stay per-profile and ride along with Drive / WebDAV sync.
class SportsPrefsStore {
  SportsPrefsStore({FlutterSecureStorage? secureStorage})
    : _secure = secureStorage ?? const FlutterSecureStorage();

  static const _apiKeySecure = 'sports_thesportsdb_api_key';
  static const _legacyPrefsKey = 'sports_prefs_v1';

  final FlutterSecureStorage _secure;

  Future<String> loadApiKey() async {
    try {
      final apiKey = (await _secure.read(key: _apiKeySecure))?.trim() ?? '';
      if (apiKey.isNotEmpty) {
        LogRedactor.instance.registerSecrets([apiKey]);
        return apiKey;
      }
    } catch (_) {}
    // Older builds stored the key in the plaintext prefs blob.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_legacyPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final key = (decoded['apiKey'] as String?)?.trim() ?? '';
          if (key.isNotEmpty) {
            LogRedactor.instance.registerSecrets([key]);
            await saveApiKey(key);
            return key;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  Future<void> saveApiKey(String apiKey) async {
    final trimmed = apiKey.trim();
    if (trimmed.isNotEmpty) {
      await _secure.write(key: _apiKeySecure, value: trimmed);
      LogRedactor.instance.registerSecrets([trimmed]);
    } else {
      await _secure.delete(key: _apiKeySecure);
    }
  }
}
