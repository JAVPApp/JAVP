import 'dart:convert';

import 'package:javp/compat/javp_compute.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/caption_style.dart';
import 'package:javp/models/display_settings.dart';
import 'package:javp/models/epg_reminder.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/library_collection.dart';
import 'package:javp/models/library_playlist.dart';
import 'package:javp/models/live_quality_mode.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/models/metadata_settings.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/models/sports_models.dart';
import 'package:javp/models/track_language_settings.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/storage/profile_avatar_store.dart';
import 'package:javp/services/sync/profile_snapshot.dart';
import 'package:javp/services/sync/sync_remote.dart';

/// A profile found in the sync folder.
class RemoteProfileEntry {
  const RemoteProfileEntry({
    required this.profileId,
    required this.profileName,
    required this.updatedAt,
    required this.deviceId,
  });

  final String profileId;
  final String profileName;
  final DateTime updatedAt;
  final String deviceId;
}

/// What a sync run did.
class SyncOutcome {
  const SyncOutcome({
    required this.pulled,
    required this.pushed,
    required this.at,
    this.changedSections = const [],
    this.avatarChanged = false,
    this.avatarUpdatedAt,
    this.avatarPhoto,
    this.avatarBaseToken,
    this.avatarBaseUpdatedAt,
  });

  /// A remote snapshot existed and was merged into this device.
  final bool pulled;

  /// The merged result was written back out.
  final bool pushed;
  final DateTime at;
  final List<String> changedSections;

  /// Profile photo file / registry meta changed on this device.
  final bool avatarChanged;
  final DateTime? avatarUpdatedAt;
  final String? avatarPhoto;

  /// Avatar metadata captured when this sync started. The provider compares
  /// these fields before applying the result so an in-flight local edit wins.
  final String? avatarBaseToken;
  final DateTime? avatarBaseUpdatedAt;
}

/// Coarse stages for profile sync UI. Indeterminate — byte-level Drive
/// progress isn't available without streaming the whole snapshot twice.
enum SyncPhase {
  downloading,
  readingLocal,
  merging,
  uploading,
  applyingLibrary,
  applyingPrefs,
}

/// Library-shaped sections vs preference sections (for apply progress).
const _librarySections = <String>{
  SnapshotSections.sources,
  SnapshotSections.categories,
  SnapshotSections.history,
  SnapshotSections.watchlist,
  SnapshotSections.favoriteChannels,
  SnapshotSections.favoriteCategories,
  SnapshotSections.recentChannels,
  SnapshotSections.preferredLiveQualities,
  SnapshotSections.preferredVodVariants,
  SnapshotSections.collections,
  SnapshotSections.playlists,
  SnapshotSections.epgReminders,
  SnapshotSections.trackerStatuses,
};

/// Reads and writes a profile's syncable state as a single file in whatever
/// folder the user pointed us at.
///
/// There is no server and nothing long-running: sync happens when the app asks
/// for it, and the only thing that has to be reachable is the file host.
class ProfileSyncService {
  ProfileSyncService({
    required this.store,
    required this.profile,
    required this.deviceId,
    ProfileAvatarStore? avatarStore,
    this.currentProfile,
  }) : avatarStore = avatarStore ?? ProfileAvatarStore();

  static const rootFolder = 'javp';
  static const profilesFolder = '$rootFolder/profiles';

  final LibraryStore store;
  final Profile profile;
  final String deviceId;
  final ProfileAvatarStore avatarStore;
  final Profile Function()? currentProfile;

  static String snapshotPath(String profileId) =>
      '$profilesFolder/$profileId.json';

  /// Per-section `{hash, updatedAt}` from the last time this device built or
  /// applied a snapshot. Comparing hashes is what lets us stamp only the
  /// sections that actually changed, instead of claiming every section is new
  /// on every run and stomping the other device's edits.
  ///
  /// Kept in memory for the duration of a run and only written to disk once
  /// that run lands something. A run that dies halfway must leave no stamps
  /// behind: they would tell the next run "this device has synced before", and
  /// its freshly stamped *empty* sections would then look newer than the real
  /// data already sitting in the folder.
  Map<String, _SectionStamp>? _stamps;

