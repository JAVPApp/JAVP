import 'package:javp/models/media_item.dart';
import 'package:javp/services/recommendations/home_type_affinity.dart';

/// Lean Accueil shelf paint from last close — ids + posters + titles enough
/// to render tiles before catalog / VOD hydrate / Drive sync finish.
class HomeShelfSnapshot {
  const HomeShelfSnapshot({
    required this.savedAt,
    this.continueWatching = const [],
    this.watching = const [],
    this.movies = const [],
    this.series = const [],
    this.forYou = const [],
    this.myList = const [],
    this.trending = const [],
    this.popular = const [],
    this.recentLive = const [],
    this.watchLive = false,
    this.typeOrder = const [],
  });

  static const schemaVersion = 1;

  final DateTime savedAt;
  final List<MediaItem> continueWatching;
  final List<MediaItem> watching;
  final List<MediaItem> movies;
  final List<MediaItem> series;
  final List<MediaItem> forYou;
  final List<MediaItem> myList;
  final List<MediaItem> trending;
  final List<MediaItem> popular;

  /// Android TV Home “Watch live” row from last close (recents then favorites).
  final List<MediaItem> recentLive;

  /// True when the Watch live CTA was shown — even with an empty recent row.
  final bool watchLive;

  /// Last-close Movies / Series / Watch live order (empty = default).
  final List<HomeContentType> typeOrder;

  bool get hasContent =>
      continueWatching.isNotEmpty ||
      watching.isNotEmpty ||
      movies.isNotEmpty ||
      series.isNotEmpty ||
      forYou.isNotEmpty ||
      myList.isNotEmpty ||
      trending.isNotEmpty ||
      popular.isNotEmpty ||
      recentLive.isNotEmpty ||
      watchLive;

  /// Fingerprint for skip-write when shelves are unchanged.
  int get contentStamp => Object.hash(
    continueWatching.length,
    watching.length,
    movies.length,
    series.length,
    forYou.length,
    myList.length,
    trending.length,
    popular.length,
    recentLive.length,
    watchLive,
    Object.hashAll([for (final t in typeOrder) t.index]),
    _idsFinger(continueWatching),
    _idsFinger(watching),
    _idsFinger(movies),
    _idsFinger(series),
    _idsFinger(forYou),
    _idsFinger(myList),
    _idsFinger(trending),
    _idsFinger(popular),
    _idsFinger(recentLive),
  );

  static int _idsFinger(List<MediaItem> items) {
    if (items.isEmpty) return 0;
    return Object.hashAll([
      for (final m in items.take(24)) Object.hash(m.id, m.progress),
    ]);
  }

  Map<String, dynamic> toJson() => {
    'v': schemaVersion,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'continue': continueWatching.map((m) => m.toSyncJson()).toList(),
    'watching': watching.map((m) => m.toSyncJson()).toList(),
    'movies': movies.map((m) => m.toSyncJson()).toList(),
    'series': series.map((m) => m.toSyncJson()).toList(),
    'forYou': forYou.map((m) => m.toSyncJson()).toList(),
    'myList': myList.map((m) => m.toSyncJson()).toList(),
    'trending': trending.map((m) => m.toSyncJson()).toList(),
    'popular': popular.map((m) => m.toSyncJson()).toList(),
    'recentLive': recentLive.map((m) => m.toSyncJson()).toList(),
    'watchLive': watchLive,
    if (typeOrder.isNotEmpty)
      'typeOrder': HomeTypeAffinity.encodeOrder(typeOrder),
  };

  static HomeShelfSnapshot? tryDecode(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final v = map['v'];
    if (v is int && v > schemaVersion) return null;
    final savedAt =
        DateTime.tryParse('${map['savedAt'] ?? ''}')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return HomeShelfSnapshot(
      savedAt: savedAt,
      continueWatching: _items(map['continue']),
      watching: _items(map['watching']),
      movies: _items(map['movies']),
      series: _items(map['series']),
      forYou: _items(map['forYou']),
      myList: _items(map['myList']),
      trending: _items(map['trending']),
      popular: _items(map['popular']),
      recentLive: _items(map['recentLive']),
      watchLive: map['watchLive'] == true,
      typeOrder: HomeTypeAffinity.parseOrder(map['typeOrder']) ?? const [],
    );
  }

  static List<MediaItem> _items(Object? raw) {
    if (raw is! List) return const [];
    final out = <MediaItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        out.add(MediaItem.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {
        // Skip corrupt tile rows.
      }
      if (out.length >= 24) break;
    }
    return out;
  }

  /// Drop tiles that [keep] rejects (gone / disabled catalogs).
  ///
  /// Returns [this] when nothing changed so callers can skip a disk write.
  HomeShelfSnapshot whereItems(bool Function(MediaItem item) keep) {
    List<MediaItem> take(List<MediaItem> items) {
      if (items.isEmpty) return items;
      final out = [
        for (final m in items)
          if (keep(m)) m,
      ];
      return out.length == items.length ? items : out;
    }

    final nextContinue = take(continueWatching);
    final nextWatching = take(watching);
    final nextMovies = take(movies);
    final nextSeries = take(series);
    final nextForYou = take(forYou);
    final nextMyList = take(myList);
    final nextTrending = take(trending);
    final nextPopular = take(popular);
    final nextRecentLive = take(recentLive);
    if (identical(nextContinue, continueWatching) &&
        identical(nextWatching, watching) &&
        identical(nextMovies, movies) &&
        identical(nextSeries, series) &&
        identical(nextForYou, forYou) &&
        identical(nextMyList, myList) &&
        identical(nextTrending, trending) &&
        identical(nextPopular, popular) &&
        identical(nextRecentLive, recentLive)) {
      return this;
    }
    return HomeShelfSnapshot(
      savedAt: savedAt,
      continueWatching: nextContinue,
      watching: nextWatching,
      movies: nextMovies,
      series: nextSeries,
      forYou: nextForYou,
      myList: nextMyList,
      trending: nextTrending,
      popular: nextPopular,
      recentLive: nextRecentLive,
      watchLive: watchLive && (nextRecentLive.isNotEmpty || recentLive.isEmpty),
      typeOrder: typeOrder,
    );
  }
}
