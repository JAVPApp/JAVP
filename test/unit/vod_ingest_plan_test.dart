import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/vod_ingest_plan.dart';
import 'package:javp/services/iptv/vod_variant_index.dart';

void main() {
  MediaItem vod({
    required String id,
    required String title,
    String sourceId = 'src',
    int? tmdbId,
    int? year,
  }) {
    return MediaItem(
      id: id,
      title: title,
      playUrl: 'http://x/$id',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvM3u,
      sourceId: sourceId,
      streamId: id,
      group: 'Movies',
      tmdbId: tmdbId,
      year: year,
    );
  }

  test('buildVodIngestPlan packs SQL rows and Versions ids', () {
    final en = vod(id: 'en', title: 'EN| SampleTitle', tmdbId: 42, year: 2022);
    final fr = vod(id: 'fr', title: 'FR| SampleTitle', tmdbId: 42, year: 2022);
    final other = vod(id: 'other', title: 'Other Film', year: 1999);

    final plan = buildVodIngestPlan([en, fr, other], fallbackSourceId: 'src');
    expect(plan.vodCount, 3);
    expect(plan.rows.map((r) => r['id']), containsAll(['en', 'fr', 'other']));
    expect(plan.rows.first['source_id'], 'src');
    expect(plan.rows.first['kind'], 'vod');
    expect(plan.rows.any((r) => r['group_name'] == 'Movies'), isTrue);

    final family = plan.families.values.firstWhere(
      (ids) => ids.contains('en') && ids.contains('fr'),
    );
    expect(family, containsAll(['en', 'fr']));
    expect(family, isNot(contains('other')));
  });

  test('splitAndPackVodItems keeps live leftovers', () {
    final movie = vod(id: 'm', title: 'Film');
    final live = MediaItem(
      id: 'live-1',
      title: 'News',
      playUrl: 'http://x/live',
      kind: MediaKind.live,
      origin: MediaOrigin.customCatalog,
      sourceId: 'src',
    );
    final split = splitAndPackVodItems([movie, live], fallbackSourceId: 'src');
    expect(split.leftovers.single.id, 'live-1');
    expect(split.vod.rows.single['id'], 'm');
  });

  test('stampEmptyVodGroupNames fills blank groups and keeps existing', () {
    final rows = [
      {'id': 'a', 'group_name': null},
      {'id': 'b', 'group_name': ''},
      {'id': 'c', 'group_name': '  '},
      {'id': 'd', 'group_name': 'Action'},
    ];
    stampEmptyVodGroupNames(rows, fallbackGroup: 'My JSON');
    expect(rows[0]['group_name'], 'My JSON');
    expect(rows[1]['group_name'], 'My JSON');
    expect(rows[2]['group_name'], 'My JSON');
    expect(rows[3]['group_name'], 'Action');
  });

  test('buildVodIngestPlan skips live rows', () {
    final live = MediaItem(
      id: 'live-1',
      title: 'News',
      playUrl: 'http://x/live',
      kind: MediaKind.live,
      origin: MediaOrigin.iptvM3u,
      sourceId: 'src',
    );
    final plan = buildVodIngestPlan([live], fallbackSourceId: 'src');
    expect(plan.rows, isEmpty);
    expect(plan.families, isEmpty);
  });

  test(
    'isolated assembly keeps SQL rows and indexes variant batches',
    () async {
      final sqlRows = <Map<String, Object?>>[
        {'id': 'en'},
        {'id': 'fr'},
      ];
      final en = VodVariantIndex.packRow(
        vod(id: 'en', title: 'EN| SampleTitle', tmdbId: 42, year: 2022),
      );
      final fr = VodVariantIndex.packRow(
        vod(id: 'fr', title: 'FR| SampleTitle', tmdbId: 42, year: 2022),
      );
      final padding = [
        for (var i = 0; i < 400; i++)
          VodVariantIndex.packRow(
            vod(id: 'padding-$i', title: 'Other $i', tmdbId: 1000 + i),
          ),
      ];

      final plan = await vodIngestPlanFromVariantRowChunksInIsolate(
        rows: sqlRows,
        variantRowChunks: [
          [en, ...padding.take(200)],
          [...padding.skip(200), fr],
        ],
      );

      expect(identical(plan.rows, sqlRows), isTrue);
      expect(plan.families['tmdb:movie:42'], containsAll(<String>['en', 'fr']));
    },
  );
}
