import 'dart:convert';

import 'package:javp/models/profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Device-global profile registry.
///
/// These keys are deliberately never namespaced by profile — they are what
/// tells the app which namespace to use in the first place.
class ProfileStore {
  ProfileStore({SharedPreferences? prefs}) {
    _prefs = prefs;
  }

  static const _profilesKey = 'profiles';
  static const _activeProfileKey = 'active_profile_id';
  static const _deviceIdKey = 'sync_device_id';
  static const _uuid = Uuid();

  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensurePrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Always returns at least the default profile, creating it on first run.
  Future<List<Profile>> loadProfiles() async {
    final prefs = await _ensurePrefs();
    final raw = prefs.getString(_profilesKey);
    final profiles = <Profile>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final profile =
                Profile.tryFromJson(Map<String, dynamic>.from(entry));
            if (profile != null) profiles.add(profile);
          }
        }
      } catch (_) {
        // Corrupt registry falls back to a fresh default below.
      }
    }
    if (profiles.every((p) => !p.isDefault)) {
      profiles.insert(
        0,
        Profile(
          id: Profile.defaultId,
          name: 'Me',
          createdAt: DateTime.now(),
        ),
      );
    }
    return profiles;
  }

  Future<void> saveProfiles(List<Profile> profiles) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(
      _profilesKey,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<Profile> createProfile(String name) async {
    final profiles = await loadProfiles();
    final profile = Profile(
      id: _uuid.v4(),
      name: name.trim().isEmpty ? 'Profile ${profiles.length + 1}' : name.trim(),
      createdAt: DateTime.now(),
    );
    await saveProfiles([...profiles, profile]);
    return profile;
  }

  /// Removes a profile from the registry. The default profile cannot be
  /// deleted; callers are responsible for clearing its namespaced data.
  Future<List<Profile>> deleteProfile(String id) async {
    if (id == Profile.defaultId) return loadProfiles();
    final profiles = await loadProfiles();
    final remaining = profiles.where((p) => p.id != id).toList();
    await saveProfiles(remaining);
    if (await loadActiveProfileId() == id) {
      await saveActiveProfileId(Profile.defaultId);
    }
    return remaining;
  }

  Future<String> loadActiveProfileId() async {
    final prefs = await _ensurePrefs();
    return _resolveActiveProfileId(
      prefs.getString(_activeProfileKey),
      await loadProfiles(),
    );
  }

  /// Everything the app must know before the first frame, from one decode.
  ///
  /// [loadActiveProfileId] validates the stored id against the registry, so
  /// asking for the list and the active id separately parses it twice — on the
  /// critical path, before anything has been painted.
  Future<({List<Profile> profiles, String activeProfileId, String deviceId})>
      loadBootstrap() async {
    final prefs = await _ensurePrefs();
    final profiles = await loadProfiles();
    return (
      profiles: profiles,
      activeProfileId: _resolveActiveProfileId(
        prefs.getString(_activeProfileKey),
        profiles,
      ),
      deviceId: await deviceId(),
    );
  }

  static String _resolveActiveProfileId(String? stored, List<Profile> profiles) {
    final id = stored?.trim();
    if (id == null || id.isEmpty) return Profile.defaultId;
    if (!profiles.any((p) => p.id == id)) return Profile.defaultId;
    return id;
  }

  Future<void> saveActiveProfileId(String id) async {
    final prefs = await _ensurePrefs();
    await prefs.setString(_activeProfileKey, id);
  }

  /// Stable per-install id, used to attribute snapshot writes.
  Future<String> deviceId() async {
    final prefs = await _ensurePrefs();
    final existing = prefs.getString(_deviceIdKey)?.trim();
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _uuid.v4();
    await prefs.setString(_deviceIdKey, id);
    return id;
  }
}
