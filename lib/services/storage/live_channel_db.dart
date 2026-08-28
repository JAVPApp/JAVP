import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';
import 'package:javp/services/iptv/live_ingest_plan.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';
import 'package:javp/services/storage/app_documents.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Ordering for [LiveChannelDb.pageListings].
///
/// Default is [position] — provider/playlist sync order (Xtream/M3U/Plex).
/// Use [name] only when the user explicitly picks A–Z.
enum LiveListingSort { name, category, catchupFirst, position }

/// Result of [LiveChannelDb.upsertSourceGroupLive].
enum LiveGroupUpsertResult {
  /// Group rows were replaced.
  written,

  /// Incoming payload matched stored content; rows left in place.
  unchanged,

  /// Empty payload would have wiped a warm group; kept existing rows.
  keptExisting,
}

/// SQLite store for live IPTV channels — page queries, never full-list scans.
class LiveChannelDb {
  LiveChannelDb({
    this.profileId = Profile.defaultId,
    this.debugDatabasePath,
    this.debugForceDisableFts = false,
  });

  /// Channels are a per-profile cache under `{Documents}/JAVP`.
  /// [AppDocuments] moves a pre-subfolder default-profile file in place so
  /// existing installs don't re-index on upgrade.
  final String profileId;

  /// When set (tests), open this file instead of the app documents path.
  final String? debugDatabasePath;

  /// Test-only: skip FTS5 install and exercise the token LIKE search path.
  final bool debugForceDisableFts;

  /// Idle Xtream live groups are treated as fresh for this long after a fill.
  static const Duration defaultGroupFreshness = Duration(hours: 24);

  static const _ftsMeta = 'fts5';
  static const _ftsSchemaMeta = 'fts_schema';

  /// `2` = unicode61 remove_diacritics so MATCH folds accents without INSTR.
  static const _ftsSchemaVersion = '2';

  Database? _db;
  Future<Database>? _opening;
  bool _ftsEnabled = false;

