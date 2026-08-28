import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/recommendations/local_recommender.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryProvider library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    library = LibraryProvider(store: LibraryStore(prefs: prefs));
    await library.bootstrap();
  });

  tearDown(() => library.dispose());

  MediaItem sample(String id, {MediaKind kind = MediaKind.vod}) {
    return MediaItem(
      id: id,
      title: 'Title $id',
      playUrl: 'https://example.com/$id.mp4',
      kind: kind,
      origin: MediaOrigin.url,
    );
  }

  test('recordWatch keeps newest-first local history without SIMKL', () async {
    await library.recordWatch(sample('a'));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await library.recordWatch(sample('b', kind: MediaKind.live));

    expect(library.recentHistory.map((e) => e.id), ['b', 'a']);
    expect(library.recentHistory.first.kind, MediaKind.live);
    expect(library.recentHistory.every((e) => e.lastWatchedAt != null), isTrue);
  });

  test('recordProgress updates resume point and reorders history', () async {
    await library.recordWatch(sample('a'));
    await library.recordWatch(sample('b'));
    await library.recordProgress(sample('a'), 0.42);

    expect(library.recentHistory.first.id, 'a');
    expect(library.recentHistory.first.progress, closeTo(0.42, 0.001));
  });

  test('recordProgress never rewrites catalog rows', () async {
    final item = sample('a');
    library.catalog = [item, sample('b'), sample('c')];
    await library.recordWatch(item);

    await library.recordProgress(item, 0.25);
    await library.recordProgress(item, 0.50);
    await library.recordProgress(item, 0.75);

    expect(library.recentHistory.first.id, 'a');
    expect(library.recentHistory.first.progress, closeTo(0.75, 0.001));
    // Resume ticks must not scan/patch the catalog — that used to hitch every 5s.
    expect(
      library.catalog.firstWhere((m) => m.id == 'a').progress,
      closeTo(0.0, 0.001),
    );
  });

  test('recordProgress soft-persists history until flush', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    await library.recordWatch(sample('a'));
    await library.flushPendingWrites();

    await library.recordProgress(sample('a'), 0.33);
    // Soft delay — disk should still show the pre-tick progress until flush.
    final beforeFlush = await store.loadHistory();
    expect(beforeFlush.first.progress, closeTo(0.0, 0.001));

    await library.flushPendingWrites();
    final afterFlush = await store.loadHistory();
    expect(afterFlush.first.progress, closeTo(0.33, 0.001));
  });

  test('remove and clear history', () async {
    await library.recordWatch(sample('a'));
    await library.recordWatch(sample('b'));
    await library.removeFromHistory('a');
    expect(library.recentHistory.map((e) => e.id), ['b']);

    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    expect(
      (await store.loadHistoryDeleted()).keys,
      unorderedEquals(['a', 'url:https://example.com/a.mp4']),
    );

    await library.clearHistory();
    expect(library.recentHistory, isEmpty);
    expect(await store.loadHistoryDeleted(), isEmpty);
  });

  test('removeFromHistory tombstones sibling URL ghosts by playUrl', () async {
    const url = 'https://example.com/same.m3u8';
    final kept = MediaItem(
      id: 'kept',
      title: 'azeaze',
      playUrl: url,
      kind: MediaKind.network,
      origin: MediaOrigin.url,
      lastWatchedAt: DateTime.utc(2026, 8, 11),
    );
    final ghost = MediaItem(
      id: 'ghost-bac',
      title: 'bac',
      playUrl: url,
      kind: MediaKind.network,
      origin: MediaOrigin.url,
      lastWatchedAt: DateTime.utc(2026, 8, 10),
    );
    library.history = [kept, ghost];
    await library.removeFromHistory('ghost-bac');

    expect(library.recentHistory, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final deleted = await LibraryStore(prefs: prefs).loadHistoryDeleted();
    expect(deleted.containsKey('ghost-bac'), isTrue);
    expect(deleted.containsKey('kept'), isTrue);
    expect(deleted.containsKey('url:$url'), isTrue);
  });

  test('historyDisplayTitle prefers series · SxxExx over Episode N', () {
    final item = MediaItem(
      id: 'anilist-1-s1e7',
      title: 'Episode 7',
      playUrl: 'magnet:?xt=urn:btih:abc',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      seriesId: 'anilist-1',
      seasonNumber: 1,
      episodeNumber: 7,
      subtitle: 'Sample Show · S01E07 · 1080p',
    );
    expect(library.historyDisplayTitle(item), 'Sample Show · S01E07');

    final simklProgressOnly = item.copyWith(subtitle: '11/13 eps · Next E12');
    expect(library.historyDisplayTitle(simklProgressOnly), 'S01E07');
  });

  test('historyDisplayTitle / continueWatching remap live family titles', () {
    final fhd = MediaItem(
      id: 'channela-fhd',
      title: 'FR| ChannelA FHD',
      playUrl: 'http://example.com/channela-fhd.ts',
      kind: MediaKind.live,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src1',
      streamId: '101',
      channelName: 'FR| ChannelA',
    );
    final car = MediaItem(
      id: 'channela-car',
      title: 'FR-CAR| ChannelA',
      playUrl: 'http://example.com/channela-car.ts',
      kind: MediaKind.live,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src1',
      streamId: '104',
      channelName: 'FR-CAR| ChannelA',
    );
    library.catalog = [fhd, car];

    // Stale history snapshot still has the regional label.
    final stale = car.copyWith(
      title: 'FR-CAR| ChannelA (FHD)',
      progress: 0.4,
      lastWatchedAt: DateTime.utc(2026, 8, 12),
    );
    // Family resolve remaps the regional snapshot to the shared list label.
    expect(library.historyDisplayTitle(stale), 'ChannelA');
    // Public display helper used by player chrome / tiles / actions sheets.
    expect(library.liveOrCatchupDisplayTitle(stale), 'ChannelA');
    expect(library.officialLiveTitle(library.resolveLiveChannel(car)), 'ChannelA');

    library.history = [stale];
    final cw = library.continueWatching;
    expect(cw, hasLength(1));
    expect(cw.single.title, 'ChannelA');
    // Disk snapshot is unchanged — display-time remap only.
    expect(library.history.single.title, 'FR-CAR| ChannelA (FHD)');
  });

  test('historyDisplayTitle remaps catchup DVR but keeps programme titles', () {
    final channel = MediaItem(
      id: 'channela-fhd',
      title: 'FR| ChannelA FHD',
      playUrl: 'http://example.com/channela-fhd.ts',
      kind: MediaKind.live,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src1',
      streamId: '101',
      catchupDays: 7,
    );
    library.catalog = [channel];

    final startMs = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    final dvr = MediaItem(
      id: 'dvr-101-$startMs',
      title: 'FR-CAR| ChannelA (FHD) (DVR)',
      playUrl: 'http://example.com/dvr.ts',
      kind: MediaKind.catchup,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src1',
      streamId: '101',
      subtitle: 'FR-CAR| ChannelA (FHD)',
      catchupDays: 7,
      progress: 0.3,
      lastWatchedAt: DateTime.utc(2026, 8, 12),
    );
    expect(library.historyDisplayTitle(dvr), 'ChannelA (DVR)');

    final programme = dvr.copyWith(title: 'Journal de 20h (Catchup)');
    expect(library.historyDisplayTitle(programme), 'Journal de 20h (Catchup)');

    library.history = [dvr];
    expect(library.continueWatching.single.title, 'ChannelA (DVR)');
  });

  test('continueWatching dedupes series shell and episode sibling', () {
    final series = MediaItem(
      id: 'show-1',
      title: 'Sample Show',
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.customCatalog,
      anilistId: 147105,
      tmdbId: 196950,
      progress: 0.1,
      lastWatchedAt: DateTime.utc(2026, 8, 11, 20),
    );
    final episode = MediaItem(
      id: 'anilist-147105-s1e7',
      title: 'Episode 7',
      playUrl: 'https://example.com/e7',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      seriesId: 'show-1',
      seasonNumber: 1,
      episodeNumber: 7,
      anilistId: 147105,
      tmdbId: 196950,
      progress: 0.85,
      lastWatchedAt: DateTime.utc(2026, 8, 11, 22),
    );
    library.history = [series, episode];
    library.catalog = [series];

    final cw = library.continueWatching;
    expect(cw, hasLength(1));
    expect(cw.single.id, 'show-1');
    expect(cw.single.progress, closeTo(0.85, 0.001));
    expect(cw.single.seasonNumber, 1);
    expect(cw.single.episodeNumber, 7);
    expect(cw.single.subtitle, 'S01E07');
  });

  MediaItem movieEncode(String id, {double progress = 0.4, DateTime? at}) {
    return MediaItem(
      id: id,
      title: 'Sample Feature Film',
      playUrl: 'https://example.com/$id.mp4',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src-1',
      year: 2024,
      progress: progress,
      lastWatchedAt: at ?? DateTime.utc(2026, 8, 12, 20),
    );
  }

  test(
    'recordWatch collapses sibling episode versions onto one history row',
    () async {
      MediaItem epVersion(String id, {required double progress}) {
        return MediaItem(
          id: id,
          title: 'Episode 3',
          playUrl: 'magnet:?xt=urn:btih:$id',
          kind: MediaKind.vod,
          origin: MediaOrigin.customCatalog,
          seriesId: 'anilist-201817',
          seasonNumber: 1,
          episodeNumber: 3,
          anilistId: 201817,
          progress: progress,
        );
      }

      await library.recordWatch(
        epVersion('ver-a', progress: 0.4),
        progress: 0.4,
      );
      await library.recordWatch(
        epVersion('ver-b', progress: 0.7),
        progress: 0.7,
      );

      final rows = library.history.where(
        (m) =>
            m.seriesId == 'anilist-201817' &&
            m.seasonNumber == 1 &&
            m.episodeNumber == 3,
      );
      expect(rows, hasLength(1));
      expect(rows.single.id, 'ver-b');
      expect(rows.single.progress, closeTo(0.7, 0.001));

      final listed = library.historyForSeriesEpisode(
        series: MediaItem(
          id: 'anilist-201817',
          title: 'Show',
          playUrl: '',
          kind: MediaKind.series,
          origin: MediaOrigin.customCatalog,
          anilistId: 201817,
        ),
        episode: const SeriesEpisode(
          id: 'anilist-201817-s1e3',
          episodeNum: 3,
          seasonNumber: 1,
          title: 'Episode 3',
          containerExtension: 'mkv',
        ),
      );
      expect(listed?.progress, closeTo(0.7, 0.001));
    },
  );

  test('continueWatching keeps one card for movie quality encodes', () {
    final hd = movieEncode('encode-hd', at: DateTime.utc(2026, 8, 12, 22));
    final sd = movieEncode(
      'encode-sd',
      progress: 0.2,
      at: DateTime.utc(2026, 8, 12, 20),
    );
    final fr = movieEncode('encode-fr', progress: 0.3).copyWith(
      title: 'FR| Sample Feature Film',
      lastWatchedAt: DateTime.utc(2026, 8, 12, 18),
    );
    library.history = [hd, sd, fr];

    final cw = library.continueWatching;
    expect(cw, hasLength(1));
    expect(cw.single.id, 'encode-hd');
  });

  test(
    'recordWatch collapses sibling movie encodes onto one history row',
    () async {
      final sd = movieEncode('encode-sd', progress: 0.4);
      await library.recordWatch(sd, progress: 0.4);
      final hd = movieEncode('encode-hd', progress: 0.55);
      await library.recordWatch(hd, progress: 0.55);

      expect(
        library.history.where((m) => m.title.contains('Sample Feature')),
        hasLength(1),
      );
      expect(library.history.first.id, 'encode-hd');
      expect(library.continueWatching, hasLength(1));
      expect(library.continueWatching.single.id, 'encode-hd');
    },
  );

  test('resumeSnapshotFor shares progress across movie encodes', () async {
    await library.recordWatch(
      movieEncode('encode-sd', progress: 0.42),
      progress: 0.42,
    );
    final hd = movieEncode('encode-hd', progress: 0);
    final snap = library.resumeSnapshotFor(hd);
    expect(snap, isNotNull);
    expect(snap!.progress, closeTo(0.42, 0.001));
  });

  test('removeFromContinueWatching drops every movie-family encode', () async {
    await library.recordWatch(movieEncode('encode-sd'), progress: 0.3);
    // Pre-collapse leftover rows (older installs kept one row per encode).
    library.history = [
      movieEncode('encode-hd', at: DateTime.utc(2026, 8, 12, 22)),
      movieEncode(
        'encode-sd',
        progress: 0.2,
        at: DateTime.utc(2026, 8, 12, 20),
      ),
    ];
    expect(library.continueWatching, hasLength(1));
    await library.removeFromContinueWatching(library.continueWatching.single);
    expect(library.continueWatching, isEmpty);
    expect(
      library.history.where(
        (m) => LocalRecommender.isContinueWatchingCandidate(m),
      ),
      isEmpty,
    );
  });

  test('continueWatching heals bare Episode N via details / magnet title', () {
    final episode = MediaItem(
      id: 'anilist-147105-s1e7',
      title: 'Episode 7',
      playUrl:
          'magnet:?xt=urn:btih:abc&dn=%5BTrix%5D%20Sample%20Show%20S01%20%28Batch%29',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      seriesId: 'anilist-147105',
      seasonNumber: 1,
      episodeNumber: 7,
      anilistId: 147105,
      tmdbId: 196950,
      simklId: '1885096',
      progress: 0.85,
      lastWatchedAt: DateTime.utc(2026, 8, 11, 22, 22),
      subtitle: '11/13 eps · Next E12',
      posterUrl: 'https://example.com/poster.jpg',
    );
    library.history = [episode];
    library.detailsCache = {
      'simkl-anime-1885096': const MediaDetails(
        id: 'simkl-anime-1885096',
        title: 'Sample Show JP',
        anilistId: 147105,
        tmdbId: 196950,
      ),
    };

    final cw = library.continueWatching;
    expect(cw, hasLength(1));
    expect(cw.single.isSeries, isTrue);
    expect(cw.single.id, 'anilist-147105');
    expect(cw.single.title, 'Sample Show JP');
    expect(cw.single.title.toLowerCase(), isNot(contains('episode')));
    expect(cw.single.subtitle, 'S01E07');
    expect(cw.single.subtitle?.toLowerCase(), isNot(contains('episode')));
    expect(cw.single.progress, closeTo(0.85, 0.001));
    expect(cw.single.seasonNumber, 1);
    expect(cw.single.episodeNumber, 7);
  });

  test('continueWatching keeps AniList episodes before catalog hydrate', () {
    final episode = MediaItem(
      id: 'xtream-ep-7',
      title: 'Episode 7',
      playUrl: 'https://example.com/e7',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src1',
      seasonNumber: 1,
      episodeNumber: 7,
      anilistId: 147105,
      tmdbId: 196950,
      progress: 0.4,
      lastWatchedAt: DateTime.utc(2026, 8, 12),
    );
    library.history = [episode];
    library.catalog = [];

    final cw = library.continueWatching;
    expect(cw, hasLength(1));
    expect(cw.single.isSeries, isTrue);
    expect(cw.single.id, 'anilist-147105');
    expect(cw.single.anilistId, 147105);
    expect(cw.single.progress, closeTo(0.4, 0.001));
    expect(cw.single.seasonNumber, 1);
    expect(cw.single.episodeNumber, 7);
  });

  test('removeFromHistory notifies before persist finishes', () async {
    await library.recordWatch(sample('a'));
    await library.recordWatch(sample('b'));

    var notified = 0;
    library.addListener(() => notified++);

    final pending = library.removeFromHistory('a');
    // UI must update on the same turn — not after SharedPreferences I/O.
    expect(notified, greaterThan(0));
    expect(library.recentHistory.map((e) => e.id), ['b']);
    await pending;
  });

  test('removeFromContinueWatching notifies before persist finishes', () async {
    final watching = sample('movie').copyWith(progress: 0.4);
    await library.recordWatch(watching);

    var notified = 0;
    library.addListener(() => notified++);

    final pending = library.removeFromContinueWatching(watching);
    expect(notified, greaterThan(0));
    expect(library.continueWatching, isEmpty);
    await pending;
  });

  test(
    'removeFromContinueWatching drops catalog series matched by AniList',
    () async {
      final series = MediaItem(
        id: 'xtream-show-99',
        title: 'Sample Show',
        playUrl: '',
        kind: MediaKind.series,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'src1',
        anilistId: 147105,
        tmdbId: 196950,
      );
      final episode = MediaItem(
        id: 'xtream-ep-7',
        title: 'Episode 7',
        playUrl: 'https://example.com/e7',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'src1',
        seasonNumber: 1,
        episodeNumber: 7,
        anilistId: 147105,
        tmdbId: 196950,
        progress: 0.4,
        lastWatchedAt: DateTime.utc(2026, 8, 12),
      );
      library.catalog = [series];
      library.history = [episode];

      final cw = library.continueWatching;
      expect(cw, hasLength(1));
      expect(cw.single.id, 'xtream-show-99');

      await library.removeFromContinueWatching(cw.single);
      expect(library.continueWatching, isEmpty);
      expect(library.history, isEmpty);
    },
  );

  test(
    'removeFromHistory of last in-progress title clears continue watching',
    () async {
      final watching = sample('movie').copyWith(progress: 0.4);
      await library.recordWatch(watching);
      expect(library.continueWatching, hasLength(1));

      await library.removeFromHistory(watching.id);
      expect(library.recentHistory, isEmpty);
      expect(library.continueWatching, isEmpty);
    },
  );

  test('recordWatch after remove clears the history tombstone', () async {
    await library.recordWatch(sample('a'));
    await library.removeFromHistory('a');
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    expect((await store.loadHistoryDeleted()).containsKey('a'), isTrue);

    await library.recordWatch(sample('a'));
    expect(await store.loadHistoryDeleted(), isEmpty);
    expect(library.recentHistory.map((e) => e.id), ['a']);
  });

  test('clearHistory wins over in-flight write-behind persist', () async {
    await library.recordWatch(sample('a'));
    await library.recordWatch(sample('b'));
    expect(library.recentHistory, isNotEmpty);

    // Flush the dirty write-behind mark concurrently with clear — without an
    // epoch guard the flush can rewrite the pre-clear snapshot after [].
    final flush = library.flushPendingWrites();
    await library.clearHistory();
    await flush;

    expect(library.recentHistory, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final stored = await LibraryStore(prefs: prefs).loadHistory();
    expect(stored, isEmpty);
  });

  test(
    'markAsWatched and markAsUnwatched update local history progress',
    () async {
      final episode = sample('ep1').copyWith(
        seriesId: 'series-1',
        seasonNumber: 1,
        episodeNumber: 2,
        progress: 0.26,
      );
      await library.recordWatch(episode, progress: 0.26);
      expect(library.history.first.progress, closeTo(0.26, 0.001));

      await library.markAsWatched(episode);
      expect(library.history.first.id, 'ep1');
      expect(library.history.first.progress, 1.0);

      await library.markAsUnwatched(library.history.first);
      expect(library.history.first.progress, 0.0);
      expect(library.history.first.tags.contains('continue-up-next'), isFalse);
    },
  );

  test('markAsUnwatched clears continue-up-next tag', () async {
    final episode = sample('ep2').copyWith(
      seriesId: 'series-1',
      seasonNumber: 1,
      episodeNumber: 3,
      tags: const ['continue-up-next'],
      progress: 0,
    );
    await library.recordWatch(episode, progress: 0);
    expect(library.history.first.tags, contains('continue-up-next'));

    await library.markAsUnwatched(library.history.first);
    expect(library.history.first.progress, 0.0);
    expect(library.history.first.tags, isNot(contains('continue-up-next')));
  });
}
