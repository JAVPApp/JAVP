import 'dart:convert';

/// Named slices of a profile that sync independently.
///
/// Keeping them separate means editing sources on one device and the watchlist
/// on another doesn't make the two devices fight over a single timestamp.
class SnapshotSections {
  SnapshotSections._();

  static const sources = 'sources';
  static const categories = 'categories';
  static const history = 'history';
  static const watchlist = 'watchlist';
  static const favoriteChannels = 'favoriteChannels';
  static const favoriteCategories = 'favoriteCategories';
  static const recentChannels = 'recentChannels';
  static const preferredLiveQualities = 'preferredLiveQualities';
  static const preferredVodVariants = 'preferredVodVariants';
  static const collections = 'collections';
  static const playlists = 'playlists';
  static const captionStyle = 'captionStyle';
  static const skipSettings = 'skipSettings';
  static const trackLanguages = 'trackLanguages';
  static const downloadSettings = 'downloadSettings';
  static const metadataSettings = 'metadataSettings';
  static const displaySettings = 'displaySettings';
  static const proxySettings = 'proxySettings';
  static const liveScrubMode = 'liveScrubMode';
  static const liveQualityMode = 'liveQualityMode';
  static const mediaServerQuality = 'mediaServerQuality';
  static const cyclePlaybackSpeeds = 'cyclePlaybackSpeeds';
  static const sportsFollows = 'sportsFollows';
  static const epgReminders = 'epgReminders';
  static const trackerStatuses = 'trackerStatuses';

  /// Everything a snapshot may carry. Derived caches (catalog, VOD cache, live
  /// channel index, details/segment caches) are deliberately absent: they are
  /// rebuilt from the sources and would only cause pointless churn.
  ///
  /// [categories] is still recognized on read (legacy fat snapshots) but new
  /// writes empty it — Xtream/Stalker rebuild category lists on source sync.
  static const all = <String>[
    sources,
    categories,
    history,
    watchlist,
    favoriteChannels,
    favoriteCategories,
    recentChannels,
    preferredLiveQualities,
    preferredVodVariants,
    collections,
    playlists,
    captionStyle,
    skipSettings,
    trackLanguages,
    downloadSettings,
    metadataSettings,
    displaySettings,
    proxySettings,
    liveScrubMode,
    liveQualityMode,
    mediaServerQuality,
    cyclePlaybackSpeeds,
    sportsFollows,
    epgReminders,
    trackerStatuses,
  ];
}

/// One section's payload plus when this device last changed it.
class SnapshotSection {
  const SnapshotSection({required this.updatedAt, required this.data});

  final DateTime updatedAt;
  final Object? data;

  Map<String, dynamic> toJson() => {
    'updatedAt': updatedAt.toIso8601String(),
    'data': data,
  };

  static SnapshotSection? tryFromJson(Map<String, dynamic> json) {
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (updatedAt == null) return null;
    return SnapshotSection(updatedAt: updatedAt.toUtc(), data: json['data']);
  }
}

/// A profile's syncable state as a single portable document.
///
/// This is what gets written to the sync folder — one file per profile — and
/// what an export/import round-trips through.
class ProfileSnapshot {
  const ProfileSnapshot({
    required this.profileId,
    required this.profileName,
    required this.deviceId,
    required this.updatedAt,
    required this.sections,
    this.schema = currentSchema,
    this.avatarPhoto,
    this.avatarUpdatedAt,
  });

  static const currentSchema = 1;

  final int schema;
  final String profileId;
  final String profileName;

  /// Which install wrote this revision; only used for display and diagnostics.
  final String deviceId;
  final DateTime updatedAt;
  final Map<String, SnapshotSection> sections;

  /// Base64 JPEG profile photo. Empty string + [avatarUpdatedAt] means cleared.
  final String? avatarPhoto;

  /// Last-write-wins stamp for [avatarPhoto]. Independent of section stamps.
  final DateTime? avatarUpdatedAt;

  SnapshotSection? section(String name) => sections[name];

  Object? dataFor(String name) => sections[name]?.data;

