import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/iptv/vod_grouping.dart';
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

  MediaItem vod(
    String id, {
    required String title,
    required String sourceId,
    int? tmdbId,
    int? year,
    MediaOrigin origin = MediaOrigin.iptvXtream,
  }) {
    return MediaItem(
      id: id,
      title: title,
      playUrl: 'https://example.com/$id.mp4',
      kind: MediaKind.vod,
      origin: origin,
      sourceId: sourceId,
      tmdbId: tmdbId,
      year: year,
    );
  }

  test('Films shelf collapses SampleTitle across sources and EN|/FR| rows', () {
    final jelly = vod(
      'jf-backrooms',
      title: 'SampleTitle',
      sourceId: 'jelly',
      tmdbId: 999001,
      year: 2022,
      origin: MediaOrigin.jellyfin,
    );
    final en = vod(
      'xt-en-backrooms',
      title: 'EN| SampleTitle',
      sourceId: 'xtream',
      year: 2022,
    );
    final fr = vod(
      'xt-fr-backrooms',
      title: 'FR| SampleTitle',
      sourceId: 'xtream',
      year: 2022,
    );
    final other = vod('other', title: 'Drive', sourceId: 'xtream');

    library.catalog = [jelly, en, fr, other];

    final shelf = library.collapseHomeShelfItems([
      en,
      jelly,
      fr,
      other,
      en,
    ], limit: 18);

    expect(shelf, hasLength(2));
    final backrooms = shelf.first;
    expect(library.vodVariantCountFor(backrooms), 3);
    expect(library.vodSourceCountFor(backrooms), 2);
    expect(library.shelfSourceLabelFor(backrooms), '2 sources');
    expect({jelly.id, en.id, fr.id}, contains(backrooms.id));
    expect(shelf.last.id, 'other');
    expect(library.shelfSourceLabelFor(other), isNot(contains('sources')));
  });

  test('name-only IPTV row joins TMDB-enriched sibling family', () {
    final enriched = vod(
      'tmdb-row',
      title: 'SampleTitle',
      sourceId: 'plex',
      tmdbId: 42,
      origin: MediaOrigin.plex,
    );
    final plain = vod(
      'iptv-row',
      title: 'EN| SampleTitle [MULTI-SUB]',
      sourceId: 'xtream',
    );
    library.catalog = [enriched, plain];

    expect(
      library.canonicalVodGroupKey(plain),
      library.canonicalVodGroupKey(enriched),
    );
    expect(
      library.vodVariantsFor(plain).map((m) => m.id),
      containsAll(['tmdb-row', 'iptv-row']),
    );
  });

  test('different Belle films do not collapse across years/tmdb', () {
    final belle2013 = vod(
      'belle-2013',
      title: 'Belle',
      sourceId: 'xtream',
      tmdbId: 84327,
      year: 2013,
    );
    final belle2021 = vod(
      'belle-2021',
      title: 'EN| Belle',
      sourceId: 'xtream',
      tmdbId: 795597,
      year: 2021,
    );
    final belleFr = vod(
      'belle-fr-other',
      title: 'FR| Belle',
      sourceId: 'xtream',
      year: 1995,
    );
    final belleYearless = vod(
      'belle-yearless',
      title: 'Belle',
      sourceId: 'jelly',
      origin: MediaOrigin.jellyfin,
    );
    library.catalog = [belle2013, belle2021, belleFr, belleYearless];

    expect(
      library.canonicalVodGroupKey(belle2013),
      isNot(library.canonicalVodGroupKey(belle2021)),
    );
    expect(
      library.canonicalVodGroupKey(belle2013),
      isNot(library.canonicalVodGroupKey(belleFr)),
    );
    // Yearless orphan must not join either TMDB family when several claim "Belle".
    expect(library.canonicalVodGroupKey(belleYearless), isNull);
    expect(library.vodVariantsFor(belle2013), hasLength(1));
    expect(library.vodVariantsFor(belle2021), hasLength(1));
    expect(library.vodVariantsFor(belleFr), hasLength(1));
    expect(library.vodSourceCountFor(belle2013), 1);

    final shelf = library.collapseHomeShelfItems([
      belle2013,
      belle2021,
      belleFr,
      belleYearless,
    ], limit: 18);
    expect(shelf, hasLength(4));
    expect(shelf.map((m) => m.id).toSet(), {
      belle2013.id,
      belle2021.id,
      belleFr.id,
      belleYearless.id,
    });
  });

  test(
    'same cleaned title and year with two TMDB families stay separate versions',
    () {
      final guestA = vod(
        'guest-a',
        title: 'The Guest',
        sourceId: 'catalog-a',
        tmdbId: 111001,
        year: 2014,
        origin: MediaOrigin.customCatalog,
      );
      final guestAFr = vod(
        'guest-a-fr',
        title: 'FR| The Guest',
        sourceId: 'xtream',
        tmdbId: 111001,
        year: 2014,
      );
      final guestB = vod(
        'guest-b',
        title: 'The Guest',
        sourceId: 'catalog-b',
        tmdbId: 222002,
        year: 2014,
        origin: MediaOrigin.customCatalog,
      );
      final guestBEn = vod(
        'guest-b-en',
        title: 'EN| The Guest',
        sourceId: 'jelly',
        tmdbId: 222002,
        year: 2014,
        origin: MediaOrigin.jellyfin,
      );
      final guestPlain = vod(
        'guest-plain',
        title: 'The Guest',
        sourceId: 'panel',
        year: 2014,
      );
      library.catalog = [guestA, guestAFr, guestB, guestBEn, guestPlain];

      expect(
        library.canonicalVodGroupKey(guestA),
        isNot(library.canonicalVodGroupKey(guestB)),
      );
      expect(library.vodVariantsFor(guestA).map((m) => m.id).toSet(), {
        guestA.id,
        guestAFr.id,
      });
      expect(library.vodVariantsFor(guestB).map((m) => m.id).toSet(), {
        guestB.id,
        guestBEn.id,
      });
      expect(library.vodVariantsFor(guestPlain).map((m) => m.id).toSet(), {
        guestPlain.id,
      });
    },
  );

  test('same Belle TMDB editions across lang/source do collapse', () {
    final en = vod(
      'belle-en',
      title: 'EN| Belle',
      sourceId: 'xtream',
      tmdbId: 84327,
      year: 2013,
    );
    final fr = vod(
      'belle-fr',
      title: 'FR| Belle',
      sourceId: 'xtream',
      tmdbId: 84327,
      year: 2013,
    );
    final jelly = vod(
      'belle-jf',
      title: 'Belle',
      sourceId: 'jelly',
      tmdbId: 84327,
      year: 2013,
      origin: MediaOrigin.jellyfin,
    );
    library.catalog = [en, fr, jelly];

    expect(library.canonicalVodGroupKey(en), library.canonicalVodGroupKey(fr));
    expect(
      library.canonicalVodGroupKey(en),
      library.canonicalVodGroupKey(jelly),
    );
    expect(library.vodVariantsFor(en), hasLength(3));
    expect(library.vodSourceCountFor(en), 2);
    expect(library.shelfSourceLabelFor(en), '2 sources');

    final shelf = library.collapseHomeShelfItems([en, fr, jelly], limit: 18);
    expect(shelf, hasLength(1));
    expect({en.id, fr.id, jelly.id}, contains(shelf.single.id));
  });

  test('title-embedded TMDB ids collapse language editions in search', () {
    final us = vod(
      'us-backrooms',
      title: 'US| SampleTitle {tmdb-999001}',
      sourceId: 'xtream',
    );
    final fr = vod(
      'fr-backrooms',
      title: 'FR| Les SampleTitle {tmdb-999001}',
      sourceId: 'xtream',
    );
    library.catalog = [us, fr];

    expect(library.canonicalVodGroupKey(us), library.canonicalVodGroupKey(fr));
    expect(library.vodVariantsFor(us), hasLength(2));
    final shelf = library.collapseHomeShelfItems([us, fr], limit: 18);
    expect(shelf, hasLength(1));
    final search = library.collapseSearchHits([us, fr], query: 'backrooms');
    expect(search, hasLength(1));
  });

  test('same title different year stay separate cards', () {
    final a = vod(
      'up-2009',
      title: 'EN| Sample Film',
      sourceId: 'xtream',
      year: 2009,
    );
    final b = vod(
      'up-2024',
      title: 'FR| Sample Film',
      sourceId: 'xtream',
      year: 2024,
    );
    library.catalog = [a, b];
    expect(
      library.canonicalVodGroupKey(a),
      isNot(library.canonicalVodGroupKey(b)),
    );
    expect(library.collapseHomeShelfItems([a, b], limit: 18), hasLength(2));
  });

  test('same yearless title from two sources without id stays separate', () {
    final xt = vod('xt-up', title: 'EN| Sample Film', sourceId: 'xtream');
    final jf = vod(
      'jf-up',
      title: 'Sample Film',
      sourceId: 'jelly',
      origin: MediaOrigin.jellyfin,
    );
    library.catalog = [xt, jf];
    expect(
      library.canonicalVodGroupKey(xt),
      isNot(library.canonicalVodGroupKey(jf)),
    );
    expect(library.vodVariantsFor(xt), hasLength(1));
    expect(library.vodVariantsFor(jf), hasLength(1));
    expect(library.collapseHomeShelfItems([xt, jf], limit: 18), hasLength(2));
  });

  test('same-source yearless EN|/FR| multi-word editions do collapse', () {
    final en = vod('en-up', title: 'EN| Sample Film', sourceId: 'xtream');
    final fr = vod('fr-up', title: 'FR| Sample Film', sourceId: 'xtream');
    library.catalog = [en, fr];
    expect(library.canonicalVodGroupKey(en), library.canonicalVodGroupKey(fr));
    expect(library.vodVariantsFor(en), hasLength(2));
    expect(library.collapseHomeShelfItems([en, fr], limit: 18), hasLength(1));
  });

  test('disabled source editions do not inflate versions or source count', () {
    final customcat = vod(
      'customcat-catch',
      title: 'Always a Catch!',
      sourceId: 'customcat',
      year: 2026,
      origin: MediaOrigin.customCatalog,
    );
    final xtEn = vod(
      'xt-en-catch',
      title: 'EN| Always a Catch!',
      sourceId: 'iptv',
      year: 2026,
    );
    library.sources = [
      IptvSource(
        id: 'customcat',
        name: 'Custom catalog',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2024),
        enabled: true,
      ),
      IptvSource(
        id: 'iptv',
        name: 'IPTV',
        type: IptvSourceType.xtream,
        createdAt: DateTime.utc(2024),
        enabled: false,
      ),
    ];
    library.catalog = [customcat, xtEn];

    expect(library.vodVariantsFor(customcat).map((m) => m.id), ['customcat-catch']);
    expect(library.vodSourceCountFor(customcat), 1);
    expect(library.shelfSourceLabelFor(customcat), isNot(contains('sources')));
  });

  test('series shell does not inherit movie siblings for source badge', () {
    final series = MediaItem(
      id: 'customcat-series',
      title: 'Always a Catch!',
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.customCatalog,
      sourceId: 'customcat',
      year: 2026,
    );
    final xtMovie = vod(
      'xt-en-catch',
      title: 'EN| Always a Catch!',
      sourceId: 'iptv',
      year: 2026,
    );
    library.sources = [
      IptvSource(
        id: 'customcat',
        name: 'Custom catalog',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2024),
      ),
      IptvSource(
        id: 'iptv',
        name: 'IPTV',
        type: IptvSourceType.xtream,
        createdAt: DateTime.utc(2024),
      ),
    ];
    library.catalog = [series, xtMovie];

    // Series detail has no cross-source Versions UI — badge must stay at 1.
    expect(library.vodVariantsFor(series), hasLength(1));
    expect(library.vodSourceCountFor(series), 1);
    expect(library.shelfSourceLabelFor(series), isNot(contains('sources')));
    // Movie family still lists only movie editions.
    expect(library.vodVariantsFor(xtMovie).map((m) => m.id), ['xt-en-catch']);
  });

  test('badge version count matches title-detail seed variants', () {
    final jelly = vod(
      'jf-backrooms',
      title: 'SampleTitle',
      sourceId: 'jelly',
      tmdbId: 999001,
      year: 2022,
      origin: MediaOrigin.jellyfin,
    );
    final en = vod(
      'xt-en-backrooms',
      title: 'EN| SampleTitle',
      sourceId: 'xtream',
      year: 2022,
    );
    final fr = vod(
      'xt-fr-backrooms',
      title: 'FR| SampleTitle',
      sourceId: 'xtream',
      year: 2022,
    );
    library.catalog = [jelly, en, fr];

    final shelf = library.collapseHomeShelfItems([en, jelly, fr], limit: 18);
    final tile = shelf.single;
    final badgeCount = library.vodVariantCountFor(tile);
    // Title detail anchors to the route seed (tile), not only the preferred play row.
    final detailVariants = library.vodVariantsFor(tile);
    expect(badgeCount, 3);
    expect(detailVariants, hasLength(badgeCount));
    expect(detailVariants.map((m) => m.id).toSet(), {jelly.id, en.id, fr.id});
  });

  test(
    'selecting a preferred VOD version keeps the full versions list',
    () async {
      final jelly = vod(
        'jf-backrooms',
        title: 'SampleTitle',
        sourceId: 'jelly',
        tmdbId: 999001,
        year: 2022,
        origin: MediaOrigin.jellyfin,
      );
      final en = vod(
        'xt-en-backrooms',
        title: 'EN| SampleTitle',
        sourceId: 'xtream',
        year: 2022,
      );
      final fr = vod(
        'xt-fr-backrooms',
        title: 'FR| SampleTitle',
        sourceId: 'xtream',
        year: 2022,
      );
      library.catalog = [jelly, en, fr];

      expect(library.vodVariantsFor(en), hasLength(3));

      await library.setPreferredVodVariant(fr);

      // Detail screen anchors variants to the opened title, then resolves play.
      final seed = en;
      final variants = library.vodVariantsFor(seed);
      final resolved = library.resolveVodVariant(seed);

      expect(variants, hasLength(3));
      expect(resolved.id, fr.id);
      expect(variants.map((m) => m.id), containsAll([jelly.id, en.id, fr.id]));
    },
  );

  test('preferring a catalog edition resolves from an IPTV seed', () async {
    final catalog = vod(
      'cat-1',
      title: 'SampleTitle',
      sourceId: 'cataloga',
      tmdbId: 999001,
      year: 2022,
      origin: MediaOrigin.customCatalog,
    );
    final en = vod(
      'xt-en',
      title: 'EN| SampleTitle',
      sourceId: 'xt',
      year: 2022,
    );
    library.catalog = [catalog, en];
    await library.setPreferredVodVariant(catalog);
    expect(library.resolveVodVariant(en).id, catalog.id);
    await library.setPreferredVodVariant(en);
    expect(library.resolveVodVariant(catalog).id, en.id);
  });

  test(
    'large VOD cache builds Versions index without sync freeze path',
    () async {
      // Above [_vodVariantIndexSyncLimit] the index is scheduled on a worker
      // isolate (compact row payload) so Catalog → Movies / Home / minimize do
      // not freeze after a ~200k hydrate.
      final filler = List<MediaItem>.generate(
        2600,
        (i) => vod(
          'filler-$i',
          title: 'Filler $i',
          sourceId: 'xt',
          year: 2000 + (i % 20),
        ),
      );
      final jelly = vod(
        'jf-backrooms',
        title: 'SampleTitle',
        sourceId: 'jelly',
        tmdbId: 999001,
        year: 2022,
        origin: MediaOrigin.jellyfin,
      );
      final xt = vod(
        'xt-backrooms',
        title: 'EN| SampleTitle',
        sourceId: 'xt',
        tmdbId: 999001,
        year: 2022,
      );
      library.debugSeedVodStreamCache([
        ...filler,
        jelly,
        xt,
      ], buildIndex: false);

      // Cold path: must not block on the full scan — single-edition until ready.
      expect(library.vodVariantCountFor(jelly), 1);

      await library.ensureVodVariantIndex();

      expect(library.vodVariantCountFor(jelly), 2);
      expect(
        library.vodVariantsFor(jelly).map((m) => m.id),
        containsAll([jelly.id, xt.id]),
      );
    },
  );

  test('invalidating Versions index does not drop a known family', () async {
    final filler = List<MediaItem>.generate(
      2600,
      (i) => vod(
        'filler-$i',
        title: 'Filler $i',
        sourceId: 'xt',
        year: 2000 + (i % 20),
      ),
    );
    final jelly = vod(
      'jf-keep',
      title: 'SampleTitle',
      sourceId: 'jelly',
      tmdbId: 999001,
      year: 2022,
      origin: MediaOrigin.jellyfin,
    );
    final xt = vod(
      'xt-keep',
      title: 'FR| SampleTitle',
      sourceId: 'xt',
      tmdbId: 999001,
      year: 2022,
    );
    library.debugSeedVodStreamCache([...filler, jelly, xt], buildIndex: false);
    await library.ensureVodVariantIndex();
    expect(library.vodVariantCountFor(jelly), 2);

    library.debugInvalidateVodVariantIndex();
    expect(library.vodVariantCountFor(jelly), 2);
    await library.setPreferredVodVariant(xt);
    expect(library.vodVariantsFor(jelly).map((m) => m.id), {jelly.id, xt.id});
    expect(library.resolveVodVariant(jelly).id, xt.id);
  });

  test('search clusters catalog TMDB with IPTV name editions', () {
    final filler = List<MediaItem>.generate(
      2600,
      (i) => vod(
        'filler-$i',
        title: 'Filler $i',
        sourceId: 'xt',
        year: 2000 + (i % 20),
      ),
    );
    final xtEn = vod(
      'xt-en',
      title: 'EN| SampleTitle',
      sourceId: 'xt',
      year: 2022,
    );
    final xtFr = vod(
      'xt-fr',
      title: 'FR| SampleTitle',
      sourceId: 'xt',
      year: 2022,
    );
    final catalogHit = vod(
      'cat-1',
      title: 'SampleTitle',
      sourceId: 'cataloga',
      tmdbId: 999001,
      year: 2022,
      origin: MediaOrigin.customCatalog,
    );
    library.debugSeedVodStreamCache([...filler, xtEn, xtFr], buildIndex: false);
    library.catalog = [catalogHit];

    final hits = [xtEn, xtFr, catalogHit];
    final search = library.collapseSearchHits(hits, query: 'sampletitle');
    expect(search, hasLength(1));
    final family = library.vodVariantsForSearch(search.single, extraHits: hits);
    expect(family.map((m) => m.id).toSet(), {xtEn.id, xtFr.id, catalogHit.id});
  });

  test(
    'search collapses panel language editions when year lives in the title',
    () {
      MediaItem row(String id, String title) =>
          vod(id, title: title, sourceId: 'panel');
      final hits = [
        row('alb', 'ALB| Backrooms - 2026'),
        row('ar', 'AR| Backrooms - 2026'),
        row('br', 'BR| Backrooms: Um Não-Lugar - 2026 [HDTS]'),
        row('multi', 'Backrooms - 2026 [MULTI-SUB]'),
        row('de', 'DE| Backrooms - 2026'),
        row('amity', 'EN| Amityville Backrooms - 2024'),
        row('en', 'EN| Backrooms - 2026'),
        row('en-hdts', 'EN| Backrooms - 2026 [HDTS]'),
        row('fr', 'FR| Backrooms - 2026'),
        row('fr-4k', 'FR| Backrooms - 2026 [4K]'),
        row('fr-vost', 'FR| Backrooms - 2026 [VOSTFR]'),
        row('ku', 'KU| Backrooms - 2026'),
        row('pt', 'PT| Backrooms - O Labirinto - 2026'),
      ];
      library.catalog = hits;
      final search = library.collapseSearchHits(hits, query: 'backrooms');
      expect(search, hasLength(4));
      final main = search.firstWhere(
        (m) => VodGrouping.displayTitle(m) == 'Backrooms',
      );
      expect(
        library.vodVariantsForSearch(main, extraHits: hits),
        hasLength(10),
      );
      expect(search.any((m) => m.title.contains('Amityville')), isTrue);
      expect(
        VodGrouping.searchHitSubtitle(
          variantCount: 10,
          sourceCount: 1,
          versionsLabel: '10 versions',
          sourceLabel: 'Panel',
        ),
        '10 versions',
      );
    },
  );

  test(
    'search families keep IPTV language editions when catalog TMDB also matches',
    () {
      MediaItem row(String id, String title) =>
          vod(id, title: title, sourceId: 'panel');
      final catalogb = vod(
        'cine',
        title: 'Backrooms',
        sourceId: 'catalogb',
        tmdbId: 1242011,
        year: 2026,
        origin: MediaOrigin.customCatalog,
      );
      final cataloga = vod(
        'pur',
        title: 'Backrooms',
        sourceId: 'cataloga',
        tmdbId: 1242011,
        year: 2026,
        origin: MediaOrigin.customCatalog,
      );
      final iptv = [
        row('en', 'EN| Backrooms - 2026'),
        row('fr', 'FR| Backrooms - 2026'),
        row('fr-4k', 'FR| Backrooms - 2026 [4K]'),
        row('en-hdts', 'EN| Backrooms - 2026 [HDTS]'),
      ];
      // Catalog-only in memory (sqlite FTS hits are not in the Versions index).
      library.catalog = [catalogb, cataloga];
      final raw = [catalogb, cataloga, ...iptv];
      final collapsed = library.collapseSearchHits(raw, query: 'backrooms');
      final main = collapsed.firstWhere(
        (m) => VodGrouping.displayTitle(m) == 'Backrooms',
      );
      expect(
        library.vodSearchFamilyIndex(raw)[main.id]!.map((m) => m.id).toSet(),
        {catalogb.id, cataloga.id, 'en', 'fr', 'fr-4k', 'en-hdts'},
      );
      // Collapsing before the family index drops sqlite-only IPTV siblings.
      expect(
        library
            .vodSearchFamilyIndex(collapsed)[main.id]!
            .map((m) => m.id)
            .toSet(),
        {catalogb.id, cataloga.id},
      );
      library.mergeVodSearchFamilyOverlay(library.vodSearchFamilyIndex(raw));
      expect(library.vodVariantsFor(catalogb).map((m) => m.id).toSet(), {
        catalogb.id,
        cataloga.id,
        'en',
        'fr',
        'fr-4k',
        'en-hdts',
      });
    },
  );

  test('searchTmdbEnrichmentSeeds picks one Xtream cluster missing TMDB', () {
    MediaItem row(String id, String title, {int? tmdbId, MediaOrigin? origin}) {
      return MediaItem(
        id: id,
        title: title,
        playUrl: 'https://example.com/$id',
        kind: MediaKind.vod,
        origin: origin ?? MediaOrigin.iptvXtream,
        sourceId: 'panel',
        streamId: id,
        tmdbId: tmdbId,
      );
    }

    final seeds = LibraryProvider.searchTmdbEnrichmentSeeds([
      row('en', 'EN| SampleTitle - 2026'),
      row('fr', 'FR| SampleTitle - 2026'),
      row('pt', 'PT| SampleTitle - The Maze - 2026'),
      row(
        'pur',
        'SampleTitle',
        tmdbId: 999001,
        origin: MediaOrigin.customCatalog,
      ),
      row('am', 'EN| OtherTitle - 2024'),
    ]);
    expect(seeds, hasLength(2));
    expect(seeds.map((m) => m.id).toSet(), containsAll(['en', 'am']));
    expect(seeds.map((m) => m.id), isNot(contains('fr')));
    expect(seeds.map((m) => m.id), isNot(contains('pur')));
  });

  test('title hydrate overlay keeps only the opened title family', () {
    final opened = vod(
      'open',
      title: 'OpenedFilm',
      sourceId: 'catalog',
      tmdbId: 101,
      year: 2020,
      origin: MediaOrigin.customCatalog,
    );
    final openedFr = vod(
      'open-fr',
      title: 'FR| OpenedFilm',
      sourceId: 'panel',
      year: 2020,
    );
    final other = vod(
      'other',
      title: 'OtherFilm',
      sourceId: 'panel',
      tmdbId: 202,
      year: 2019,
    );
    final otherEn = vod(
      'other-en',
      title: 'EN| OtherFilm',
      sourceId: 'panel',
      year: 2019,
    );
    library.catalog = [opened];
    final fts = [openedFr, other, otherEn];
    final clustered = library.vodSearchFamilyIndex([opened, ...fts]);
    expect(clustered.keys, containsAll([opened.id, other.id, otherEn.id]));
    final overlay = library.vodHydrateOverlayIndex(opened, fts);
    expect(overlay.keys, {opened.id, openedFr.id});
    expect(overlay[opened.id]!.map((m) => m.id).toSet(), {
      opened.id,
      openedFr.id,
    });
  });

  test(
    'overlay cap wipe forgets hydrated keys so sqlite families can return',
    () {
      final keep = vod(
        'keep',
        title: 'KeepFilm',
        sourceId: 'catalog',
        tmdbId: 303,
        year: 2021,
        origin: MediaOrigin.customCatalog,
      );
      final keepFr = vod(
        'keep-fr',
        title: 'FR| KeepFilm',
        sourceId: 'panel',
        year: 2021,
      );
      // Catalog-only in memory — IPTV edition lives only in the overlay,
      // matching sqlite-only panel rows.
      library.catalog = [keep];
      final family = [keep, keepFr];
      final overlayRev = library.vodFamilyOverlayRevision;
      library.mergeVodSearchFamilyOverlay({keep.id: family, keepFr.id: family});
      expect(library.vodFamilyOverlayRevision, greaterThan(overlayRev));
      expect(library.vodVariantsFor(keep).map((m) => m.id).toSet(), {
        keep.id,
        keepFr.id,
      });
      final hydratedKey = library.canonicalVodGroupKey(keep)!;
      library.debugMarkVodFamilyHydrated(hydratedKey);
      expect(library.debugIsVodFamilyHydrated(hydratedKey), isTrue);

      final flood = <String, List<MediaItem>>{
        for (var i = 0; i < 801; i++)
          'flood-$i': [
            vod('flood-$i', title: 'Flood $i', sourceId: 'panel', year: 1990),
          ],
      };
      library.mergeVodSearchFamilyOverlay(flood);
      expect(library.vodVariantsFor(keep).map((m) => m.id).toSet(), {keep.id});
      expect(library.debugIsVodFamilyHydrated(hydratedKey), isFalse);
    },
  );

  test('overlay merge updates Home source chip without a title tap', () {
    final catalog = vod(
      'cat',
      title: 'KeepFilm',
      sourceId: 'catalog',
      tmdbId: 404,
      year: 2021,
      origin: MediaOrigin.customCatalog,
    );
    final panelA = vod(
      'a',
      title: 'EN| KeepFilm',
      sourceId: 'panel-a',
      year: 2021,
    );
    final panelB = vod(
      'b',
      title: 'FR| KeepFilm',
      sourceId: 'panel-b',
      year: 2021,
    );
    library.sources = [
      IptvSource(
        id: 'catalog',
        name: 'Catalog',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2024),
      ),
      IptvSource(
        id: 'panel-a',
        name: 'Panel A',
        type: IptvSourceType.xtream,
        createdAt: DateTime.utc(2024),
      ),
      IptvSource(
        id: 'panel-b',
        name: 'Panel B',
        type: IptvSourceType.xtream,
        createdAt: DateTime.utc(2024),
      ),
    ];
    library.catalog = [catalog];
    expect(library.vodSourceCountFor(catalog), 1);

    final family = [catalog, panelA, panelB];
    library.mergeVodSearchFamilyOverlay({
      catalog.id: family,
      panelA.id: family,
      panelB.id: family,
    }, notify: false);
    expect(library.vodSourceCountFor(catalog), 3);
    expect(library.shelfSourceLabelFor(catalog), '3 sources');
  });
}
