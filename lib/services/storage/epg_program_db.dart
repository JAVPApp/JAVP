import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/services/storage/app_documents.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite store for XMLTV programmes — page + channel lookup, never a full
/// in-memory guide.
///
/// Native live/VOD already follow this pattern. A 90k–400k programme list
/// in [LibraryProvider.epg] was the leftover IPTV-scale RAM copy.
class EpgProgramDb {
  EpgProgramDb({this.profileId = Profile.defaultId, this.debugDatabasePath});

  final String profileId;
  final String? debugDatabasePath;

  static const _batchChunk = 400;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    try {
      return await (_opening ??= _open());
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<void> ensureOpen() async {
    await _database;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    await db?.close();
  }

  Future<Database> _open() async {
    if (kIsWeb) {
      throw UnsupportedError('EpgProgramDb is unavailable on web');
    }
    final resolved =
        debugDatabasePath ??
        await AppDocuments.profileFilePath(
          profileId: profileId,
          fileName: 'epg_programs.db',
        );
    await Directory(p.dirname(resolved)).create(recursive: true);
    return openDatabase(
      resolved,
      version: 1,
      onConfigure: (db) async {
        // Android sqflite rejects these PRAGMAs via execute() — use rawQuery.
        await db.rawQuery('PRAGMA busy_timeout=30000');
        await db.rawQuery('PRAGMA journal_mode=WAL');
      },
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE epg_feeds (
  url TEXT PRIMARY KEY NOT NULL,
  program_count INTEGER NOT NULL DEFAULT 0,
  applied_at_ms INTEGER NOT NULL DEFAULT 0
)''');
        await db.execute('''
CREATE TABLE epg_channels (
  feed_url TEXT NOT NULL,
  exact_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  PRIMARY KEY (feed_url, exact_id)
)''');
        await db.execute(
          'CREATE INDEX idx_epg_ch_exact ON epg_channels(exact_id)',
        );
        await db.execute('''
CREATE TABLE epg_programs (
  feed_url TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  image_url TEXT,
  catchup_id TEXT,
  has_archive INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (feed_url, channel_id, start_ms, end_ms, title)
)''');
        await db.execute(
          'CREATE INDEX idx_epg_prog_ch_start ON epg_programs(channel_id, start_ms)',
        );
        await db.execute(
          'CREATE INDEX idx_epg_prog_ch_window ON epg_programs(channel_id, start_ms, end_ms)',
        );
        await db.execute(
          'CREATE INDEX idx_epg_prog_feed ON epg_programs(feed_url)',
        );
      },
    );
  }

  Future<bool> get hasPrograms async {
    if (kIsWeb) return false;
    final db = await _database;
    final rows = await db.rawQuery('SELECT 1 FROM epg_programs LIMIT 1');
    return rows.isNotEmpty;
  }

  Future<int> countPrograms() async {
    final db = await _database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM epg_programs');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<bool> hasFeed(String url) async {
    final db = await _database;
    final rows = await db.query(
      'epg_feeds',
      columns: ['program_count'],
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return ((rows.first['program_count'] as num?)?.toInt() ?? 0) > 0;
  }

  Future<Set<String>> listFeedUrls() async {
    final db = await _database;
    final rows = await db.query('epg_feeds', columns: ['url']);
    return {for (final r in rows) '${r['url']}'};
  }

  /// Drop one feed so the next chunked insert can replace it.
  Future<void> clearFeed(String url) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('epg_programs', where: 'feed_url = ?', whereArgs: [url]);
      await txn.delete('epg_channels', where: 'feed_url = ?', whereArgs: [url]);
      await txn.delete('epg_feeds', where: 'url = ?', whereArgs: [url]);
    });
    await yieldAfterIsolateChunk();
  }

  Future<void> insertChannels(String url, Map<String, String> names) async {
    if (names.isEmpty) return;
    final db = await _database;
    final entries = names.entries.toList(growable: false);
    for (var i = 0; i < entries.length; i += _batchChunk) {
      final end = i + _batchChunk > entries.length
          ? entries.length
          : i + _batchChunk;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var j = i; j < end; j++) {
          final e = entries[j];
          final id = e.key.trim();
          final name = e.value.trim();
          if (id.isEmpty || name.isEmpty) continue;
          batch.insert('epg_channels', {
            'feed_url': url,
            'exact_id': id,
            'display_name': name,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      });
      await pumpUi(label: 'epg-channels');
    }
  }

  Future<void> insertPrograms(
    String url,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    final db = await _database;
    for (var i = 0; i < rows.length; i += _batchChunk) {
      final end = i + _batchChunk > rows.length ? rows.length : i + _batchChunk;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var j = i; j < end; j++) {
          final row = Map<String, Object?>.from(rows[j]);
          row['feed_url'] = url;
          batch.insert(
            'epg_programs',
            row,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      });
      // Windows: 1ms timer is not enough while Synchroniser shows
      // « Mise à jour du guide » — force an embedder frame between batches.
      await pumpUi(label: 'epg-insert');
    }
  }

  Future<void> touchFeed(String url, int programCount) async {
    final db = await _database;
    await db.insert('epg_feeds', {
      'url': url,
      'program_count': programCount,
      'applied_at_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Drop feeds that are no longer attached to any live source.
  Future<void> keepFeeds(Set<String> urls) async {
    final db = await _database;
    if (urls.isEmpty) {
      await clear();
      return;
    }
    final placeholders = List.filled(urls.length, '?').join(',');
    final args = urls.toList(growable: false);
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM epg_programs WHERE feed_url NOT IN ($placeholders)',
        args,
      );
      await txn.rawDelete(
        'DELETE FROM epg_channels WHERE feed_url NOT IN ($placeholders)',
        args,
      );
      await txn.rawDelete(
        'DELETE FROM epg_feeds WHERE url NOT IN ($placeholders)',
        args,
      );
    });
    await yieldAfterIsolateChunk();
  }

  Future<void> clear() async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('epg_programs');
      await txn.delete('epg_channels');
      await txn.delete('epg_feeds');
    });
    await yieldAfterIsolateChunk();
  }

  Future<Map<String, String>> loadChannelNames() async {
    final db = await _database;
    final rows = await db.query(
      'epg_channels',
      columns: ['exact_id', 'display_name'],
    );
    final out = <String, String>{};
    final slice = Stopwatch()..start();
    for (var i = 0; i < rows.length; i++) {
      final id = '${rows[i]['exact_id'] ?? ''}'.trim();
      final name = '${rows[i]['display_name'] ?? ''}'.trim();
      if (id.isEmpty || name.isEmpty) continue;
      out[id] = name;
      await yieldUiSlice(slice, i: i, label: 'epg-channel-names');
    }
    return out;
  }

  Future<List<EpgProgram>> programsForChannel({
    required String channelId,
    required int fromMs,
    required int toMs,
    int limit = 400,
  }) async {
    final id = channelId.trim();
    if (id.isEmpty) return const [];
    final db = await _database;
    final rows = await db.rawQuery(
      '''
SELECT channel_id, start_ms, end_ms, title, description, image_url,
       catchup_id, has_archive
FROM epg_programs
WHERE channel_id = ?
  AND end_ms >= ?
  AND start_ms <= ?
GROUP BY channel_id, start_ms, end_ms, title
ORDER BY start_ms ASC
LIMIT ?
''',
      [id, fromMs, toMs, limit],
    );
    return [for (final r in rows) programFromRow(r)];
  }

  Future<Map<String, List<EpgProgram>>> programsForChannels({
    required List<String> channelIds,
    required int fromMs,
    required int toMs,
    int limitPerChannel = 200,
  }) async {
    final ids = [
      for (final id in channelIds)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    if (ids.isEmpty) return const {};
    final db = await _database;
    final out = <String, List<EpgProgram>>{
      for (final id in ids) id: <EpgProgram>[],
    };
    const page = 40;
    for (var i = 0; i < ids.length; i += page) {
      final end = i + page > ids.length ? ids.length : i + page;
      final chunk = ids.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.rawQuery(
        '''
SELECT channel_id, start_ms, end_ms, title, description, image_url,
       catchup_id, has_archive
FROM epg_programs
WHERE channel_id IN ($placeholders)
  AND end_ms >= ?
  AND start_ms <= ?
GROUP BY channel_id, start_ms, end_ms, title
ORDER BY channel_id, start_ms ASC
''',
        [...chunk, fromMs, toMs],
      );
      for (final r in rows) {
        final program = programFromRow(r);
        final list = out[program.channelId];
        if (list == null) continue;
        if (list.length >= limitPerChannel) continue;
        list.add(program);
      }
      await yieldAfterIsolateChunk();
    }
    return out;
  }

  Future<EpgProgram?> nowPlaying({
    required String channelId,
    required int atMs,
  }) async {
    final id = channelId.trim();
    if (id.isEmpty) return null;
    final db = await _database;
    final rows = await db.rawQuery(
      '''
SELECT channel_id, start_ms, end_ms, title, description, image_url,
       catchup_id, has_archive
FROM epg_programs
WHERE channel_id = ?
  AND start_ms <= ?
  AND end_ms > ?
ORDER BY start_ms DESC
LIMIT 1
''',
      [id, atMs, atMs],
    );
    if (rows.isEmpty) return null;
    return programFromRow(rows.first);
  }

  Future<List<EpgProgram>> searchTitles({
    required String needle,
    required int fromMs,
    required int toMs,
    int limit = 80,
  }) async {
    final q = needle.trim();
    if (q.isEmpty) return const [];
    final db = await _database;
    final rows = await db.rawQuery(
      '''
SELECT channel_id, start_ms, end_ms, title, description, image_url,
       catchup_id, has_archive
FROM epg_programs
WHERE title LIKE ?
  AND end_ms >= ?
  AND start_ms <= ?
ORDER BY start_ms ASC
LIMIT ?
''',
      ['%$q%', fromMs, toMs, limit],
    );
    return [for (final r in rows) programFromRow(r)];
  }

  static Map<String, Object?> packProgram(
    EpgProgram program, {
    required String feedUrl,
  }) {
    return {
      'feed_url': feedUrl,
      'channel_id': program.channelId,
      'start_ms': program.start.toUtc().millisecondsSinceEpoch,
      'end_ms': program.end.toUtc().millisecondsSinceEpoch,
      'title': program.title,
      'description': program.description,
      'image_url': program.imageUrl,
      'catchup_id': program.catchupId,
      'has_archive': program.hasArchive ? 1 : 0,
    };
  }

  static EpgProgram programFromRow(Map<String, Object?> row) {
    return EpgProgram(
      channelId: '${row['channel_id'] ?? ''}',
      title: '${row['title'] ?? 'Program'}',
      start: DateTime.fromMillisecondsSinceEpoch(
        (row['start_ms'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      end: DateTime.fromMillisecondsSinceEpoch(
        (row['end_ms'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      description: _stringOrNull(row['description']),
      imageUrl: _stringOrNull(row['image_url']),
      catchupId: _stringOrNull(row['catchup_id']),
      hasArchive: ((row['has_archive'] as num?)?.toInt() ?? 0) != 0,
    );
  }

  static String? _stringOrNull(Object? value) {
    if (value == null) return null;
    final s = '$value';
    return s.isEmpty ? null : s;
  }
}