  Future<Map<String, _SectionStamp>> _loadStamps() async {
    final cached = _stamps;
    if (cached != null) return cached;
    final stamps = <String, _SectionStamp>{};
    final raw = await store.loadSyncState();
    if (raw == null || raw.isEmpty) return _stamps = stamps;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          final stamp = _SectionStamp.tryFromJson(
            Map<String, dynamic>.from(value),
          );
          if (stamp != null) stamps['${entry.key}'] = stamp;
        }
      }
    } catch (_) {
      stamps.clear();
    }
    return _stamps = stamps;
  }

  Future<void> _commitStamps() async {
    final stamps = _stamps;
    if (stamps == null) return;
    await store.saveSyncState(
      jsonEncode({for (final e in stamps.entries) e.key: e.value.toJson()}),
    );
  }

  /// Snapshot of this device's current state for [profile].
  ///
  /// [preloaded] lets a caller that has just read disk hand that read over
  /// instead of paying for a second one.
  Future<ProfileSnapshot> buildSnapshot({
    DateTime? now,
    Map<String, Object?>? preloaded,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    final data = preloaded ?? await _readSections();
    final stamps = await _loadStamps();
    final sections = <String, SnapshotSection>{};
    final nextStamps = <String, _SectionStamp>{};

    // jsonEncode + FNV over every section is CPU-heavy on large libraries —
    // keep it off the UI isolate so resume/sync doesn't trip Android ANRs.
    final hashes = await _hashSections(data);

    for (final name in SnapshotSections.all) {
      final value = data[name];
      final hash = hashes[name] ?? _hash(value);
      final previous = stamps[name];
      final updatedAt = previous != null && previous.hash == hash
          ? previous.updatedAt
          : at;
      sections[name] = SnapshotSection(updatedAt: updatedAt, data: value);
      nextStamps[name] = _SectionStamp(hash: hash, updatedAt: updatedAt);
    }
    _stamps = nextStamps;

    final newest = sections.values
        .map((s) => s.updatedAt)
        .fold<DateTime>(
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          (a, b) => b.isAfter(a) ? b : a,
        );

    final latestProfile = currentProfile?.call() ?? profile;
    String? avatarPhoto;
    var avatarAt = latestProfile.avatarUpdatedAt?.toUtc();
    if (avatarAt != null) {
      if (latestProfile.hasAvatar) {
        final bytes = await avatarStore.load(latestProfile.id);
        if (bytes == null || bytes.isEmpty) {
          // A missing/corrupt local file is not an intentional clear. Give the
          // remote copy a chance to restore it instead of publishing a clear.
          avatarAt = null;
        } else {
          avatarPhoto = ProfileAvatarStore.encodeBase64(bytes);
        }
      } else {
        avatarPhoto = '';
      }
    }

    return ProfileSnapshot(
      profileId: profile.id,
      profileName: profile.name,
      deviceId: deviceId,
      updatedAt: newest,
      sections: sections,
      avatarPhoto: avatarPhoto,
      avatarUpdatedAt: avatarAt,
    );
  }

  /// Writes a snapshot into this device's store.
  ///
  /// Callers must reload the provider afterwards — this only touches storage.
  Future<List<String>> applySnapshot(
    ProfileSnapshot snapshot, {
    Map<String, Object?>? preloaded,
    void Function(SyncPhase phase)? onProgress,
  }) async {
    final current = preloaded ?? await _readSections();
    final changed = <String>[];
    final stamps = await _loadStamps();

    final incomingByName = <String, Object?>{
      for (final name in SnapshotSections.all)
        if (snapshot.section(name) != null) name: snapshot.section(name)!.data,
    };
    // javpCompute: Isolate.run throws UnsupportedError on web (RawReceivePort).
    final hashes = await javpCompute(() {
      return <String, String>{
        for (final name in SnapshotSections.all) ...{
          'cur:$name': _hash(current[name]),
          if (incomingByName.containsKey(name))
            'in:$name': _hash(incomingByName[name]),
        },
      };
    }, debugLabel: 'sync-hash');
    await pumpUi();

    var announcedLibrary = false;
    var announcedPrefs = false;
    for (final name in SnapshotSections.all) {
      final section = snapshot.section(name);
      if (section == null) continue;
      final incoming = section.data;
      final inHash = hashes['in:$name'] ?? _hash(incoming);
      final curHash = hashes['cur:$name'] ?? _hash(current[name]);
      var needsWrite = inHash != curHash;
      // Coalesce fill-ins change the history wire hash without changing
      // playheads — rewriting prefs here hitches Accueil for no UI gain.
      if (needsWrite &&
          name == SnapshotSections.history &&
          !_historyPlayheadsOrTombstonesDiffer(current[name], incoming)) {
        needsWrite = false;
      }
      if (needsWrite) {
        final isLibrary = _librarySections.contains(name);
        if (isLibrary && !announcedLibrary) {
          announcedLibrary = true;
          await _announce(onProgress, SyncPhase.applyingLibrary);
        } else if (!isLibrary && !announcedPrefs) {
          announcedPrefs = true;
          await _announce(onProgress, SyncPhase.applyingPrefs);
        }
        await _writeSection(name, incoming);
        changed.add(name);
        // Keep Accueil / banner interactive across multi-section applies.
        await pumpUi();
      }
      stamps[name] = _SectionStamp(
        hash: needsWrite ? inHash : curHash,
        updatedAt: section.updatedAt,
      );
    }
    _stamps = stamps;
    await _commitStamps();
    return changed;
  }

  /// Pull, merge, push. Safe to call on app open and on the way out.
  ///
  /// The write is a compare-and-swap against the version we merged from, so a
  /// device that syncs the same profile at the same moment can't silently drop
  /// our push — we notice, re-merge against what they wrote, and try again.
  ///
  /// Local state is snapshotted *after* the remote read (and again before
  /// apply) so edits made while network I/O is in flight — e.g. adding a
  /// source — are not overwritten by a stale merge.
  Future<SyncOutcome> sync(
    SyncRemote remote, {
    DateTime? now,
    int maxAttempts = 4,
    void Function(SyncPhase phase)? onProgress,
    bool applyLocal = true,
  }) async {
    // Sync is the other half of the reported lag, and "it hung" is unactionable
    // without knowing whether the time went to the remote or to the merge.
    final watch = Stopwatch()..start();
    try {
      final outcome = await _sync(
        remote,
        now: now,
        maxAttempts: maxAttempts,
        onProgress: onProgress,
        applyLocal: applyLocal,
      );
      JavpLog.i(
        'sync',
        'done in ${watch.elapsedMilliseconds}ms '
            'pulled=${outcome.pulled} pushed=${outcome.pushed} '
            'changed=${outcome.changedSections.join(',')}',
      );
      return outcome;
    } catch (e) {
      JavpLog.w(
        'sync',
        'failed after ${watch.elapsedMilliseconds}ms',
        error: e,
      );
      rethrow;
    }
  }

  /// Let ProfileSyncBanner / Accueil paint the new phase before the next
  /// CPU or network chunk (otherwise Téléchargement→Envoi→Application feels
  /// frozen while isolate work runs with the old label).
  static Future<void> _announce(
    void Function(SyncPhase phase)? onProgress,
    SyncPhase phase,
  ) async {
    onProgress?.call(phase);
    await Future<void>.delayed(const Duration(milliseconds: 24));
  }

  Future<SyncOutcome> _sync(
    SyncRemote remote, {
    DateTime? now,
    int maxAttempts = 4,
    void Function(SyncPhase phase)? onProgress,
    bool applyLocal = true,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();
    // Every run starts from what is actually on disk. A run that died before
    // committing must not leave its stamps behind in memory either, or a retry
    // would think this device had synced before.
    _stamps = null;
    // Read before the first build, which is what fills the stamps in.
    final neverSynced = (await _loadStamps()).isEmpty;
    final path = snapshotPath(profile.id);

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final phase = Stopwatch()..start();
      await _announce(onProgress, SyncPhase.downloading);
      final current = await remote.readWithRevision(path);
      final readMs = phase.elapsedMilliseconds;

      // Capture disk *after* the slow remote round-trip so mid-sync UI edits
      // are included in the merge instead of being clobbered on apply.
      phase.reset();
      await _announce(onProgress, SyncPhase.readingLocal);
      final local = await buildSnapshot(now: now ?? DateTime.now().toUtc());
      // Section hashes at capture time — cheap drift check after upload.
      final localHashes = <String, String>{
        for (final e in (_stamps ?? const {}).entries) e.key: e.value.hash,
      };
      final buildMs = phase.elapsedMilliseconds;
      final remoteSnapshot = current.contents == null
          ? null
          : await _decodeSnapshot(current.contents!);

      if (current.exists && remoteSnapshot == null) {
        await _preserveDamaged(remote, current.contents!, at);
      }

      final usable =
          remoteSnapshot != null && remoteSnapshot.profileId == profile.id
          ? remoteSnapshot
          : null;

      if (usable == null) {
        phase.reset();
        final encoded = await _encodeSnapshot(local);
        final encodeMs = phase.elapsedMilliseconds;
        phase.reset();
        await _announce(onProgress, SyncPhase.uploading);
        final ok = await remote.writeIfUnchanged(
          path,
          encoded,
          expectedRevision: current.revision,
        );
        final writeMs = phase.elapsedMilliseconds;
        JavpLog.i(
          'sync',
          'attempt=$attempt mode=seedEmpty '
              'readMs=$readMs buildMs=$buildMs mergeMs=0 '
              'encodeMs=$encodeMs writeMs=$writeMs applyMs=0 '
              'bytes=${encoded.length} sections=${local.sections.length}',
        );
        if (!ok) continue;
        await _commitStamps();
        return _outcome(
          pulled: false,
          pushed: true,
          at: at,
          snapshot: local,
          local: local,
        );
      }

      final mode = _modeFor(neverSynced: neverSynced, local: local);
      phase.reset();
      await _announce(onProgress, SyncPhase.merging);
      final merged = await _mergeAsync(mode, local, usable);
      final mergeMs = phase.elapsedMilliseconds;
      phase.reset();
      final mergedJson = await _encodeSnapshot(merged);
      final encodeMs = phase.elapsedMilliseconds;

      if (mergedJson == current.contents) {
        phase.reset();
        final changed = await _applyOrSkip(
          merged,
          local: local,
          remote: usable,
          mode: mode,
          localHashes: localHashes,
          onProgress: onProgress,
          applyLocal: applyLocal,
        );
        final applyMs = phase.elapsedMilliseconds;
        JavpLog.i(
          'sync',
          'attempt=$attempt mode=${mode.name} '
              'readMs=$readMs buildMs=$buildMs mergeMs=$mergeMs '
              'encodeMs=$encodeMs writeMs=0 applyMs=$applyMs '
              'bytes=${mergedJson.length} sections=${merged.sections.length}',
        );
        if (changed == null) continue;
        return _outcome(
          pulled: true,
          pushed: false,
          at: at,
          changedSections: changed,
          snapshot: merged,
          local: local,
        );
      }

      phase.reset();
      await _announce(onProgress, SyncPhase.uploading);
      final ok = await remote.writeIfUnchanged(
        path,
        mergedJson,
        expectedRevision: current.revision,
      );
      final writeMs = phase.elapsedMilliseconds;
      // Someone wrote between our read and our write; go around with theirs.
      if (!ok) {
        JavpLog.i(
          'sync',
          'attempt=$attempt mode=${mode.name} '
              'readMs=$readMs buildMs=$buildMs mergeMs=$mergeMs '
              'encodeMs=$encodeMs writeMs=$writeMs applyMs=0 '
              'bytes=${mergedJson.length} sections=${merged.sections.length} '
              'cas=retry',
        );
        continue;
      }

      phase.reset();
      final changed = await _applyOrSkip(
        merged,
        local: local,
        remote: usable,
        mode: mode,
        localHashes: localHashes,
        onProgress: onProgress,
        applyLocal: applyLocal,
      );
      final applyMs = phase.elapsedMilliseconds;
      JavpLog.i(
        'sync',
        'attempt=$attempt mode=${mode.name} '
            'readMs=$readMs buildMs=$buildMs mergeMs=$mergeMs '
            'encodeMs=$encodeMs writeMs=$writeMs applyMs=$applyMs '
            'bytes=${mergedJson.length} sections=${merged.sections.length}',
      );
      // Local changed again during the write — push the fuller merge next loop.
      if (changed == null) continue;

      return _outcome(
        pulled: true,
        pushed: true,
        at: at,
        changedSections: changed,
        snapshot: merged,
        local: local,
      );
    }

    throw SyncRemoteException(
      'Another device kept changing this profile while syncing. Try again.',
    );
  }

  SyncOutcome _outcome({
    required bool pulled,
    required bool pushed,
    required DateTime at,
    required ProfileSnapshot snapshot,
    required ProfileSnapshot local,
    List<String> changedSections = const [],
  }) {
    final avatarChanged =
        snapshot.avatarUpdatedAt != local.avatarUpdatedAt ||
        snapshot.avatarPhoto != local.avatarPhoto;
    return SyncOutcome(
      pulled: pulled,
      pushed: pushed,
      at: at,
      changedSections: changedSections,
      avatarChanged: avatarChanged,
      avatarUpdatedAt: snapshot.avatarUpdatedAt,
      avatarPhoto: snapshot.avatarPhoto,
      avatarBaseToken: profile.avatarToken,
      avatarBaseUpdatedAt: profile.avatarUpdatedAt?.toUtc(),
    );
  }

  /// How much of the remote a run is entitled to take.
  ///
  /// Only the first sync on a device has to make this call; after that both
  /// sides have real timestamps and [_MergeMode.merge] is always right.
  static _MergeMode _modeFor({
    required bool neverSynced,
    required ProfileSnapshot local,
  }) {
    if (!neverSynced) return _MergeMode.merge;
    // A device with nothing of its own (restore flow) adopts wholesale: its
    // untouched defaults have no claim over settings someone actually chose.
    // A device that already has a library only fills its gaps, so an empty
    // remote — another install of the shared `default` profile, say — cannot
    // wipe it.
    return _isUnused(local) ? _MergeMode.adopt : _MergeMode.seed;
  }

  static ProfileSnapshot _merge(
    _MergeMode mode,
    ProfileSnapshot local,
    ProfileSnapshot remote,
  ) => switch (mode) {
    _MergeMode.adopt => local.adopt(remote),
    _MergeMode.seed => local.seededWith(remote),
    _MergeMode.merge => local.mergedWith(remote),
  };

  /// History union + section LWW is CPU-heavy on large libraries — off UI.
  ///
  /// Uses [javpCompute] so Flutter web does not hit `RawReceivePort`.
  static Future<ProfileSnapshot> _mergeAsync(
    _MergeMode mode,
    ProfileSnapshot local,
    ProfileSnapshot remote,
  ) async {
    final merged = await javpCompute(
      () => _merge(mode, local, remote),
      debugLabel: 'sync-merge',
    );
    await pumpUi();
    return merged;
  }

  /// True when nothing has been added to this profile yet. Preferences are
  /// deliberately not consulted: a fresh install always has default ones.
  static bool _isUnused(ProfileSnapshot local) {
    const owned = [
      SnapshotSections.sources,
      SnapshotSections.history,
      SnapshotSections.watchlist,
      SnapshotSections.favoriteChannels,
      SnapshotSections.favoriteCategories,
      SnapshotSections.collections,
      SnapshotSections.playlists,
      SnapshotSections.epgReminders,
      SnapshotSections.trackerStatuses,
    ];
    for (final name in owned) {
      final data = local.dataFor(name);
      if (name == SnapshotSections.history) {
        if (!HistorySyncData.isItemsEmpty(data)) return false;
        continue;
      }
      if (data is List && data.isNotEmpty) return false;
    }
    return true;
  }

  /// Push-only path: leave disk and in-memory library alone (playback).
  ///
  /// Stamps stay on the pre-apply values so the next full sync still sees
  /// remote-only sections as needing a write.
  Future<List<String>?> _applyOrSkip(
    ProfileSnapshot merged, {
    required ProfileSnapshot local,
    required ProfileSnapshot remote,
    required _MergeMode mode,
    required Map<String, String> localHashes,
    void Function(SyncPhase phase)? onProgress,
    required bool applyLocal,
  }) async {
    if (!applyLocal) {
      final needing = await _sectionsNeedingDiskApply(
        local,
        merged,
        localHashes,
      );
      JavpLog.i(
        'sync',
        'apply skip reason=playback '
            'sections=${needing.isEmpty ? "-" : needing.join(",")}',
      );
      return needing;
    }
    return _applyWithoutClobbering(
      merged,
      local: local,
      remote: remote,
      mode: mode,
      localHashes: localHashes,
      onProgress: onProgress,
    );
  }

  /// Applies [merged], but if disk moved since [merged] was built, re-merges
  /// with [remote] so we never write an older sources/history list over a
  /// newer local edit. Returns null when the caller should retry the whole
  /// sync loop (local grew past what we already pushed).
  ///
  /// Fast path: when section hashes still match [localHashes] from the
  /// pre-upload capture, skip re-merge + dual full-snapshot encode (journals:
  /// ~1s+ applyMs with Accueil jank on the Envoi→Application transition).
  ///
  /// No-op path: when merge only reshaped history (coalesce fill-ins) without
  /// changing playheads / tombstones / other section hashes, skip rewriting
  /// disk entirely — journals showed applyMs≈1s + ~0.6s Home hitch even when
  /// reloadAfterSync reported content unchanged.
  Future<List<String>?> _applyWithoutClobbering(
    ProfileSnapshot merged, {
    required ProfileSnapshot local,
    required ProfileSnapshot remote,
    required _MergeMode mode,
    required Map<String, String> localHashes,
    void Function(SyncPhase phase)? onProgress,
  }) async {
    await _announce(onProgress, SyncPhase.applyingLibrary);

    final needingWrite = await _sectionsNeedingDiskApply(
      local,
      merged,
      localHashes,
    );
    if (needingWrite.isEmpty) {
      JavpLog.i('sync', 'apply fast-path reason=no-op');
      await _adoptStampsKeepingDiskHashes(merged, localHashes);
      return const [];
    }

    final latest = await _readSections();
    // Let Accueil paint between the full-section read and the write storm.
    await Future<void>.delayed(Duration.zero);
    final latestHashes = await _hashSections(latest);
    var drifted = false;
    for (final name in SnapshotSections.all) {
      if ((latestHashes[name] ?? '') != (localHashes[name] ?? '')) {
        drifted = true;
        break;
      }
    }
    if (!drifted) {
      JavpLog.i(
        'sync',
        'apply fast-path reason=no-local-drift '
            'sections=${needingWrite.join(',')}',
      );
      return applySnapshot(merged, preloaded: latest, onProgress: onProgress);
    }

    // Disk moved under us during upload — re-merge, then cheap hash compare
    // (not two full jsonEncode passes of ~180KB+ snapshots on the UI path).
    await _announce(onProgress, SyncPhase.merging);
    final latestLocal = await buildSnapshot(
      now: DateTime.now().toUtc(),
      preloaded: latest,
    );
    final latestMerged = await _mergeAsync(mode, latestLocal, remote);
    final mergedData = <String, Object?>{
      for (final name in SnapshotSections.all) name: merged.section(name)?.data,
    };
    final latestMergedData = <String, Object?>{
      for (final name in SnapshotSections.all)
        name: latestMerged.section(name)?.data,
    };
    final a = await _hashSections(mergedData);
    final b = await _hashSections(latestMergedData);
    for (final name in SnapshotSections.all) {
      if ((a[name] ?? '') != (b[name] ?? '')) {
        return null;
      }
    }
    await _announce(onProgress, SyncPhase.applyingLibrary);
    return applySnapshot(
      latestMerged,
      preloaded: latest,
      onProgress: onProgress,
    );
  }

  /// Sections whose on-disk blobs must change for [merged] to match what we
  /// pushed. History ignores coalesce-only / serialization hash churn when
  /// playheads and tombstones are unchanged.
  static Future<List<String>> _sectionsNeedingDiskApply(
    ProfileSnapshot local,
    ProfileSnapshot merged,
    Map<String, String> localHashes,
  ) async {
    final mergedData = <String, Object?>{
      for (final name in SnapshotSections.all) name: merged.section(name)?.data,
    };
    final mergedHashes = await _hashSections(mergedData);
    final out = <String>[];
    for (final name in SnapshotSections.all) {
      if ((mergedHashes[name] ?? '') == (localHashes[name] ?? '')) {
        continue;
      }
      if (name == SnapshotSections.history &&
          !_historyPlayheadsOrTombstonesDiffer(
            local.section(name)?.data,
            merged.section(name)?.data,
          )) {
        continue;
      }
      out.add(name);
    }
    return out;
  }

  /// True when history items (id / progress / lastWatchedAt) or tombstones
  /// differ — not when merge only filled optional poster fields.
  static bool _historyPlayheadsOrTombstonesDiffer(Object? a, Object? b) {
    final ha = HistorySyncData.parse(a);
    final hb = HistorySyncData.parse(b);
    if (ha.deleted.length != hb.deleted.length) return true;
    for (final e in ha.deleted.entries) {
      final other = hb.deleted[e.key];
      if (other == null || other != e.value) return true;
    }
    for (final key in hb.deleted.keys) {
      if (!ha.deleted.containsKey(key)) return true;
    }
    if (ha.items.length != hb.items.length) return true;
    final byId = <String, Map<String, dynamic>>{
      for (final item in ha.items)
        if (item['id'] != null) '${item['id']}': item,
    };
    for (final item in hb.items) {
      final id = '${item['id'] ?? ''}';
      if (id.isEmpty) continue;
      final other = byId.remove(id);
      if (other == null) return true;
      if ((item['progress'] ?? 0) != (other['progress'] ?? 0)) return true;
      if ('${item['lastWatchedAt'] ?? ''}' !=
          '${other['lastWatchedAt'] ?? ''}') {
        return true;
      }
    }
    return byId.isNotEmpty;
  }

  /// Disk blobs unchanged — refresh LWW stamp times from [merged] but keep
  /// hashes aligned with what is still on disk ([localHashes]).
  Future<void> _adoptStampsKeepingDiskHashes(
    ProfileSnapshot merged,
    Map<String, String> localHashes,
  ) async {
    final stamps = <String, _SectionStamp>{};
    for (final name in SnapshotSections.all) {
      final section = merged.section(name);
      if (section == null) continue;
      stamps[name] = _SectionStamp(
        hash: localHashes[name] ?? _hash(section.data),
        updatedAt: section.updatedAt,
      );
    }
    _stamps = stamps;
    await _commitStamps();
  }

  /// Hash every section off the UI isolate (sendable Maps/Lists only).
  ///
  /// [javpCompute] runs inline on web — isolates are unsupported there.
  static Future<Map<String, String>> _hashSections(
    Map<String, Object?> data,
  ) async {
    final payload = <String, Object?>{
      for (final name in SnapshotSections.all) name: data[name],
    };
    final hashes = await javpCompute(() {
      return <String, String>{
        for (final e in payload.entries) e.key: _hash(e.value),
      };
    }, debugLabel: 'sync-hash');
    await pumpUi();
    return hashes;
  }

  /// jsonEncode of a full snapshot can stall the UI isolate on big libraries.
  static Future<String> _encodeSnapshot(ProfileSnapshot snapshot) async {
    // Snapshot graphs are sendable (Maps/Lists/primitives/DateTime).
    // Always write the slim wire shape even if merge still held fat legacy rows.
    final encoded = await javpCompute(
      () => jsonEncode(snapshot.forWire().toJson()),
      debugLabel: 'sync-encode',
    );
    await pumpUi();
    return encoded;
  }

  /// jsonDecode + [ProfileSnapshot.tryFromJson] off the UI isolate (journals
  /// show multi-second frames overlapping sync read/apply on Accueil).
  ///
  /// Runs on the current isolate on web ([javpCompute]).
  static Future<ProfileSnapshot?> _decodeSnapshot(String raw) async {
    final snapshot = await javpCompute(() {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        return ProfileSnapshot.tryFromJson(Map<String, dynamic>.from(decoded));
      } catch (_) {
        return null;
      }
    }, debugLabel: 'sync-decode');
    await pumpUi();
    return snapshot;
  }

  /// Keeps a copy of an unreadable snapshot instead of overwriting the only
  /// version of it. Named so profile discovery skips it.
  Future<void> _preserveDamaged(
    SyncRemote remote,
    String contents,
    DateTime at,
  ) async {
    final stamp = at.toIso8601String().replaceAll(':', '-');
    try {
      await remote.write(
        '$profilesFolder/${profile.id}.damaged-$stamp.json.bak',
        contents,
      );
    } catch (_) {
      // Best effort: a read-only or full remote must not block syncing.
    }
  }

  /// Profiles already present in the sync folder, so a new device can adopt
  /// one instead of starting empty.
  static Future<List<RemoteProfileEntry>> listRemoteProfiles(
    SyncRemote remote,
  ) async {
    final names = await remote.list(profilesFolder);
    final entries = <RemoteProfileEntry>[];
    for (final name in names) {
      if (!name.endsWith('.json')) continue;
      final raw = await remote.read('$profilesFolder/$name');
      if (raw == null) continue;
      final snapshot = await _decodeSnapshot(raw);
      if (snapshot == null) continue;
      entries.add(
        RemoteProfileEntry(
          profileId: snapshot.profileId,
          profileName: snapshot.profileName,
          updatedAt: snapshot.updatedAt,
          deviceId: snapshot.deviceId,
        ),
      );
    }
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return entries;
  }

  /// Reads every syncable section from disk.
  ///
  /// Sections are independent, and the big ones (sources, history, watchlist)
  /// each hand their decode to a worker isolate — read one at a time, a sync
  /// run waits out those decodes back to back while the UI isolate sits idle
  /// between them. [Future.wait] also subscribes to all of them, so a section
  /// that fails can't leave an unobserved error behind.
  Future<Map<String, Object?>> _readSections() async {
    final data = <String, Object?>{};
    Future<void> read(String name, Future<Object?> Function() value) async {
      data[name] = await value();
    }

    await Future.wait([
      read(
        SnapshotSections.sources,
        () async => [for (final s in await store.loadSources()) s.toJson()],
      ),
      read(
        SnapshotSections.categories,
        // Rebuilt from sources on sync; keep section for LWW clear of legacy fat.
        () async => const <Object>[],
      ),
      read(
        SnapshotSections.history,
        () async => HistorySyncData(
          items: await _toSyncJsonMaps(await store.loadHistory()),
          deleted: await store.loadHistoryDeleted(),
        ).toWire(),
      ),
      read(
        SnapshotSections.watchlist,
        () async => _toJsonMaps(await store.loadWatchlist()),
      ),
      read(SnapshotSections.favoriteChannels, store.loadFavoriteChannelIds),
      read(SnapshotSections.favoriteCategories, store.loadFavoriteCategoryIds),
      read(SnapshotSections.recentChannels, store.loadRecentChannelIds),
      read(
        SnapshotSections.preferredLiveQualities,
        store.loadPreferredLiveQualities,
      ),
      read(
        SnapshotSections.preferredVodVariants,
        store.loadPreferredVodVariants,
      ),
      read(
        SnapshotSections.collections,
        () async => [for (final c in await store.loadCollections()) c.toJson()],
      ),
      read(
        SnapshotSections.playlists,
        () async => [for (final p in await store.loadPlaylists()) p.toJson()],
      ),
      read(
        SnapshotSections.captionStyle,
        () async => (await store.loadCaptionStyle()).toJson(),
      ),
      read(
        SnapshotSections.skipSettings,
        () async => (await store.loadSkipSettings()).toJson(),
      ),
      read(
        SnapshotSections.trackLanguages,
        () async => (await store.loadTrackLanguageSettings()).toJson(),
      ),
      read(
        SnapshotSections.downloadSettings,
        () async => (await store.loadDownloadSettings()).toJson(),
      ),
      read(
        SnapshotSections.metadataSettings,
        () async => (await store.loadMetadataSettings()).toJson(),
      ),
      read(
        SnapshotSections.displaySettings,
        () async => (await store.loadDisplaySettings()).toJson(),
      ),
      read(
        SnapshotSections.proxySettings,
        () async => (await store.loadProxySettings()).toJson(),
      ),
      read(
        SnapshotSections.liveScrubMode,
        () async => (await store.loadLiveScrubMode()).storageValue,
      ),
      read(
        SnapshotSections.liveQualityMode,
        () async => (await store.loadLiveQualityMode()).storageValue,
      ),
      read(
        SnapshotSections.mediaServerQuality,
        () async => (await store.loadMediaServerStreamQuality()).name,
      ),
      read(
        SnapshotSections.cyclePlaybackSpeeds,
        () async => await store.loadCyclePlaybackSpeeds(),
      ),
      read(
        SnapshotSections.sportsFollows,
        () async => (await store.loadSportsFollows()).toFollowsJson(),
      ),
      read(
        SnapshotSections.epgReminders,
        () async => [
          for (final r in await store.loadEpgReminders()) r.toJson(),
        ],
      ),
      read(
        SnapshotSections.trackerStatuses,
        () async => [
          for (final e in await store.loadTrackerStatuses())
            if (e.worthSyncingForContinueWatching) e.toJson(),
        ],
      ),
    ]);
    return data;
  }

  Future<void> _writeSection(String name, Object? data) async {
    switch (name) {
      case SnapshotSections.sources:
        await store.saveSources(
          await _decodedAsync(data, IptvSource.tryFromJson),
        );
      case SnapshotSections.categories:
        final cats = await _decodedAsync(data, IptvCategory.fromJson);
        // Slim wire writes empty categories; don't wipe a device that still
        // has them — source sync refreshes the list.
        if (cats.isNotEmpty) {
          await store.saveCategories(cats);
        }
      case SnapshotSections.history:
        final history = await javpCompute(
          () => HistorySyncData.parse(data),
          debugLabel: 'sync-history-parse',
        );
        await store.saveHistory(
          await _decodedAsync(history.items, MediaItem.fromJson),
        );
        await store.saveHistoryDeleted(history.deleted);
      case SnapshotSections.watchlist:
        await store.saveWatchlist(
          await _decodedAsync(data, MediaItem.fromJson),
        );
      case SnapshotSections.favoriteChannels:
        await store.saveFavoriteChannelIds(_strings(data));
      case SnapshotSections.favoriteCategories:
        await store.saveFavoriteCategoryIds(_strings(data));
      case SnapshotSections.recentChannels:
        await store.saveRecentChannelIds(_strings(data));
      case SnapshotSections.preferredLiveQualities:
        await store.savePreferredLiveQualities(_stringMap(data));
      case SnapshotSections.preferredVodVariants:
        await store.savePreferredVodVariants(_stringMap(data));
      case SnapshotSections.collections:
        await store.saveCollections(
          await _decodedAsync(data, LibraryCollection.fromJson),
        );
      case SnapshotSections.playlists:
        await store.savePlaylists(
          await _decodedAsync(data, LibraryPlaylist.fromJson),
        );
      case SnapshotSections.captionStyle:
        final map = _map(data);
        if (map != null) {
          await store.saveCaptionStyle(CaptionStyleSettings.fromJson(map));
        }
      case SnapshotSections.skipSettings:
        final map = _map(data);
        if (map != null) {
          await store.saveSkipSettings(SkipSegmentSettings.fromJson(map));
        }
      case SnapshotSections.trackLanguages:
        final map = _map(data);
        if (map != null) {
          await store.saveTrackLanguageSettings(
            TrackLanguageSettings.fromJson(map),
          );
        }
      case SnapshotSections.downloadSettings:
        final map = _map(data);
        if (map != null) {
          await store.saveDownloadSettings(DownloadSettings.fromJson(map));
        }
      case SnapshotSections.metadataSettings:
        final map = _map(data);
        if (map != null) {
          await store.saveMetadataSettings(MetadataSettings.fromJson(map));
        }
      case SnapshotSections.displaySettings:
        final map = _map(data);
        if (map != null) {
          await store.saveDisplaySettings(DisplaySettings.fromJson(map));
        }
      case SnapshotSections.proxySettings:
        final map = _map(data);
        if (map != null) {
          await store.saveProxySettings(ProxySettings.fromJson(map));
        }
      case SnapshotSections.liveScrubMode:
        await store.saveLiveScrubMode(
          LiveScrubModeX.fromStorage(data is String ? data : null),
        );
      case SnapshotSections.liveQualityMode:
        await store.saveLiveQualityMode(
          LiveQualityModeX.fromStorage(data is String ? data : null),
        );
      case SnapshotSections.mediaServerQuality:
        await store.saveMediaServerStreamQuality(
          MediaServerStreamQualityX.fromName(data is String ? data : null),
        );
      case SnapshotSections.cyclePlaybackSpeeds:
        final speeds = <double>[];
        if (data is List) {
          for (final e in data) {
            if (e is num) {
              speeds.add(e.toDouble());
            } else if (e is String) {
              final n = double.tryParse(e);
              if (n != null) speeds.add(n);
            }
          }
        }
        await store.saveCyclePlaybackSpeeds(
          normalizeCyclePlaybackSpeeds(speeds),
        );
      case SnapshotSections.sportsFollows:
        final map = _map(data);
        await store.saveSportsFollows(
          map == null ? SportsPrefs.empty : SportsPrefs.fromJson(map),
        );
      case SnapshotSections.epgReminders:
        await store.saveEpgReminders(
          await _decodedAsync(data, EpgReminder.fromJson),
        );
      case SnapshotSections.trackerStatuses:
        final incoming = await _decodedAsync(data, TrackerStatusEntry.fromJson);
        // Slim snapshots omit completed; keep local completed so CW exclusion
        // survives until the next tracker pull re-imports the bulk list.
        if (incoming.isEmpty) {
          break;
        }
        final local = await store.loadTrackerStatuses();
        await store.saveTrackerStatuses(
          mergeTrackerStatuses([
            for (final e in local)
              if (e.status == TrackerStatusKind.completed) e,
          ], incoming),
        );
    }
  }

  static Map<String, dynamic>? _map(Object? data) =>
      data is Map ? Map<String, dynamic>.from(data) : null;

  /// Snapshot [toJson] loops with yields so large history/watchlist builds
  /// don't freeze the frame during sync.
  static Future<List<Map<String, dynamic>>> _toJsonMaps(
    List<MediaItem> items,
  ) async {
    final maps = <Map<String, dynamic>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < items.length; i++) {
      maps.add(items[i].toJson());
      await yieldUiSlice(slice, i: i, checkMask: 31, label: 'sync-tojson-maps');
    }
    return maps;
  }

  /// History-only lean maps for the sync folder (see [MediaItem.toSyncJson]).
  static Future<List<Map<String, dynamic>>> _toSyncJsonMaps(
    List<MediaItem> items,
  ) async {
    final maps = <Map<String, dynamic>>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < items.length; i++) {
      maps.add(items[i].toSyncJson());
      await yieldUiSlice(
        slice,
        i: i,
        checkMask: 31,
        label: 'sync-tosyncjson-maps',
      );
    }
    return maps;
  }

  /// Rows a newer build wrote in a shape we don't understand are dropped
  /// rather than thrown: one bad entry must not make every future sync fail.
  ///
  /// Yields between chunks so a heavy apply can't ANR the UI isolate.
  static Future<List<T>> _decodedAsync<T>(
    Object? data,
    T? Function(Map<String, dynamic> json) parse,
  ) async {
    if (data is! List) return const [];
    final items = <T>[];
    final slice = Stopwatch()..start();
    for (var i = 0; i < data.length; i++) {
      final e = data[i];
      if (e is! Map) continue;
      try {
        final parsed = parse(Map<String, dynamic>.from(e));
        if (parsed != null) items.add(parsed);
      } catch (_) {
        // Skip rows written by a build that knew fields we don't.
      }
      await yieldUiSlice(slice, i: i, label: 'sync-decode-rows');
    }
    return items;
  }

  static List<String> _strings(Object? data) {
    if (data is! List) return const [];
    return [for (final e in data) '$e'];
  }

  static Map<String, String> _stringMap(Object? data) {
    if (data is! Map) return const {};
    return {
      for (final e in data.entries)
        if (e.value != null) '${e.key}': '${e.value}',
    };
  }

  /// FNV-1a over the canonical JSON. Needs to be stable across app runs, which
  /// rules out `Object.hashCode`.
  static String _hash(Object? value) {
    final encoded = jsonEncode(value);
    // BigInt keeps full 64-bit FNV-1a on web (JS number can't hold these consts).
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final unit in encoded.codeUnits) {
      hash = (hash ^ BigInt.from(unit)) & mask;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16);
  }
}

/// How a run reconciles local state with what the folder already holds.
enum _MergeMode { adopt, seed, merge }

class _SectionStamp {
  const _SectionStamp({required this.hash, required this.updatedAt});

  final String hash;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static _SectionStamp? tryFromJson(Map<String, dynamic> json) {
    final hash = json['hash'] as String?;
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (hash == null || updatedAt == null) return null;
    return _SectionStamp(hash: hash, updatedAt: updatedAt.toUtc());
  }
}
