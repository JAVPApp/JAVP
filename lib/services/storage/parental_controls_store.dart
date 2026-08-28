import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:javp/services/storage/pin_hash.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local parental controls for one profile.
///
/// PIN material stays in [FlutterSecureStorage] and is never written to profile
/// sync snapshots. Hidden Live category ids and source ids live in
/// SharedPreferences only.
class ParentalControlsStore {
  ParentalControlsStore({
    required this.profileId,
    FlutterSecureStorage? secureStorage,
    SharedPreferences? prefs,
  })  : _secure = secureStorage ?? const FlutterSecureStorage(),
        _prefsOverride = prefs;

  final String profileId;
  final FlutterSecureStorage _secure;
  final SharedPreferences? _prefsOverride;

  static const _pinKeySuffix = 'parental_pin_v1';
  static const _hiddenCatsKeySuffix = 'hidden_live_category_ids';
  static const _hiddenNamesKeySuffix = 'hidden_live_category_names';
  static const _hiddenSourcesKeySuffix = 'hidden_source_ids';
  static const _lockOnResumeKeySuffix = 'parental_lock_on_resume';
  static const _hideSourceAdultKeySuffix = 'parental_hide_source_adult';

  String get _keyPrefix => 'profile.$profileId.';

  String get _pinKey => '$_keyPrefix$_pinKeySuffix';
  String get _hiddenCatsKey => '$_keyPrefix$_hiddenCatsKeySuffix';
  String get _hiddenNamesKey => '$_keyPrefix$_hiddenNamesKeySuffix';
  String get _hiddenSourcesKey => '$_keyPrefix$_hiddenSourcesKeySuffix';
  String get _lockOnResumeKey => '$_keyPrefix$_lockOnResumeKeySuffix';
  String get _hideSourceAdultKey => '$_keyPrefix$_hideSourceAdultKeySuffix';

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  Future<bool> hasPin() async {
    final raw = await _secure.read(key: _pinKey);
    return raw != null && raw.isNotEmpty;
  }

  Future<void> setPin(String pin) async {
    await _secure.write(key: _pinKey, value: await PinHash.encode(pin));
  }

  Future<bool> verifyPin(String pin) async {
    final raw = await _secure.read(key: _pinKey);
    if (raw == null || raw.isEmpty) return false;
    return PinHash.verify(pin, raw);
  }

  Future<void> clearPin() async {
    await _secure.delete(key: _pinKey);
  }

  Future<List<String>> loadHiddenLiveCategoryIds() async {
    final prefs = await _prefs();
    return prefs.getStringList(_hiddenCatsKey) ?? const [];
  }

  Future<void> saveHiddenLiveCategoryIds(List<String> ids) async {
    final prefs = await _prefs();
    await prefs.setStringList(_hiddenCatsKey, ids);
  }

  /// Display names for hidden category ids (Live DB filters by group_name).
  Future<Map<String, String>> loadHiddenLiveCategoryNames() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_hiddenNamesKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveHiddenLiveCategoryNames(Map<String, String> names) async {
    final prefs = await _prefs();
    if (names.isEmpty) {
      await prefs.remove(_hiddenNamesKey);
      return;
    }
    await prefs.setString(_hiddenNamesKey, jsonEncode(names));
  }

  Future<List<String>> loadHiddenSourceIds() async {
    final prefs = await _prefs();
    return prefs.getStringList(_hiddenSourcesKey) ?? const [];
  }

  Future<void> saveHiddenSourceIds(List<String> ids) async {
    final prefs = await _prefs();
    await prefs.setStringList(_hiddenSourcesKey, ids);
  }

  Future<bool> loadLockOnResume() async {
    final prefs = await _prefs();
    return prefs.getBool(_lockOnResumeKey) ?? false;
  }

  Future<void> saveLockOnResume(bool value) async {
    final prefs = await _prefs();
    await prefs.setBool(_lockOnResumeKey, value);
  }

  /// When true (default), locked sessions also hide source-marked adult items.
  Future<bool> loadHideSourceAdult() async {
    final prefs = await _prefs();
    return prefs.getBool(_hideSourceAdultKey) ?? true;
  }

  Future<void> saveHideSourceAdult(bool value) async {
    final prefs = await _prefs();
    await prefs.setBool(_hideSourceAdultKey, value);
  }

  static String normalizePin(String pin) => PinHash.normalize(pin);

  static void assertPinShape(String pin) => PinHash.assertShape(pin);
}
