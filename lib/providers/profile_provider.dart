import 'dart:async';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/storage/profile_avatar_store.dart';
import 'package:javp/services/storage/profile_lock_store.dart';
import 'package:javp/services/storage/profile_store.dart';
import 'package:javp/services/storage/sync_settings_store.dart';
import 'package:javp/services/sync/profile_sync_service.dart';
import 'package:javp/services/sync/sync_remote.dart';
import 'package:javp/services/ui/persist_after_frame.dart';

enum SyncStatus { idle, running, ok, failed }

/// Owns the profile list, which one is active, per-profile sync, and lock PINs.
///
/// Each profile writes one small file into *its* configured backend. Automatic
/// sync (when that profile's toggle is on) runs on open/resume and after local
/// changes (Drive apply/reload waits until playback ends; push still runs).
class ProfileProvider extends ChangeNotifier {
  ProfileProvider({
    ProfileStore? profileStore,
    SyncSettingsStore? syncSettingsStore,
    ProfileAvatarStore? avatarStore,
    ProfileLockStore? lockStore,
  }) : _profiles = profileStore ?? ProfileStore(),
       _syncSettings = syncSettingsStore ?? SyncSettingsStore(),
       _avatars = avatarStore ?? ProfileAvatarStore(),
       _locks = lockStore ?? ProfileLockStore();

  final ProfileStore _profiles;
  final SyncSettingsStore _syncSettings;
  final ProfileAvatarStore _avatars;
  final ProfileLockStore _locks;
  Future<void> _avatarMutation = Future<void>.value();
  final Map<String, int> _avatarRevisions = {};

  List<Profile> profiles = const [];
  Profile? activeProfile;
  SyncSettings syncSettings = SyncSettings.disabled;
  final Map<String, SyncSettings> _syncByProfile = {};
  Set<String> lockedProfileIds = {};
  bool profileUnlocked = true;
  SyncStatus syncStatus = SyncStatus.idle;
  SyncPhase? syncPhase;
  DateTime? lastSyncAt;
  String? syncError;

  /// Sections written by the last successful [syncNow] (for slim reload).
  List<String> lastChangedSections = const [];
  bool ready = false;

  String _deviceId = '';

  ProfileAvatarStore get avatars => _avatars;
  int avatarRevision(String profileId) => _avatarRevisions[profileId] ?? 0;

  void _bumpAvatarRevision(String profileId) {
    _avatarRevisions[profileId] = avatarRevision(profileId) + 1;
  }

  bool get hasMultipleProfiles => profiles.length > 1;
  String get activeProfileId => activeProfile?.id ?? Profile.defaultId;
  bool get isActiveProfileLocked => isProfileLocked(activeProfileId);
  bool get needsProfileUnlock => isActiveProfileLocked && !profileUnlocked;

  /// Open / resume / local-change sync when the toggle is on.
  bool get autoSyncEnabled =>
      syncSettings.syncOnOpen && syncSettings.isConfigured;

  bool isProfileLocked(String id) => lockedProfileIds.contains(id);

  SyncSettings syncSettingsFor(String profileId) =>
      _syncByProfile[profileId] ?? SyncSettings.disabled;

  /// Prefs-only, and awaited before the first frame: the app can't build a
  /// library until it knows whose data to open. Lock flags are prefs too so
  /// the unlock overlay can paint without waiting on secure storage.
  Future<void> bootstrap() async {
    final loaded = await _profiles.loadBootstrap();
    profiles = loaded.profiles;
    activeProfile = profiles.firstWhere(
      (p) => p.id == loaded.activeProfileId,
      orElse: () => profiles.first,
    );
    _deviceId = loaded.deviceId;
    lockedProfileIds = await _locks.loadLockedIds(profiles.map((p) => p.id));
    profileUnlocked = !isActiveProfileLocked;
    ready = true;
    notifyListeners();
  }

  /// Secure storage read, so it waits until after the first frame.
  Future<void> loadSyncSettings() async {
    await _syncSettings.migrateLegacy(profiles.map((p) => p.id));
    _syncByProfile.clear();
    for (final profile in profiles) {
      _syncByProfile[profile.id] = await _syncSettings.load(profile.id);
    }
    syncSettings = syncSettingsFor(activeProfileId);
    notifyListeners();
  }

