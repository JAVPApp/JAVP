import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/catalog_browse_prefs.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/catalog/catalog_browse.dart';

MediaItem movie({
  required String id,
  required String title,
  double progress = 0,
  int? tmdbId,
  double? rating,
  double? popularity,
  int? year,
  String? sourceId,
  List<String> genres = const [],
  int? seasonNumber,
  int? episodeNumber,
  String? seriesId,
  MediaKind kind = MediaKind.vod,
}) {
  return MediaItem(
    id: id,
    title: title,
    playUrl: 'https://example.com/$id',
    kind: kind,
    origin: MediaOrigin.iptvXtream,
    progress: progress,
    tmdbId: tmdbId,
    rating: rating,
    popularity: popularity,
    year: year,
    sourceId: sourceId,
    genres: genres,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    seriesId: seriesId,
  );
}

void main() {
  test('prefs json round-trip keeps popular + hide watched defaults', () {
    const prefs = CatalogBrowsePrefs(
      sort: CatalogBrowseSort.yearDesc,
      hideWatched: false,
      includeGenres: {'Action', 'Comedy'},
      excludeGenres: {'Horror'},
    );
    final copy = CatalogBrowsePrefs.fromJson(prefs.toJson());
    expect(copy.sort, CatalogBrowseSort.yearDesc);
    expect(copy.hideWatched, isFalse);
    expect(copy.includeGenres, {'Action', 'Comedy'});
    expect(copy.excludeGenres, {'Horror'});
    expect(CatalogBrowsePrefs.fromJson({}).hideWatched, isTrue);
    expect(CatalogBrowsePrefs.fromJson({}).sort, CatalogBrowseSort.popular);
  });

  test('hide watched drops finished movies, not a one-episode series', () {
    final watched = movie(id: 'm1', title: 'Done', progress: 1, tmdbId: 10);
    final sibling = movie(id: 'm1-fr', title: 'Done FR', tmdbId: 10);
    final unwatched = movie(id: 'm2', title: 'New');
    final series = movie(
      id: 's1',
      title: 'Show',
      kind: MediaKind.series,
      tmdbId: 99,
    );
    final episode = movie(
      id: 'e1',
      title: 'Show S01E01',
      seriesId: 's1',
      seasonNumber: 1,
      episodeNumber: 1,
      progress: 1,
    );
    final index = CatalogWatchedIndex(history: [watched, episode]);
    final prefs = const CatalogBrowsePrefs(hideWatched: true);
    final out = applyCatalogBrowse(
      [watched, sibling, unwatched, series],
      prefs: prefs,
      watched: index,
    );
    expect(out.map((m) => m.id), ['m2', 's1']);
  });

  test('tracker completed hides matching catalog title', () {
    final item = movie(id: 'local', title: 'Heat', tmdbId: 42);
    final index = CatalogWatchedIndex(
      history: const [],
      trackerStatuses: const [
        TrackerStatusEntry(
          source: 'simkl',
          status: TrackerStatusKind.completed,
          title: 'Heat',
          tmdbId: 42,
        ),
      ],
    );
    expect(index.isWatched(item), isTrue);
    expect(
      applyCatalogBrowse(
        [item],
        prefs: const CatalogBrowsePrefs(),
        watched: index,
      ),
      isEmpty,
    );
  });

  test('include / exclude genres', () {
    final action = movie(id: 'a', title: 'A', genres: ['Action']);
    final horror = movie(id: 'h', title: 'H', genres: ['Horror']);
    final both = movie(id: 'b', title: 'B', genres: ['Action', 'Horror']);
    final unknown = movie(id: 'u', title: 'U');
    final watched = CatalogWatchedIndex(history: const []);

    final onlyAction = applyCatalogBrowse(
      [action, horror, both, unknown],
      prefs: const CatalogBrowsePrefs(
        hideWatched: false,
        includeGenres: {'Action'},
      ),
      watched: watched,
    );
    expect(onlyAction.map((m) => m.id).toSet(), {'a', 'b'});

    final noHorror = applyCatalogBrowse(
      [action, horror, both, unknown],
      prefs: const CatalogBrowsePrefs(
        hideWatched: false,
        excludeGenres: {'Horror'},
      ),
      watched: watched,
    );
    expect(noHorror.map((m) => m.id).toSet(), {'a', 'u'});
  });

  test('popular sort uses TMDB rank then rating then year', () {
    final hot = movie(
      id: 'hot',
      title: 'Hot',
      tmdbId: 1,
      rating: 5,
      year: 2000,
    );
    final alsoHot = movie(
      id: 'also',
      title: 'Also',
      tmdbId: 2,
      rating: 9,
      year: 2024,
    );
    final rated = movie(id: 'rated', title: 'Rated', rating: 8, year: 2010);
    final old = movie(id: 'old', title: 'Old', rating: 8, year: 1990);
    final watched = CatalogWatchedIndex(history: const []);
    final out = applyCatalogBrowse(
      [old, rated, alsoHot, hot],
      prefs: const CatalogBrowsePrefs(hideWatched: false),
      watched: watched,
      popularRankByTmdbId: {1: 0, 2: 1},
    );
    expect(out.map((m) => m.id).toList(), ['hot', 'also', 'rated', 'old']);
  });

  test('popularity norms are per-source so scales do not fight', () {
    final torrentHot = movie(
      id: 't-hot',
      title: 'Torrent Hot',
      sourceId: 'customcat',
      popularity: 1000,
    );
    final torrentMid = movie(
      id: 't-mid',
      title: 'Torrent Mid',
      sourceId: 'customcat',
      popularity: 100,
    );
    final torrentLow = movie(
      id: 't-low',
      title: 'Torrent Low',
      sourceId: 'customcat',
      popularity: 10,
    );
    final scoreHot = movie(
      id: 's-hot',
      title: 'Score Hot',
      sourceId: 'bridge',
      popularity: 90,
    );
    final scoreMid = movie(
      id: 's-mid',
      title: 'Score Mid',
      sourceId: 'bridge',
      popularity: 50,
    );
    final scoreLow = movie(
      id: 's-low',
      title: 'Score Low',
      sourceId: 'bridge',
      popularity: 10,
    );
    final norms = catalogPopularityNorms([
      torrentHot,
      torrentMid,
      torrentLow,
      scoreHot,
      scoreMid,
      scoreLow,
    ]);
    expect(norms[catalogPopularityKey(torrentHot)], 1.0);
    expect(norms[catalogPopularityKey(torrentMid)], 0.5);
    expect(norms[catalogPopularityKey(torrentLow)], 0.0);
    expect(norms[catalogPopularityKey(scoreHot)], 1.0);
    expect(norms[catalogPopularityKey(scoreMid)], 0.5);
    expect(norms[catalogPopularityKey(scoreLow)], 0.0);
  });

  test('popular sort uses catalog heat after TMDB, before rating', () {
    final tmdb = movie(
      id: 'tmdb',
      title: 'Tmdb',
      tmdbId: 1,
      rating: 4,
      popularity: 1,
      sourceId: 'a',
    );
    final hot = movie(
      id: 'hot',
      title: 'Hot',
      rating: 5,
      popularity: 100,
      sourceId: 'a',
    );
    final cool = movie(
      id: 'cool',
      title: 'Cool',
      rating: 9,
      popularity: 10,
      sourceId: 'a',
    );
    final rated = movie(id: 'rated', title: 'Rated', rating: 8, sourceId: 'a');
    final out = applyCatalogBrowse(
      [rated, cool, hot, tmdb],
      prefs: const CatalogBrowsePrefs(hideWatched: false),
      watched: CatalogWatchedIndex(history: const []),
      popularRankByTmdbId: {1: 0},
    );
    expect(out.map((m) => m.id).toList(), ['tmdb', 'hot', 'cool', 'rated']);
  });

  test(
    'popularity norms use the pre-filter list so hide-watched does not inflate',
    () {
      final watchedHot = movie(
        id: 'done',
        title: 'Done',
        popularity: 100,
        sourceId: 'a',
        progress: 1,
      );
      final mid = movie(id: 'mid', title: 'Mid', popularity: 50, sourceId: 'a');
      final low = movie(id: 'low', title: 'Low', popularity: 10, sourceId: 'a');
      final norms = catalogPopularityNorms([watchedHot, mid, low]);
      expect(norms[catalogPopularityKey(mid)], 0.5);
      final out = applyCatalogBrowse(
        [watchedHot, mid, low],
        prefs: const CatalogBrowsePrefs(hideWatched: true),
        watched: CatalogWatchedIndex(history: [watchedHot]),
      );
      expect(out.map((m) => m.id).toList(), ['mid', 'low']);
      expect(catalogPopularityNorms(out)[catalogPopularityKey(mid)], 1.0);
    },
  );

  test('title sort stays A–Z', () {
    final b = movie(id: 'b', title: 'Bravo');
    final a = movie(id: 'a', title: 'Alpha');
    final out = applyCatalogBrowse(
      [b, a],
      prefs: CatalogBrowsePrefs.legacyTitle,
      watched: CatalogWatchedIndex(history: const []),
    );
    expect(out.map((m) => m.id).toList(), ['a', 'b']);
  });
}
