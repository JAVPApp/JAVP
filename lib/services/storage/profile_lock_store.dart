import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:javp/services/storage/pin_hash.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local PIN that gates opening a profile.
///
/// The hash lives in [FlutterSecureStorage] and is never written to sync
/// snapshots. A prefs flag lets the lock overlay paint before secure storage
/// is read.
class ProfileLockStore {
  ProfileLockStore({
    FlutterSecureStorage? secureStorage,
    SharedPreferences? prefs,
  })  : _secure = secureStorage ?? const FlutterSecureStorage(),
        _prefsOverride = prefs;

  final FlutterSecureStorage _secure;
  final SharedPreferences? _prefsOverride;

  static const _pinKeySuffix = 'lock_pin_v1';
  static const _flagKeySuffix = 'has_lock_pin';

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  String _pinKey(String profileId) => 'profile.$profileId.$_pinKeySuffix';
  String _flagKey(String profileId) => 'profile.$profileId.$_flagKeySuffix';

  /// Prefs-only: which of [profileIds] have a lock PIN on this device.
  Future<Set<String>> loadLockedIds(Iterable<String> profileIds) async {
    final prefs = await _prefs();
    return {
      for (final id in profileIds)
        if (prefs.getBool(_flagKey(id)) == true) id,
    };
  }

  Future<bool> hasPin(String profileId) async {
    final prefs = await _prefs();
    if (prefs.getBool(_flagKey(profileId)) == true) return true;
    final raw = await _secure.read(key: _pinKey(profileId));
    return raw != null && raw.isNotEmpty;
  }

  Future<void> setPin(String profileId, String pin) async {
    await _secure.write(key: _pinKey(profileId), value: await PinHash.encode(pin));
    final prefs = await _prefs();
    await prefs.setBool(_flagKey(profileId), true);
  }

  Future<bool> verifyPin(String profileId, String pin) async {
    final raw = await _secure.read(key: _pinKey(profileId));
    if (raw == null || raw.isEmpty) return false;
    return PinHash.verify(pin, raw);
  }

  Future<void> clearPin(String profileId) async {
    await _secure.delete(key: _pinKey(profileId));
    final prefs = await _prefs();
    await prefs.remove(_flagKey(profileId));
  }
}