  Future<Profile> createProfile(String name) async {
    final profile = await _profiles.createProfile(name);
    profiles = await _profiles.loadProfiles();
    _syncByProfile[profile.id] = SyncSettings.disabled;
    notifyListeners();
    return profile;
  }

  /// New profile on this device with sources already in its store.
  ///
  /// Used when a phone pairs into a TV: the current viewer stays on their
  /// profile; the guest lands as a separate identity.
  Future<Profile> createProfileWithSources({
    required String name,
    required List<IptvSource> sources,
  }) async {
    final profile = await createProfile(name);
    if (sources.isNotEmpty) {
      await LibraryStore(profileId: profile.id).saveSources(sources);
    }
    return profile;
  }

  Future<void> renameProfile(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    profiles = [
      for (final p in profiles) p.id == id ? p.copyWith(name: trimmed) : p,
    ];
    await _profiles.saveProfiles(profiles);
    if (activeProfile?.id == id) {
      activeProfile = profiles.firstWhere((p) => p.id == id);
    }
    notifyListeners();
  }

  /// Imports a device photo, downscales it, and stores it for [id].
  ///
  /// Returns false when [bytes] could not be decoded as an image.
  Future<bool> setProfilePhoto(String id, Uint8List bytes) =>
      _serializeAvatarMutation(() async {
        final encoded = await _avatars.save(id, bytes);
        if (encoded == null) return false;
        _bumpAvatarRevision(id);
        final token = sha1.convert(encoded).toString().substring(0, 12);
        final at = DateTime.now().toUtc();
        await _patchProfile(
          id,
          (p) => p.copyWith(avatarToken: token, avatarUpdatedAt: at),
        );
        return true;
      });

  /// Clears the custom photo. The clear stamp syncs so other devices drop it.
  Future<void> clearProfilePhoto(String id) =>
      _serializeAvatarMutation(() async {
        await _avatars.delete(id);
        _bumpAvatarRevision(id);
        final at = DateTime.now().toUtc();
        await _patchProfile(
          id,
          (p) => p.copyWith(clearAvatar: true, avatarUpdatedAt: at),
        );
      });

