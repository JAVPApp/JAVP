import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';
import 'package:javp/services/storage/app_documents.dart';
import 'package:javp/services/storage/vod_sql_writer.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

typedef VodReplaceProgressCallback =
    FutureOr<void> Function(VodReplaceProgress progress);

class VodReplaceProgress {
  const VodReplaceProgress({
    required this.committed,
    required this.total,
    required this.finalized,
  });

  final int committed;
  final int total;
  final bool finalized;
}

/// Sort for [VodCatalogDb.pageItems] (SQLite ORDER BY).
enum VodCatalogOrder {
  /// A–Z on [sort_title] (legacy Catalog / Search pages).
  title,

  /// Catalog heat then rating then year — used for Popular Catalog browse.
  /// Same-source scale is fine in SQL; mixed sources are equalized in memory.
  popularity,

  /// Rating then year then title — used for Rating Catalog browse.
  rating,

  /// Year then title.
  year,

  /// Insertion/rowid order — cheap paging (no sort_title scan).
  ///
  /// Do **not** use a single unscoped `ORDER BY rowid LIMIT n` for mixed-source
  /// Home rails: after SyncEngine replaces a fat Xtream catalog, that source
  /// gets high rowids while a tiny BYO/custom catalog keeps low ones and
  /// monopolizes Accueil. Prefer [VodCatalogDb.pageHomePreviewItems].
  rowid,
}

/// SQLite store for IPTV / catalog VOD + series — page + FTS, not full-list scans.
///
/// FTS5 is best-effort: some Android SQLite builds ship without the module
/// (`no such module: fts5`). Paging still works; search falls back to LIKE.
class VodCatalogDb {
  VodCatalogDb({
    this.profileId = Profile.defaultId,
    this.debugDatabasePath,
    this.debugForceDisableFts = false,
  });

  final String profileId;

  /// When set (tests), open this file instead of the app documents path.
  final String? debugDatabasePath;

  /// Test-only: skip FTS5 install and exercise the LIKE search path.
  final bool debugForceDisableFts;

  Database? _db;
  Future<Database>? _opening;
  String? _resolvedPath;
  bool _ftsEnabled = false;
  final Map<String, Future<void>> _sourceReplaceTails = {};
  final Map<String, int> _activeSyncGenerationBySource = {};
  final Map<String, int> _committedGenerationBySource = {};

  static const _batchChunk = 400;
  static int _lastSyncGeneration = 0;
  static const _migratedMeta = 'migrated_from_json';
  static const _schemaNoteMeta = 'schema_note';
  static const _ftsMeta = 'fts5';
  static const _ftsSchemaMeta = 'fts_schema';
  static const _itemCountMeta = 'item_count';

  /// `2` = unicode61 remove_diacritics so MATCH folds accents without INSTR.
  static const _ftsSchemaVersion = '2';
  static const _sortTitleLogicMeta = 'sort_title_logic';

  /// Bumped when ingest-time [sort_title] normalization changes meaning.
  static const _sortTitleLogicVersion = '1';

  /// True when this connection has a usable `vod_fts` table.
  bool get ftsEnabled => _ftsEnabled;

  /// Absolute path of the open catalog file (native ingest writer).
  Future<String> get databaseFilePath async {
    if (_resolvedPath != null) return _resolvedPath!;
    await _database;
    return _resolvedPath!;
  }

  Future<Database> get _database async {
    if (_db != null) return _db!;
    try {
      return await (_opening ??= _open());
    } catch (_) {
      // Allow a later retry after a failed create (e.g. transient IO).
      _opening = null;
      rethrow;
    }
  }

  /// Open (or no-op) so callers can probe before flipping `_useVodDb`.
  Future<void> ensureOpen() async {
    await _database;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    _ftsEnabled = false;
    await db?.close();
  }

