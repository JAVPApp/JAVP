import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
import 'package:javp/services/metadata/external_ids.dart';

/// Versions / multi-source VOD index built off the UI isolate.
///
/// Shipping full [MediaItem] graphs through [Isolate.run] crashed the Windows
/// embedder (same lesson as [VodSearchIndex] / live channel indexing). Pack
/// only the fields [VodGrouping] needs, build family → ordered ids + canonical
/// map in a worker, then remap ids to live [MediaItem]s on the UI isolate.
class VodVariantIndex {
  VodVariantIndex._();

  /// Above this, opportunistic builds prefer [Isolate.run] over UI slicing.
  static const isolateMinRows = 2500;

  /// Pack one movie-family row for isolate transfer.
  static Map<String, Object?> packRow(MediaItem m) {
    return {
      'id': m.id,
      'title': m.title,
      'originalTitle': m.originalTitle,
      'year': m.year,
      'sourceId': m.sourceId,
      'tmdbId': ExternalIds.resolvedTmdbId(
        tmdbId: m.tmdbId,
        title: m.title,
        id: m.id,
        tags: m.tags,
        originalTitle: m.originalTitle,
      ),
      'imdbId': ExternalIds.resolvedImdbId(
        imdbId: m.imdbId,
        title: m.title,
        id: m.id,
        tags: m.tags,
        originalTitle: m.originalTitle,
      ),
      'anilistId': m.anilistId,
      'isSeries': m.isSeries,
      'origin': m.origin.name,
      'group': m.group,
      'subtitle': m.subtitle,
      'audioLanguages': m.audioLanguages,
      'subtitleLanguages': m.subtitleLanguages,
      'hasExtSubs': m.hasExternalSubtitles,
      'subLangs': [
        for (final s in m.subtitles)
          if ((s.language ?? '').trim().isNotEmpty) s.language!.trim(),
      ],
      'audioTrackLangs': [
        for (final t in m.audioTracks)
          if ((t.language ?? '').trim().isNotEmpty) t.language!.trim(),
      ],
    };
  }

  /// Isolate entry — must stay top-level-callable without capturing library.
  ///
  /// Large caches stream rows in and family maps out in [kIsolateListChunk]
  /// messages. A single [Isolate.run] of ~100k packed maps freezes Windows
  /// on the copy, even though the CPU work itself is off-UI.
  static Future<Map<String, Object?>> buildInIsolate(
    List<Map<String, Object?>> rows,
  ) {
    return buildChunksInIsolate([rows]);
  }

  /// Build from separately packed batches without first joining every row
  /// into one large UI-isolate list.
  static Future<Map<String, Object?>> buildChunksInIsolate(
    List<List<Map<String, Object?>>> rowChunks,
  ) {
    final rowCount = rowChunks.fold<int>(0, (sum, rows) => sum + rows.length);
    if (rowCount == 0) {
      return Future.value(const {'families': {}, 'canonical': {}});
    }
    if (kIsWeb || rowCount < kIsolateListChunk) {
      final rows = [for (final chunk in rowChunks) ...chunk];
      if (kIsWeb) return Future.value(buildPacked(rows));
      return Isolate.run(() => buildPacked(rows));
    }
    return _buildChunked(rowChunks);
  }

  static Future<Map<String, Object?>> _buildChunked(
    List<List<Map<String, Object?>>> rowChunks,
  ) async {
    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _vodVariantIsolateMain,
        receive.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      receive.close();
      errors.close();
      rethrow;
    }

