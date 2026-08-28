import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';

/// Fetches intro/credits markers from IntroDB + TheIntroDB and merges them.
class SegmentResolver {
  SegmentResolver({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  static String cacheKey({
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
  }) {
    final s = season ?? 0;
    final e = episode ?? 0;
    if (imdbId != null && imdbId.isNotEmpty) {
      return 'imdb:$imdbId:s${s}e$e';
    }
    if (tmdbId != null) return 'tmdb:$tmdbId:s${s}e$e';
    return 'unknown';
  }

  static String? keyForItem(MediaItem item) {
    final key = cacheKey(
      imdbId: item.imdbId,
      tmdbId: item.tmdbId,
      season: item.seasonNumber,
      episode: item.episodeNumber,
    );
    return key == 'unknown' ? null : key;
  }

  Future<MediaSegmentBundle> resolve(MediaItem item) async {
    final key = keyForItem(item);
    if (key == null) {
      return MediaSegmentBundle(key: 'unknown', fetchedAt: DateTime.now());
    }

    final segments = <MediaSegment>[];
    final introDb = await _fetchIntroDb(item);
    segments.addAll(introDb);
    final theIntro = await _fetchTheIntroDb(item);
    segments.addAll(theIntro);

    // Prefer higher-confidence / first unique type windows.
    final merged = <MediaSegmentType, MediaSegment>{};
    for (final seg in segments) {
      final existing = merged[seg.type];
      if (existing == null ||
          (seg.confidence ?? 0) > (existing.confidence ?? 0)) {
        merged[seg.type] = seg;
      }
    }

    return MediaSegmentBundle(
      key: key,
      segments: merged.values.toList(),
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<MediaSegment>> _fetchIntroDb(MediaItem item) async {
    final imdb = item.imdbId?.trim();
    if (imdb == null || imdb.isEmpty) return const [];
    try {
      final params = <String, String>{'imdb_id': imdb};
      if (item.seasonNumber != null) {
        params['season'] = '${item.seasonNumber}';
      }
      if (item.episodeNumber != null) {
        params['episode'] = '${item.episodeNumber}';
      }
      final uri = Uri.https('api.introdb.app', '/segments', params);
      final response = await _http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode >= 400) {
        // Legacy intro-only endpoint
        final legacy = Uri.https('api.introdb.app', '/intro', params);
        final legacyRes =
            await _http.get(legacy).timeout(const Duration(seconds: 8));
        if (legacyRes.statusCode >= 400) return const [];
        return _parseIntroDbLegacy(legacyRes.body);
      }
      return _parseIntroDbSegments(response.body);
    } catch (_) {
      return const [];
    }
  }

  List<MediaSegment> _parseIntroDbLegacy(String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final startMs = (map['start_ms'] as num?)?.toInt();
      final endMs = (map['end_ms'] as num?)?.toInt();
      if (startMs == null || endMs == null) return const [];
      return [
        MediaSegment(
          type: MediaSegmentType.intro,
          start: Duration(milliseconds: startMs),
          end: Duration(milliseconds: endMs),
          source: 'introdb',
          confidence: (map['confidence'] as num?)?.toDouble(),
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  List<MediaSegment> _parseIntroDbSegments(String body) {
    try {
      final decoded = jsonDecode(body);
      final list = decoded is List
          ? decoded
          : (decoded is Map && decoded['segments'] is List)
              ? decoded['segments'] as List
              : const [];
      final out = <MediaSegment>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final typeName =
            (map['segment_type'] as String?) ?? (map['type'] as String?) ?? '';
        final type = MediaSegmentType.values.asNameMap()[typeName];
        if (type == null) continue;
        final start = _parseTime(map['start_sec'] ?? map['start_ms'] ?? map['start']);
        final end = _parseTime(map['end_sec'] ?? map['end_ms'] ?? map['end']);
        if (start == null) continue;
        out.add(
          MediaSegment(
            type: type,
            start: start,
            end: end,
            source: 'introdb',
            confidence: (map['confidence'] as num?)?.toDouble(),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<MediaSegment>> _fetchTheIntroDb(MediaItem item) async {
    if (item.tmdbId == null && (item.imdbId == null || item.imdbId!.isEmpty)) {
      return const [];
    }
    try {
      final params = <String, String>{};
      if (item.tmdbId != null) params['tmdb_id'] = '${item.tmdbId}';
      if (item.imdbId != null && item.imdbId!.isNotEmpty) {
        params['imdb_id'] = item.imdbId!;
      }
      final isTv = item.seasonNumber != null || item.episodeNumber != null;
      params['type'] = isTv ? 'tv' : 'movie';
      if (item.seasonNumber != null) params['season'] = '${item.seasonNumber}';
      if (item.episodeNumber != null) {
        params['episode'] = '${item.episodeNumber}';
      }

      final uri = Uri.https('api.theintrodb.org', '/v3/media', params);
      var response = await _http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode >= 400) {
        final v1 = Uri.https('api.theintrodb.org', '/v1/media', params);
        response = await _http.get(v1).timeout(const Duration(seconds: 8));
        if (response.statusCode >= 400) return const [];
      }
      return _parseTheIntroDb(response.body);
    } catch (_) {
      return const [];
    }
  }

  List<MediaSegment> _parseTheIntroDb(String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final out = <MediaSegment>[];
      for (final type in MediaSegmentType.values) {
        final raw = map[type.name];
        if (raw is! List) continue;
        for (final entry in raw) {
          if (entry is! Map) continue;
          final m = Map<String, dynamic>.from(entry);
          final startMs = m['start_ms'];
          final endMs = m['end_ms'];
          final start = startMs == null
              ? Duration.zero
              : Duration(milliseconds: (startMs as num).toInt());
          final end = endMs == null
              ? null
              : Duration(milliseconds: (endMs as num).toInt());
          out.add(
            MediaSegment(
              type: type,
              start: start,
              end: end,
              source: 'theintrodb',
            ),
          );
          break; // first window per type
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Duration? _parseTime(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      // Heuristic: large numbers are ms.
      if (value >= 10000) return Duration(milliseconds: value.toInt());
      return Duration(milliseconds: (value * 1000).round());
    }
    if (value is String) {
      final parts = value.split(':').map((e) => int.tryParse(e) ?? 0).toList();
      if (parts.length == 3) {
        return Duration(
          hours: parts[0],
          minutes: parts[1],
          seconds: parts[2],
        );
      }
      if (parts.length == 2) {
        return Duration(minutes: parts[0], seconds: parts[1]);
      }
      final asNum = double.tryParse(value);
      if (asNum != null) return _parseTime(asNum);
    }
    return null;
  }

  void close() => _http.close();
}