  Future<Database> _open() async {
    final resolved =
        debugDatabasePath ??
        await AppDocuments.profileFilePath(
          profileId: profileId,
          fileName: 'vod_catalog.db',
        );
    _resolvedPath = resolved;
    await Directory(p.dirname(resolved)).create(recursive: true);
    final db = await openDatabase(
      resolved,
      version: 1,
      onConfigure: (db) async {
        // UI reads + SyncEngine / VodSqlWriter share this file under WAL.
        // Android sqflite rejects these PRAGMAs via execute() — use rawQuery.
        await db.rawQuery('PRAGMA busy_timeout = 30000');
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA synchronous=NORMAL');
      },
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE vod_items (
  id TEXT PRIMARY KEY NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  origin TEXT NOT NULL,
  title TEXT NOT NULL,
  sort_title TEXT NOT NULL,
  play_url TEXT NOT NULL,
  subtitle TEXT,
  group_name TEXT,
  stream_id TEXT,
  thumbnail_url TEXT,
  poster_url TEXT,
  backdrop_url TEXT,
  year INTEGER,
  rating REAL,
  popularity REAL,
  tmdb_id INTEGER,
  imdb_id TEXT,
  anilist_id INTEGER,
  tvdb_id INTEGER,
  details_id TEXT,
  series_id TEXT,
  server_item_id TEXT,
  is_adult INTEGER NOT NULL DEFAULT 0,
  sync_generation INTEGER NOT NULL DEFAULT 0,
  extras_json TEXT
)''');
        await db.execute('CREATE INDEX idx_vod_source ON vod_items(source_id)');
        await db.execute(
          'CREATE INDEX idx_vod_group_kind ON vod_items(group_name, kind)',
        );
        await db.execute(
          'CREATE INDEX idx_vod_source_group ON vod_items(source_id, group_name, kind)',
        );
        await db.execute(
          'CREATE INDEX idx_vod_kind_sort ON vod_items(kind, sort_title)',
        );
        await db.execute('CREATE INDEX idx_vod_tmdb ON vod_items(tmdb_id)');
        await db.execute(
          'CREATE INDEX idx_vod_popularity ON vod_items(source_id, popularity)',
        );
        await db.execute(
          'CREATE INDEX idx_vod_source_generation '
          'ON vod_items(source_id, sync_generation)',
        );
        await db.execute(
          'CREATE INDEX idx_vod_source_group_generation '
          'ON vod_items(source_id, group_name, sync_generation)',
        );

        await db.execute('''
CREATE TABLE vod_meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
)''');
        // FTS5 is optional — never fail onCreate when the module is missing.
        if (!debugForceDisableFts) {
          await _installFtsIfSupported(db, rebuild: false);
        }
      },
    );
    _db = db;
    // Soft migrate: older v1 DBs may lack the TMDB lookup index / FTS.
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_vod_tmdb ON vod_items(tmdb_id)',
      );
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE vod_items ADD COLUMN popularity REAL');
    } catch (_) {}
    try {
      await db.execute(
        'ALTER TABLE vod_items ADD COLUMN '
        'sync_generation INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_vod_popularity '
        'ON vod_items(source_id, popularity)',
      );
    } catch (_) {}
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_vod_source_generation '
        'ON vod_items(source_id, sync_generation)',
      );
    } catch (_) {}
    try {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_vod_source_group_generation '
        'ON vod_items(source_id, group_name, sync_generation)',
      );
    } catch (_) {}
    if (debugForceDisableFts) {
      _ftsEnabled = false;
      await _dropFtsTriggers(db);
      try {
        await _setMetaOn(db, _ftsMeta, '0');
      } catch (_) {}
    } else {
      await _syncFtsSupport(db);
    }
    // Progressive replacement deliberately commits between chunks so Catalog
    // and Search can interleave reads. WAL + NORMAL are set in onConfigure;
    // keep a soft fallback for older open paths / tests.
    try {
      await db.rawQuery('PRAGMA busy_timeout = 30000');
      await db.rawQuery('PRAGMA journal_mode=WAL');
      await db.rawQuery('PRAGMA synchronous=NORMAL');
    } catch (_) {
      // Some platform SQLite builds own journal configuration. The generation
      // protocol remains correct; only commit throughput may be lower.
    }
    return db;
  }

  /// Fire TV / some Android SQLite builds omit FTS5. Probe a temp table so we
  /// never create `vod_fts` (or its sync triggers) when the module is missing.
  /// A failed `CREATE VIRTUAL TABLE vod_fts` can still leave a sqlite_master
  /// row; DROP then also fails, and leftover AFTER DELETE triggers abort
  /// every `vod_items` write with `no such module: fts5`.
  Future<bool> _sqliteSupportsFts5(DatabaseExecutor db) async {
    try {
      await db.execute(
        'CREATE VIRTUAL TABLE temp._javp_fts5_probe USING fts5(x)',
      );
      await db.execute('DROP TABLE temp._javp_fts5_probe');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ftsTableExists(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT 1 AS x FROM sqlite_master WHERE type = 'table' "
      "AND name = 'vod_fts' LIMIT 1",
    );
    return rows.isNotEmpty;
  }

  /// Create FTS5 + sync triggers when the linked SQLite build includes FTS5.
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
CREATE VIRTUAL TABLE vod_fts USING fts5(
  title,
  subtitle,
  group_name,
  stream_id,
  content='vod_items',
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
CREATE TRIGGER IF NOT EXISTS vod_items_ai AFTER INSERT ON vod_items BEGIN
  INSERT INTO vod_fts(rowid, title, subtitle, group_name, stream_id)
  VALUES (new.rowid, new.title, new.subtitle, new.group_name, new.stream_id);
END''');
      await db.execute('''
CREATE TRIGGER IF NOT EXISTS vod_items_ad AFTER DELETE ON vod_items BEGIN
  INSERT INTO vod_fts(vod_fts, rowid, title, subtitle, group_name, stream_id)
  VALUES ('delete', old.rowid, old.title, old.subtitle, old.group_name, old.stream_id);
END''');
      await db.execute('''
CREATE TRIGGER IF NOT EXISTS vod_items_au AFTER UPDATE ON vod_items BEGIN
  INSERT INTO vod_fts(vod_fts, rowid, title, subtitle, group_name, stream_id)
  VALUES ('delete', old.rowid, old.title, old.subtitle, old.group_name, old.stream_id);
  INSERT INTO vod_fts(rowid, title, subtitle, group_name, stream_id)
  VALUES (new.rowid, new.title, new.subtitle, new.group_name, new.stream_id);
END''');
      if (rebuild && !alreadyHad) {
        await db.execute("INSERT INTO vod_fts(vod_fts) VALUES('rebuild')");
      }
      try {
        await _setMetaOn(db, _ftsSchemaMeta, _ftsSchemaVersion);
      } catch (_) {}
      return true;
    } catch (_) {
      // Keep an existing FTS table; only roll back a brand-new create.
      if (!alreadyHad) {
        try {
          await db.execute('DROP TABLE IF EXISTS vod_fts');
        } catch (_) {}
        await _dropFtsTriggers(db);
      }
      return alreadyHad;
    }
  }

  Future<void> _dropFtsTriggers(DatabaseExecutor db) async {
    for (final name in ['vod_items_ai', 'vod_items_ad', 'vod_items_au']) {
      try {
        await db.execute('DROP TRIGGER IF EXISTS $name');
      } catch (_) {}
    }
  }

  Future<void> _dropFtsTable(DatabaseExecutor db) async {
    await _dropFtsTriggers(db);
    try {
      await db.execute('DROP TABLE IF EXISTS vod_fts');
    } catch (_) {}
  }

  Future<void> _syncFtsSupport(Database db) async {
    if (!await _sqliteSupportsFts5(db)) {
      await _dropFtsTriggers(db);
      _ftsEnabled = false;
      try {
        await _setMetaOn(db, _ftsMeta, '0');
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
      // Ensure triggers exist for older DBs that created the table only.
      await _installFtsIfSupported(db, rebuild: false);
      try {
        await _setMetaOn(db, _ftsMeta, '1');
      } catch (_) {}
      return;
    }
    final installed = await _installFtsIfSupported(db, rebuild: true);
    _ftsEnabled = installed;
    try {
      await _setMetaOn(db, _ftsMeta, installed ? '1' : '0');
    } catch (_) {}
  }

  Future<bool> get hasItems async {
    final db = await _database;
    final rows = await db.rawQuery('SELECT 1 AS x FROM vod_items LIMIT 1');
    return rows.isNotEmpty;
  }

  Future<int> countItems({
    String? kind,
    bool? series,
    String? groupName,
    String? sourceId,
    List<String>? allowedSourceIds,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    _appendItemFilters(
      where: where,
      args: args,
      kind: kind,
      series: series,
      groupName: groupName,
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
      excludeAdult: excludeAdult,
    );
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM vod_items'
      '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> countForSource(String sourceId) => countItems(sourceId: sourceId);

  /// Cached total from the last replace / enable — avoids COUNT(*) of 200k rows.
  Future<int?> get cachedItemCount async {
    final raw = await _getMeta(_itemCountMeta);
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  Future<void> storeCachedItemCount(int n) =>
      _setMeta(_itemCountMeta, '$n');

  /// Source ids that already have at least one VOD/series row.
  Future<Set<String>> listSourceIds() async {
    final db = await _database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT source_id AS s FROM vod_items "
      "WHERE source_id IS NOT NULL AND source_id != '' "
      "AND kind IN ('vod', 'series')",
    );
    return {
      for (final r in rows)
        if ('${r['s'] ?? ''}'.trim().isNotEmpty) '${r['s']}'.trim(),
    };
  }

  Future<int> countInGroup({
    required String sourceId,
    required String groupName,
  }) => countItems(sourceId: sourceId, groupName: groupName);

  /// Give ungrouped VOD/series the source display name so Catalog can list them.
  ///
  /// Custom JSON / M3U / media-server rows with a null or blank `group_name`
  /// are invisible to [listGroupCounts] and the Catalog tab. Home still finds
  /// them via unscoped [pageItems]. Returns the number of rows updated.
  Future<int> fillEmptyGroups({
    required Map<String, String> namesBySourceId,
  }) async {
    if (namesBySourceId.isEmpty) return 0;
    final db = await _database;
    var changed = 0;
    for (final entry in namesBySourceId.entries) {
      final sourceId = entry.key.trim();
      final name = entry.value.trim();
      if (sourceId.isEmpty || name.isEmpty) continue;
      changed += await db.update(
        'vod_items',
        {'group_name': name},
        where:
            "source_id = ? AND (group_name IS NULL OR TRIM(group_name) = '')",
        whereArgs: [sourceId],
      );
    }
    return changed;
  }

  /// Distinct category titles, optionally scoped to one source / kind.
  Future<List<String>> listGroupNames({
    String? sourceId,
    List<String>? allowedSourceIds,
    bool? series,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    final where = <String>["group_name IS NOT NULL AND group_name != ''"];
    final args = <Object?>[];
    _appendItemFilters(
      where: where,
      args: args,
      series: series,
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
      excludeAdult: excludeAdult,
    );
    final rows = await db.rawQuery('''
SELECT DISTINCT group_name AS g
FROM vod_items
WHERE ${where.join(' AND ')}
ORDER BY g COLLATE NOCASE
''', args);
    return [
      for (final r in rows)
        if ('${r['g'] ?? ''}'.trim().isNotEmpty) '${r['g']}'.trim(),
    ];
  }

  Future<List<({String name, int count})>> listGroupCounts({
    String? sourceId,
    List<String>? allowedSourceIds,
    bool? series,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    final where = <String>["group_name IS NOT NULL AND group_name != ''"];
    final args = <Object?>[];
    _appendItemFilters(
      where: where,
      args: args,
      series: series,
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
      excludeAdult: excludeAdult,
    );
    final rows = await db.rawQuery('''
SELECT group_name AS g, COUNT(*) AS c
FROM vod_items
WHERE ${where.join(' AND ')}
GROUP BY group_name
ORDER BY g COLLATE NOCASE
''', args);
    return [
      for (final r in rows)
        if ('${r['g'] ?? ''}'.trim().isNotEmpty)
          (name: '${r['g']}'.trim(), count: (r['c'] as num?)?.toInt() ?? 0),
    ];
  }

  /// Group names per source — Catalog source chips without a RAM working set.
  Future<Map<String, Set<String>>> listGroupsBySource({
    List<String>? allowedSourceIds,
    bool? series,
    bool excludeAdult = false,
  }) async {
    final db = await _database;
    final where = <String>[
      "group_name IS NOT NULL AND group_name != ''",
      "source_id IS NOT NULL AND source_id != ''",
    ];
    final args = <Object?>[];
    _appendItemFilters(
      where: where,
      args: args,
      series: series,
      allowedSourceIds: allowedSourceIds,
      excludeAdult: excludeAdult,
    );
    final rows = await db.rawQuery('''
SELECT source_id AS s, group_name AS g
FROM vod_items
WHERE ${where.join(' AND ')}
GROUP BY source_id, group_name
''', args);
    final out = <String, Set<String>>{};
    for (final r in rows) {
      final sourceId = '${r['s'] ?? ''}'.trim();
      final group = '${r['g'] ?? ''}'.trim();
      if (sourceId.isEmpty || group.isEmpty) continue;
      out.putIfAbsent(sourceId, () => {}).add(group);
    }
    return out;
  }

  Future<List<MediaItem>> pageItems({
    String? kind,
    bool? series,
    String? groupName,
    String? sourceId,
    List<String>? allowedSourceIds,
    bool excludeAdult = false,
    bool latestGenerationOnly = true,
    VodCatalogOrder order = VodCatalogOrder.title,
    int offset = 0,
    int limit = 80,
  }) async {
    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    _appendItemFilters(
      where: where,
      args: args,
      kind: kind,
      series: series,
      groupName: groupName,
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
      excludeAdult: excludeAdult,
      latestGenerationOnly: latestGenerationOnly,
    );
    args.addAll([limit, offset < 0 ? 0 : offset]);
    final rows = await db.rawQuery('''
SELECT * FROM vod_items
${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
${_orderBySql(order)}
LIMIT ? OFFSET ?
''', args);
    return _itemsFromRowsYielding(rows);
  }

  /// Home Films/Series preview window that stays multi-source after a fat
  /// catalog replace.
  ///
  /// Unscoped `ORDER BY rowid LIMIT 64` returns only the lowest rowids. SyncEngine
  /// Xtream replaces rewrite ~200k rows to *new* high rowids, so a small
  /// custom/BYO catalog that kept older ids filled Accueil alone. Quota each
  /// allowed source, then merge (caller ranks with [VodGrouping.compareForHome]).
  Future<List<MediaItem>> pageHomePreviewItems({
    required bool series,
    List<String>? allowedSourceIds,
    bool excludeAdult = false,
    int limit = 64,
  }) async {
    if (limit <= 0) return const [];
    final sources = allowedSourceIds;
    if (sources == null || sources.isEmpty) {
      return pageItems(
        series: series,
        allowedSourceIds: allowedSourceIds,
        excludeAdult: excludeAdult,
        order: VodCatalogOrder.rowid,
        limit: limit,
      );
    }
    final per = (limit / sources.length).ceil().clamp(8, limit);
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final sid in sources) {
      if (sid.isEmpty) continue;
      final chunk = await pageItems(
        series: series,
        sourceId: sid,
        excludeAdult: excludeAdult,
        order: VodCatalogOrder.rowid,
        limit: per,
      );
      for (final item in chunk) {
        if (seen.add(item.id)) out.add(item);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  static String _orderBySql(VodCatalogOrder order) {
    switch (order) {
      case VodCatalogOrder.popularity:
        return 'ORDER BY (popularity IS NULL) ASC, popularity DESC, '
            '(rating IS NULL) ASC, rating DESC, '
            '(year IS NULL) ASC, year DESC, '
            'sort_title COLLATE NOCASE, title COLLATE NOCASE';
      case VodCatalogOrder.rating:
        return 'ORDER BY (rating IS NULL) ASC, rating DESC, '
            '(year IS NULL) ASC, year DESC, '
            'sort_title COLLATE NOCASE, title COLLATE NOCASE';
      case VodCatalogOrder.year:
        return 'ORDER BY (year IS NULL) ASC, year DESC, '
            'sort_title COLLATE NOCASE, title COLLATE NOCASE';
      case VodCatalogOrder.rowid:
        return 'ORDER BY rowid';
      case VodCatalogOrder.title:
        return 'ORDER BY sort_title COLLATE NOCASE, title COLLATE NOCASE';
    }
  }

  /// Full-text search; uses FTS5 when available, else AND-of-LIKE tokens.
  ///
  /// Ranks with `bm25` in SQL (cheap; FTS can stop at LIMIT), then re-ranks
  /// the small page in Dart. The old `ORDER BY CASE … LIKE/INSTR` forced
  /// SQLite to score every MATCH hit before LIMIT — one-char `k*` on ~200k
  /// rows hung Search for seconds (see `fts timeout` / `local in 4297ms`).
  Future<List<MediaItem>> searchFts(
    String query, {
    String? sourceId,
    List<String>? allowedSourceIds,
    bool? series,
    bool excludeAdult = false,
    int limit = 60,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final db = await _database;
    if (!_ftsEnabled) {
      return _searchLike(
        q,
        sourceId: sourceId,
        allowedSourceIds: allowedSourceIds,
        series: series,
        excludeAdult: excludeAdult,
        limit: limit,
      );
    }

    final match = IptvSearchQuery.ftsMatchQuery(q);
    if (match.isEmpty) return const [];

    final where = <String>['vod_fts MATCH ?'];
    final args = <Object?>[match];
    if (series != null) {
      where.add(series ? "i.kind = 'series'" : "i.kind = 'vod'");
    } else {
      where.add("i.kind IN ('vod', 'series')");
    }
    _appendSourceFilter(
      where: where,
      args: args,
      column: 'i.source_id',
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
    );
    if (excludeAdult) {
      where.add('IFNULL(i.is_adult, 0) = 0');
    }
    where.add(_latestGenerationSql(table: 'i'));
    // Over-fetch so Dart prefix/exact re-rank still has room after filters.
    final cap = limit < 1 ? 60 : limit;
    final fetch = (cap * 2).clamp(cap, 320);
    args.add(fetch);
    try {
      final rows = await db.rawQuery('''
SELECT i.*
FROM vod_fts
INNER JOIN vod_items i ON i.rowid = vod_fts.rowid
WHERE ${where.join(' AND ')}
ORDER BY bm25(vod_fts), i.sort_title COLLATE NOCASE
LIMIT ?
''', args);
      final items = await _itemsFromRowsYielding(rows);
      return _rankSearchHits(items, query: q, limit: cap);
    } catch (_) {
      // FTS vanished / module unloaded mid-session — degrade gracefully.
      _ftsEnabled = false;
      return _searchLike(
        q,
        sourceId: sourceId,
        allowedSourceIds: allowedSourceIds,
        series: series,
        excludeAdult: excludeAdult,
        limit: limit,
      );
    }
  }

  /// Prefix / exact title preference on a small FTS page (not the full MATCH set).
  static List<MediaItem> _rankSearchHits(
    List<MediaItem> items, {
    required String query,
    required int limit,
  }) {
    if (items.length <= 1) {
      return items.length <= limit ? items : items.sublist(0, limit);
    }
    final ranked = List<MediaItem>.of(items);
    ranked.sort((a, b) {
      final byRel = IptvSearchQuery.relevance(
        query,
        a,
      ).compareTo(IptvSearchQuery.relevance(query, b));
      if (byRel != 0) return byRel;
      return IptvSearchQuery.rankTitle(
        a,
      ).compareTo(IptvSearchQuery.rankTitle(b));
    });
    if (ranked.length > limit) return ranked.sublist(0, limit);
    return ranked;
  }

  /// LIKE fallback when FTS5 is unavailable (same token AND semantics).
  Future<List<MediaItem>> _searchLike(
    String query, {
    String? sourceId,
    List<String>? allowedSourceIds,
    bool? series,
    bool excludeAdult = false,
    int limit = 60,
  }) async {
    final tokens = IptvSearchQuery.tokens(query);
    if (tokens.isEmpty) return const [];

    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    if (series != null) {
      where.add(series ? "kind = 'series'" : "kind = 'vod'");
    } else {
      where.add("kind IN ('vod', 'series')");
    }
    _appendSourceFilter(
      where: where,
      args: args,
      column: 'source_id',
      sourceId: sourceId,
      allowedSourceIds: allowedSourceIds,
    );
    if (excludeAdult) {
      where.add('IFNULL(is_adult, 0) = 0');
    }
    for (final token in tokens) {
      where.add(
        '(INSTR(sort_title, ?) > 0 OR '
        "INSTR(LOWER(IFNULL(subtitle, '')), ?) > 0 OR "
        "INSTR(LOWER(IFNULL(group_name, '')), ?) > 0 OR "
        "INSTR(LOWER(IFNULL(stream_id, '')), ?) > 0)",
      );
      args.addAll([token, token, token, token]);
    }
    args.addAll(_searchRankArgs(query));
    args.add(limit < 1 ? 60 : limit);
    final rows = await db.rawQuery('''
SELECT * FROM vod_items
WHERE ${where.join(' AND ')}
ORDER BY ${_searchRankOrderSql(column: 'sort_title')}, sort_title COLLATE NOCASE, title COLLATE NOCASE
LIMIT ?
''', args);
    return _itemsFromRowsYielding(rows);
  }

  Future<MediaItem?> itemById(String id) async {
    final db = await _database;
    final rows = await db.query(
      'vod_items',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _itemFromRow(rows.first);
  }

  Future<List<MediaItem>> itemsByIds(List<String> ids) async {
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
        'SELECT * FROM vod_items WHERE id IN ($placeholders)',
        slice,
      );
      final byId = {for (final r in rows) '${r['id']}': _itemFromRow(r)};
      for (final id in slice) {
        final item = byId[id];
        if (item != null) out.add(item);
      }
    }
    return out;
  }

  /// Lookup VOD/series rows that carry any of [tmdbIds] (TMDB Popular ∩ local).
  Future<List<MediaItem>> itemsByTmdbIds(
    List<int> tmdbIds, {
    List<String>? allowedSourceIds,
    bool? series,
    bool excludeAdult = false,
  }) async {
    final ids = [
      for (final id in tmdbIds)
        if (id > 0) id,
    ];
    if (ids.isEmpty) return const [];
    final db = await _database;
    final out = <MediaItem>[];
    const chunk = 200;
    for (var i = 0; i < ids.length; i += chunk) {
      final slice = ids.sublist(
        i,
        i + chunk > ids.length ? ids.length : i + chunk,
      );
      final where = <String>[
        'tmdb_id IN (${List.filled(slice.length, '?').join(',')})',
      ];
      final args = <Object?>[...slice];
      if (series != null) {
        where.add(series ? "kind = 'series'" : "kind = 'vod'");
      } else {
        where.add("kind IN ('vod', 'series')");
      }
      _appendSourceFilter(
        where: where,
        args: args,
        column: 'source_id',
        allowedSourceIds: allowedSourceIds,
      );
      if (excludeAdult) {
        where.add('IFNULL(is_adult, 0) = 0');
      }
      final rows = await db.rawQuery(
        'SELECT * FROM vod_items WHERE ${where.join(' AND ')}',
        args,
      );
      out.addAll(await _itemsFromRowsYielding(rows));
    }
    return out;
  }

  Future<List<MediaItem>> itemsForSource(String sourceId) async {
    final db = await _database;
    final rows = await db.query(
      'vod_items',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'sort_title COLLATE NOCASE',
    );
    return _itemsFromRowsYielding(rows);
  }

  /// Deserialize query rows without holding the UI isolate for a whole page.
  ///
  /// [_itemFromRow] decodes `extras_json` per row, so a category page (up to
  /// 1500 rows) built in one list comprehension ran long enough for the
  /// desktop shell to drop focus and clicks. The span names the phase so a
  /// stall does not report `phase=-`.
  Future<List<MediaItem>> _itemsFromRowsYielding(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return const [];
    if (rows.length < 64) {
      return [for (final r in rows) _itemFromRow(r)];
    }
    return UiStallWatchdog.span(
      'vod-row-decode',
      () => mapYielding(rows, _itemFromRow, label: 'vod-row-decode'),
    );
  }

  /// Builds row maps for one ingest, yielding the UI isolate per slice.
  ///
  /// [packItem] runs title normalization ([IptvSearchQuery.rankTitle]) plus
  /// per-row JSON for extras, so a 134k-row Xtream catalog built in one tight
  /// loop was freezing the UI isolate mid-sync. Slice by elapsed time like
  /// [LibraryStore] instead of a fixed row count.
  Future<List<Map<String, Object?>>> _buildRows(
    Iterable<MediaItem> items, {
    String? fallbackSourceId,
    String? groupName,
  }) async {
    final rows = <Map<String, Object?>>[];
    final slice = Stopwatch()..start();
    var i = 0;
    for (final item in items) {
      if (item.kind != MediaKind.vod && item.kind != MediaKind.series) continue;
      final m = groupName == null ? item : item.copyWith(group: groupName);
      rows.add(packItem(m, fallbackSourceId: fallbackSourceId));
      await yieldUiSlice(slice, i: i++, label: 'vod-build-rows');
    }
    return rows;
  }

  /// Replace all VOD/series rows for one source.
  Future<void> replaceSourceVod({
    required String sourceId,
    required List<MediaItem> items,
  }) async {
    final rows = await _buildRows(items, fallbackSourceId: sourceId);
    await replaceSourceVodPacked(sourceId: sourceId, rows: rows);
  }

  /// Insert already-packed SQL maps (M3U ingest worker / isolate).
  ///
  /// Empty [rows] still deletes the source — a live-only playlist must not
  /// leave the previous VOD set on disk.
  Future<void> replaceSourceVodPacked({
    required String sourceId,
    required List<Map<String, Object?>> rows,
    VodReplaceProgressCallback? onProgress,
  }) {
    final previous = _sourceReplaceTails[sourceId];
    late final Future<void> run;
    run = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed generation must not prevent the next refresh.
        }
      }
      await _replaceSourceVodPackedProgressive(
        sourceId: sourceId,
        rows: rows,
        onProgress: onProgress,
      );
    }();
    _sourceReplaceTails[sourceId] = run;
    return run.whenComplete(() {
      if (identical(_sourceReplaceTails[sourceId], run)) {
        _sourceReplaceTails.remove(sourceId);
      }
    });
  }

  /// Stream 400-row SQL chunks into a replace without holding the full dump
  /// on the UI isolate. Fingerprint skip happens before [addChunk] via
  /// [VodStreamingReplace.skipIfFingerprint].
  Future<VodStreamingReplace> beginStreamingReplace({
    required String sourceId,
    VodReplaceProgressCallback? onProgress,
  }) async {
    final previous = _sourceReplaceTails[sourceId];
    final done = Completer<void>();
    _sourceReplaceTails[sourceId] = done.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    return VodStreamingReplace._(
      db: this,
      sourceId: sourceId,
      onProgress: onProgress,
      done: done,
    );
  }

  Future<void> _replaceSourceVodPackedProgressive({
    required String sourceId,
    required List<Map<String, Object?>> rows,
    VodReplaceProgressCallback? onProgress,
  }) async {
    final db = await _database;
    if (rows.isEmpty) {
      await db.transaction((txn) async {
        await txn.delete(
          'vod_items',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
      });
      _committedGenerationBySource.remove(sourceId);
      await onProgress?.call(
        const VodReplaceProgress(committed: 0, total: 0, finalized: true),
      );
      await _setMeta(_sourceFpMetaKey(sourceId), '0');
      await _setMeta(_sourceBodyFpMetaKey(sourceId), '0');
      return;
    }

    final fp = await vodContentFingerprintAsync(rows);
    final fpKey = _sourceFpMetaKey(sourceId);
    if (await _getMeta(fpKey) == fp) {
      await onProgress?.call(
        VodReplaceProgress(
          committed: rows.length,
          total: rows.length,
          finalized: true,
        ),
      );
      return;
    }

    final now = DateTime.now().microsecondsSinceEpoch;
    final generation = now > _lastSyncGeneration
        ? now
        : _lastSyncGeneration + 1;
    _lastSyncGeneration = generation;
    _activeSyncGenerationBySource[sourceId] = generation;
    var finalized = false;
    try {
      var start = 0;
      while (start < rows.length) {
        // Same 400-row commits everywhere. Larger batches used to copy a
        // fat map list onto the SQLite isolate and stall the UI isolate —
        // Windows showed that as a dead HWND; other platforms just hitch.
        final end = start + _batchChunk > rows.length
            ? rows.length
            : start + _batchChunk;
        final chunk = <Map<String, Object?>>[
          for (var i = start; i < end; i++)
            {...rows[i], 'sync_generation': generation},
        ];
        await db.transaction((txn) => _insertRows(txn, chunk));
        await onProgress?.call(
          VodReplaceProgress(
            committed: end,
            total: rows.length,
            finalized: false,
          ),
        );
        await pumpUi();
        start = end;
      }

      // Old rows remain queryable throughout ingest. Only a fully ingested
      // generation may retire them, in one short delete-only transaction.
      await db.transaction((txn) async {
        await txn.delete(
          'vod_items',
          where: 'source_id = ? AND sync_generation != ?',
          whereArgs: [sourceId, generation],
        );
      });
      finalized = true;
      _committedGenerationBySource[sourceId] = generation;
      await _setMeta(fpKey, fp);
      await onProgress?.call(
        VodReplaceProgress(
          committed: rows.length,
          total: rows.length,
          finalized: true,
        ),
      );
    } catch (_) {
      if (!finalized) {
        try {
          await db.delete(
            'vod_items',
            where: 'source_id = ? AND sync_generation = ?',
            whereArgs: [sourceId, generation],
          );
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (_activeSyncGenerationBySource[sourceId] == generation) {
        _activeSyncGenerationBySource.remove(sourceId);
      }
    }
  }

  /// Replace one category for a source; keep other groups intact.
  Future<void> upsertSourceGroupVod({
    required String sourceId,
    required String groupName,
    required List<MediaItem> items,
  }) async {
    final db = await _database;
    final rows = await _buildRows(
      items,
      fallbackSourceId: sourceId,
      groupName: groupName,
    );
    final active = _activeSyncGenerationBySource[sourceId];
    final generation = await _writeGenerationFor(sourceId);
    final generationRows = [
      for (final row in rows) {...row, 'sync_generation': generation},
    ];
    await db.transaction((txn) async {
      if (active == null) {
        await txn.delete(
          'vod_items',
          where: 'source_id = ? AND group_name = ?',
          whereArgs: [sourceId, groupName],
        );
      } else {
        // Keep already-committed same-generation bulk rows. A full replace
        // inserts in packed order, so a demand fetch for this group would
        // otherwise delete earlier chunks that the replace loop never
        // revisits.
        await txn.delete(
          'vod_items',
          where: 'source_id = ? AND group_name = ? AND sync_generation != ?',
          whereArgs: [sourceId, groupName, generation],
        );
      }
      await _insertRows(txn, generationRows);
    });
  }

  /// Upsert individual rows (enrich / single-title updates) without wiping.
  Future<void> upsertItems(Iterable<MediaItem> items) async {
    final rows = await _buildRows(items);
    await upsertItemsPacked(rows);
  }

  /// Insert already-packed SQL maps without deleting other rows.
  Future<void> upsertItemsPacked(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final tagged = await _tagWriteGeneration(rows);
    final db = await _database;
    await db.transaction((txn) async {
      await _insertRows(txn, tagged);
    });
  }

  Future<int> _writeGenerationFor(String sourceId) async {
    final active = _activeSyncGenerationBySource[sourceId];
    if (active != null) return active;
    final cached = _committedGenerationBySource[sourceId];
    if (cached != null) return cached;
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT IFNULL(MAX(sync_generation), 0) AS g FROM vod_items '
      'WHERE source_id = ?',
      [sourceId],
    );
    final generation = (rows.first['g'] as num?)?.toInt() ?? 0;
    _committedGenerationBySource[sourceId] = generation;
    return generation;
  }

  Future<List<Map<String, Object?>>> _tagWriteGeneration(
    List<Map<String, Object?>> rows,
  ) async {
    final generations = <String, int>{};
    final tagged = <Map<String, Object?>>[];
    for (final row in rows) {
      final sourceId = '${row['source_id'] ?? ''}';
      if (sourceId.isEmpty) {
        tagged.add(row);
        continue;
      }
      final generation = generations[sourceId] ??= await _writeGenerationFor(
        sourceId,
      );
      tagged.add({...row, 'sync_generation': generation});
    }
    return tagged;
  }

  /// Ids already stored for [sourceId] (deep-sync de-dupe).
  Future<Set<String>> idsForSource(String sourceId) async {
    final db = await _database;
    final rows = await db.query(
      'vod_items',
      columns: ['id'],
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
    return {for (final r in rows) '${r['id']}'};
  }

  /// Drop every row for [sourceId].
  Future<void> deleteSource(String sourceId) async {
    final db = await _database;
    await db.delete('vod_items', where: 'source_id = ?', whereArgs: [sourceId]);
  }

  /// Keep only rows whose source_id is in [knownSourceIds] (or empty/local).
  Future<int> pruneUnknownSources(Set<String> knownSourceIds) async {
    final db = await _database;
    if (knownSourceIds.isEmpty) {
      final before = await countItems();
      await db.delete('vod_items');
      return before;
    }
    final placeholders = List.filled(knownSourceIds.length, '?').join(',');
    final args = knownSourceIds.toList(growable: false);
    // Fast path: a no-op DELETE still scans ~200k FTS-backed rows and can
    // monopolize the sqflite queue for minutes on Windows (blocks Search FTS).
    final orphan = await db.rawQuery(
      'SELECT 1 AS x FROM vod_items '
      'WHERE source_id NOT IN ($placeholders) AND source_id != \'\' '
      'LIMIT 1',
      args,
    );
    if (orphan.isEmpty) return 0;
    final result = await db.rawDelete(
      'DELETE FROM vod_items WHERE source_id NOT IN ($placeholders) '
      "AND source_id != ''",
      args,
    );
    return result;
  }

  /// One-shot migrate from JSON / in-memory VOD rows.
  Future<void> migrateFromMediaItems(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final bySource = <String, List<MediaItem>>{};
    final slice = Stopwatch()..start();
    var i = 0;
    for (final item in items) {
      if (item.kind != MediaKind.vod && item.kind != MediaKind.series) continue;
      final sourceId = item.sourceId ?? '__unknown__';
      bySource.putIfAbsent(sourceId, () => []).add(item);
      await yieldUiSlice(slice, i: i++, label: 'vod-migrate-group');
    }
    for (final entry in bySource.entries) {
      await replaceSourceVod(sourceId: entry.key, items: entry.value);
    }
    await _setMeta(_migratedMeta, '1');
    await _setMeta(_schemaNoteMeta, 'v1');
  }

  Future<bool> get wasMigratedFromJson async =>
      (await _getMeta(_migratedMeta)) == '1';

  Future<void> markMigratedFromJson() => _setMeta(_migratedMeta, '1');

  static String _sourceFpMetaKey(String sourceId) =>
      'sfp:${Uri.encodeComponent(sourceId)}';

  static String _sourceBodyFpMetaKey(String sourceId) =>
      'sbfp:${Uri.encodeComponent(sourceId)}';

  /// Stable hash of id/title/group/stream so an unchanged refresh can skip
  /// rewriting hundreds of thousands of rows.
  static String vodContentFingerprint(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return '0';
    final buf = StringBuffer('${rows.length}');
    for (final row in rows) {
      buf.write(_vodContentFingerprintLine(row));
    }
    return sha1.convert(utf8.encode(buf.toString())).toString();
  }

  /// Chunked fingerprint with UI yields — same digest as [vodContentFingerprint].
  static Future<String> vodContentFingerprintAsync(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.length < 400) return vodContentFingerprint(rows);
    final out = _VodDigestSink();
    final input = sha1.startChunkedConversion(out);
    input.add(utf8.encode('${rows.length}'));
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      input.add(utf8.encode(_vodContentFingerprintLine(rows[i])));
      await yieldUiSlice(slice, i: i, checkMask: 127, label: 'vod-fingerprint');
    }
    input.close();
    return out.value!.toString();
  }

  static String _vodContentFingerprintLine(Map<String, Object?> row) {
    return '|${row['id']}|${row['title']}|${row['group_name']}|${row['stream_id']}';
  }

  Future<void> _insertRows(
    Transaction txn,
    List<Map<String, Object?>> rows,
  ) async {
    for (var i = 0; i < rows.length; i += _batchChunk) {
      final end = i + _batchChunk > rows.length ? rows.length : i + _batchChunk;
      final batch = txn.batch();
      for (var j = i; j < end; j++) {
        batch.insert(
          'vod_items',
          rows[j],
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> _setMeta(String key, String value) async {
    final db = await _database;
    await _setMetaOn(db, key, value);
  }

  Future<void> _setMetaOn(DatabaseExecutor db, String key, String value) async {
    await db.insert('vod_meta', {
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
      'vod_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// True when existing rows still carry pre-normalize [sort_title] values.
  Future<bool> get needsSortTitleReindex async {
    final current = await _getMeta(_sortTitleLogicMeta);
    return current != _sortTitleLogicVersion;
  }

  /// Rewrite [sort_title] with [IptvSearchQuery.rankTitle] for accent / year hay.
  Future<void> reindexSortTitles() async {
    final db = await _database;
    const pageSize = 400;
    var offset = 0;
    while (true) {
      final rows = await db.query(
        'vod_items',
        limit: pageSize,
        offset: offset,
        orderBy: 'rowid',
      );
      if (rows.isEmpty) break;
      final batch = db.batch();
      var updates = 0;
      for (final row in rows) {
        final item = _itemFromRow(row);
        final next = IptvSearchQuery.rankTitle(item);
        if (next == '${row['sort_title'] ?? ''}') continue;
        batch.update(
          'vod_items',
          {'sort_title': next},
          where: 'id = ?',
          whereArgs: [item.id],
        );
        updates++;
      }
      if (updates > 0) {
        await batch.commit(noResult: true);
      }
      if (rows.length < pageSize) break;
      offset += pageSize;
      await yieldAfterIsolateChunk();
    }
    await _setMeta(_sortTitleLogicMeta, _sortTitleLogicVersion);
  }

  static void _appendItemFilters({
    required List<String> where,
    required List<Object?> args,
    String? kind,
    bool? series,
    String? groupName,
    String? sourceId,
    List<String>? allowedSourceIds,
    bool excludeAdult = false,
    bool latestGenerationOnly = true,
  }) {
    if (kind != null && kind.isNotEmpty) {
      where.add('kind = ?');
      args.add(kind);
    } else if (series != null) {
      where.add(series ? "kind = 'series'" : "kind = 'vod'");
    } else {
      where.add("kind IN ('vod', 'series')");
    }
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
    if (excludeAdult) {
      where.add('IFNULL(is_adult, 0) = 0');
    }
    // Correlated MAX(sync_generation) is cheap on a single *small* group and
    // deadly on unscoped COUNT / GROUP BY of 200k rows — and still deadly
    // when Catalog warms ~180 fat shelf groups in parallel (each subquery
    // re-scans the group). Shelf posters skip it; See-all keeps latest-gen.
    if (latestGenerationOnly &&
        groupName != null &&
        groupName.isNotEmpty) {
      where.add(_latestGenerationSql());
    }
  }

  /// Hide stale-generation rows once a newer generation exists for the same
  /// source + group. Untouched groups stay on the previous catalog.
  static String _latestGenerationSql({String table = 'vod_items'}) {
    return '''
$table.sync_generation = (
  SELECT MAX(g.sync_generation)
  FROM vod_items g
  WHERE g.source_id = $table.source_id
    AND IFNULL(g.group_name, '') = IFNULL($table.group_name, '')
)''';
  }

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
    if (allowedSourceIds != null) {
      if (allowedSourceIds.isEmpty) {
        where.add('0');
        return;
      }
      final placeholders = List.filled(allowedSourceIds.length, '?').join(',');
      where.add('$column IN ($placeholders)');
      args.addAll(allowedSourceIds);
    }
  }

  /// Prefix / contains on [column], then caller-supplied tie-break.
  static String _searchRankOrderSql({required String column}) {
    return '''
CASE
  WHEN $column = ? THEN 0
  WHEN $column LIKE ? THEN 1
  WHEN $column LIKE ? THEN 2
  WHEN INSTR($column, ?) > 0 THEN 3
  ELSE 4
END ASC''';
  }

  static List<Object?> _searchRankArgs(String query) {
    final q = IptvSearchQuery.normalize(query);
    final tokens = IptvSearchQuery.tokens(query);
    final first = tokens.isNotEmpty ? tokens.first : q;
    return [q, '$q%', '$first%', q];
  }

  /// Pack one VOD/series row for SQLite insert (safe to call off the UI isolate).
  static Map<String, Object?> packItem(
    MediaItem item, {
    String? fallbackSourceId,
  }) {
    final sourceId = (item.sourceId?.trim().isNotEmpty == true)
        ? item.sourceId!.trim()
        : (fallbackSourceId ?? '');
    final extras = <String, dynamic>{};
    void putExtra(String key, Object? value) {
      if (value == null) return;
      if (value is String && value.isEmpty) return;
      if (value is List && value.isEmpty) return;
      if (value is Map && value.isEmpty) return;
      extras[key] = value;
    }

    putExtra('plot', item.plot);
    putExtra('genres', item.genres);
    putExtra('simklId', item.simklId);
    putExtra('durationMs', item.duration?.inMilliseconds);
    putExtra('seasonNumber', item.seasonNumber);
    putExtra('episodeNumber', item.episodeNumber);
    putExtra('channelId', item.channelId);
    putExtra('channelName', item.channelName);
    putExtra('epgChannelId', item.epgChannelId);
    putExtra('audioLanguages', item.audioLanguages);
    putExtra('subtitleLanguages', item.subtitleLanguages);
    putExtra(
      'subtitles',
      item.subtitles.isEmpty
          ? null
          : item.subtitles.map((s) => s.toJson()).toList(),
    );
    putExtra(
      'audioTracks',
      item.audioTracks.isEmpty
          ? null
          : item.audioTracks.map((a) => a.toJson()).toList(),
    );
    putExtra('httpHeaders', item.httpHeaders.isEmpty ? null : item.httpHeaders);
    putExtra(
      'segments',
      item.segments.isEmpty
          ? null
          : [for (final s in item.segments) s.toJson()],
    );
    putExtra('trailerUrl', item.trailerUrl);
    putExtra('contentRating', item.contentRating);
    putExtra('studio', item.studio);
    putExtra('originalTitle', item.originalTitle);
    putExtra('releaseDate', item.releaseDate);
    putExtra('tags', item.tags);
    putExtra('resolution', item.resolution);
    putExtra('videoCodec', item.videoCodec);
    putExtra('audioCodec', item.audioCodec);
    putExtra('hdr', item.hdr);
    putExtra('torrentFile', item.torrentFile);
    putExtra('updatedAt', item.updatedAt?.toIso8601String());
    putExtra('popularity', item.popularity);

    return {
      'id': item.id,
      'source_id': sourceId,
      'kind': item.kind.name,
      'origin': item.origin.name,
      'title': item.title,
      'sort_title': IptvSearchQuery.rankTitle(item),
      'play_url': item.playUrl,
      'subtitle': item.subtitle,
      'group_name': item.group,
      'stream_id': item.streamId,
      'thumbnail_url': item.thumbnailUrl,
      'poster_url': item.posterUrl,
      'backdrop_url': item.backdropUrl,
      'year': item.year,
      'rating': item.rating,
      'popularity': item.popularity,
      'tmdb_id': item.tmdbId,
      'imdb_id': item.imdbId,
      'anilist_id': item.anilistId,
      'tvdb_id': item.tvdbId,
      'details_id': item.detailsId,
      'series_id': item.seriesId,
      'server_item_id': item.serverItemId,
      'is_adult': item.isAdult ? 1 : 0,
      'extras_json': extras.isEmpty ? null : jsonEncode(extras),
    };
  }

  static MediaItem _itemFromRow(Map<String, Object?> row) {
    final originName = '${row['origin'] ?? ''}';
    final origin =
        MediaOrigin.values.asNameMap()[originName] ??
        (originName.isEmpty ? MediaOrigin.iptvXtream : MediaOrigin.url);
    final kindName = '${row['kind'] ?? 'vod'}';
    final kind = MediaKind.values.asNameMap()[kindName] ?? MediaKind.vod;

    Map<String, dynamic> extras = const {};
    final rawExtras = row['extras_json'];
    if (rawExtras is String && rawExtras.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawExtras);
        if (decoded is Map) {
          extras = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }

    Map<String, String> headers = const {};
    final rawHeaders = extras['httpHeaders'];
    if (rawHeaders is Map) {
      headers = {for (final e in rawHeaders.entries) '${e.key}': '${e.value}'};
    }

    List<ExternalSubtitle> subtitles = const [];
    final rawSubs = extras['subtitles'];
    if (rawSubs is List) {
      subtitles = [
        for (final e in rawSubs)
          if (e is Map) ExternalSubtitle.fromJson(Map<String, dynamic>.from(e)),
      ];
    }

    List<ExternalAudio> audioTracks = const [];
    final rawAudio = extras['audioTracks'];
    if (rawAudio is List) {
      audioTracks = [
        for (final e in rawAudio)
          if (e is Map) ExternalAudio.fromJson(Map<String, dynamic>.from(e)),
      ];
    }

    final rawPlayUrl = '${row['play_url'] ?? ''}';
    return MediaItem(
      id: '${row['id']}',
      title: '${row['title']}',
      playUrl: origin == MediaOrigin.iptvXtream
          ? stripXtreamCredentials(rawPlayUrl)
          : rawPlayUrl,
      kind: kind,
      origin: origin,
      subtitle: row['subtitle'] as String?,
      thumbnailUrl: row['thumbnail_url'] as String?,
      posterUrl: row['poster_url'] as String?,
      backdropUrl: row['backdrop_url'] as String?,
      group: row['group_name'] as String?,
      duration: extras['durationMs'] == null
          ? null
          : Duration(milliseconds: (extras['durationMs'] as num).toInt()),
      channelId: extras['channelId'] as String?,
      channelName: extras['channelName'] as String?,
      streamId: row['stream_id'] as String?,
      epgChannelId: extras['epgChannelId'] as String?,
      sourceId: () {
        final s = '${row['source_id'] ?? ''}';
        return s.isEmpty ? null : s;
      }(),
      simklId: extras['simklId'] as String?,
      detailsId: row['details_id'] as String?,
      tmdbId: (row['tmdb_id'] as num?)?.toInt(),
      anilistId: (row['anilist_id'] as num?)?.toInt(),
      imdbId: row['imdb_id'] as String?,
      tvdbId: (row['tvdb_id'] as num?)?.toInt(),
      plot: extras['plot'] as String?,
      genres:
          (extras['genres'] as List?)?.map((e) => '$e').toList() ?? const [],
      rating: (row['rating'] as num?)?.toDouble(),
      popularity:
          (row['popularity'] as num?)?.toDouble() ??
          (extras['popularity'] as num?)?.toDouble(),
      year: (row['year'] as num?)?.toInt(),
      seasonNumber: (extras['seasonNumber'] as num?)?.toInt(),
      episodeNumber: (extras['episodeNumber'] as num?)?.toInt(),
      seriesId: row['series_id'] as String?,
      serverItemId: () {
        final s = '${row['server_item_id'] ?? ''}'.trim();
        return s.isEmpty ? null : s;
      }(),
      torrentFile: extras['torrentFile'] as String?,
      audioLanguages:
          (extras['audioLanguages'] as List?)?.map((e) => '$e').toList() ??
          const [],
      subtitleLanguages:
          (extras['subtitleLanguages'] as List?)?.map((e) => '$e').toList() ??
          const [],
      subtitles: subtitles,
      audioTracks: audioTracks,
      httpHeaders: headers,
      // List-row cache rarely carries skip segments; extras keep them when present.
      segments: const [],
      trailerUrl: extras['trailerUrl'] as String?,
      contentRating: extras['contentRating'] as String?,
      isAdult: ((row['is_adult'] as num?)?.toInt() ?? 0) != 0,
      studio: extras['studio'] as String?,
      originalTitle: extras['originalTitle'] as String?,
      releaseDate: extras['releaseDate'] as String?,
      tags: (extras['tags'] as List?)?.map((e) => '$e').toList() ?? const [],
      resolution: extras['resolution'] as String?,
      videoCodec: extras['videoCodec'] as String?,
      audioCodec: extras['audioCodec'] as String?,
      hdr: extras['hdr'] as String?,
      updatedAt: extras['updatedAt'] == null
          ? null
          : DateTime.tryParse('${extras['updatedAt']}'),
    );
  }
}

/// Progressive VOD replace that never holds the full dump on the UI isolate.
class VodStreamingReplace {
  VodStreamingReplace._({
    required VodCatalogDb db,
    required this.sourceId,
    required this.onProgress,
    required Completer<void> done,
  }) : _db = db,
       _done = done;

  final VodCatalogDb _db;
  final String sourceId;
  final VodReplaceProgressCallback? onProgress;
  final Completer<void> _done;

  int? _generation;
  int _committed = 0;
  int _progressTotal = 0;
  bool _finalized = false;
  bool _skipped = false;
  bool _closed = false;
  VodSqlWriter? _writer;
  StreamSubscription<int>? _writerSub;

  String get _fpKey => VodCatalogDb._sourceFpMetaKey(sourceId);
  String get _bodyFpKey => VodCatalogDb._sourceBodyFpMetaKey(sourceId);

  void noteExpectedTotal(int total) {
    if (total > 0) _progressTotal = total;
  }

  /// Native: SQL maps go JSON-worker → writer isolate (never UI).
  /// Null on web — callers keep [addChunk].
  Future<SendPort?> ensureSqlWriterSink() async {
    if (kIsWeb) return null;
    if (_writer != null) return _writer!.sink;
    final generation = _generation ?? _nextGeneration();
    _generation = generation;
    _db._activeSyncGenerationBySource[sourceId] = generation;
    final path = await _db.databaseFilePath;
    final writer = await VodSqlWriter.start(
      dbPath: path,
      sourceId: sourceId,
      generation: generation,
    );
    _writer = writer;
    _writerSub = writer.committed.listen((n) {
      _committed = n;
      final cb = onProgress;
      if (cb == null) return;
      unawaited(
        Future.sync(
          () => cb(
            VodReplaceProgress(
              committed: n,
              total: _progressTotal > 0 ? _progressTotal : n,
              finalized: false,
            ),
          ),
        ),
      );
    });
    return writer.sink;
  }

  /// True when raw dump body hashes match — skip without jsonDecode.
  Future<bool> skipIfBodyFingerprint(String bodyFingerprint) async {
    if (bodyFingerprint.isEmpty || bodyFingerprint == '0') return false;
    final stored = await _db._getMeta(_bodyFpKey);
    if (stored != bodyFingerprint) {
      JavpLog.i(
        'vod',
        'body fingerprint miss source=$sourceId '
            'have=${stored == null ? 'none' : 'other'}',
      );
      return false;
    }
    _skipped = true;
    await onProgress?.call(
      VodReplaceProgress(
        committed: 0,
        total: 0,
        finalized: true,
      ),
    );
    await close();
    JavpLog.i('vod', 'body fingerprint hit source=$sourceId (skip decode)');
    return true;
  }

  Future<void> storeBodyFingerprint(String bodyFingerprint) async {
    if (bodyFingerprint.isEmpty || bodyFingerprint == '0') return;
    await _db._setMeta(_bodyFpKey, bodyFingerprint);
    JavpLog.i('vod', 'stored body fingerprint source=$sourceId');
  }

  /// True when [fingerprint] matches the last finished replace.
  Future<bool> skipIfFingerprint(String fingerprint) async {
    if (fingerprint.isEmpty || fingerprint == '0') return false;
    if (await _db._getMeta(_fpKey) != fingerprint) return false;
    _skipped = true;
    await onProgress?.call(
      VodReplaceProgress(
        committed: 0,
        total: 0,
        finalized: true,
      ),
    );
    await close();
    return true;
  }

  Future<void> addChunk(
    List<Map<String, Object?>> rows, {
    required int total,
  }) async {
    if (_closed || _skipped || rows.isEmpty) return;
    // Writer path owns inserts — UI must not also write.
    if (_writer != null) return;
    final db = await _db._database;
    final generation = _generation ?? _nextGeneration();
    _generation = generation;
    _db._activeSyncGenerationBySource[sourceId] = generation;
    for (final row in rows) {
      row['sync_generation'] = generation;
    }
    await db.transaction((txn) => _db._insertRows(txn, rows));
    _committed += rows.length;
    await onProgress?.call(
      VodReplaceProgress(
        committed: _committed,
        total: total,
        finalized: false,
      ),
    );
    await pumpUi();
  }

  Future<void> finish({
    required String fingerprint,
    required int total,
  }) async {
    if (_closed) return;
    // Flush writer before retiring old generations on the UI connection.
    final writer = _writer;
    if (writer != null) {
      await writer.close();
      _writer = null;
      await _writerSub?.cancel();
      _writerSub = null;
    }
    final db = await _db._database;
    if (_committed == 0 && !_skipped) {
      await db.transaction((txn) async {
        await txn.delete(
          'vod_items',
          where: 'source_id = ?',
          whereArgs: [sourceId],
        );
      });
      _db._committedGenerationBySource.remove(sourceId);
      await _db._setMeta(_fpKey, '0');
      await _db._setMeta(_bodyFpKey, '0');
      await onProgress?.call(
        const VodReplaceProgress(committed: 0, total: 0, finalized: true),
      );
      _finalized = true;
      await close();
      return;
    }
    final generation = _generation;
    if (generation == null) {
      await close();
      return;
    }
    await db.transaction((txn) async {
      await txn.delete(
        'vod_items',
        where: 'source_id = ? AND sync_generation != ?',
        whereArgs: [sourceId, generation],
      );
    });
    _finalized = true;
    _db._committedGenerationBySource[sourceId] = generation;
    await _db._setMeta(_fpKey, fingerprint);
    await onProgress?.call(
      VodReplaceProgress(
        committed: _committed,
        total: total,
        finalized: true,
      ),
    );
    await close();
  }

  Future<void> abort() async {
    if (_closed) return;
    final writer = _writer;
    if (writer != null) {
      await writer.close();
      _writer = null;
      await _writerSub?.cancel();
      _writerSub = null;
    }
    final generation = _generation;
    if (generation != null && !_finalized) {
      try {
        final db = await _db._database;
        await db.delete(
          'vod_items',
          where: 'source_id = ? AND sync_generation = ?',
          whereArgs: [sourceId, generation],
        );
      } catch (_) {}
    }
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final writer = _writer;
    if (writer != null) {
      await writer.close();
      _writer = null;
    }
    await _writerSub?.cancel();
    _writerSub = null;
    final generation = _generation;
    if (generation != null &&
        _db._activeSyncGenerationBySource[sourceId] == generation) {
      _db._activeSyncGenerationBySource.remove(sourceId);
    }
    if (!_done.isCompleted) _done.complete();
    if (identical(_db._sourceReplaceTails[sourceId], _done.future)) {
      _db._sourceReplaceTails.remove(sourceId);
    }
  }

  int _nextGeneration() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final generation = now > VodCatalogDb._lastSyncGeneration
        ? now
        : VodCatalogDb._lastSyncGeneration + 1;
    VodCatalogDb._lastSyncGeneration = generation;
    return generation;
  }
}

class _VodDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