    Object? isolateError;
    final errorSub = errors.listen((msg) {
      isolateError ??= msg;
    });
    final iter = StreamIterator(receive);
    try {
      if (!await iter.moveNext()) {
        throw StateError('VOD variant isolate exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final workerPort = iter.current as SendPort;
      const chunk = kIsolateListChunk;
      for (final rows in rowChunks) {
        for (var i = 0; i < rows.length; i += chunk) {
          if (isolateError != null) throw isolateError!;
          final end = i + chunk > rows.length ? rows.length : i + chunk;
          workerPort.send(
            List<Map<String, Object?>>.from(rows.getRange(i, end)),
          );
          await yieldAfterIsolateChunk();
        }
      }
      workerPort.send(null);

      final families = <String, List<String>>{};
      final canonical = <String, String>{};
      while (await iter.moveNext()) {
        if (isolateError != null) throw isolateError!;
        final message = iter.current;
        if (message == null) break;
        if (message is Map) {
          final type = '${message['t'] ?? ''}';
          final raw = message['v'];
          if (type == 'families' && raw is List) {
            for (final e in raw) {
              if (e is! List || e.length < 2) continue;
              families['${e[0]}'] = [
                for (final id in (e[1] is List ? e[1] as List : const []))
                  '$id',
              ];
            }
          } else if (type == 'canonical' && raw is List) {
            for (final e in raw) {
              if (e is! List || e.length < 2) continue;
              canonical['${e[0]}'] = '${e[1]}';
            }
          }
        }
        await yieldAfterIsolateChunk();
      }
      if (isolateError != null) throw isolateError!;
      return {'families': families, 'canonical': canonical};
    } finally {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  }

  /// Pure build used by [buildInIsolate] and unit tests.
  static Map<String, Object?> buildPacked(List<Map<String, Object?>> rows) {
    final primary = <String, List<Map<String, Object?>>>{};
    final orphans = <Map<String, Object?>>[];
    for (final row in rows) {
      final key = _groupKey(row);
      if (key == null) {
        orphans.add(row);
      } else {
        primary.putIfAbsent(key, () => []).add(row);
      }
    }

    final aliasClaimants = <String, Set<String>>{};
    for (final entry in primary.entries) {
      if (!VodGrouping.isIdentityGroupKey(entry.key)) continue;
      for (final item in entry.value) {
        for (final alias in _nameAliases(item)) {
          aliasClaimants.putIfAbsent(alias, () => {}).add(entry.key);
        }
      }
    }
    final nameToCanonical = <String, String>{
      for (final e in aliasClaimants.entries)
        if (e.value.length == 1) e.key: e.value.single,
    };

    String? identityTargetFor(
      Iterable<Map<String, Object?>> items,
      String primaryKey,
    ) {
      final direct = nameToCanonical[primaryKey];
      if (direct != null) return direct;
      String? target;
      for (final item in items) {
        for (final alias in _nameAliases(item)) {
          final hit = nameToCanonical[alias];
          if (hit == null) continue;
          if (target != null && target != hit) return null;
          target = hit;
        }
      }
      return target;
    }

    final canonical = <String, String>{};
    final index = <String, List<Map<String, Object?>>>{};
    for (final entry in primary.entries) {
      final target = identityTargetFor(entry.value, entry.key) ?? entry.key;
      canonical[entry.key] = target;
      index.putIfAbsent(target, () => []).addAll(entry.value);
    }
    for (final e in nameToCanonical.entries) {
      canonical[e.key] = e.value;
    }

    for (final item in orphans) {
      String? target;
      for (final alias in _nameAliases(item)) {
        final hit = nameToCanonical[alias];
        if (hit != null) {
          target = hit;
          break;
        }
      }
      if (target == null) continue;
      index.putIfAbsent(target, () => []).add(item);
      for (final alias in _nameAliases(item)) {
        canonical.putIfAbsent(alias, () => target!);
      }
    }

    final families = <String, List<String>>{};
    for (final entry in index.entries) {
      final members = entry.value;
      if (members.length <= 1) {
        families[entry.key] = [for (final m in members) '${m['id'] ?? ''}'];
        continue;
      }
      final byId = <String, Map<String, Object?>>{
        for (final m in members) '${m['id'] ?? ''}': m,
      };
      final list = byId.values.toList()..sort((a, b) => _compareVariants(a, b));
      families[entry.key] = [for (final m in list) '${m['id'] ?? ''}'];
    }

    return {'families': families, 'canonical': canonical};
  }

  /// Cluster a small [MediaItem] list with the same rules as the isolate index.
  ///
  /// Used by Search so catalog TMDB rows and IPTV `FR|` / `US|` hits merge even
  /// while the global Versions map is rebuilding.
  static ({Map<String, List<String>> families, Map<String, String> canonical})
  clusterItems(List<MediaItem> items) {
    if (items.isEmpty) {
      return (families: const {}, canonical: const {});
    }
    final packed = buildPacked([for (final m in items) packRow(m)]);
    final rawFamilies = packed['families'] as Map? ?? const {};
    final rawCanonical = packed['canonical'] as Map? ?? const {};
    return (
      families: {
        for (final e in rawFamilies.entries)
          '${e.key}': [for (final id in (e.value as List)) '$id'],
      },
      canonical: {
        for (final e in rawCanonical.entries) '${e.key}': '${e.value}',
      },
    );
  }

  static String? _groupKey(Map<String, Object?> row) {
    final title = '${row['title'] ?? ''}';
    final originalTitle = row['originalTitle'] as String?;
    final tmdb = ExternalIds.resolvedTmdbId(
      tmdbId: ExternalIds.parsePositiveInt(row['tmdbId']),
      title: title,
      id: '${row['id'] ?? ''}',
      originalTitle: originalTitle,
    );
    if (tmdb != null && tmdb > 0) {
      final isSeries = row['isSeries'] == true;
      return isSeries ? 'tmdb:tv:$tmdb' : 'tmdb:movie:$tmdb';
    }
    final imdb = ExternalIds.resolvedImdbId(
      imdbId: row['imdbId'] as String?,
      title: title,
      id: '${row['id'] ?? ''}',
      originalTitle: originalTitle,
    );
    if (imdb != null && imdb.isNotEmpty) {
      return 'imdb:$imdb';
    }
    final anilist = row['anilistId'];
    if (anilist is int && anilist > 0) return 'anilist:$anilist';

    final base = VodGrouping.normalizeTitle(title);
    if (base.length < 2) return null;
    final year = row['year'] is int
        ? row['year'] as int
        : VodGrouping.yearFromTitle(title);
    final isSeries = row['isSeries'] == true;
    return VodGrouping.nameGroupKeyFor(
      title: title,
      year: year,
      sourceId: row['sourceId'] as String?,
      isSeries: isSeries,
    );
  }

  static List<String> _nameAliases(Map<String, Object?> row) {
    final title = '${row['title'] ?? ''}';
    final year = row['year'] is int
        ? row['year'] as int
        : VodGrouping.yearFromTitle(title);
    return VodGrouping.nameGroupAliasesFor(
      title: title,
      originalTitle: row['originalTitle'] as String?,
      year: year,
      isSeries: row['isSeries'] == true,
    );
  }

  static int _compareVariants(Map<String, Object?> a, Map<String, Object?> b) {
    final rank = _rank(b).compareTo(_rank(a));
    if (rank != 0) return rank;
    final ta = VodGrouping.displayTitleFor('${a['title'] ?? ''}').toLowerCase();
    final tb = VodGrouping.displayTitleFor('${b['title'] ?? ''}').toLowerCase();
    final byTitle = ta.compareTo(tb);
    if (byTitle != 0) return byTitle;
    final as = (a['sourceId'] as String?) ?? '';
    final bs = (b['sourceId'] as String?) ?? '';
    final bySource = as.compareTo(bs);
    if (bySource != 0) return bySource;
    return '${a['id'] ?? ''}'.compareTo('${b['id'] ?? ''}');
  }

  static int _rank(Map<String, Object?> row) {
    final title = '${row['title'] ?? ''}';
    final group = row['group'] as String?;
    final subtitle = row['subtitle'] as String?;
    final audioLanguages = _stringList(row['audioLanguages']);
    final subtitleLanguages = _stringList(row['subtitleLanguages']);
    final subLangs = _stringList(row['subLangs']);
    final audioTrackLangs = _stringList(row['audioTrackLangs']);
    final hasExtSubs = row['hasExtSubs'] == true;
    final originName = '${row['origin'] ?? ''}';
    final tmdb = row['tmdbId'];

    final lang = () {
      if (audioLanguages.isNotEmpty) {
        return audioLanguages.first.trim().toLowerCase();
      }
      return VodGrouping.languageFromTitle(title) ??
          VodGrouping.languageFromCategory(group ?? subtitle ?? '');
    }();

    var score = VodGrouping.languagesAffinity(
      audioLanguages: [...audioLanguages, ...audioTrackLangs],
      subtitleLanguages: [
        ...subtitleLanguages,
        ...VodGrouping.inferredSubtitleLanguagesFor(
          title: title,
          group: group,
          subtitle: subtitle,
          subtitleLanguages: subtitleLanguages,
          audioLanguages: audioLanguages,
          trackSubtitleLanguages: subLangs,
        ),
        ...subLangs,
      ],
      title: title,
      group: group ?? subtitle,
    );
    score += switch (lang) {
      'en' => 80,
      'multi' => 60,
      'fr' => 50,
      null => 40,
      _ => 30,
    };
    score += switch (originName) {
      'jellyfin' || 'emby' || 'plex' => 25,
      'customCatalog' => 15,
      'localFile' || 'download' => 10,
      _ => 0,
    };
    final upper = title.toUpperCase();
    if (upper.contains('MULTI-SUB')) score -= 5;
    if (RegExp(r'\b4K\b|\bUHD\b').hasMatch(upper)) score += 10;
    if (tmdb is int) score += 5;
    if (audioLanguages.length > 1) score += 8;
    if (hasExtSubs ||
        subtitleLanguages.isNotEmpty ||
        VodGrouping.inferredSubtitleLanguagesFor(
          title: title,
          group: group,
          subtitle: subtitle,
          subtitleLanguages: subtitleLanguages,
          audioLanguages: audioLanguages,
          trackSubtitleLanguages: subLangs,
        ).isNotEmpty) {
      score += 4;
    }
    return score;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e != null && '$e'.trim().isNotEmpty) '$e'.trim(),
    ];
  }
}

