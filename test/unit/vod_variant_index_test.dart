import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/vod_variant_index.dart';

MediaItem vod(
  String id, {
  required String title,
  String sourceId = 'xt',
  int? year,
  int? tmdbId,
  MediaOrigin origin = MediaOrigin.iptvXtream,
}) {
  return MediaItem(
    id: id,
    title: title,
    playUrl: 'https://example/$id',
    kind: MediaKind.vod,
    origin: origin,
    sourceId: sourceId,
    year: year,
    tmdbId: tmdbId,
  );
}

void main() {
  test('buildPacked merges TMDB siblings and sorts media-server first', () {
    final jelly = vod(
      'jf',
      title: 'SampleTitle',
      sourceId: 'jelly',
      tmdbId: 42,
      year: 2022,
      origin: MediaOrigin.jellyfin,
    );
    final xt = vod(
      'xt',
      title: 'SampleTitle',
      sourceId: 'xt',
      tmdbId: 42,
      year: 2022,
    );
    final other = vod('other', title: 'Other Film', year: 2021);

    final packed = VodVariantIndex.buildPacked([
      VodVariantIndex.packRow(jelly),
      VodVariantIndex.packRow(xt),
      VodVariantIndex.packRow(other),
    ]);

    final families = packed['families'] as Map;
    final family = families['tmdb:movie:42'] as List;
    // Language ties: media-server origin outranks IPTV (same as compareVariants).
    expect(family, ['jf', 'xt']);
    expect(families['name:other film|2021'], ['other']);
  });

  test('buildPacked attaches yearless orphan to unique identity alias', () {
    final withId = vod('id-row', title: 'SampleTitle', tmdbId: 99, year: 2022);
    final orphan = vod('orphan', title: 'FR| SampleTitle');

    final packed = VodVariantIndex.buildPacked([
      VodVariantIndex.packRow(withId),
      VodVariantIndex.packRow(orphan),
    ]);
    final families = packed['families'] as Map;
    final members = families['tmdb:movie:99'] as List;
    expect(members, containsAll(['id-row', 'orphan']));
  });

  test(
    'buildPacked groups language rows that only embed TMDB in the title',
    () {
      final us = vod('us', title: 'US| SampleTitle {tmdb-42}');
      final fr = vod('fr', title: 'FR| Les SampleTitle {tmdb-42}');
      final packed = VodVariantIndex.buildPacked([
        VodVariantIndex.packRow(us),
        VodVariantIndex.packRow(fr),
      ]);
      final family = (packed['families'] as Map)['tmdb:movie:42'] as List;
      expect(family, containsAll(['us', 'fr']));
    },
  );

  test(
    'buildPacked tie-break matches compareDisplayTitle sourceId then id',
    () {
      final a = vod(
        'b-id',
        title: 'EN| Same Film',
        sourceId: 'src-a',
        tmdbId: 7,
        year: 2020,
      );
      final b = vod(
        'a-id',
        title: 'FR| Same Film',
        sourceId: 'src-b',
        tmdbId: 7,
        year: 2020,
      );

      final packed = VodVariantIndex.buildPacked([
        VodVariantIndex.packRow(a),
        VodVariantIndex.packRow(b),
      ]);
      final family = (packed['families'] as Map)['tmdb:movie:7'] as List;
      // Same rank → display title tie → sourceId asc (src-a before src-b).
      expect(family, ['b-id', 'a-id']);
    },
  );

  test('buildPacked ranks track-only captions like sync path', () {
    final withSubs = MediaItem(
      id: 'with-subs',
      title: 'Caption Film',
      playUrl: 'https://example/with-subs',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'xt',
      year: 2021,
      tmdbId: 11,
      subtitles: const [ExternalSubtitle(url: '', language: 'en')],
    );
    final bare = vod('bare', title: 'Caption Film', tmdbId: 11, year: 2021);

    final packed = VodVariantIndex.buildPacked([
      VodVariantIndex.packRow(bare),
      VodVariantIndex.packRow(withSubs),
    ]);
    final family = (packed['families'] as Map)['tmdb:movie:11'] as List;
    // Track-only captions earn the +4 caption score → ordered first.
    expect(family.first, 'with-subs');
  });

  test(
    'buildChunksInIsolate matches packed output across input batches',
    () async {
      final rows = [
        for (var i = 0; i < 450; i++)
          VodVariantIndex.packRow(
            vod(
              'id$i',
              title: 'Title $i',
              year: 2000 + (i % 20),
              tmdbId: i + 1,
            ),
          ),
      ];
      final packed = VodVariantIndex.buildPacked(rows);
      final isolated = await VodVariantIndex.buildChunksInIsolate([
        rows.sublist(0, 225),
        rows.sublist(225),
      ]);
      expect(isolated['families'], packed['families']);
      expect(isolated['canonical'], packed['canonical']);
    },
  );

  test(
    'buildChunksInIsolate joins a family split across input batches',
    () async {
      final first = VodVariantIndex.packRow(
        vod('first', title: 'EN| Shared Film', tmdbId: 42, year: 2022),
      );
      final second = VodVariantIndex.packRow(
        vod('second', title: 'FR| Shared Film', tmdbId: 42, year: 2022),
      );
      final padding = [
        for (var i = 0; i < 400; i++)
          VodVariantIndex.packRow(
            vod('padding-$i', title: 'Other $i', tmdbId: 1000 + i),
          ),
      ];

      final isolated = await VodVariantIndex.buildChunksInIsolate([
        [first, ...padding.take(200)],
        [...padding.skip(200), second],
      ]);
      expect(
        (isolated['families'] as Map)['tmdb:movie:42'],
        containsAll(['first', 'second']),
      );
    },
  );
}