  Future<T> _serializeAvatarMutation<T>(Future<T> Function() action) {
    final result = _avatarMutation.then((_) => action());
    _avatarMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _applySyncedAvatar(String id, SyncOutcome outcome) {
    return _serializeAvatarMutation(() async {
      final current = profiles.firstWhereOrNull((p) => p.id == id);
      if (current == null ||
          current.avatarToken != outcome.avatarBaseToken ||
          current.avatarUpdatedAt?.toUtc() != outcome.avatarBaseUpdatedAt) {
        // The user changed/cleared the photo while sync was in flight. Keep
        // that edit; the next sync will publish it.
        return;
      }

      final at = outcome.avatarUpdatedAt?.toUtc();
      if (at == null) return;
      final photo = outcome.avatarPhoto?.trim() ?? '';
      if (photo.isEmpty) {
        await _avatars.delete(id);
        _bumpAvatarRevision(id);
        await _patchProfile(
          id,
          (p) => p.copyWith(clearAvatar: true, avatarUpdatedAt: at),
        );
        return;
      }

      final bytes = ProfileAvatarStore.tryDecodeBase64(photo);
      if (bytes == null || bytes.isEmpty) return;
      final token = sha1.convert(bytes).toString().substring(0, 12);
      final stored = await _avatars.load(id);
      if (!listEquals(stored, bytes)) {
        await _avatars.saveEncoded(id, bytes);
        _bumpAvatarRevision(id);
      }
      await _patchProfile(
        id,
        (p) => p.copyWith(avatarToken: token, avatarUpdatedAt: at),
      );
    });
  }

  Future<void> _patchProfile(
    String id,
    Profile Function(Profile) update,
  ) async {
    profiles = [for (final p in profiles) p.id == id ? update(p) : p];
    await _profiles.saveProfiles(profiles);
    if (activeProfile?.id == id) {
      activeProfile = profiles.firstWhere((p) => p.id == id);
    }
    notifyListeners();
  }

  /// Removes a profile and everything it owns on this device. The copy in the
  /// sync folder is left alone so another device can still restore it.
  Future<void> deleteProfile(String id) async {
    if (id == Profile.defaultId) return;
    await LibraryStore(profileId: id).deleteProfileData();
    await _avatars.delete(id);
    await _syncSettings.delete(id);
    await _locks.clearPin(id);
    _syncByProfile.remove(id);
    lockedProfileIds = {...lockedProfileIds}..remove(id);
    profiles = await _profiles.deleteProfile(id);
    if (activeProfile?.id == id) {
      final fallbackId = await _profiles.loadActiveProfileId();
      activeProfile = profiles.firstWhere(
        (p) => p.id == fallbackId,
        orElse: () => profiles.first,
      );
      syncSettings = syncSettingsFor(activeProfile!.id);
      profileUnlocked = !isActiveProfileLocked;
    }
    notifyListeners();
  }

  /// Records the switch. Rebuilding the library for the new profile is the
  /// app shell's job, since it owns the provider instances.
  ///
  /// Pass [sessionUnlocked] after a successful PIN check so a locked profile
  /// does not immediately re-show the overlay.
  Future<void> setActiveProfile(
    Profile profile, {
    bool sessionUnlocked = false,
  }) async {
    await _profiles.saveActiveProfileId(profile.id);
    activeProfile = profile;
    lastSyncAt = null;
    syncStatus = SyncStatus.idle;
    syncPhase = null;
    syncError = null;
    if (!_syncByProfile.containsKey(profile.id)) {
      _syncByProfile[profile.id] = await _syncSettings.load(profile.id);
    }
    syncSettings = syncSettingsFor(profile.id);
    profileUnlocked = sessionUnlocked || !isProfileLocked(profile.id);
    notifyListeners();
  }

  /// Call after a successful PIN check for the (new) active profile.
  void markProfileUnlocked() {
    if (profileUnlocked) return;
    profileUnlocked = true;
    notifyListeners();
  }

  Future<bool> verifyLockPin(String profileId, String pin) =>
      _locks.verifyPin(profileId, pin);

  Future<void> setLockPin(String profileId, String pin) async {
    await _locks.setPin(profileId, pin);
    lockedProfileIds = {...lockedProfileIds, profileId};
    if (profileId == activeProfileId) profileUnlocked = true;
    notifyListeners();
  }

  Future<bool> changeLockPin({
    required String profileId,
    required String currentPin,
    required String newPin,
  }) async {
    if (!await _locks.verifyPin(profileId, currentPin)) return false;
    await _locks.setPin(profileId, newPin);
    lockedProfileIds = {...lockedProfileIds, profileId};
    if (profileId == activeProfileId) profileUnlocked = true;
    notifyListeners();
    return true;
  }

  Future<bool> clearLockPin(String profileId, String currentPin) async {
    if (!await _locks.verifyPin(profileId, currentPin)) return false;
    await _locks.clearPin(profileId);
    lockedProfileIds = {...lockedProfileIds}..remove(profileId);
    if (profileId == activeProfileId) profileUnlocked = true;
    notifyListeners();
    return true;
  }

  Future<void> updateSyncSettings(SyncSettings settings) async {
    await updateSyncSettingsFor(activeProfileId, settings);
  }

  Future<void> updateSyncSettingsFor(
    String profileId,
    SyncSettings settings,
  ) async {
    _syncByProfile[profileId] = settings;
    if (profileId == activeProfileId) {
      syncSettings = settings;
      // Settings switch paints optimistically; defer fan-out off settle vsync.
      SchedulerBinding.instance.scheduleTask(() {
        notifyListeners();
      }, Priority.idle);
    } else {
      notifyListeners();
    }
    await persistAfterFrame(() => _syncSettings.save(profileId, settings));
  }

  /// Verifies a target is reachable before saving it.
  ///
  /// Pass [requireWrite]: false for restore/import — listing profiles only
  /// needs read access (Android often blocks the write probe on picked folders).
  Future<String?> testConnection(
    SyncSettings settings, {
    bool requireWrite = true,
  }) async {
    final remote = _openRemote(settings);
    if (remote == null) return 'Sync is not configured yet.';
    try {
      await remote.probe(requireWrite: requireWrite);
      return null;
    } on SyncRemoteException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    } finally {
      remote.close();
    }
  }

  Future<bool>? _inFlight;