  ProfileSnapshot copyWith({
    String? profileName,
    String? deviceId,
    DateTime? updatedAt,
    Map<String, SnapshotSection>? sections,
    String? avatarPhoto,
    DateTime? avatarUpdatedAt,
    bool clearAvatar = false,
  }) {
    return ProfileSnapshot(
      schema: schema,
      profileId: profileId,
      profileName: profileName ?? this.profileName,
      deviceId: deviceId ?? this.deviceId,
      updatedAt: updatedAt ?? this.updatedAt,
      sections: sections ?? this.sections,
      avatarPhoto: clearAvatar ? null : (avatarPhoto ?? this.avatarPhoto),
      avatarUpdatedAt: avatarUpdatedAt ?? this.avatarUpdatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'profileId': profileId,
    'profileName': profileName,
    'deviceId': deviceId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'sections': {for (final e in sections.entries) e.key: e.value.toJson()},
    if (avatarUpdatedAt != null)
      'avatarUpdatedAt': avatarUpdatedAt!.toUtc().toIso8601String(),
    if (avatarUpdatedAt != null) 'avatarPhoto': avatarPhoto ?? '',
  };

  String encode() => jsonEncode(forWire().toJson());

  /// Drops rebuildable / tracker-restorable fat before writing to the sync folder.
  ///
  /// - History **items** are slimmed (read path still accepts full legacy items);
  ///   id + `url:<playUrl>` tombstones are unchanged.
  /// - Categories are emptied (Xtream/Stalker rebuild on source sync).
  /// - Tracker statuses keep only dropped / hold / watching.
  ProfileSnapshot forWire() {
    final next = <String, SnapshotSection>{};
    for (final e in sections.entries) {
      final name = e.key;
      final section = e.value;
      if (name == SnapshotSections.categories) {
        next[name] = SnapshotSection(
          updatedAt: section.updatedAt,
          data: const <Object>[],
        );
        continue;
      }
      if (name == SnapshotSections.history) {
        next[name] = SnapshotSection(
          updatedAt: section.updatedAt,
          data: HistorySyncData.parse(section.data).slimmed().toWire(),
        );
        continue;
      }
      if (name == SnapshotSections.trackerStatuses) {
        next[name] = SnapshotSection(
          updatedAt: section.updatedAt,
          data: slimTrackerStatusesData(section.data),
        );
        continue;
      }
      next[name] = section;
    }
    return copyWith(sections: next);
  }

  static ProfileSnapshot? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return tryFromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static ProfileSnapshot? tryFromJson(Map<String, dynamic> json) {
    final profileId = (json['profileId'] as String?)?.trim();
    if (profileId == null || profileId.isEmpty) return null;
    final schema = (json['schema'] as num?)?.toInt() ?? currentSchema;
    // Refuse anything newer than we understand rather than dropping fields.
    if (schema > currentSchema) return null;
    final sections = <String, SnapshotSection>{};
    final rawSections = json['sections'];
    if (rawSections is Map) {
      for (final entry in rawSections.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final section = SnapshotSection.tryFromJson(
          Map<String, dynamic>.from(value),
        );
        if (section != null) sections['${entry.key}'] = section;
      }
    }
    final avatarAt = DateTime.tryParse(
      json['avatarUpdatedAt'] as String? ?? '',
    )?.toUtc();
    final avatarRaw = json['avatarPhoto'];
    return ProfileSnapshot(
      schema: schema,
      profileId: profileId,
      profileName: (json['profileName'] as String?)?.trim() ?? 'Profile',
      deviceId: (json['deviceId'] as String?)?.trim() ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sections: sections,
      avatarUpdatedAt: avatarAt,
      avatarPhoto: avatarAt == null
          ? null
          : (avatarRaw is String ? avatarRaw : ''),
    );
  }

  /// Last-write-wins for the profile photo (including intentional clears).
  static ({String? photo, DateTime? updatedAt}) mergeAvatar({
    required String? minePhoto,
    required DateTime? mineAt,
    required String? theirsPhoto,
    required DateTime? theirsAt,
  }) {
    if (mineAt == null && theirsAt == null) {
      return (photo: null, updatedAt: null);
    }
    if (mineAt == null) {
      return (photo: theirsPhoto, updatedAt: theirsAt);
    }
    if (theirsAt == null) {
      return (photo: minePhoto, updatedAt: mineAt);
    }
    if (theirsAt.isAfter(mineAt)) {
      return (photo: theirsPhoto, updatedAt: theirsAt);
    }
    return (photo: minePhoto, updatedAt: mineAt);
  }

  /// Combines two snapshots of the same profile.
  ///
  /// Watch history is merged entry by entry so progress made on either device
  /// survives — except an intentional clear (empty section with a newer
  /// stamp), which must win or entry-wise merge resurrects everything.
  /// Per-item removals are carried as tombstones (`deleted` map) so a remote
  /// copy of the same id cannot come back after "remove from history".
  /// Every other section is last-write-wins on its own timestamp, which is
  /// what makes removals (a deleted source, an un-favorited channel) actually
  /// propagate instead of resurrecting.
  ProfileSnapshot mergedWith(ProfileSnapshot other) {
    final names = {...sections.keys, ...other.sections.keys};
    final merged = <String, SnapshotSection>{};
    for (final name in names) {
      final mine = sections[name];
      final theirs = other.sections[name];
      if (mine == null) {
        merged[name] = theirs!;
        continue;
      }
      if (theirs == null) {
        merged[name] = mine;
        continue;
      }
      if (name == SnapshotSections.history) {
        merged[name] = _mergeHistorySections(mine, theirs);
        continue;
      }
      merged[name] = theirs.updatedAt.isAfter(mine.updatedAt) ? theirs : mine;
    }

    final newer = other.updatedAt.isAfter(updatedAt) ? other : this;
    final avatar = mergeAvatar(
      minePhoto: avatarPhoto,
      mineAt: avatarUpdatedAt,
      theirsPhoto: other.avatarPhoto,
      theirsAt: other.avatarUpdatedAt,
    );
    return ProfileSnapshot(
      schema: currentSchema,
      profileId: profileId,
      profileName: newer.profileName,
      deviceId: newer.deviceId,
      updatedAt: newer.updatedAt,
      sections: merged,
      avatarPhoto: avatar.photo,
      avatarUpdatedAt: avatar.updatedAt,
    );
  }

  /// Takes [remote] wholesale, as a device that has never synced this profile
  /// should.
  ///
  /// A fresh install has no basis for claiming its empty watchlist is newer
  /// than the one already in the folder, so timestamps aren't consulted at all.
  /// History is still merged, so anything watched before attaching survives.
  ProfileSnapshot adopt(ProfileSnapshot remote) {
    final sections = <String, SnapshotSection>{
      ...this.sections,
      ...remote.sections,
    };
    final localHistory = section(SnapshotSections.history);
    final remoteHistory = remote.section(SnapshotSections.history);
    if (localHistory != null && remoteHistory != null) {
      sections[SnapshotSections.history] = SnapshotSection(
        updatedAt: localHistory.updatedAt.isAfter(remoteHistory.updatedAt)
            ? localHistory.updatedAt
            : remoteHistory.updatedAt,
        data: mergeHistoryData(localHistory.data, remoteHistory.data).toWire(),
      );
    }
    final avatar = mergeAvatar(
      minePhoto: avatarPhoto,
      mineAt: avatarUpdatedAt,
      theirsPhoto: remote.avatarPhoto,
      theirsAt: remote.avatarUpdatedAt,
    );
    return ProfileSnapshot(
      profileId: profileId,
      profileName: remote.profileName,
      deviceId: remote.deviceId,
      updatedAt: remote.updatedAt.isAfter(updatedAt)
          ? remote.updatedAt
          : updatedAt,
      sections: sections,
      avatarPhoto: avatar.photo,
      avatarUpdatedAt: avatar.updatedAt,
    );
  }

  /// First sync for a device that already has a library of its own.
  ///
  /// Unlike [adopt], an empty remote section cannot wipe a non-empty local one
  /// — that is what cleared libraries when enabling Google Drive against a
  /// previously synced empty `default` profile. Unlike [mergedWith], a blank
  /// local section still takes remote content even though a first sync stamps
  /// every local section as "now" and would otherwise win every comparison.
  ProfileSnapshot seededWith(ProfileSnapshot remote) {
    final names = {...sections.keys, ...remote.sections.keys};
    final merged = <String, SnapshotSection>{};
    for (final name in names) {
      final mine = sections[name];
      final theirs = remote.sections[name];
      if (mine == null) {
        merged[name] = theirs!;
        continue;
      }
      if (theirs == null) {
        merged[name] = mine;
        continue;
      }
      if (name == SnapshotSections.history) {
        merged[name] = SnapshotSection(
          updatedAt: mine.updatedAt.isAfter(theirs.updatedAt)
              ? mine.updatedAt
              : theirs.updatedAt,
          data: mergeHistoryData(mine.data, theirs.data).toWire(),
        );
        continue;
      }
      final localEmpty = _isEmptySection(mine.data);
      final remoteEmpty = _isEmptySection(theirs.data);
      if (localEmpty && !remoteEmpty) {
        merged[name] = theirs;
        continue;
      }
      if (!localEmpty && remoteEmpty) {
        merged[name] = mine;
        continue;
      }
      merged[name] = theirs.updatedAt.isAfter(mine.updatedAt) ? theirs : mine;
    }

    final newer = remote.updatedAt.isAfter(updatedAt) ? remote : this;
    final avatar = mergeAvatar(
      minePhoto: avatarPhoto,
      mineAt: avatarUpdatedAt,
      theirsPhoto: remote.avatarPhoto,
      theirsAt: remote.avatarUpdatedAt,
    );
    return ProfileSnapshot(
      schema: currentSchema,
      profileId: profileId,
      profileName: newer.profileName,
      deviceId: newer.deviceId,
      updatedAt: newer.updatedAt,
      sections: merged,
      avatarPhoto: avatar.photo,
      avatarUpdatedAt: avatar.updatedAt,
    );
  }

  static bool _isEmptySection(Object? data) {
    if (data == null) return true;
    if (data is List) return data.isEmpty;
    if (data is Map) return data.isEmpty;
    if (data is String) return data.isEmpty;
    return false;
  }

  /// History merge with clear support: an empty section whose stamp is newer
  /// replaces the peer wholesale; otherwise entries are unioned by id and
  /// filtered by tombstones.
  static SnapshotSection _mergeHistorySections(
    SnapshotSection mine,
    SnapshotSection theirs,
  ) {
    final mineEmpty = HistorySyncData.isItemsEmpty(mine.data);
    final theirsEmpty = HistorySyncData.isItemsEmpty(theirs.data);
    if (mineEmpty && theirsEmpty) {
      // Prefer the side that still carries tombstones when both lists are empty.
      final merged = mergeHistoryData(mine.data, theirs.data);
      return SnapshotSection(
        updatedAt: mine.updatedAt.isAfter(theirs.updatedAt)
            ? mine.updatedAt
            : theirs.updatedAt,
        data: merged.toWire(),
      );
    }
    if (mineEmpty && mine.updatedAt.isAfter(theirs.updatedAt)) {
      return SnapshotSection(
        updatedAt: mine.updatedAt,
        data: HistorySyncData.parse(mine.data).toWire(),
      );
    }
    if (theirsEmpty && theirs.updatedAt.isAfter(mine.updatedAt)) {
      return SnapshotSection(
        updatedAt: theirs.updatedAt,
        data: HistorySyncData.parse(theirs.data).toWire(),
      );
    }
    return SnapshotSection(
      updatedAt: mine.updatedAt.isAfter(theirs.updatedAt)
          ? mine.updatedAt
          : theirs.updatedAt,
      data: mergeHistoryData(mine.data, theirs.data).toWire(),
    );
  }

  /// Union of two history payloads: items by id, tombstones by id / play URL,
  /// then drop any item whose tombstone is newer than (or equal to) its last
  /// watch. URL tombstones (`url:<playUrl>`) keep pasted-stream ghosts dead
  /// even when Drive still has a sibling row under another id.
  static HistorySyncData mergeHistoryData(Object? mine, Object? theirs) {
    final a = HistorySyncData.parse(mine);
    final b = HistorySyncData.parse(theirs);
    final deleted = <String, DateTime>{...a.deleted};
    for (final e in b.deleted.entries) {
      final existing = deleted[e.key];
      if (existing == null || e.value.isAfter(existing)) {
        deleted[e.key] = e.value;
      }
    }

    final items = mergeHistory(a.items, b.items);
    final kept = <Map<String, dynamic>>[];
    for (final item in items) {
      final id = item['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final watched = _watchedAt(item);
      final idDelAt = deleted[id];
      if (idDelAt != null) {
        // A watch strictly after the delete resurrects the row and drops the
        // tombstone; equal/older watches stay deleted.
        if (watched == null || !watched.isAfter(idDelAt)) {
          continue;
        }
        deleted.remove(id);
      }
      final urlKey = HistorySyncData.urlTombstoneKey(
        item['playUrl'] as String?,
      );
      if (urlKey != null) {
        final urlDelAt = deleted[urlKey];
        if (urlDelAt != null) {
          if (watched == null || !watched.isAfter(urlDelAt)) {
            continue;
          }
          deleted.remove(urlKey);
        }
      }
      kept.add(item);
    }
    return HistorySyncData(items: kept, deleted: deleted);
  }

  /// Union of two history lists keyed by item id, keeping whichever copy was
  /// watched most recently. Entries with no timestamp lose to ones that have
  /// it, then fall back to the further-along progress.
  ///
  /// Prefer [mergeHistoryData] when tombstones may be present; this keeps the
  /// list-only API used by older tests and call sites.
  static List<Map<String, dynamic>> mergeHistory(Object? mine, Object? theirs) {
    final byId = <String, Map<String, dynamic>>{};
    final order = <String>[];

    void absorb(Object? raw) {
      final list = raw is List ? raw : HistorySyncData.parse(raw).items;
      for (final entry in list) {
        if (entry is! Map) continue;
        final item = Map<String, dynamic>.from(entry);
        final id = item['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final existing = byId[id];
        if (existing == null) {
          byId[id] = item;
          order.add(id);
        } else if (_isFresher(item, existing)) {
          // Fresher playhead wins; still fill blanks from the older fat copy
          // so a slim write doesn't erase a poster left on the peer.
          byId[id] = coalesceHistoryItem(item, existing);
        } else {
          byId[id] = coalesceHistoryItem(existing, item);
        }
      }
    }

    absorb(mine);
    absorb(theirs);

    final items = [for (final id in order) byId[id]!];
    items.sort((a, b) {
      final at = _watchedAt(a);
      final bt = _watchedAt(b);
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return items;
  }

  static bool _isFresher(
    Map<String, dynamic> candidate,
    Map<String, dynamic> existing,
  ) {
    final candidateAt = _watchedAt(candidate);
    final existingAt = _watchedAt(existing);
    if (candidateAt != null && existingAt != null) {
      if (candidateAt != existingAt) return candidateAt.isAfter(existingAt);
      return _progress(candidate) > _progress(existing);
    }
    if (candidateAt != null) return true;
    if (existingAt != null) return false;
    return _progress(candidate) > _progress(existing);
  }

  static DateTime? _watchedAt(Map<String, dynamic> item) {
    final raw = item['lastWatchedAt'];
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static double _progress(Map<String, dynamic> item) {
    final raw = item['progress'];
    if (raw is num) return raw.toDouble();
    return 0;
  }

  /// Prefer [preferred]'s playhead fields; fill missing keys from [fallback].
  static Map<String, dynamic> coalesceHistoryItem(
    Map<String, dynamic> preferred,
    Map<String, dynamic> fallback,
  ) {
    final out = Map<String, dynamic>.from(preferred);
    for (final e in fallback.entries) {
      if (!_isBlankHistoryValue(out[e.key]) || _isBlankHistoryValue(e.value)) {
        continue;
      }
      out[e.key] = e.value;
    }
    // One poster for CW tiles: prefer explicit poster, else thumbnail.
    final poster = out['posterUrl'];
    if (_isBlankHistoryValue(poster)) {
      final thumb = out['thumbnailUrl'] ?? fallback['thumbnailUrl'];
      if (!_isBlankHistoryValue(thumb)) {
        out['posterUrl'] = thumb;
      }
    }
    return out;
  }

  static bool _isBlankHistoryValue(Object? value) {
    if (value == null) return true;
    if (value is String) return value.trim().isEmpty;
    if (value is List) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    return false;
  }

  /// Wire-slim a single history map (idempotent; fat legacy rows OK).
  static Map<String, dynamic> slimHistoryItem(Map<String, dynamic> item) {
    final poster = () {
      final p = (item['posterUrl'] as String?)?.trim();
      if (p != null && p.isNotEmpty) return p;
      final t = (item['thumbnailUrl'] as String?)?.trim();
      if (t != null && t.isNotEmpty) return t;
      return null;
    }();
    final map = <String, dynamic>{
      'id': item['id'],
      'title': item['title'] ?? '',
      'playUrl': item['playUrl'] ?? '',
      'kind': item['kind'] ?? 'vod',
      'origin': item['origin'] ?? 'url',
      'progress': item['progress'] ?? 0,
    };
    void put(String key, Object? value) {
      if (_isBlankHistoryValue(value)) return;
      map[key] = value;
    }

    put('subtitle', item['subtitle']);
    put('posterUrl', poster);
    put('durationMs', item['durationMs']);
    put('channelId', item['channelId']);
    put('channelName', item['channelName']);
    put('streamId', item['streamId']);
    final catchup = item['catchupDays'];
    if (catchup is num && catchup > 0) map['catchupDays'] = catchup.toInt();
    put('lastWatchedAt', item['lastWatchedAt']);
    put('sourceId', item['sourceId']);
    put('simklId', item['simklId']);
    put('detailsId', item['detailsId']);
    put('tmdbId', item['tmdbId']);
    put('anilistId', item['anilistId']);
    put('imdbId', item['imdbId']);
    put('tvdbId', item['tvdbId']);
    put('year', item['year']);
    put('seasonNumber', item['seasonNumber']);
    put('episodeNumber', item['episodeNumber']);
    put('seriesId', item['seriesId']);
    put('serverItemId', item['serverItemId']);
    put('torrentFile', item['torrentFile']);
    if (item['isAdult'] == true) map['isAdult'] = true;
    return map;
  }

  /// Keep dropped / hold / watching only.
  static List<Map<String, dynamic>> slimTrackerStatusesData(Object? raw) {
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final status = '${map['status'] ?? ''}';
      if (status != 'dropped' && status != 'hold' && status != 'watching') {
        continue;
      }
      out.add(map);
    }
    return out;
  }
}

/// Wire format for the history section: a bare list (legacy) or
/// `{ "items": [...], "deleted": { "<id>": "<iso8601>" } }`.
class HistorySyncData {
  const HistorySyncData({this.items = const [], this.deleted = const {}});

  final List<Map<String, dynamic>> items;
  final Map<String, DateTime> deleted;

  /// Tombstone key for a pasted/import play URL (Drive + local Retirer).
  static const urlTombstonePrefix = 'url:';

  static String? urlTombstoneKey(String? playUrl) {
    final trimmed = playUrl?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return '$urlTombstonePrefix$trimmed';
  }

  static bool isItemsEmpty(Object? raw) => parse(raw).items.isEmpty;

  HistorySyncData slimmed() => HistorySyncData(
    items: [for (final item in items) ProfileSnapshot.slimHistoryItem(item)],
    deleted: deleted,
  );

  static HistorySyncData parse(Object? raw) {
    if (raw == null) return const HistorySyncData();
    if (raw is List) {
      return HistorySyncData(items: _itemMaps(raw));
    }
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final itemsRaw = map['items'];
      final deletedRaw = map['deleted'];
      final deleted = <String, DateTime>{};
      if (deletedRaw is Map) {
        for (final e in deletedRaw.entries) {
          final id = '${e.key}'.trim();
          if (id.isEmpty) continue;
          final at = DateTime.tryParse('${e.value}')?.toUtc();
          if (at == null) continue;
          deleted[id] = at;
        }
      }
      return HistorySyncData(
        items: itemsRaw is List ? _itemMaps(itemsRaw) : const [],
        deleted: deleted,
      );
    }
    return const HistorySyncData();
  }

  /// Prefer a bare list when there are no tombstones so older builds keep
  /// reading history; switch to the map once any delete must travel.
  Object toWire() {
    if (deleted.isEmpty) return items;
    return {
      'items': items,
      'deleted': {
        for (final e in deleted.entries)
          e.key: e.value.toUtc().toIso8601String(),
      },
    };
  }

  static List<Map<String, dynamic>> _itemMaps(List<dynamic> raw) {
    return [
      for (final entry in raw)
        if (entry is Map) Map<String, dynamic>.from(entry),
    ];
  }
}
