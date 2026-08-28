import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/services/simkl/simkl_match.dart';

void main() {
  group('SimklCredentials bundled client id', () {
    test('empty clientId uses bundled effectiveClientId', () {
      const creds = SimklCredentials(clientId: '');
      expect(creds.usesBundledClientId, isTrue);
      expect(creds.effectiveClientId, SimklCredentials.bundledClientId);
      expect(creds.isConfigured, isTrue);
      expect(creds.isAuthenticated, isFalse);
    });

    test('custom clientId overrides bundled', () {
      const creds = SimklCredentials(clientId: 'my-custom-id');
      expect(creds.usesBundledClientId, isFalse);
      expect(creds.effectiveClientId, 'my-custom-id');
    });
  });

  group('SimklLibraryItem.fromSyncEntry', () {
    test('parses show watching row', () {
      final item = SimklLibraryItem.fromSyncEntry(
        {
          'last_watched_at': '2024-01-02T03:04:05Z',
          'watched_episodes_count': 3,
          'total_episodes_count': 10,
          'next_to_watch': 'S02E01',
          'show': {
            'title': 'Example Show',
            'year': 2020,
            'poster': 'abc123',
            'ids': {
              'simkl': 111,
              'tmdb': 222,
              'imdb': 'tt123',
            },
          },
        },
        mediaKey: 'show',
      );
      expect(item.title, 'Example Show');
      expect(item.isShow, isTrue);
      expect(item.ids.simkl, '111');
      expect(item.ids.tmdb, 222);
      expect(item.ids.imdb, 'tt123');
      expect(item.watchedEpisodes, 3);
      expect(item.totalEpisodes, 10);
      expect(item.nextToWatch, 'S02E01');
      expect(item.posterUrl, 'https://simkl.in/posters/abc123_m.jpg');
    });

    test('parses anilist id from anime ids block', () {
      final item = SimklLibraryItem.fromSyncEntry(
        {
          'status': 'watching',
          'watched_episodes_count': 2,
          'total_episodes_count': 10,
          'show': {
            'title': 'Example Anime',
            'ids': {'simkl': 9, 'anilist': 21, 'mal': '1'},
          },
        },
        mediaKey: 'anime',
      );
      expect(item.ids.anilist, 21);
      expect(item.episodeProgress, closeTo(0.2, 0.001));
    });

    test('anime rows nest under show key', () {
      final item = SimklLibraryItem.fromSyncEntry(
        {
          'status': 'watching',
          'show': {
            'title': 'Cowboy Bebop',
            'year': 1998,
            'ids': {'simkl': 37089, 'mal': '1'},
          },
        },
        mediaKey: 'anime',
      );
      expect(item.title, 'Cowboy Bebop');
      expect(item.ids.simkl, '37089');
      expect(item.isShow, isTrue);
      expect(item.isWatchingStatus, isTrue);
    });

    test('completed status is not treated as watching', () {
      final item = SimklLibraryItem.fromSyncEntry(
        {
          'status': 'completed',
          'show': {
            'title': 'Done Show',
            'ids': {'simkl': 1},
          },
        },
        mediaKey: 'show',
      );
      expect(item.isWatchingStatus, isFalse);
    });
  });

  group('SimklPlayback.fromApiEntry', () {
    test('normalizes progress percent to 0–1', () {
      final pb = SimklPlayback.fromApiEntry({
        'progress': 42,
        'paused_at': '2024-05-01T12:00:00Z',
        'movie': {
          'title': 'Film',
          'year': 2019,
          'ids': {'tmdb': 99},
        },
      });
      expect(pb.progress, closeTo(0.42, 0.001));
      expect(pb.isShow, isFalse);
      expect(pb.ids.tmdb, 99);
      expect(pb.title, 'Film');
    });

    test('reads episode season/number for shows', () {
      final pb = SimklPlayback.fromApiEntry({
        'progress': 10,
        'show': {
          'title': 'Show',
          'ids': {'simkl': 5},
        },
        'episode': {'season': 1, 'number': 4},
      });
      expect(pb.isShow, isTrue);
      expect(pb.seasonNumber, 1);
      expect(pb.episodeNumber, 4);
      expect(pb.progress, closeTo(0.1, 0.001));
    });
  });

  group('SimklActivities', () {
    test('fromApi extracts watching + playback stamps', () {
      final a = SimklActivities.fromApi({
        'tv': {
          'all': '2024-01-01T00:00:00Z',
          'watching': '2024-02-01T00:00:00Z',
        },
        'anime': {
          'watching': '2024-02-02T00:00:00Z',
        },
        'playback': {
          'all': '2024-02-03T00:00:00Z',
        },
      });
      expect(a.tvWatching, '2024-02-01T00:00:00Z');
      expect(a.animeWatching, '2024-02-02T00:00:00Z');
      expect(a.playback, '2024-02-03T00:00:00Z');
      expect(a.dateFromStamp, '2024-02-03T00:00:00Z');
      expect(a.watchingUnchanged(a), isTrue);
    });
  });

  group('simkl match helpers', () {
    MediaItem movie({
      required String id,
      int? tmdb,
      String? imdb,
      String? simkl,
      String playUrl = 'https://example/stream',
    }) {
      return MediaItem(
        id: id,
        title: 'Local $id',
        playUrl: playUrl,
        kind: MediaKind.vod,
        origin: MediaOrigin.url,
        tmdbId: tmdb,
        imdbId: imdb,
        simklId: simkl,
      );
    }

    test('prefers playable catalog over empty shell candidate', () {
      final catalog = [
        movie(id: 'playable', tmdb: 42),
        movie(id: 'empty', tmdb: 42, playUrl: ''),
      ];
      final hit = matchSimklIdsToLocal(
        const SimklIds(tmdb: 42),
        catalog: catalog,
        history: const [],
        watchlist: const [],
      );
      expect(hit?.id, 'playable');
    });

    test('resolve falls back to shell when unmatched', () {
      final rows = [
        const SimklLibraryItem(
          title: 'Only on Simkl',
          isShow: true,
          ids: SimklIds(simkl: '999'),
          posterUrl: 'https://simkl.in/posters/x_m.jpg',
        ),
      ];
      final resolved = resolveSimklWatchingItems(
        rows,
        catalog: const [],
        history: const [],
        watchlist: const [],
      );
      expect(resolved, hasLength(1));
      expect(resolved.single.id, 'simkl:999');
      expect(resolved.single.playUrl, isEmpty);
      expect(resolved.single.tags, contains('simkl-watching'));
      expect(resolved.single.isSeries, isTrue);
    });

    test('matches from extra VOD pool by tmdb', () {
      final vod = [
        MediaItem(
          id: 'xtream-1',
          title: 'Cached Movie',
          playUrl: 'https://example/m',
          kind: MediaKind.vod,
          origin: MediaOrigin.iptvXtream,
          tmdbId: 55,
        ),
      ];
      final hit = matchSimklIdsToLocal(
        const SimklIds(tmdb: 55),
        catalog: const [],
        history: const [],
        watchlist: const [],
        extra: vod,
      );
      expect(hit?.id, 'xtream-1');
    });

    test('matches AniList id used by custom-catalog-style catalogs', () {
      final catalog = [
        MediaItem(
          id: 'customcat-1',
          title: 'Local Anime Title',
          playUrl: '',
          kind: MediaKind.series,
          origin: MediaOrigin.customCatalog,
          anilistId: 21,
        ),
      ];
      final hit = matchSimklIdsToLocal(
        const SimklIds(anilist: 21),
        catalog: catalog,
        history: const [],
        watchlist: const [],
      );
      expect(hit?.id, 'customcat-1');
    });

    test('does not link Watching to Episode N catalog rows', () {
      final catalog = [
        MediaItem(
          id: 'anilist-147105',
          title: 'Sample Show',
          playUrl: '',
          kind: MediaKind.series,
          origin: MediaOrigin.customCatalog,
          anilistId: 147105,
          sourceId: 'customcat',
        ),
        MediaItem(
          id: 'anilist-147105-s1e7',
          title: 'Episode 7',
          playUrl: 'magnet:?xt=urn:btih:abc',
          kind: MediaKind.vod,
          origin: MediaOrigin.customCatalog,
          anilistId: 147105,
          seasonNumber: 1,
          episodeNumber: 7,
          seriesId: 'anilist-147105',
          sourceId: 'customcat',
        ),
      ];
      final hit = matchSimklIdsToLocal(
        const SimklIds(anilist: 147105, simkl: '1885096'),
        catalog: catalog,
        history: const [],
        watchlist: const [],
        title: 'Sample Show',
      );
      expect(hit?.id, 'anilist-147105');
      expect(hit?.isEpisode, isFalse);

      final resolved = resolveSimklWatchingItems(
        const [
          SimklLibraryItem(
            title: 'Sample Show',
            isShow: true,
            ids: SimklIds(anilist: 147105, simkl: '1885096'),
            watchedEpisodes: 11,
            totalEpisodes: 13,
            status: 'watching',
          ),
        ],
        catalog: catalog,
        history: const [],
        watchlist: const [],
      );
      expect(resolved.single.id, 'anilist-147105');
      expect(resolved.single.title, 'Sample Show');
      expect(resolved.single.subtitle, contains('11/13'));
    });

    test('relink heals persisted Episode N Watching cards', () {
      final episode = MediaItem(
        id: 'anilist-147105-s1e7',
        title: 'Episode 7',
        playUrl: 'magnet:?xt=urn:btih:abc',
        kind: MediaKind.vod,
        origin: MediaOrigin.customCatalog,
        anilistId: 147105,
        simklId: '1885096',
        seasonNumber: 1,
        episodeNumber: 7,
        seriesId: 'anilist-147105',
        subtitle: '11/13 eps',
        progress: 11 / 13,
      );
      final healed = relinkSimklWatchingItems(
        [episode],
        catalog: [
          MediaItem(
            id: 'anilist-147105',
            title: 'Sample Show',
            playUrl: '',
            kind: MediaKind.series,
            origin: MediaOrigin.customCatalog,
            anilistId: 147105,
          ),
        ],
        history: const [],
        watchlist: const [],
      );
      expect(healed.single.id, 'anilist-147105');
      expect(healed.single.title, 'Sample Show');
      expect(healed.single.subtitle, '11/13 eps');
    });

    test('shell carries episode progress from Simkl counts', () {
      const row = SimklLibraryItem(
        title: 'Show',
        isShow: true,
        ids: SimklIds(simkl: '1'),
        watchedEpisodes: 3,
        totalEpisodes: 12,
        nextToWatch: 'S01E04',
      );
      final shell = simklLibraryShell(row);
      expect(shell.progress, closeTo(0.25, 0.001));
      expect(shell.subtitle, contains('3/12'));
      expect(shell.subtitle, contains('Next S01E04'));
    });

    test('shell reconciles N/M when next-up is inside watched count', () {
      const row = SimklLibraryItem(
        title: 'Show',
        isShow: true,
        ids: SimklIds(simkl: '1'),
        watchedEpisodes: 5,
        totalEpisodes: 12,
        nextToWatch: 'S01E05',
      );
      expect(row.displayWatchedEpisodes, 4);
      final shell = simklLibraryShell(row);
      expect(shell.progress, closeTo(4 / 12, 0.001));
      expect(shell.subtitle, '4/12 eps · Next S01E05');
    });

    test('falls back to normalized title when ids missing locally', () {
      final catalog = [
        MediaItem(
          id: 'local-title',
          title: 'The Example Show!',
          playUrl: 'https://example/s',
          kind: MediaKind.series,
          origin: MediaOrigin.iptvXtream,
          year: 2021,
        ),
      ];
      final hit = matchSimklIdsToLocal(
        const SimklIds(tmdb: 999),
        catalog: catalog,
        history: const [],
        watchlist: const [],
        title: 'The Example Show',
        year: 2021,
      );
      expect(hit?.id, 'local-title');
    });

    test('relink upgrades shells after local catalog appears', () {
      final shells = resolveSimklWatchingItems(
        const [
          SimklLibraryItem(
            title: 'Later Match',
            isShow: false,
            ids: SimklIds(tmdb: 77),
          ),
        ],
        catalog: const [],
        history: const [],
        watchlist: const [],
      );
      expect(shells.single.tags, contains('simkl-watching'));

      final linked = relinkSimklWatchingItems(
        shells,
        catalog: [
          MediaItem(
            id: 'now-local',
            title: 'Later Match',
            playUrl: 'https://example/v',
            kind: MediaKind.vod,
            origin: MediaOrigin.url,
            tmdbId: 77,
          ),
        ],
        history: const [],
        watchlist: const [],
      );
      expect(linked.single.id, 'now-local');
      expect(linked.single.tags, isNot(contains('simkl-watching')));
    });

    test('title match against FTS-style hit pool links anime shell', () {
      // Simulates SQLite FTS / custom /search returning candidates that were
      // never in the RAM match index (Xtream mid-sync, query-API catalogs).
      final shell = simklLibraryShell(
        const SimklLibraryItem(
          title: 'Example Anime',
          isShow: true,
          ids: SimklIds(anilist: 21, simkl: '9'),
        ),
      );
      expect(isSimklWatchingShell(shell), isTrue);

      final ftsHits = [
        MediaItem(
          id: 'xtream:anime-1',
          title: 'Example Anime',
          playUrl: 'https://xtream.example/series/1',
          kind: MediaKind.series,
          origin: MediaOrigin.iptvXtream,
          sourceId: 'xtream-1',
          anilistId: 21,
        ),
        MediaItem(
          id: 'noise',
          title: 'Unrelated Show',
          playUrl: 'https://xtream.example/series/2',
          kind: MediaKind.series,
          origin: MediaOrigin.iptvXtream,
          sourceId: 'xtream-1',
        ),
      ];
      final matched = matchSimklIdsToLocal(
        SimklIds(
          simkl: shell.simklId,
          anilist: shell.anilistId,
        ),
        catalog: ftsHits,
        history: const [],
        watchlist: const [],
        title: shell.title,
      );
      expect(matched?.id, 'xtream:anime-1');
      expect(isTrackerListShell(matched!), isFalse);
    });

    test('buildAsync matches sync index for tmdb + loose title', () async {
      final catalog = [
        for (var i = 0; i < 40; i++)
          MediaItem(
            id: 'filler-$i',
            title: 'Filler Title $i',
            playUrl: 'https://example/$i',
            kind: MediaKind.vod,
            origin: MediaOrigin.url,
            tmdbId: 1000 + i,
          ),
        MediaItem(
          id: 'target',
          title: 'The Example Show!',
          playUrl: 'https://example/s',
          kind: MediaKind.series,
          origin: MediaOrigin.iptvXtream,
          year: 2021,
        ),
      ];
      final index = await SimklMatchIndex.buildAsync(catalog, yieldEvery: 8);
      final byId = index.match(const SimklIds(tmdb: 1010));
      expect(byId?.id, 'filler-10');
      final byTitle = index.match(
        const SimklIds(tmdb: 9999),
        title: 'The Example Show',
        year: 2021,
      );
      expect(byTitle?.id, 'target');
    });

    test('shared index resolves watching without rebuilding', () {
      final catalog = [
        MediaItem(
          id: 'local-1',
          title: 'Show',
          playUrl: 'https://example/1',
          kind: MediaKind.series,
          origin: MediaOrigin.url,
          tmdbId: 42,
        ),
      ];
      final index = SimklMatchIndex(catalog);
      final resolved = resolveSimklWatchingItems(
        const [
          SimklLibraryItem(
            title: 'Show',
            isShow: true,
            ids: SimklIds(tmdb: 42),
            status: 'watching',
          ),
        ],
        catalog: catalog,
        history: const [],
        watchlist: const [],
        index: index,
      );
      expect(resolved.single.id, 'local-1');
    });
  });
}
