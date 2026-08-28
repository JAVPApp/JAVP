import 'dart:math' as math;

import 'package:javp/models/media_item.dart';

/// Home discovery rails that follow what the user actually plays.
enum HomeContentType { live, movies, series }

/// Recency-weighted live / movies / series order for Home type rails.
///
/// Continue watching stays first; this only ranks Watch live, Movies, and
/// Series. Consecutive live/catchup rows collapse to one session weighted
/// by unique channels (capped) so zapping cannot bury VOD.
class HomeTypeAffinity {
  HomeTypeAffinity._();

  /// Matches today's Home when there is no history yet (Watch live, then
  /// Movies, then Series).
  static const defaultOrder = [
    HomeContentType.live,
    HomeContentType.movies,
    HomeContentType.series,
  ];

  static const lookback = 80;
  static const decay = 0.9;

  /// Scores must differ by more than this or the default relative order wins.
  static const tieEpsilon = 0.75;

  static HomeContentType? classify(MediaItem item) {
    if (item.isLive || item.kind == MediaKind.catchup) {
      return HomeContentType.live;
    }
    if (item.isSeries || item.isEpisode) return HomeContentType.series;
    if (item.kind == MediaKind.vod ||
        item.kind == MediaKind.local ||
        item.kind == MediaKind.network) {
      return HomeContentType.movies;
    }
    return null;
  }

  static String encode(HomeContentType type) => type.name;

  static HomeContentType? tryParse(String? raw) {
    switch (raw) {
      case 'live':
        return HomeContentType.live;
      case 'movies':
        return HomeContentType.movies;
      case 'series':
        return HomeContentType.series;
      default:
        return null;
    }
  }

  static List<String> encodeOrder(List<HomeContentType> order) => [
    for (final type in sanitizeOrder(order)) encode(type),
  ];

  static List<HomeContentType>? parseOrder(Object? raw) {
    if (raw is! List) return null;
    final parsed = <HomeContentType>[];
    for (final entry in raw) {
      final type = tryParse('$entry');
      if (type == null || parsed.contains(type)) continue;
      parsed.add(type);
    }
    if (parsed.length != HomeContentType.values.length) return null;
    return parsed;
  }

  /// Fills any missing types after [preferred] using [defaultOrder].
  static List<HomeContentType> sanitizeOrder(List<HomeContentType> preferred) {
    if (preferred.length == HomeContentType.values.length &&
        HomeContentType.values.every(preferred.contains)) {
      return List<HomeContentType>.from(preferred);
    }
    final out = <HomeContentType>[];
    for (final type in preferred) {
      if (!out.contains(type)) out.add(type);
    }
    for (final type in defaultOrder) {
      if (!out.contains(type)) out.add(type);
    }
    return out;
  }

  /// Newest-first history → ranked types. Empty history keeps [snapshotOrder]
  /// (last-close) or [defaultOrder].
  static List<HomeContentType> rank({
    required List<MediaItem> history,
    List<HomeContentType>? snapshotOrder,
  }) {
    final fallback = snapshotOrder == null
        ? defaultOrder
        : sanitizeOrder(snapshotOrder);
    if (history.isEmpty) return fallback;

    final scores = {for (final type in HomeContentType.values) type: 0.0};
    final n = math.min(history.length, lookback);
    var eventIndex = 0;
    var i = 0;
    while (i < n) {
      final type = classify(history[i]);
      if (type == null) {
        i++;
        continue;
      }
      if (type != HomeContentType.live) {
        scores[type] = scores[type]! + math.pow(decay, eventIndex);
        eventIndex++;
        i++;
        continue;
      }
      // One channel-surf session: unique channels, capped so zapping cannot
      // bury Movies/Series, but a real live evening still counts.
      final channels = <String>{};
      while (i < n) {
        final next = classify(history[i]);
        if (next != HomeContentType.live) break;
        channels.add(_liveIdentity(history[i]));
        i++;
      }
      final session = math.min(channels.length, 4);
      scores[HomeContentType.live] =
          scores[HomeContentType.live]! + session * math.pow(decay, eventIndex);
      eventIndex++;
    }
    if (eventIndex == 0) return fallback;

    final ranked = List<HomeContentType>.from(defaultOrder);
    ranked.sort((a, b) {
      final delta = scores[b]! - scores[a]!;
      if (delta.abs() <= tieEpsilon) {
        return defaultOrder.indexOf(a).compareTo(defaultOrder.indexOf(b));
      }
      return scores[b]!.compareTo(scores[a]!);
    });
    return ranked;
  }

  static String _liveIdentity(MediaItem item) {
    final stream = item.streamId?.trim();
    if (stream != null && stream.isNotEmpty) return 'stream:$stream';
    final channel = item.channelId?.trim();
    if (channel != null && channel.isNotEmpty) return 'ch:$channel';
    return 'id:${item.id}';
  }

  /// First Movies/Series type in [order] — loaded in reveal phase 1.
  static HomeContentType firstVodType(List<HomeContentType> order) {
    for (final type in order) {
      if (type != HomeContentType.live) return type;
    }
    return HomeContentType.movies;
  }

  /// Staggered Home reveal: later types append below, never jump above.
  ///
  /// Watch live is phase 0 when live is ranked first; otherwise it waits until
  /// every VOD type above it has been revealed (phase 1 or 2).
  static int minRevealPhase(HomeContentType type, List<HomeContentType> order) {
    var vodSeen = 0;
    for (final candidate in order) {
      if (candidate == HomeContentType.live) {
        if (type == candidate) {
          if (vodSeen == 0) return 0;
          return vodSeen == 1 ? 1 : 2;
        }
        continue;
      }
      final phase = vodSeen == 0 ? 1 : 2;
      vodSeen++;
      if (candidate == type) return phase;
    }
    return 2;
  }
}