  /// True when this connection has a usable `live_fts` table.
  bool get ftsEnabled => _ftsEnabled;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    return _opening ??= _open();
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    _ftsEnabled = false;
    await db?.close();
  }

  Future<Database> _open() async {
    if (kIsWeb) {
      throw UnsupportedError('LiveChannelDb is unavailable on web');
    }
    final resolved =
        debugDatabasePath ??
        await AppDocuments.profileFilePath(
          profileId: profileId,
          fileName: 'live_channels.db',
        );
    await Directory(p.dirname(resolved)).create(recursive: true);
    final db = await openDatabase(
      resolved,
      version: 5,
      onConfigure: (db) async {
        // UI + SyncEngine child share this file; retry instead of failing at ~10s.
        // Android sqflite rejects these PRAGMAs via execute() — use rawQuery.
        await db.rawQuery('PRAGMA busy_timeout = 30000');
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA synchronous=NORMAL');
      },
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE live_channels (
  id TEXT PRIMARY KEY NOT NULL,
  source_id TEXT NOT NULL,
  title TEXT NOT NULL,
  play_url TEXT NOT NULL,
  origin TEXT NOT NULL,
  thumbnail_url TEXT,
  group_name TEXT,
  channel_id TEXT,
  channel_name TEXT,
  stream_id TEXT,
  epg_channel_id TEXT,
  server_item_id TEXT,
  catchup_days INTEGER NOT NULL DEFAULT 0,
  http_headers_json TEXT,
  is_adult INTEGER NOT NULL DEFAULT 0
)''');
        await db.execute(
          'CREATE INDEX idx_live_source ON live_channels(source_id)',
        );
        await db.execute(
          'CREATE INDEX idx_live_group ON live_channels(group_name)',
        );

        await db.execute('''
CREATE TABLE live_listings (
  id TEXT PRIMARY KEY NOT NULL,
  source_id TEXT NOT NULL,
  group_name TEXT,
  family_key TEXT,
  variant_count INTEGER NOT NULL DEFAULT 1,
  sort_title TEXT NOT NULL,
  search_title TEXT NOT NULL,
  catchup_days INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL
)''');
        await db.execute(
          'CREATE INDEX idx_listings_pos ON live_listings(position)',
        );
        await db.execute(
          'CREATE INDEX idx_listings_group_pos ON live_listings(group_name, position)',
        );
        await db.execute(
          'CREATE INDEX idx_listings_source_group ON live_listings(source_id, group_name)',
        );
        await db.execute(
          'CREATE INDEX idx_listings_catchup ON live_listings(catchup_days DESC, sort_title)',
        );

        await db.execute('''
CREATE TABLE live_variants (
  family_key TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  rank INTEGER NOT NULL,
  PRIMARY KEY (family_key, channel_id)
)''');
        await db.execute(
          'CREATE INDEX idx_variants_family ON live_variants(family_key, rank)',
        );

        await db.execute('''
CREATE TABLE live_meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
)''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_listings_source_group '
            'ON live_listings(source_id, group_name)',
          );
        }
        if (oldVersion < 3) {
          // Plex (and other media-server) live rows resolve play URLs via
          // serverItemId at playback time — must survive the SQLite cache.
          await db.execute(
            'ALTER TABLE live_channels ADD COLUMN server_item_id TEXT',
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE live_channels ADD COLUMN is_adult INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 5) {
          try {
            await db.execute(
              "ALTER TABLE live_listings ADD COLUMN search_title TEXT NOT NULL DEFAULT ''",
            );
          } catch (_) {}
          try {
            await db.execute(
              'UPDATE live_listings SET search_title = sort_title '
              "WHERE IFNULL(search_title, '') = ''",
            );
          } catch (_) {}
        }
      },
    );
    _db = db;
    if (debugForceDisableFts) {
      _ftsEnabled = false;
      await _dropFtsTriggers(db);
      try {
        await _setMeta(_ftsMeta, '0');
      } catch (_) {}
    } else {
      await _syncFtsSupport(db);
    }
    return db;
  }

  Future<bool> _sqliteSupportsFts5(DatabaseExecutor db) async {
    try {
      await db.execute(
        'CREATE VIRTUAL TABLE temp._javp_live_fts5_probe USING fts5(x)',
      );
      await db.execute('DROP TABLE temp._javp_live_fts5_probe');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ftsTableExists(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT 1 AS x FROM sqlite_master WHERE type = 'table' "
      "AND name = 'live_fts' LIMIT 1",
    );
    return rows.isNotEmpty;
  }

  Future<bool> _installFtsIfSupported(
    DatabaseExecutor db, {
    required bool rebuild,
  }) async {
    if (!await _sqliteSupportsFts5(db)) {
      await _dropFtsTriggers(db);
      return false;
    }
    final alreadyHad = await _ftsTableExists(db);
    if (!alreadyHad) {
      try {
        await db.execute('''
CREATE VIRTUAL TABLE live_fts USING fts5(
  title,
  channel_name,
  group_name,
  stream_id,
  epg_channel_id,
  content='live_channels',
  content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 1'
)''');
      } catch (_) {
        await _dropFtsTriggers(db);
        return false;
      }
    }

    try {
      await db.execute('''
CREATE TRIGGER IF NOT EXISTS live_channels_ai AFTER INSERT ON live_channels BEGIN
  INSERT INTO live_fts(rowid, title, channel_name, group_name, stream_id, epg_channel_id)
  VALUES (new.rowid, new.title, new.channel_name, new.group_name, new.stream_id, new.epg_channel_id);
END''');
      await db.execute('''
CREATE TRIGGER IF NOT EXISTS live_channels_ad AFTER DELETE ON live_channels BEGIN
  INSERT INTO live_fts(live_fts, rowid, title, channel_name, group_name, stream_id, epg_channel_id)
  VALUES ('delete', old.rowid, old.title, old.channel_name, old.group_name, old.stream_id, old.epg_channel_id);
END''');
      await db.execute('''
CREATE TRIGGER IF NOT EXISTS live_channels_au AFTER UPDATE ON live_channels BEGIN
  INSERT INTO live_fts(live_fts, rowid, title, channel_name, group_name, stream_id, epg_channel_id)
  VALUES ('delete', old.rowid, old.title, old.channel_name, old.group_name, old.stream_id, old.epg_channel_id);
  INSERT INTO live_fts(rowid, title, channel_name, group_name, stream_id, epg_channel_id)
  VALUES (new.rowid, new.title, new.channel_name, new.group_name, new.stream_id, new.epg_channel_id);
END''');
      if (rebuild && !alreadyHad) {
        await db.execute("INSERT INTO live_fts(live_fts) VALUES('rebuild')");
      }
      try {
        await _setMetaOn(db, _ftsSchemaMeta, _ftsSchemaVersion);
      } catch (_) {}
      return true;
    } catch (_) {
      if (!alreadyHad) {
        try {
          await db.execute('DROP TABLE IF EXISTS live_fts');
        } catch (_) {}
        await _dropFtsTriggers(db);
      }
      return alreadyHad;
    }
  }

  Future<void> _dropFtsTriggers(DatabaseExecutor db) async {
    for (final name in [
      'live_channels_ai',
      'live_channels_ad',
      'live_channels_au',
    ]) {
      try {
        await db.execute('DROP TRIGGER IF EXISTS $name');
      } catch (_) {}
    }
  }

  Future<void> _dropFtsTable(DatabaseExecutor db) async {
    await _dropFtsTriggers(db);
    try {
      await db.execute('DROP TABLE IF EXISTS live_fts');
    } catch (_) {}
  }

  Future<void> _syncFtsSupport(Database db) async {
    if (!await _sqliteSupportsFts5(db)) {
      await _dropFtsTriggers(db);
      _ftsEnabled = false;
      try {
        await _setMeta(_ftsMeta, '0');
      } catch (_) {}
      return;
    }
    try {
      final schema = await _getMetaOn(db, _ftsSchemaMeta);
      if (await _ftsTableExists(db) && schema != _ftsSchemaVersion) {
        await _dropFtsTable(db);
      }
    } catch (_) {}
    if (await _ftsTableExists(db)) {
      _ftsEnabled = true;
      await _installFtsIfSupported(db, rebuild: false);
      try {
        await _setMeta(_ftsMeta, '1');
      } catch (_) {}
      return;
    }
    final installed = await _installFtsIfSupported(db, rebuild: true);
    _ftsEnabled = installed;
    try {
      await _setMeta(_ftsMeta, installed ? '1' : '0');
    } catch (_) {}
  }

  Future<int> countListings({
    String? groupName,
    String? sourceId,
    List<String>? allowedSourceIds,
    List<String>? excludedGroupNames,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    if (groupName != null && groupName.isNotEmpty) {
      where.add('group_name = ?');
      args.add(groupName);
    }
    _appendSourceFilter(
      where: where,
      args: args,
      column: 'source_id',
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
    );
    _appendExcludedGroups(
      where: where,
      args: args,
      column: 'group_name',
      excludedGroupNames: excludedGroupNames,
    );
    if (excludeAdult) {
      final jWhere = <String>[];
      final jArgs = <Object?>[];
      if (groupName != null && groupName.isNotEmpty) {
        jWhere.add('l.group_name = ?');
        jArgs.add(groupName);
      }
      _appendSourceFilter(
        where: jWhere,
        args: jArgs,
        column: 'l.source_id',
        sourceId: sourceId,
        allowedSourceIds: allowedSourceIds,
      );
      _appendExcludedGroups(
        where: jWhere,
        args: jArgs,
        column: 'l.group_name',
        excludedGroupNames: excludedGroupNames,
      );
      jWhere.add('IFNULL(c.is_adult, 0) = 0');
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM live_listings l '
        'INNER JOIN live_channels c ON c.id = l.id'
        '${jWhere.isEmpty ? '' : ' WHERE ${jWhere.join(' AND ')}'}',
        jArgs,
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM live_listings'
      '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// Distinct live group titles, optionally scoped to one IPTV source.
  Future<List<String>> listGroupNames({
    String? sourceId,
    List<String>? allowedSourceIds,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    if (excludeAdult) {
      final jWhere = <String>[
        "l.group_name IS NOT NULL AND l.group_name != ''",
        'IFNULL(c.is_adult, 0) = 0',
      ];
      final jArgs = <Object?>[];
      _appendSourceFilter(
        where: jWhere,
        args: jArgs,
        column: 'l.source_id',
        sourceId: sourceId,
        allowedSourceIds: allowedSourceIds,
      );
      final rows = await db.rawQuery('''
SELECT DISTINCT l.group_name AS g
FROM live_listings l
INNER JOIN live_channels c ON c.id = l.id
WHERE ${jWhere.join(' AND ')}
''', jArgs);
      final names = <String>[
        for (final row in rows)
          if (row['g'] case final String name when name.trim().isNotEmpty) name,
      ];
      names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    }
    final where = <String>["group_name IS NOT NULL AND group_name != ''"];
    final args = <Object?>[];
    _appendSourceFilter(
      where: where,
      args: args,
      column: 'source_id',
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
    );
    final rows = await db.rawQuery('''
SELECT DISTINCT group_name AS g
FROM live_listings
WHERE ${where.join(' AND ')}
''', args);
    final names = <String>[
      for (final row in rows)
        if (row['g'] case final String name when name.trim().isNotEmpty) name,
    ];
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// Category names with collapsed listing counts (source-scoped when set).
  Future<List<({String name, int count})>> listGroupCounts({
    String? sourceId,
    List<String>? allowedSourceIds,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    // Avoid TRIM()/COLLATE in SQL so indexes can be used; filter/sort in Dart.
    final where = <String>["group_name IS NOT NULL AND group_name != ''"];
    final args = <Object?>[];
    _appendSourceFilter(
      where: where,
      args: args,
      column: 'source_id',
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
    );
    final List<Map<String, Object?>> rows;
    if (excludeAdult) {
      final jWhere = <String>[
        "l.group_name IS NOT NULL AND l.group_name != ''",
        'IFNULL(c.is_adult, 0) = 0',
      ];
      final jArgs = <Object?>[];
      _appendSourceFilter(
        where: jWhere,
        args: jArgs,
        column: 'l.source_id',
        sourceId: sourceId,
        allowedSourceIds: allowedSourceIds,
      );
      rows = await db.rawQuery('''
SELECT l.group_name AS g, COUNT(*) AS c
FROM live_listings l
INNER JOIN live_channels c ON c.id = l.id
WHERE ${jWhere.join(' AND ')}
GROUP BY l.group_name
''', jArgs);
    } else {
      rows = await db.rawQuery('''
SELECT group_name AS g, COUNT(*) AS c
FROM live_listings
WHERE ${where.join(' AND ')}
GROUP BY group_name
''', args);
    }
    final out = <({String name, int count})>[
      for (final row in rows)
        if (row['g'] case final String name when name.trim().isNotEmpty)
          (name: name, count: (row['c'] as num?)?.toInt() ?? 0),
    ];
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// [sourceId] wins when set; otherwise optional allow-list (enabled sources).
  static void _appendSourceFilter({
    required List<String> where,
    required List<Object?> args,
    required String column,
    String? sourceId,
    List<String>? allowedSourceIds,
  }) {
    if (sourceId != null && sourceId.isNotEmpty) {
      where.add('$column = ?');
      args.add(sourceId);
      return;
    }
    if (allowedSourceIds == null) return;
    if (allowedSourceIds.isEmpty) {
      where.add('0');
      return;
    }
    final placeholders = List.filled(allowedSourceIds.length, '?').join(',');
    where.add('$column IN ($placeholders)');
    args.addAll(allowedSourceIds);
  }

  static void _appendExcludeAdult({
    required List<String> where,
    required List<Object?> args,
    required String column,
    required bool excludeAdult,
  }) {
    if (!excludeAdult) return;
    where.add('IFNULL($column, 0) = 0');
  }

  static void _appendExcludedGroups({
    required List<String> where,
    required List<Object?> args,
    required String column,
    List<String>? excludedGroupNames,
  }) {
    if (excludedGroupNames == null || excludedGroupNames.isEmpty) return;
    final names = <String>{
      for (final n in excludedGroupNames)
        if (n.trim().isNotEmpty) n.trim(),
    }.toList();
    if (names.isEmpty) return;
    final placeholders = List.filled(names.length, '?').join(',');
    where.add('$column NOT IN ($placeholders)');
    args.addAll(names);
  }

  /// Drop live rows whose [source_id] is no longer in [knownSourceIds].
  ///
  /// Source JSON skips unknown types (`tryFromJson` → null) without deleting
  /// SQLite, so dropped types (Twitch/Kick) used to stay playable.
  Future<Set<String>> pruneUnknownSources(Set<String> knownSourceIds) async {
    final orphan = {
      for (final id in await listSourceIds())
        if (!knownSourceIds.contains(id)) id,
    };
    if (orphan.isEmpty) return const {};
    final db = await _database;
    await db.transaction((txn) async {
      if (knownSourceIds.isEmpty) {
        await txn.delete('live_variants');
        await txn.delete('live_listings');
        await txn.delete('live_channels');
        return;
      }
      final placeholders = List.filled(knownSourceIds.length, '?').join(',');
      final args = knownSourceIds.toList(growable: false);
      await txn.rawDelete('''
DELETE FROM live_variants WHERE channel_id IN (
  SELECT id FROM live_channels
  WHERE source_id NOT IN ($placeholders) AND source_id != ''
)
''', args);
      await txn.rawDelete(
        'DELETE FROM live_listings WHERE source_id NOT IN ($placeholders) '
        "AND source_id != ''",
        args,
      );
      await txn.rawDelete(
        'DELETE FROM live_channels WHERE source_id NOT IN ($placeholders) '
        "AND source_id != ''",
        args,
      );
    });
    return orphan;
  }

  /// Source ids that already have at least one live row (Drive stamps ignored).
  Future<Set<String>> listSourceIds() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT source_id AS s FROM live_channels '
      "WHERE source_id IS NOT NULL AND source_id != ''",
    );
    return {
      for (final r in rows)
        if ('${r['s'] ?? ''}'.trim().isNotEmpty) '${r['s']}'.trim(),
    };
  }

  Future<int> countChannels({String? sourceId}) async {
    final db = await _database;
    if (sourceId == null) {
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM live_channels');
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM live_channels WHERE source_id = ?',
      [sourceId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> countInGroup({
    required String sourceId,
    required String groupName,
  }) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM live_channels '
      'WHERE source_id = ? AND IFNULL(group_name, \'\') = ?',
      [sourceId, groupName],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// Listing rows for one group — TV pages this, not [live_channels].
  Future<int> countListingsInGroup({
    required String sourceId,
    required String groupName,
  }) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM live_listings '
      'WHERE source_id = ? AND IFNULL(group_name, \'\') = ?',
      [sourceId, groupName],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// One GROUP BY for idle prefetch so we don't N× COUNT each category.
  Future<Map<String, int>> listingCountsByGroup({
    required String sourceId,
  }) async {
    final db = await _database;
    final rows = await db.rawQuery(
      '''
SELECT IFNULL(group_name, '') AS g, COUNT(*) AS c
FROM live_listings
WHERE source_id = ?
GROUP BY IFNULL(group_name, '')
''',
      [sourceId],
    );
    return {
      for (final row in rows) '${row['g']}': (row['c'] as num?)?.toInt() ?? 0,
    };
  }

  Future<List<MediaItem>> channelsInGroup({
    required String sourceId,
    required String groupName,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'live_channels',
      where: 'source_id = ? AND IFNULL(group_name, \'\') = ?',
      whereArgs: [sourceId, groupName],
    );
    return [for (final row in rows) _itemFromRow(row)];
  }

  /// Missing timestamp = fresh (don't refetch every group on upgrade).
  Future<bool> groupIsStale({
    required String sourceId,
    required String groupName,
    Duration maxAge = defaultGroupFreshness,
  }) async {
    final raw = await _getMeta(_groupFilledMetaKey(sourceId, groupName));
    if (raw == null || raw.isEmpty) return false;
    final at = DateTime.tryParse(raw);
    if (at == null) return false;
    return DateTime.now().toUtc().difference(at.toUtc()) > maxAge;
  }

  /// Whether a prior full live dump is still within [maxAge].
  ///
  /// Used so Synchroniser can skip re-downloading `get_live_streams` when
  /// SQLite already holds a warm fingerprint (same 24h window as VOD).
  Future<bool> sourceLiveDumpIsFresh({
    required String sourceId,
    Duration maxAge = defaultGroupFreshness,
  }) async {
    final fp = await _getMeta(_sourceFpMetaKey(sourceId));
    if (fp == null || fp.isEmpty) return false;
    final raw = await _getMeta(_sourceLiveDumpAtMetaKey(sourceId));
    if (raw == null || raw.isEmpty) {
      // Upgrade path: fingerprint exists from an older build — stamp now so
      // the next Sync within [maxAge] can skip the network dump entirely.
      await touchSourceLiveDumpAt(sourceId: sourceId);
      return true;
    }
    final at = DateTime.tryParse(raw);
    if (at == null) return false;
    return DateTime.now().toUtc().difference(at.toUtc()) <= maxAge;
  }

  Future<void> touchSourceLiveDumpAt({
    required String sourceId,
    DateTime? at,
  }) async {
    await _setMeta(
      _sourceLiveDumpAtMetaKey(sourceId),
      (at ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  Future<void> touchGroupFilled({
    required String sourceId,
    required String groupName,
    DateTime? at,
  }) async {
    await _setMeta(
      _groupFilledMetaKey(sourceId, groupName),
      (at ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  /// Stamp filled-at only once so restart skip doesn't reset the 24h clock.
  Future<void> touchGroupFilledIfMissing({
    required String sourceId,
    required String groupName,
  }) async {
    final key = _groupFilledMetaKey(sourceId, groupName);
    final existing = await _getMeta(key);
    if (existing != null && existing.isNotEmpty) return;
    await touchGroupFilled(sourceId: sourceId, groupName: groupName);
  }

  Future<List<MediaItem>> channelsForSource(String sourceId) async {
    final db = await _database;
    final rows = await db.query(
      'live_channels',
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
    return [for (final row in rows) _itemFromRow(row)];
  }

  /// Replace live rows for one group of [sourceId], keep other groups.
  ///
  /// Rebuilds collapsed listings for **this group only** — never reloads the
  /// whole source into memory (idle Xtream fill used to N× load ~27k rows).
  ///
  /// Skips the DELETE+rebuild when [channels] matches the stored fingerprint
  /// so a restart prefetch does not flash an empty list. An empty payload
  /// does not wipe a warm group (failed/partial Xtream replies).
  Future<LiveGroupUpsertResult> upsertSourceGroupLive({
    required String sourceId,
    required String groupName,
    required List<MediaItem> channels,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    if (channels.isEmpty) {
      final listingCount = await countListingsInGroup(
        sourceId: sourceId,
        groupName: groupName,
      );
      if (listingCount > 0) return LiveGroupUpsertResult.keptExisting;
      return LiveGroupUpsertResult.unchanged;
    }
    final packed = await packLiveChannelRowsYielding(channels);
    return upsertSourceGroupLivePacked(
      sourceId: sourceId,
      groupName: groupName,
      channels: packed,
      epgDisplayNames: epgDisplayNames,
      preferredLiveQualities: preferredLiveQualities,
    );
  }

  /// Same as [upsertSourceGroupLive] from packed SQL maps — no [MediaItem]
  /// hydrate. Opening a 20k-row live group must not copy that graph on UI.
  Future<LiveGroupUpsertResult> upsertSourceGroupLivePacked({
    required String sourceId,
    required String groupName,
    required List<Map<String, Object?>> channels,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    final listingCount = await countListingsInGroup(
      sourceId: sourceId,
      groupName: groupName,
    );
    if (channels.isEmpty) {
      if (listingCount > 0) return LiveGroupUpsertResult.keptExisting;
      return LiveGroupUpsertResult.unchanged;
    }

    final packed = channels;
    final fp = await liveContentFingerprintAsync(packed);
    final fpKey = _groupFpMetaKey(sourceId, groupName);
    final storedFp = await _getMeta(fpKey);
    if (listingCount > 0 && storedFp == fp) {
      await touchGroupFilled(sourceId: sourceId, groupName: groupName);
      return LiveGroupUpsertResult.unchanged;
    }
    if (listingCount > 0 && storedFp == null) {
      final existing = await _packedChannelsInGroup(
        sourceId: sourceId,
        groupName: groupName,
      );
      if (existing.isNotEmpty &&
          await liveContentFingerprintAsync(existing) == fp) {
        await _setMeta(fpKey, fp);
        await touchGroupFilled(sourceId: sourceId, groupName: groupName);
        return LiveGroupUpsertResult.unchanged;
      }
    }

    final db = await _database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        '''
DELETE FROM live_variants WHERE channel_id IN (
  SELECT id FROM live_channels
  WHERE source_id = ? AND IFNULL(group_name, '') = ?
)
''',
        [sourceId, groupName],
      );
      await txn.delete(
        'live_listings',
        where: 'source_id = ? AND IFNULL(group_name, \'\') = ?',
        whereArgs: [sourceId, groupName],
      );
      await txn.delete(
        'live_channels',
        where: 'source_id = ? AND IFNULL(group_name, \'\') = ?',
        whereArgs: [sourceId, groupName],
      );

      await _insertChannelRows(txn, packed);
    });

    await yieldAfterIsolateChunk();

    final scopedEpg = scopedEpgDisplayNamesForPacked(packed, epgDisplayNames);
    if (packed.isNotEmpty) {
      final plan = await buildLiveIngestPlanInIsolate(
        sourceId: sourceId,
        channels: packed,
        epgDisplayNames: scopedEpg,
        preferredLiveQualities: preferredLiveQualities,
      );
      await _writeListingPlan(
        sourceId: sourceId,
        plan: plan,
        replaceSource: false,
        groupName: groupName,
      );
    }

    await yieldAfterIsolateChunk();
    // Group upserts are frequent during idle fill — avoid scanning the full
    // source just to rewrite a content fingerprint used by legacy migrate.
    await _setMeta(_familyKeyLogicMeta, _familyKeyLogicVersion);
    await _setMeta(fpKey, fp);
    await touchGroupFilled(sourceId: sourceId, groupName: groupName);
    return LiveGroupUpsertResult.written;
  }

  Future<List<Map<String, Object?>>> _packedChannelsInGroup({
    required String sourceId,
    required String groupName,
  }) async {
    final db = await _database;
    return db.query(
      'live_channels',
      where: 'source_id = ? AND IFNULL(group_name, \'\') = ?',
      whereArgs: [sourceId, groupName],
    );
  }

  Future<bool> get hasListings async {
    if (kIsWeb) return false;
    final db = await _database;
    // Never COUNT(*) the whole table just to probe emptiness.
    final rows = await db.rawQuery('SELECT 1 FROM live_listings LIMIT 1');
    return rows.isNotEmpty;
  }

  /// Replace all live rows for [sourceId], then rebuild collapsed listings.
  ///
  /// Returns `false` when [channels] match the stored content fingerprint so
  /// callers can skip live-list revision bumps (Live TV would otherwise
  /// rematerialize and steal the restore / input frame).
  Future<bool> replaceSourceLive({
    required String sourceId,
    required List<MediaItem> channels,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    final packed = await packLiveChannelRowsYielding(channels);
    return replaceSourceLivePacked(
      sourceId: sourceId,
      channels: packed,
      epgDisplayNames: epgDisplayNames,
      preferredLiveQualities: preferredLiveQualities,
    );
  }

  /// Replace live rows from packed SQL maps — no [MediaItem] hydrate.
  ///
  /// When [plan] is omitted, listings are built in a worker from [channels].
  Future<bool> replaceSourceLivePacked({
    required String sourceId,
    required List<Map<String, Object?>> channels,
    LiveIngestPlan? plan,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    final scopedEpg = scopedEpgDisplayNamesForPacked(channels, epgDisplayNames);
    final fp =
        plan?.contentFingerprint ?? await liveContentFingerprintAsync(channels);
    final fpKey = _sourceFpMetaKey(sourceId);
    final storedFp = await _getMeta(fpKey);
    if (storedFp == fp) {
      return false;
    }
    final resolved =
        plan ??
        await buildLiveIngestPlanInIsolate(
          sourceId: sourceId,
          channels: channels,
          epgDisplayNames: scopedEpg,
          preferredLiveQualities: preferredLiveQualities,
        );
    final db = await _database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        '''
DELETE FROM live_variants WHERE channel_id IN (
  SELECT id FROM live_channels WHERE source_id = ?
)
''',
        [sourceId],
      );
      await txn.delete(
        'live_listings',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      await txn.delete(
        'live_channels',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );

      await _insertChannelRows(txn, resolved.channelRows);
    });

    await yieldAfterIsolateChunk();
    await _writeListingPlan(
      sourceId: sourceId,
      plan: resolved,
      replaceSource: true,
    );

    await yieldAfterIsolateChunk();
    await _setMeta(fpKey, fp);
    await _setMeta('fingerprint', resolved.indexFingerprint);
    await _setMeta(_familyKeyLogicMeta, _familyKeyLogicVersion);
    return true;
  }

  /// Stream an unscoped live dump without holding the full channel list.
  Future<LiveStreamingMerge> beginStreamingMerge({
    required String sourceId,
    Future<void> Function(int committed, int total)? onProgress,
  }) async {
    return LiveStreamingMerge._(
      db: this,
      sourceId: sourceId,
      onProgress: onProgress,
    );
  }

  /// Upsert a full live dump without wiping first — old channels stay
  /// queryable until the new id set is committed, then leftovers are retired.
  ///
  /// TV demand fills can keep serving a group while this runs. An empty dump
  /// does not wipe a warm source. Unchanged fingerprints skip the write.
  Future<bool> mergeSourceLivePacked({
    required String sourceId,
    required List<Map<String, Object?>> channels,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
    Future<void> Function(int committed, int total)? onProgress,
  }) async {
    if (channels.isEmpty) return false;
    final fp = await liveContentFingerprintAsync(channels);
    final fpKey = _sourceFpMetaKey(sourceId);
    if (await _getMeta(fpKey) == fp) {
      await onProgress?.call(channels.length, channels.length);
      return false;
    }

    final db = await _database;
    const chunk = 400;
    for (var i = 0; i < channels.length; i += chunk) {
      final end = i + chunk > channels.length ? channels.length : i + chunk;
      await db.transaction(
        (txn) => _insertChannelRows(txn, channels.sublist(i, end)),
      );
      await onProgress?.call(end, channels.length);
      await pumpUi();
    }

    final scopedEpg = scopedEpgDisplayNamesForPacked(channels, epgDisplayNames);
    final plan = await buildLiveIngestPlanInIsolate(
      sourceId: sourceId,
      channels: channels,
      epgDisplayNames: scopedEpg,
      preferredLiveQualities: preferredLiveQualities,
    );
    await _writeListingPlan(
      sourceId: sourceId,
      plan: plan,
      replaceSource: true,
    );

    final keepIds = {for (final row in channels) '${row['id'] ?? ''}'};
    keepIds.remove('');
    await db.transaction((txn) async {
      await txn.execute(
        'CREATE TEMP TABLE IF NOT EXISTS live_merge_keep (id TEXT PRIMARY KEY)',
      );
      await txn.delete('live_merge_keep');
      const idChunk = 400;
      final idList = keepIds.toList(growable: false);
      for (var i = 0; i < idList.length; i += idChunk) {
        final end = i + idChunk > idList.length ? idList.length : i + idChunk;
        final batch = txn.batch();
        for (var j = i; j < end; j++) {
          batch.insert('live_merge_keep', {'id': idList[j]});
        }
        await batch.commit(noResult: true);
      }
      await txn.rawDelete(
        '''
DELETE FROM live_variants WHERE channel_id IN (
  SELECT id FROM live_channels
  WHERE source_id = ? AND id NOT IN (SELECT id FROM live_merge_keep)
)
''',
        [sourceId],
      );
      await txn.delete(
        'live_channels',
        where: 'source_id = ? AND id NOT IN (SELECT id FROM live_merge_keep)',
        whereArgs: [sourceId],
      );
      await txn.execute('DROP TABLE IF EXISTS live_merge_keep');
    });

    await _setMeta(fpKey, fp);
    await _setMeta('fingerprint', plan.indexFingerprint);
    await _setMeta(_familyKeyLogicMeta, _familyKeyLogicVersion);
    final groups = <String>{
      for (final row in channels)
        if ('${row['group_name'] ?? ''}'.trim().isNotEmpty)
          '${row['group_name']}'.trim(),
    };
    for (final group in groups) {
      await touchGroupFilled(sourceId: sourceId, groupName: group);
    }
    return true;
  }

  /// One-shot migrate from in-memory / JSON catalog live rows.
  Future<void> migrateFromMediaItems(
    List<MediaItem> live, {
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    if (live.isEmpty) return;
    final bySource = <String, List<MediaItem>>{};
    for (final channel in live) {
      final sourceId = channel.sourceId ?? '__unknown__';
      bySource.putIfAbsent(sourceId, () => []).add(channel);
    }
    for (final entry in bySource.entries) {
      await replaceSourceLive(
        sourceId: entry.key,
        channels: entry.value,
        epgDisplayNames: epgDisplayNames,
        preferredLiveQualities: preferredLiveQualities,
      );
    }
    await _setMeta(_familyKeyLogicMeta, _familyKeyLogicVersion);
  }

  static const _familyKeyLogicMeta = 'family_key_logic';

  /// Bumped when [ChannelQuality.preferenceKey] grouping rules change so
  /// existing installs rebuild listings without a full playlist re-fetch.
  /// Also bump when listing columns used for search/ranking change meaning
  /// (e.g. v5 `search_title` must be cleaned base titles, not raw sort_title;
  /// v6 folds diacritics / punctuation into the same hay;
  /// v7–v8 store family-max catchup_days so HD Auto listings keep archive).
  static const _familyKeyLogicVersion = '8';

  /// True when collapsed listings were built with an older family-key scheme.
  Future<bool> get needsFamilyKeyReindex async {
    final current = await _getMeta(_familyKeyLogicMeta);
    return current != _familyKeyLogicVersion;
  }

  /// Rebuild listings/variants from rows already in [live_channels].
  Future<void> reindexFamilyKeys({
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
  }) async {
    final db = await _database;
    final sourceRows = await db.rawQuery(
      'SELECT DISTINCT source_id AS s FROM live_channels',
    );
    for (final row in sourceRows) {
      final sourceId = '${row['s'] ?? ''}';
      if (sourceId.isEmpty) continue;
      final channelRows = <Map<String, Object?>>[];
      var offset = 0;
      while (true) {
        final page = await db.query(
          'live_channels',
          where: 'source_id = ?',
          whereArgs: [sourceId],
          limit: kIsolateListChunk,
          offset: offset,
        );
        if (page.isEmpty) break;
        channelRows.addAll(page);
        offset += page.length;
        await yieldAfterIsolateChunk();
      }
      if (channelRows.isEmpty) continue;
      final plan = await buildLiveIngestPlanInIsolate(
        sourceId: sourceId,
        channels: channelRows,
        epgDisplayNames: epgDisplayNames,
        preferredLiveQualities: preferredLiveQualities,
      );
      await _writeListingPlan(
        sourceId: sourceId,
        plan: plan,
        replaceSource: true,
      );
    }
    await _setMeta(_familyKeyLogicMeta, _familyKeyLogicVersion);
  }

  Future<List<({MediaItem item, int variantCount, int familyCatchupDays})>>
  pageListings({
    String? groupName,
    String? sourceId,
    List<String>? allowedSourceIds,
    List<String>? excludedGroupNames,
    bool excludeAdult = false,
    String? query,
    int offset = 0,
    int limit = 80,
    bool catchupFirst = false,
    bool catchupOnly = false,
    LiveListingSort sort = LiveListingSort.position,
  }) async {
    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    if (groupName != null && groupName.isNotEmpty) {
      where.add('l.group_name = ?');
      args.add(groupName);
    }
    _appendSourceFilter(
      where: where,
      args: args,
      column: 'l.source_id',
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
    );
    _appendExcludedGroups(
      where: where,
      args: args,
      column: 'l.group_name',
      excludedGroupNames: excludedGroupNames,
    );
    _appendExcludeAdult(
      where: where,
      args: args,
      column: 'c.is_adult',
      excludeAdult: excludeAdult,
    );
    if (catchupOnly) {
      where.add('l.catchup_days > 0');
    }
    final q = query?.trim() ?? '';
    final useFts = q.isNotEmpty && _ftsEnabled;
    final digits = q.isNotEmpty ? IptvSearchQuery.digitsOnly(q) : null;
    // INNER JOIN keeps MATCH on the FTS inverted index. Digit-number OR would
    // exclude non-title hits, so those queries use an IN-subquery instead.
    final ftsJoined = useFts && digits == null;
    if (q.isNotEmpty) {
      _appendListingSearch(
        where: where,
        args: args,
        query: q,
        fts: useFts,
        ftsJoined: ftsJoined,
      );
    }

    final resolvedSort = catchupFirst ? LiveListingSort.catchupFirst : sort;
    final order = switch (resolvedSort) {
      LiveListingSort.catchupFirst => 'l.catchup_days DESC, l.sort_title ASC',
      LiveListingSort.category => 'l.group_name ASC, l.sort_title ASC',
      LiveListingSort.position => 'l.position ASC',
      LiveListingSort.name => 'l.sort_title ASC',
    };

    final ftsJoin = ftsJoined
        ? 'INNER JOIN live_fts ON live_fts.rowid = c.rowid'
        : '';
    final rankOrder = q.isEmpty
        ? order
        : '${_searchRankOrderSql(digits: digits != null, bm25: ftsJoined)}, $order';
    if (q.isNotEmpty) {
      args.addAll(_searchRankArgs(q));
    }

    final sql =
        '''
SELECT c.*, l.variant_count AS variant_count,
  l.catchup_days AS listing_catchup_days
FROM live_listings l
INNER JOIN live_channels c ON c.id = l.id
$ftsJoin
${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
ORDER BY $rankOrder
LIMIT ? OFFSET ?
''';
    args.addAll([limit, offset]);
    try {
      final rows = await db.rawQuery(sql, args);
      return [
        for (final row in rows)
          (
            item: _itemFromRow(row),
            variantCount: (row['variant_count'] as num?)?.toInt() ?? 1,
            familyCatchupDays:
                (row['listing_catchup_days'] as num?)?.toInt() ??
                (row['catchup_days'] as num?)?.toInt() ??
                0,
          ),
      ];
    } catch (_) {
      if (!useFts) rethrow;
      // FTS vanished / module unloaded mid-session — degrade to token LIKE.
      _ftsEnabled = false;
      return pageListings(
        groupName: groupName,
        sourceId: sourceId,
        allowedSourceIds: allowedSourceIds,
        excludedGroupNames: excludedGroupNames,
        excludeAdult: excludeAdult,
        query: query,
        offset: offset,
        limit: limit,
        catchupFirst: catchupFirst,
        catchupOnly: catchupOnly,
        sort: sort,
      );
    }
  }

  static void _appendListingSearch({
    required List<String> where,
    required List<Object?> args,
    required String query,
    required bool fts,
    required bool ftsJoined,
  }) {
    final parts = <String>[];
    if (fts) {
      final match = IptvSearchQuery.ftsMatchQuery(query);
      if (match.isNotEmpty) {
        if (ftsJoined) {
          parts.add('live_fts MATCH ?');
        } else {
          parts.add(
            'c.rowid IN (SELECT rowid FROM live_fts WHERE live_fts MATCH ?)',
          );
        }
        args.add(match);
      }
    } else {
      final tokens = IptvSearchQuery.tokens(query);
      if (tokens.isNotEmpty) {
        final tokenAnd = tokens
            .map((_) => 'INSTR(l.search_title, ?) > 0')
            .join(' AND ');
        parts.add('($tokenAnd)');
        args.addAll(tokens);
      }
    }
    final digits = IptvSearchQuery.digitsOnly(query);
    if (digits != null) {
      parts.add(
        '(IFNULL(c.stream_id, \'\') = ? OR IFNULL(c.channel_id, \'\') = ? OR '
        'IFNULL(c.stream_id, \'\') LIKE ? OR IFNULL(c.channel_id, \'\') LIKE ?)',
      );
      args.addAll([digits, digits, '$digits%', '$digits%']);
    }
    if (parts.isEmpty) {
      where.add('0');
      return;
    }
    where.add('(${parts.join(' OR ')})');
  }

  /// Prefix / contains on the cleaned listing title; channel numbers first.
  static String _searchRankOrderSql({
    required bool digits,
    required bool bm25,
  }) {
    final numberRank = digits
        ? 'WHEN IFNULL(c.stream_id, \'\') = ? OR IFNULL(c.channel_id, \'\') = ? THEN -1 '
              'WHEN IFNULL(c.stream_id, \'\') LIKE ? OR IFNULL(c.channel_id, \'\') LIKE ? THEN 0 '
        : '';
    return '''
CASE
  $numberRank
  WHEN l.search_title = ? THEN 1
  WHEN l.search_title LIKE ? THEN 2
  WHEN l.search_title LIKE ? THEN 3
  WHEN INSTR(l.search_title, ?) > 0 THEN 4
  ELSE 5
END ASC${bm25 ? ', bm25(live_fts)' : ''}''';
  }

  static List<Object?> _searchRankArgs(String query) {
    final nq = IptvSearchQuery.normalize(query);
    final tokens = IptvSearchQuery.tokens(query);
    final first = tokens.isNotEmpty ? tokens.first : nq;
    final digits = IptvSearchQuery.digitsOnly(query);
    return [
      if (digits != null) digits,
      if (digits != null) digits,
      if (digits != null) '$digits%',
      if (digits != null) '$digits%',
      nq,
      '$nq%',
      '$first%',
      nq,
    ];
  }

  /// First listing per XMLTV id (Guide search → live row).
  Future<List<MediaItem>> channelsByEpgChannelIds(List<String> ids) async {
    final wanted = [
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    if (wanted.isEmpty) return const [];
    final db = await _database;
    final out = <MediaItem>[];
    final seen = <String>{};
    const chunk = 400;
    for (var i = 0; i < wanted.length; i += chunk) {
      final slice = wanted.sublist(
        i,
        i + chunk > wanted.length ? wanted.length : i + chunk,
      );
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT * FROM live_channels WHERE epg_channel_id IN ($placeholders)',
        slice,
      );
      for (final row in rows) {
        final epgId = '${row['epg_channel_id'] ?? ''}'.trim();
        if (epgId.isEmpty || !seen.add(epgId)) continue;
        out.add(_itemFromRow(row));
      }
    }
    return out;
  }

  Future<List<MediaItem>> channelsByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final db = await _database;
    final out = <MediaItem>[];
    const chunk = 400;
    for (var i = 0; i < ids.length; i += chunk) {
      final slice = ids.sublist(
        i,
        i + chunk > ids.length ? ids.length : i + chunk,
      );
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT * FROM live_channels WHERE id IN ($placeholders)',
        slice,
      );
      final byId = {for (final row in rows) '${row['id']}': _itemFromRow(row)};
      for (final id in slice) {
        final item = byId[id];
        if (item != null) out.add(item);
      }
    }
    return out;
  }

  Future<MediaItem?> channelById(String id) async {
    final db = await _database;
    final rows = await db.query(
      'live_channels',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _itemFromRow(rows.first);
  }

  /// The collapsed "parent" listing row for [channel]'s quality family.
  ///
  /// Recents/favorites must collapse quality variants (HD/FHD/SD) into the one
  /// listing row the UI already shows — not record each variant the user zapped
  /// to. Returns null when the channel (or its family) is not indexed.
  Future<MediaItem?> listingForChannel(MediaItem channel) async {
    final db = await _database;

    // Direct hit: already the collapsed parent listing row.
    var rows = await db.rawQuery(
      'SELECT c.* FROM live_listings l '
      'INNER JOIN live_channels c ON c.id = l.id '
      'WHERE l.id = ? LIMIT 1',
      [channel.id],
    );
    if (rows.isNotEmpty) return _itemFromRow(rows.first);

    // Resolve the family: variant row membership, or a stream match for
    // catchup clips (which carry stream_id/source_id, not the channel row id).
    var family = await familyKeyFor(channel.id);
    if (family == null) {
      final streamId = channel.streamId?.trim();
      final sourceId = channel.sourceId?.trim();
      if (streamId != null &&
          streamId.isNotEmpty &&
          sourceId != null &&
          sourceId.isNotEmpty) {
        final viaStream = await db.rawQuery(
          'SELECT v.family_key FROM live_variants v '
          'INNER JOIN live_channels c ON c.id = v.channel_id '
          'WHERE c.stream_id = ? AND c.source_id = ? LIMIT 1',
          [streamId, sourceId],
        );
        if (viaStream.isNotEmpty) {
          family = '${viaStream.first['family_key']}';
        }
      }
    }
    if (family == null) return null;

    final familyRows = await db.rawQuery(
      'SELECT c.* FROM live_listings l '
      'INNER JOIN live_channels c ON c.id = l.id '
      'WHERE l.family_key = ? LIMIT 1',
      [family],
    );
    if (familyRows.isEmpty) return null;
    return _itemFromRow(familyRows.first);
  }

  /// All quality variants for [channel]'s family, or empty when unknown.
  ///
  /// Returns `const []` (not `[channel]`) when the channel isn't indexed so
  /// callers can distinguish "not found" from a genuine single-quality family
  /// and avoid poisoning in-memory caches.
  Future<List<MediaItem>> variantsForChannel(MediaItem channel) async {
    final db = await _database;
    final listing = await db.query(
      'live_listings',
      columns: ['family_key'],
      where: 'id = ?',
      whereArgs: [channel.id],
      limit: 1,
    );
    final family = listing.isEmpty
        ? null
        : listing.first['family_key'] as String?;
    if (family == null || family.isEmpty) {
      // Try reverse lookup via variants table membership.
      final via = await db.rawQuery(
        '''
SELECT v.family_key FROM live_variants v
WHERE v.channel_id = ?
LIMIT 1
''',
        [channel.id],
      );
      if (via.isEmpty) return const [];
      return _variantsForFamily('${via.first['family_key']}');
    }
    return _variantsForFamily(family);
  }

  Future<List<MediaItem>> _variantsForFamily(String familyKey) async {
    final db = await _database;
    final rows = await db.rawQuery(
      '''
SELECT c.* FROM live_variants v
INNER JOIN live_channels c ON c.id = v.channel_id
WHERE v.family_key = ?
ORDER BY v.rank ASC
''',
      [familyKey],
    );
    if (rows.isEmpty) return const [];
    return [for (final row in rows) _itemFromRow(row)];
  }

  Future<int> variantCountFor(String channelId) async {
    final db = await _database;
    final rows = await db.query(
      'live_listings',
      columns: ['variant_count'],
      where: 'id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    if (rows.isEmpty) return 1;
    return (rows.first['variant_count'] as num?)?.toInt() ?? 1;
  }

  Future<String?> familyKeyFor(String channelId) async {
    final db = await _database;
    final rows = await db.query(
      'live_listings',
      columns: ['family_key'],
      where: 'id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final key = rows.first['family_key'] as String?;
      if (key != null && key.isNotEmpty) return key;
    }
    final via = await db.rawQuery(
      'SELECT family_key FROM live_variants WHERE channel_id = ? LIMIT 1',
      [channelId],
    );
    if (via.isEmpty) return null;
    return '${via.first['family_key']}';
  }

  Future<void> _setMeta(String key, String value) async {
    final db = await _database;
    await _setMetaOn(db, key, value);
  }

  Future<void> _setMetaOn(DatabaseExecutor db, String key, String value) async {
    await db.insert('live_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> _getMeta(String key) async {
    final db = await _database;
    return _getMetaOn(db, key);
  }

  Future<String?> _getMetaOn(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'live_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  static Future<void> _insertChannelRows(
    Transaction txn,
    List<Map<String, Object?>> rows,
  ) async {
    const chunk = 400;
    for (var i = 0; i < rows.length; i += chunk) {
      final end = i + chunk > rows.length ? rows.length : i + chunk;
      final batch = txn.batch();
      for (var j = i; j < end; j++) {
        batch.insert(
          'live_channels',
          sanitizeLiveChannelRow(rows[j]),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  /// Write collapsed listings from a worker-built [plan].
  ///
  /// [replaceSource] deletes existing listings/variants for [sourceId] first
  /// (full replace). Group upserts already deleted those rows.
  Future<void> _writeListingPlan({
    required String sourceId,
    required LiveIngestPlan plan,
    required bool replaceSource,
    String? groupName,
  }) async {
    if (plan.listingRows.isEmpty && plan.variantRows.isEmpty) return;
    final db = await _database;
    final posSql = replaceSource
        ? 'SELECT COALESCE(MAX(position), -1) AS m FROM live_listings WHERE source_id != ?'
        : 'SELECT COALESCE(MAX(position), -1) AS m FROM live_listings';
    final posArgs = replaceSource ? [sourceId] : const <Object?>[];
    final posRows = await db.rawQuery(posSql, posArgs);
    var position = ((posRows.first['m'] as num?)?.toInt() ?? -1) + 1;

    if (replaceSource) {
      await db.transaction((txn) async {
        await txn.delete(
          'live_variants',
          where:
              'family_key IN (SELECT family_key FROM live_listings WHERE source_id = ? AND family_key IS NOT NULL)',
          whereArgs: [sourceId],
        );
        await txn.delete(
          'live_listings',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
      });
    }

    // One short transaction per chunk — never yield while a txn is open
    // (that held the FFI lock and froze Windows during live dump).
    const chunk = 400;
    for (var i = 0; i < plan.listingRows.length; i += chunk) {
      final end = i + chunk > plan.listingRows.length
          ? plan.listingRows.length
          : i + chunk;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var j = i; j < end; j++) {
          final row = Map<String, Object?>.from(plan.listingRows[j]);
          if (groupName != null &&
              (row['group_name'] == null || '${row['group_name']}' == '')) {
            row['group_name'] = groupName;
          }
          row['position'] = position++;
          batch.insert(
            'live_listings',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
      await pumpUi();
    }

    for (var i = 0; i < plan.variantRows.length; i += chunk) {
      final end = i + chunk > plan.variantRows.length
          ? plan.variantRows.length
          : i + chunk;
      await db.transaction((txn) async {
        final variantBatch = txn.batch();
        for (var j = i; j < end; j++) {
          variantBatch.insert(
            'live_variants',
            plan.variantRows[j],
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await variantBatch.commit(noResult: true);
      });
      await pumpUi();
    }
  }

  static String _groupFpMetaKey(String sourceId, String groupName) =>
      'gfp:${Uri.encodeComponent(sourceId)}:${Uri.encodeComponent(groupName)}';

  static String _sourceFpMetaKey(String sourceId) =>
      'sfp:${Uri.encodeComponent(sourceId)}';

  static String _sourceLiveDumpAtMetaKey(String sourceId) =>
      'slive_at:${Uri.encodeComponent(sourceId)}';

  static String _groupFilledMetaKey(String sourceId, String groupName) =>
      'gfilled:${Uri.encodeComponent(sourceId)}:${Uri.encodeComponent(groupName)}';

  static MediaItem _itemFromRow(Map<String, Object?> row) {
    final originName = '${row['origin'] ?? ''}';
    final origin =
        MediaOrigin.values.asNameMap()[originName] ??
        (originName.isEmpty ? MediaOrigin.iptvXtream : MediaOrigin.url);
    Map<String, String> headers = const {};
    final rawHeaders = row['http_headers_json'];
    if (rawHeaders is String && rawHeaders.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawHeaders);
        if (decoded is Map) {
          headers = {for (final e in decoded.entries) '${e.key}': '${e.value}'};
        }
      } catch (_) {}
    }
    final serverItemId = () {
      final s = '${row['server_item_id'] ?? ''}'.trim();
      return s.isEmpty ? null : s;
    }();
    final rawPlayUrl = '${row['play_url']}';
    return MediaItem(
      id: '${row['id']}',
      title: '${row['title']}',
      playUrl: origin == MediaOrigin.iptvXtream
          ? stripXtreamCredentials(rawPlayUrl)
          : rawPlayUrl,
      kind: MediaKind.live,
      origin: origin,
      thumbnailUrl: row['thumbnail_url'] as String?,
      group: row['group_name'] as String?,
      channelId: row['channel_id'] as String?,
      channelName: row['channel_name'] as String?,
      streamId: row['stream_id'] as String?,
      epgChannelId: row['epg_channel_id'] as String?,
      serverItemId: serverItemId,
      catchupDays: (row['catchup_days'] as num?)?.toInt() ?? 0,
      sourceId: () {
        final s = '${row['source_id'] ?? ''}';
        return s.isEmpty ? null : s;
      }(),
      httpHeaders: headers,
      isAdult: ((row['is_adult'] as num?)?.toInt() ?? 0) != 0,
    );
  }
}

/// Progressive live merge that never holds the unscoped dump on the UI isolate.
class LiveStreamingMerge {
  LiveStreamingMerge._({
    required LiveChannelDb db,
    required this.sourceId,
    required this.onProgress,
  }) : _db = db;

  final LiveChannelDb _db;
  final String sourceId;
  final Future<void> Function(int committed, int total)? onProgress;

  final _keepIds = <String>{};
  final _groups = <String>{};
  var _committed = 0;
  var _listingsStarted = false;
  var _position = 0;
  var _skipped = false;
  var _closed = false;
  String indexFingerprint = '';

  String get _fpKey => LiveChannelDb._sourceFpMetaKey(sourceId);

  Future<bool> skipIfFingerprint(String fingerprint) async {
    if (fingerprint.isEmpty || fingerprint == '0') return false;
    if (await _db._getMeta(_fpKey) != fingerprint) return false;
    _skipped = true;
    _closed = true;
    return true;
  }

  Future<void> addChannelChunk(
    List<Map<String, Object?>> rows, {
    required int total,
  }) async {
    if (_closed || _skipped || rows.isEmpty) return;
    final db = await _db._database;
    await db.transaction((txn) => LiveChannelDb._insertChannelRows(txn, rows));
    for (final row in rows) {
      final id = '${row['id'] ?? ''}';
      if (id.isNotEmpty) _keepIds.add(id);
      final group = '${row['group_name'] ?? ''}'.trim();
      if (group.isNotEmpty) _groups.add(group);
    }
    _committed += rows.length;
    await onProgress?.call(_committed, total);
    await pumpUi();
  }

  Future<void> addListingChunk(List<Map<String, Object?>> rows) async {
    if (_closed || _skipped || rows.isEmpty) return;
    final db = await _db._database;
    if (!_listingsStarted) {
      _listingsStarted = true;
      final posRows = await db.rawQuery(
        'SELECT COALESCE(MAX(position), -1) AS m FROM live_listings '
        'WHERE source_id != ?',
        [sourceId],
      );
      _position = ((posRows.first['m'] as num?)?.toInt() ?? -1) + 1;
      await db.transaction((txn) async {
        await txn.delete(
          'live_variants',
          where:
              'family_key IN (SELECT family_key FROM live_listings '
              'WHERE source_id = ? AND family_key IS NOT NULL)',
          whereArgs: [sourceId],
        );
        await txn.delete(
          'live_listings',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
      });
    }
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final raw in rows) {
        final row = Map<String, Object?>.from(raw);
        row['position'] = _position++;
        batch.insert(
          'live_listings',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    await pumpUi();
  }

  Future<void> addVariantChunk(List<Map<String, Object?>> rows) async {
    if (_closed || _skipped || rows.isEmpty) return;
    final db = await _db._database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'live_variants',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    await pumpUi();
  }

  Future<bool> finish({required String fingerprint}) async {
    if (_closed || _skipped) return false;
    final db = await _db._database;
    if (_keepIds.isEmpty) {
      _closed = true;
      return false;
    }
    await db.execute(
      'CREATE TEMP TABLE IF NOT EXISTS live_merge_keep (id TEXT PRIMARY KEY)',
    );
    await db.delete('live_merge_keep');
    const idChunk = 400;
    final idList = _keepIds.toList(growable: false);
    for (var i = 0; i < idList.length; i += idChunk) {
      final end = i + idChunk > idList.length ? idList.length : i + idChunk;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var j = i; j < end; j++) {
          batch.insert('live_merge_keep', {'id': idList[j]});
        }
        await batch.commit(noResult: true);
      });
      await pumpUi();
    }
    await db.transaction((txn) async {
      await txn.rawDelete(
        '''
DELETE FROM live_variants WHERE channel_id IN (
  SELECT id FROM live_channels
  WHERE source_id = ? AND id NOT IN (SELECT id FROM live_merge_keep)
)
''',
        [sourceId],
      );
      await txn.delete(
        'live_channels',
        where: 'source_id = ? AND id NOT IN (SELECT id FROM live_merge_keep)',
        whereArgs: [sourceId],
      );
      await txn.execute('DROP TABLE IF EXISTS live_merge_keep');
    });
    await _db._setMeta(_fpKey, fingerprint);
    if (indexFingerprint.isNotEmpty) {
      await _db._setMeta('fingerprint', indexFingerprint);
    }
    await _db._setMeta(
      LiveChannelDb._familyKeyLogicMeta,
      LiveChannelDb._familyKeyLogicVersion,
    );
    await _db.touchSourceLiveDumpAt(sourceId: sourceId);
    for (final group in _groups) {
      await _db.touchGroupFilled(sourceId: sourceId, groupName: group);
      await pumpUi();
    }
    _closed = true;
    return true;
  }

  Future<void> abort() async {
    _closed = true;
  }
}
