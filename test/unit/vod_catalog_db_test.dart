import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/storage/vod_catalog_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  MediaItem vod({
    required String id,
    required String title,
    required String group,
    MediaKind kind = MediaKind.vod,
    String sourceId = 'src',
  }) {
    return MediaItem(
      id: id,
      title: title,
      playUrl: kind == MediaKind.series ? '' : 'http://x/$id',
      kind: kind,
      origin: MediaOrigin.iptvXtream,
      sourceId: sourceId,
      streamId: id,
      group: group,
    );
  }

  Future<VodCatalogDb> openTempDb() async {
    final file = File(
      '${Directory.systemTemp.path}/javp_vod_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final db = VodCatalogDb(debugDatabasePath: file.path);
    addTearDown(() async {
      await db.close();
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    });
    return db;
  }

  test('replaceSourceVod then upsertSourceGroupVod isolates groups', () async {
    final db = await openTempDb();

    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: 'm1', title: 'Alpha', group: 'Action'),
        vod(id: 'm2', title: 'Beta', group: 'Comedy'),
        vod(id: 's1', title: 'Show', group: 'Drama', kind: MediaKind.series),
      ],
    );
    expect(await db.countItems(sourceId: 'src'), 3);
    expect(await db.countInGroup(sourceId: 'src', groupName: 'Action'), 1);

    await db.upsertSourceGroupVod(
      sourceId: 'src',
      groupName: 'Action',
      items: [
        vod(id: 'm3', title: 'Gamma', group: 'Action'),
        vod(id: 'm4', title: 'Delta', group: 'Action'),
      ],
    );

    expect(await db.countInGroup(sourceId: 'src', groupName: 'Action'), 2);
    expect(await db.countInGroup(sourceId: 'src', groupName: 'Comedy'), 1);
    expect(await db.countItems(sourceId: 'src'), 4);

    final all = await db.itemsForSource('src');
    final ids = all.map((c) => c.id).toSet();
    expect(ids, containsAll(['m3', 'm4', 'm2', 's1']));
    expect(ids.contains('m1'), isFalse);
  });

  test('fillEmptyGroups stamps source name onto ungrouped VOD', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'byo',
      items: [
        vod(id: 'm1', title: 'Alpha', group: '', sourceId: 'byo'),
        vod(id: 'm2', title: 'Beta', group: 'Action', sourceId: 'byo'),
        vod(
          id: 's1',
          title: 'Show',
          group: '',
          kind: MediaKind.series,
          sourceId: 'byo',
        ),
      ],
    );
    expect(await db.listGroupNames(sourceId: 'byo'), ['Action']);

    final changed = await db.fillEmptyGroups(
      namesBySourceId: const {'byo': 'JSON shelf'},
    );
    expect(changed, 2);
    final groups = await db.listGroupNames(sourceId: 'byo');
    expect(groups, containsAll(['Action', 'JSON shelf']));
    expect(await db.listGroupsBySource(series: false), {
      'byo': {'Action', 'JSON shelf'},
    });
    expect(await db.listGroupsBySource(series: true), {
      'byo': {'JSON shelf'},
    });
  });

  test(
    'replaceSourceVodPacked writes maps and empty clears the source',
    () async {
      final db = await openTempDb();
      final packed = [
        VodCatalogDb.packItem(vod(id: 'm1', title: 'Alpha', group: 'Action')),
        VodCatalogDb.packItem(vod(id: 'm2', title: 'Beta', group: 'Comedy')),
      ];
      await db.replaceSourceVodPacked(sourceId: 'src', rows: packed);
      expect(await db.countItems(sourceId: 'src'), 2);
      expect((await db.itemsForSource('src')).map((m) => m.title), [
        'Alpha',
        'Beta',
      ]);

      await db.replaceSourceVodPacked(sourceId: 'src', rows: const []);
      expect(await db.countItems(sourceId: 'src'), 0);
    },
  );

  test(
    'progressive replace publishes rows before completion and finalizes stale rows',
    () async {
      final db = await openTempDb();
      await db.replaceSourceVod(
        sourceId: 'src',
        items: [
          vod(id: 'stale', title: 'Stale', group: 'G'),
          vod(id: 'keep', title: 'Old Keep', group: 'G'),
        ],
      );
      final rows = [
        for (var i = 0; i < 850; i++)
          VodCatalogDb.packItem(
            vod(
              id: i == 0 ? 'keep' : 'new-$i',
              title: i == 0 ? 'New Keep' : 'Title $i',
              group: 'G',
            ),
          ),
      ];
      var intermediateCallbacks = 0;

      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) async {
          if (progress.finalized) return;
          intermediateCallbacks++;
          expect(progress.committed, lessThanOrEqualTo(progress.total));
          final visible = await db.countItems(sourceId: 'src');
          expect(visible, greaterThanOrEqualTo(progress.committed));
          // The previous generation remains intact until the final delete.
          expect(await db.idsForSource('src'), contains('stale'));
        },
      );

      expect(intermediateCallbacks, 3);
      expect(await db.countItems(sourceId: 'src'), 850);
      expect(await db.idsForSource('src'), isNot(contains('stale')));
      expect(
        (await db.itemsForSource(
          'src',
        )).firstWhere((m) => m.id == 'keep').title,
        'New Keep',
      );
    },
  );

  test('streaming replace commits 400-row chunks without a full-list copy', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [vod(id: 'stale', title: 'Stale', group: 'G')],
    );
    final rows = [
      for (var i = 0; i < 850; i++)
        VodCatalogDb.packItem(
          vod(id: 'new-$i', title: 'Title $i', group: 'G'),
        ),
    ];
    var mid = 0;
    final session = await db.beginStreamingReplace(
      sourceId: 'src',
      onProgress: (progress) {
        if (!progress.finalized) mid++;
      },
    );
    for (var i = 0; i < rows.length; i += 400) {
      final end = i + 400 > rows.length ? rows.length : i + 400;
      await session.addChunk(rows.sublist(i, end), total: rows.length);
    }
    await session.finish(fingerprint: 'stream-fp', total: rows.length);
    expect(mid, 3);
    expect(await db.countItems(sourceId: 'src'), 850);
    expect(await db.idsForSource('src'), isNot(contains('stale')));

    final again = await db.beginStreamingReplace(sourceId: 'src');
    expect(await again.skipIfFingerprint('stream-fp'), isTrue);
    expect(await db.countItems(sourceId: 'src'), 850);
  });

  test(
    'category fetch committed during replacement survives finalize',
    () async {
      final db = await openTempDb();
      await db.replaceSourceVod(
        sourceId: 'src',
        items: [vod(id: 'old', title: 'Old', group: 'Old group')],
      );
      final rows = [
        for (var i = 0; i < 850; i++)
          VodCatalogDb.packItem(
            vod(id: 'bulk-$i', title: 'Bulk $i', group: 'Bulk'),
          ),
      ];
      var categoryPublished = false;

      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) async {
          if (categoryPublished || progress.finalized) return;
          categoryPublished = true;
          await db.upsertSourceGroupVod(
            sourceId: 'src',
            groupName: 'Visible shelf',
            items: [
              vod(
                id: 'demand-row',
                title: 'Demand row',
                group: 'Visible shelf',
              ),
            ],
          );
        },
      );

      expect(categoryPublished, isTrue);
      expect(await db.idsForSource('src'), contains('demand-row'));
      expect(await db.idsForSource('src'), isNot(contains('old')));
    },
  );

  test(
    'same-group demand fetch during replace keeps earlier bulk rows',
    () async {
      final db = await openTempDb();
      final rows = [
        for (var i = 0; i < 850; i++)
          VodCatalogDb.packItem(
            vod(id: 'bulk-$i', title: 'Bulk $i', group: 'Bulk'),
          ),
      ];
      var categoryPublished = false;

      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) async {
          if (categoryPublished || progress.finalized) return;
          categoryPublished = true;
          await db.upsertSourceGroupVod(
            sourceId: 'src',
            groupName: 'Bulk',
            items: [
              vod(id: 'demand-a', title: 'Demand A', group: 'Bulk'),
              vod(id: 'demand-b', title: 'Demand B', group: 'Bulk'),
            ],
          );
        },
      );

      expect(categoryPublished, isTrue);
      final ids = await db.idsForSource('src');
      expect(ids, containsAll(['demand-a', 'demand-b', 'bulk-0', 'bulk-399']));
      expect(ids.length, 852);
    },
  );

  test('enrich upsert during replace survives finalize', () async {
    final db = await openTempDb();
    final rows = [
      for (var i = 0; i < 850; i++)
        VodCatalogDb.packItem(vod(id: 'bulk-$i', title: 'Bulk $i', group: 'G')),
    ];
    var enriched = false;

    await db.replaceSourceVodPacked(
      sourceId: 'src',
      rows: rows,
      onProgress: (progress) async {
        if (enriched || progress.finalized) return;
        enriched = true;
        await db.upsertItemsPacked([
          VodCatalogDb.packItem(
            vod(id: 'bulk-0', title: 'Enriched', group: 'G'),
          ),
        ]);
      },
    );

    expect(enriched, isTrue);
    final items = await db.itemsForSource('src');
    final byId = {for (final item in items) item.id: item};
    expect(byId.keys, contains('bulk-0'));
    expect(byId['bulk-0']!.title, 'Enriched');
  });

  test('page and search queries interleave with progressive ingest', () async {
    final db = await openTempDb();
    final rows = [
      for (var i = 0; i < 900; i++)
        VodCatalogDb.packItem(
          vod(id: 'item-$i', title: 'Needle $i', group: 'G'),
        ),
    ];
    var checkedDuringIngest = false;

    await db.replaceSourceVodPacked(
      sourceId: 'src',
      rows: rows,
      onProgress: (progress) async {
        if (checkedDuringIngest || progress.finalized) return;
        checkedDuringIngest = true;
        final page = await db
            .pageItems(sourceId: 'src', limit: 20)
            .timeout(const Duration(seconds: 2));
        final hits = await db
            .searchFts('needle', sourceId: 'src', limit: 20)
            .timeout(const Duration(seconds: 2));
        expect(page, isNotEmpty);
        expect(hits, isNotEmpty);
        expect(progress.committed, lessThan(progress.total));
      },
    );

    expect(checkedDuringIngest, isTrue);
  });

  test('failed progressive replace preserves stale rows', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [vod(id: 'stale', title: 'Stale', group: 'G')],
    );
    final rows = [
      for (var i = 0; i < 500; i++)
        VodCatalogDb.packItem(vod(id: 'new-$i', title: 'New $i', group: 'G')),
    ];

    await expectLater(
      db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) {
          if (!progress.finalized) throw StateError('cancel ingest');
        },
      ),
      throwsStateError,
    );

    final ids = await db.idsForSource('src');
    expect(ids, contains('stale'));
    expect(ids, isNot(contains('new-0')));
  });

  test(
    'reads hide stale same-group rows once a newer generation exists',
    () async {
      final db = await openTempDb();
      await db.replaceSourceVod(
        sourceId: 'src',
        items: [
          vod(id: 'old-action', title: 'Old Action', group: 'Action'),
          vod(id: 'old-comedy', title: 'Old Comedy', group: 'Comedy'),
        ],
      );
      final rows = [
        for (var i = 0; i < 850; i++)
          VodCatalogDb.packItem(
            vod(id: 'action-$i', title: 'Needle $i', group: 'Action'),
          ),
      ];
      var checkedDuringIngest = false;

      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) async {
          if (checkedDuringIngest || progress.finalized) return;
          checkedDuringIngest = true;
          final action = await db.pageItems(
            sourceId: 'src',
            groupName: 'Action',
            limit: 20,
          );
          final comedy = await db.pageItems(
            sourceId: 'src',
            groupName: 'Comedy',
            limit: 20,
          );
          expect(action.map((m) => m.id), isNot(contains('old-action')));
          expect(action.map((m) => m.id), contains('action-0'));
          expect(comedy.map((m) => m.id), ['old-comedy']);
          expect(
            await db.countInGroup(sourceId: 'src', groupName: 'Comedy'),
            1,
          );
          // Unscoped COUNT / GROUP BY must not apply per-row latest-gen
          // (that query hangs on 200k-row phone catalogs during db enable).
          // First progressive page is 400 new Action rows + 2 stale rows.
          expect(await db.countItems(sourceId: 'src'), 402);
          final groups = await db.listGroupsBySource(series: false);
          expect(groups['src'], containsAll(['Action', 'Comedy']));
          final hits = await db.searchFts('needle', sourceId: 'src', limit: 20);
          expect(hits, isNotEmpty);
          expect(hits.map((m) => m.id), isNot(contains('old-action')));
        },
      );

      expect(checkedDuringIngest, isTrue);
      final finalIds = (await db.pageItems(
        sourceId: 'src',
        limit: 20,
      )).map((m) => m.id).toSet();
      expect(finalIds, isNot(contains('old-comedy')));
      expect(finalIds, isNot(contains('old-action')));
    },
  );

  test('unscoped count and group list stay cheap on a large catalog', () async {
    final db = await openTempDb();
    final rows = [
      for (var i = 0; i < 8000; i++)
        VodCatalogDb.packItem(
          vod(id: 't-$i', title: 'Title $i', group: 'G${i % 20}'),
        ),
    ];
    await db.replaceSourceVodPacked(sourceId: 'src', rows: rows);
    final sw = Stopwatch()..start();
    expect(await db.countItems(sourceId: 'src'), 8000);
    final groups = await db.listGroupsBySource(series: false);
    sw.stop();
    expect(groups['src']?.length, 20);
    expect(
      sw.elapsedMilliseconds,
      lessThan(1500),
      reason:
          'unscoped COUNT/GROUP BY must not use a correlated latest-gen '
          'subquery (phone enable hung on ~200k rows)',
    );
  });

  test(
    'replaceSourceVodPacked skips a second write when content matches',
    () async {
      final db = await openTempDb();
      final rows = [
        VodCatalogDb.packItem(vod(id: 'm1', title: 'Alpha', group: 'G')),
        VodCatalogDb.packItem(vod(id: 'm2', title: 'Beta', group: 'G')),
      ];
      var midWrites = 0;
      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) {
          if (!progress.finalized) midWrites++;
        },
      );
      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: rows,
        onProgress: (progress) {
          if (!progress.finalized) midWrites++;
        },
      );
      expect(midWrites, 1);
      expect(await db.countItems(sourceId: 'src'), 2);
      expect(
        VodCatalogDb.vodContentFingerprint(rows),
        VodCatalogDb.vodContentFingerprint(rows),
      );
      expect(
        await VodCatalogDb.vodContentFingerprintAsync(rows),
        VodCatalogDb.vodContentFingerprint(rows),
      );
    },
  );

  test('large VOD fingerprint async matches the compact hash', () async {
    final rows = [
      for (var i = 0; i < 500; i++)
        VodCatalogDb.packItem(vod(id: 'm$i', title: 'Title $i', group: 'G')),
    ];
    expect(
      await VodCatalogDb.vodContentFingerprintAsync(rows),
      VodCatalogDb.vodContentFingerprint(rows),
    );
  });

  test(
    'upsertItemsPacked adds without wiping and idsForSource lists them',
    () async {
      final db = await openTempDb();
      await db.replaceSourceVodPacked(
        sourceId: 'src',
        rows: [
          VodCatalogDb.packItem(vod(id: 'm1', title: 'Alpha', group: 'G')),
        ],
      );
      await db.upsertItemsPacked([
        VodCatalogDb.packItem(vod(id: 'm2', title: 'Beta', group: 'G')),
      ]);
      expect(await db.countItems(sourceId: 'src'), 2);
      expect(await db.idsForSource('src'), {'m1', 'm2'});
    },
  );

  test('pageItems filters by series and orders by title', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: 'b', title: 'Bravo', group: 'G'),
        vod(id: 'a', title: 'Alpha', group: 'G'),
        vod(id: 's', title: 'Series A', group: 'G', kind: MediaKind.series),
      ],
    );

    final movies = await db.pageItems(series: false, limit: 10);
    expect(movies.map((m) => m.id).toList(), ['a', 'b']);

    final series = await db.pageItems(series: true, limit: 10);
    expect(series.map((m) => m.id).toList(), ['s']);
  });

  test(
    'pageHomePreviewItems quotas each source so a tiny catalog cannot monopolize',
    () async {
      final db = await openTempDb();
      // Insert small catalog first (low rowids), then a "fat" Xtream-like source.
      await db.replaceSourceVod(
        sourceId: 'byo',
        items: [
          for (var i = 0; i < 20; i++)
            vod(id: 'byo-$i', title: 'BYO $i', group: 'Films', sourceId: 'byo'),
        ],
      );
      await db.replaceSourceVod(
        sourceId: 'xtream',
        items: [
          for (var i = 0; i < 40; i++)
            vod(
              id: 'xt-$i',
              title: 'Xtream $i',
              group: 'Movies',
              sourceId: 'xtream',
            ),
        ],
      );

      final unscoped = await db.pageItems(
        series: false,
        allowedSourceIds: const ['byo', 'xtream'],
        order: VodCatalogOrder.rowid,
        limit: 16,
      );
      expect(
        unscoped.every((m) => m.sourceId == 'byo'),
        isTrue,
        reason: 'unscoped rowid still prefers the older tiny catalog',
      );

      final mixed = await db.pageHomePreviewItems(
        series: false,
        allowedSourceIds: const ['byo', 'xtream'],
        limit: 16,
      );
      final bySource = <String, int>{};
      for (final m in mixed) {
        bySource[m.sourceId!] = (bySource[m.sourceId!] ?? 0) + 1;
      }
      expect(bySource['byo'], greaterThan(0));
      expect(bySource['xtream'], greaterThan(0));
      expect(mixed.length, 16);
    },
  );

  test('pageItems can order by rating then year', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(
          id: 'low',
          title: 'Low',
          group: 'G',
        ).copyWith(rating: 4, year: 2024),
        vod(
          id: 'high',
          title: 'High',
          group: 'G',
        ).copyWith(rating: 9, year: 2010),
        vod(
          id: 'mid',
          title: 'Mid',
          group: 'G',
        ).copyWith(rating: 7, year: 2020),
        vod(id: 'none', title: 'None', group: 'G'),
      ],
    );

    final ranked = await db.pageItems(
      series: false,
      order: VodCatalogOrder.rating,
      limit: 10,
    );
    expect(ranked.map((m) => m.id).toList(), ['high', 'mid', 'low', 'none']);

    final newest = await db.pageItems(
      series: false,
      order: VodCatalogOrder.year,
      limit: 10,
    );
    expect(newest.first.id, 'low');
    expect(newest.last.id, 'none');
  });

  test('pageItems can order by popularity then rating', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: 'cool', title: 'Cool', group: 'G').copyWith(popularity: 10),
        vod(id: 'hot', title: 'Hot', group: 'G').copyWith(popularity: 90),
        vod(id: 'none', title: 'None', group: 'G').copyWith(rating: 9),
      ],
    );

    final ranked = await db.pageItems(
      series: false,
      order: VodCatalogOrder.popularity,
      limit: 10,
    );
    expect(ranked.map((m) => m.id).toList(), ['hot', 'cool', 'none']);
    expect(ranked.first.popularity, 90);
  });

  test('searchFts finds titles', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: '1', title: 'Sample Sci-Fi Long', group: 'Sci-Fi'),
        vod(id: '2', title: 'Sample Film', group: 'Sci-Fi'),
        vod(id: '3', title: 'Sample Sci-Fi Alt', group: 'Sci-Fi'),
      ],
    );

    final hits = await db.searchFts('sci-fi', limit: 10);
    expect(hits.map((m) => m.id).toSet(), {'1', '3'});
  });

  test('pruneUnknownSources no-ops without a full DELETE when clean', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'keep',
      items: [vod(id: '1', title: 'Keep', group: 'G', sourceId: 'keep')],
    );
    expect(await db.pruneUnknownSources({'keep'}), 0);
    expect(await db.countItems(), 1);

    await db.replaceSourceVod(
      sourceId: 'gone',
      items: [vod(id: '2', title: 'Gone', group: 'G', sourceId: 'gone')],
    );
    expect(await db.pruneUnknownSources({'keep'}), 1);
    expect(await db.countItems(), 1);
    expect((await db.itemsForSource('keep')).single.id, '1');
  });

  test('searchFts folds diacritics in titles', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: 'cafe', title: 'Café Network Movie', group: 'Sports'),
        vod(id: 'other', title: 'Sample Film', group: 'Sci-Fi'),
      ],
    );

    final hits = await db.searchFts('cafe', limit: 10);
    expect(hits.map((m) => m.id), ['cafe']);
  });

  test(
    'reindexSortTitles marks logic current and keeps years searchable',
    () async {
      final db = await openTempDb();
      await db.replaceSourceVod(
        sourceId: 'src',
        items: [vod(id: '1', title: 'Always a Catch - 2021', group: 'Drama')],
      );

      expect(await db.needsSortTitleReindex, isTrue);
      await db.reindexSortTitles();
      expect(await db.needsSortTitleReindex, isFalse);

      final hits = await db.searchFts('2021', limit: 10);
      expect(hits.map((m) => m.id), ['1']);
    },
  );

  test('searchFts ranks exact title before a contains hit', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: 'long', title: 'Sample Sci-Fi Long', group: 'Sci-Fi'),
        vod(id: 'exact', title: 'Sample Sci-Fi', group: 'Sci-Fi'),
      ],
    );

    final ranked = await db.searchFts('sample sci-fi', limit: 10);
    expect(ranked.first.id, 'exact');
  });

  test('searchLike fallback finds titles when FTS is disabled', () async {
    final file = File(
      '${Directory.systemTemp.path}/javp_vod_like_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final db = VodCatalogDb(
      debugDatabasePath: file.path,
      debugForceDisableFts: true,
    );
    addTearDown(() async {
      await db.close();
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    });

    await db.ensureOpen();
    expect(db.ftsEnabled, isFalse);

    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: '1', title: 'Sample Sci-Fi Long', group: 'Sci-Fi'),
        vod(id: '2', title: 'Sample Film', group: 'Sci-Fi'),
        vod(id: '3', title: 'Sample Sci-Fi Alt', group: 'Sci-Fi'),
      ],
    );

    final hits = await db.searchFts('sci-fi', limit: 10);
    expect(hits.map((m) => m.id).toSet(), {'1', '3'});
  });

  test('open succeeds and pages without FTS', () async {
    final file = File(
      '${Directory.systemTemp.path}/javp_vod_nofts_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final db = VodCatalogDb(
      debugDatabasePath: file.path,
      debugForceDisableFts: true,
    );
    addTearDown(() async {
      await db.close();
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    });

    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        vod(id: 'a', title: 'Alpha', group: 'G'),
        vod(id: 'b', title: 'Beta', group: 'G'),
      ],
    );
    expect(await db.countItems(sourceId: 'src'), 2);
    expect((await db.pageItems(limit: 10)).map((m) => m.id), ['a', 'b']);
  });

  test(
    'soft migration adds sync generation to an existing v1 database',
    () async {
      final file = File(
        '${Directory.systemTemp.path}/javp_vod_migrate_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final raw = await databaseFactory.openDatabase(file.path);
      await raw.execute('''
CREATE TABLE vod_items (
  id TEXT PRIMARY KEY NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  origin TEXT NOT NULL,
  title TEXT NOT NULL,
  sort_title TEXT NOT NULL,
  play_url TEXT NOT NULL,
  subtitle TEXT,
  group_name TEXT,
  stream_id TEXT,
  thumbnail_url TEXT,
  poster_url TEXT,
  backdrop_url TEXT,
  year INTEGER,
  rating REAL,
  popularity REAL,
  tmdb_id INTEGER,
  imdb_id TEXT,
  anilist_id INTEGER,
  tvdb_id INTEGER,
  details_id TEXT,
  series_id TEXT,
  server_item_id TEXT,
  is_adult INTEGER NOT NULL DEFAULT 0,
  extras_json TEXT
)''');
      await raw.execute('''
CREATE TABLE vod_meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
)''');
      await raw.execute('PRAGMA user_version = 1');
      await raw.close();

      final db = VodCatalogDb(
        debugDatabasePath: file.path,
        debugForceDisableFts: true,
      );
      addTearDown(() async {
        await db.close();
        if (file.existsSync()) file.deleteSync();
      });
      await db.replaceSourceVod(
        sourceId: 'src',
        items: [vod(id: 'migrated', title: 'Migrated', group: 'G')],
      );
      expect(await db.idsForSource('src'), {'migrated'});

      await db.close();
      final migrated = await databaseFactory.openDatabase(file.path);
      final columns = await migrated.rawQuery('PRAGMA table_info(vod_items)');
      final indexes = await migrated.rawQuery('PRAGMA index_list(vod_items)');
      await migrated.close();
      expect(columns.map((row) => row['name']), contains('sync_generation'));
      expect(
        indexes.map((row) => row['name']),
        contains('idx_vod_source_generation'),
      );
    },
  );

  test('itemsByTmdbIds returns matching rows', () async {
    final db = await openTempDb();
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [
        MediaItem(
          id: 'm1',
          title: 'One',
          playUrl: 'http://x/1',
          kind: MediaKind.vod,
          origin: MediaOrigin.iptvXtream,
          sourceId: 'src',
          streamId: 'm1',
          group: 'Action',
          tmdbId: 101,
        ),
        MediaItem(
          id: 'm2',
          title: 'Two',
          playUrl: 'http://x/2',
          kind: MediaKind.vod,
          origin: MediaOrigin.iptvXtream,
          sourceId: 'src',
          streamId: 'm2',
          group: 'Action',
          tmdbId: 202,
        ),
        MediaItem(
          id: 's1',
          title: 'Show',
          playUrl: '',
          kind: MediaKind.series,
          origin: MediaOrigin.iptvXtream,
          sourceId: 'src',
          streamId: 's1',
          group: 'Drama',
          tmdbId: 101,
        ),
      ],
    );

    final hits = await db.itemsByTmdbIds([101, 999]);
    expect(hits.map((m) => m.id).toSet(), {'m1', 's1'});

    final moviesOnly = await db.itemsByTmdbIds([101], series: false);
    expect(moviesOnly.map((m) => m.id), ['m1']);
  });

  test('disabled FTS drops leftover triggers so deletes still work', () async {
    final file = File(
      '${Directory.systemTemp.path}/javp_vod_trig_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final seeded = VodCatalogDb(debugDatabasePath: file.path);
    addTearDown(() async {
      await seeded.close();
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    });
    await seeded.replaceSourceVod(
      sourceId: 'src',
      items: [vod(id: '1', title: 'One', group: 'G')],
    );
    await seeded.close();

    final raw = await databaseFactory.openDatabase(file.path);
    await raw.execute('DROP TRIGGER IF EXISTS vod_items_ai');
    await raw.execute('DROP TRIGGER IF EXISTS vod_items_ad');
    await raw.execute('DROP TRIGGER IF EXISTS vod_items_au');
    await raw.execute('''
CREATE TRIGGER vod_items_ad AFTER DELETE ON vod_items BEGIN
  SELECT RAISE(ABORT, 'fts5 missing');
END''');
    await raw.close();

    final db = VodCatalogDb(
      debugDatabasePath: file.path,
      debugForceDisableFts: true,
    );
    addTearDown(db.close);
    await db.replaceSourceVod(
      sourceId: 'src',
      items: [vod(id: '2', title: 'Two', group: 'G')],
    );
    expect(await db.countItems(sourceId: 'src'), 1);
    expect((await db.itemsForSource('src')).single.id, '2');
  });

  test(
    'listGroupsBySource splits movie and series groups per source',
    () async {
      final db = await openTempDb();
      await db.replaceSourceVod(
        sourceId: 'alpha',
        items: [
          vod(
            id: 'm1',
            title: 'Alpha Film',
            group: 'Action',
            sourceId: 'alpha',
          ),
          vod(
            id: 's1',
            title: 'Alpha Show',
            group: 'Drama',
            kind: MediaKind.series,
            sourceId: 'alpha',
          ),
        ],
      );
      await db.replaceSourceVod(
        sourceId: 'beta',
        items: [
          vod(id: 'm2', title: 'Beta Film', group: 'Comedy', sourceId: 'beta'),
        ],
      );

      final movies = await db.listGroupsBySource(series: false);
      expect(movies['alpha'], {'Action'});
      expect(movies['beta'], {'Comedy'});
      expect(movies['alpha']!.contains('Drama'), isFalse);

      final shows = await db.listGroupsBySource(series: true);
      expect(shows['alpha'], {'Drama'});
      expect(shows.containsKey('beta'), isFalse);
    },
  );
}