  /// Pulls, merges, and pushes the active profile.
  ///
  /// Returns true when the local store changed, which means the caller should
  /// reload the library to show it.
  ///
  /// Only one sync runs at a time: sync-on-open and a tap on "Sync now" would
  /// otherwise race each other through the same storage.
  Future<bool> syncNow({bool applyLocal = true}) {
    return _inFlight ??= _sync(
      applyLocal: applyLocal,
    ).whenComplete(() => _inFlight = null);
  }

  SyncRemote? _openRemote([SyncSettings? settings]) {
    final target = settings ?? syncSettings;
    final bindToActive = settings == null;
    final profileId = activeProfileId;
    return target.createRemote(
      onAuthRefresh: bindToActive
          ? (updated) {
              _syncByProfile[profileId] = updated;
              syncSettings = updated;
              unawaited(_syncSettings.save(profileId, updated));
            }
          : null,
    );
  }

  Future<bool> _sync({bool applyLocal = true}) async {
    final profile = activeProfile;
    final remote = _openRemote();
    if (profile == null || remote == null) return false;

    syncStatus = SyncStatus.running;
    syncPhase = SyncPhase.downloading;
    syncError = null;
    lastChangedSections = const [];
    // Banner is IgnorePointer + optional; never AbsorbPointer / wait cursor.
    notifyListeners();

    try {
      final service = ProfileSyncService(
        store: LibraryStore(profileId: profile.id),
        profile: profile,
        deviceId: _deviceId,
        avatarStore: _avatars,
        currentProfile: () =>
            profiles.firstWhereOrNull((p) => p.id == profile.id) ?? profile,
      );
      final outcome = await service.sync(
        remote,
        applyLocal: applyLocal,
        onProgress: (phase) {
          if (syncPhase == phase) return;
          syncPhase = phase;
          // Phase label only — schedule off the critical vsync so Accueil
          // scroll/input aren't fighting banner rebuilds mid-frame.
          SchedulerBinding.instance.scheduleTask(() {
            notifyListeners();
          }, Priority.animation);
        },
      );
      lastSyncAt = outcome.at;
      lastChangedSections = List<String>.unmodifiable(outcome.changedSections);
      if (outcome.avatarChanged) {
        await _applySyncedAvatar(profile.id, outcome);
      }
      syncStatus = SyncStatus.ok;
      syncPhase = null;
      notifyListeners();
      return outcome.changedSections.isNotEmpty;
    } on SyncRemoteException catch (e) {
      syncError = e.message;
      syncStatus = SyncStatus.failed;
      syncPhase = null;
      notifyListeners();
      return false;
    } catch (e) {
      syncError = '$e';
      syncStatus = SyncStatus.failed;
      syncPhase = null;
      notifyListeners();
      return false;
    } finally {
      remote.close();
    }
  }

  /// Profiles present on a sync target.
  ///
  /// Setting up a second device usually means picking a profile this device
  /// already has an (empty) copy of — every install starts with the same
  /// default profile id — so [includeKnown] exists for the restore flow.
  /// Pass [settings] to list a target other than the active profile's.
  Future<List<RemoteProfileEntry>> discoverRemoteProfiles({
    bool includeKnown = false,
    SyncSettings? settings,
  }) async {
    final remote = _openRemote(settings);
    if (remote == null) return const [];
    try {
      final found = await ProfileSyncService.listRemoteProfiles(remote);
      if (includeKnown) return found;
      final known = profiles.map((p) => p.id).toSet();
      return found.where((e) => !known.contains(e.profileId)).toList();
    } finally {
      remote.close();
    }
  }

  /// Adds a profile that already exists on a sync target. Its data arrives
  /// on the next sync. Returns the existing profile when this device already
  /// has one under that id.
  ///
  /// When [targetSettings] is passed, that target is stored on the adopted
  /// profile only — the active profile's backend is left alone.
  Future<Profile> adoptRemoteProfile(
    RemoteProfileEntry entry, {
    SyncSettings? targetSettings,
  }) async {
    final existing = profiles.where((p) => p.id == entry.profileId).firstOrNull;
    final profile =
        existing ??
        Profile(
          id: entry.profileId,
          name: entry.profileName,
          createdAt: DateTime.now(),
        );
    if (existing == null) {
      profiles = [...profiles, profile];
      await _profiles.saveProfiles(profiles);
    }
    if (targetSettings != null) {
      await updateSyncSettingsFor(profile.id, targetSettings);
    }
    notifyListeners();
    return profile;
  }
}