@pragma('vm:entry-point')
void _vodVariantIsolateMain(SendPort reply) {
  unawaited(_vodVariantIsolateBody(reply));
}

Future<void> _vodVariantIsolateBody(SendPort reply) async {
  final inbound = ReceivePort();
  reply.send(inbound.sendPort);
  final rows = <Map<String, Object?>>[];
  await for (final message in inbound) {
    if (message == null) break;
    if (message is List) {
      for (final e in message) {
        if (e is Map<String, Object?>) {
          rows.add(e);
        } else if (e is Map) {
          rows.add(Map<String, Object?>.from(e));
        }
      }
    }
  }
  final packed = VodVariantIndex.buildPacked(rows);
  final families = packed['families'] as Map<String, List<String>>? ?? const {};
  final canonical = packed['canonical'] as Map<String, String>? ?? const {};
  const chunk = kIsolateListChunk;
  final familyEntries = families.entries.toList(growable: false);
  for (var i = 0; i < familyEntries.length; i += chunk) {
    final end = i + chunk > familyEntries.length
        ? familyEntries.length
        : i + chunk;
    reply.send({
      't': 'families',
      'v': [
        for (final e in familyEntries.sublist(i, end)) [e.key, e.value],
      ],
    });
  }
  final canonicalEntries = canonical.entries.toList(growable: false);
  for (var i = 0; i < canonicalEntries.length; i += chunk) {
    final end = i + chunk > canonicalEntries.length
        ? canonicalEntries.length
        : i + chunk;
    reply.send({
      't': 'canonical',
      'v': [
        for (final e in canonicalEntries.sublist(i, end)) [e.key, e.value],
      ],
    });
  }
  reply.send(null);
  inbound.close();
}
