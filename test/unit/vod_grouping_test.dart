import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';
import 'package:javp/services/iptv/vod_grouping.dart';

MediaItem vod(
  String title, {
  String? group,
  int? tmdbId,
  String? id,
  String? sourceId,
  MediaOrigin origin = MediaOrigin.iptvXtream,
}) {
  return MediaItem(
    id: id ?? title,
    title: title,
    playUrl: 'https://example.com/$title',
    kind: MediaKind.vod,
    origin: origin,
    group: group,
    tmdbId: tmdbId,
    sourceId: sourceId ?? 'src',
  );
}

void main() {
  tearDown(() => IptvLocaleHints.debugTimeZoneOffset(null));

  test('normalizeTitle strips EN| / FR| and year noise', () {
    expect(VodGrouping.normalizeTitle('EN| Sample Film'), 'sample film');
    expect(
      VodGrouping.normalizeTitle('FR| Murder Mystery 2'),
      'murder mystery 2',
    );
    expect(VodGrouping.normalizeTitle('EN| Mank [MULTI-SUB]'), 'mank');
    expect(
      VodGrouping.normalizeTitle('The Boys in the Band - 2020'),
      'the boys in the band',
    );
  });

  test('title acronyms are not audio language prefixes', () {
    const title = 'LOL: Studio Night - France';
    expect(VodGrouping.languageFromTitle(title), isNull);
    expect(VodGrouping.displayTitleFor(title), title);
    expect(VodGrouping.normalizeTitle(title), 'lol studio night france');
    final item = vod(title);
    expect(VodGrouping.inferredAudioLanguages(item), isEmpty);
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: const ['lol'],
        subtitleLangs: const [],
      ),
      isEmpty,
    );
  });

  test('IPTV EN| / FR: prefixes still count as audio language', () {
    expect(VodGrouping.languageFromTitle('EN| Studio Night'), 'en');
    expect(VodGrouping.languageFromTitle('FR: Studio Night'), 'fr');
    expect(VodGrouping.displayTitleFor('EN| Studio Night'), 'Studio Night');
    expect(VodGrouping.languageFromTitle('IT | Night Watch'), 'it');
    expect(VodGrouping.languageFromTitle('IT: Night Two'), isNull);
    expect(VodGrouping.languageFromTitle('CA| Studio Night'), 'ca');
  });

  test('groupKey prefers typed tmdb identity over name', () {
    final a = vod('EN| Atlas', tmdbId: 614933);
    final b = vod('FR| Atlas', tmdbId: 614933);
    final c = vod('EN| Atlas');
    expect(VodGrouping.groupKey(a), 'tmdb:movie:614933');
    expect(VodGrouping.groupKey(a), VodGrouping.groupKey(b));
    // Single-word yearless titles must not share a bare name key.
    expect(VodGrouping.groupKey(c), isNull);
  });

  test('groupKey reads {tmdb-id} from IPTV / catalog titles', () {
    final us = vod('US| SampleTitle {tmdb-999001}');
    final fr = vod('FR| Les SampleTitle {tmdb-999001}');
    final other = vod('EN| Drive {tmdb-64}');
    expect(VodGrouping.groupKey(us), 'tmdb:movie:999001');
    expect(VodGrouping.groupKey(us), VodGrouping.groupKey(fr));
    expect(VodGrouping.groupKey(us), isNot(VodGrouping.groupKey(other)));
  });

  test('panel SampleTitle: name+year groups LANG copies; PT/BR need TMDB', () {
    MediaItem row(String id, String title) => MediaItem(
      id: id,
      title: title,
      playUrl: 'https://example.com/$id',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'panel',
      streamId: id,
    );

    final en = row('en', 'EN| SampleTitle - 2026');
    final fr = row('fr', 'FR| SampleTitle - 2026');
    final pt = row('pt', 'PT| SampleTitle - The Maze - 2026');
    final br = row('br', 'BR| SampleTitle: A Non-Place - 2026 [HDTS]');
    final amity = row('am', 'EN| OtherTitle - 2024');

    expect(VodGrouping.groupKey(en), 'name:sampletitle|2026');
    expect(VodGrouping.groupKey(en), VodGrouping.groupKey(fr));
    expect(VodGrouping.groupKey(pt), isNot(VodGrouping.groupKey(en)));
    expect(VodGrouping.groupKey(br), isNot(VodGrouping.groupKey(en)));
    expect(VodGrouping.groupKey(amity), isNot(VodGrouping.groupKey(en)));

    // After get_vod_info attaches the shared panel tmdb_id, all editions merge.
    final enriched = [
      for (final m in [en, fr, pt, br]) m.copyWith(tmdbId: 999001),
    ];
    for (final m in enriched) {
      expect(VodGrouping.groupKey(m), 'tmdb:movie:999001');
    }
    expect(
      VodGrouping.groupKey(amity.copyWith(tmdbId: 999002)),
      'tmdb:movie:999002',
    );
  });

  test(
    'likelyMissingTmdbSiblings finds localized SampleTitle, skips OtherTitle',
    () {
      MediaItem row(String id, String title, {int? tmdbId}) => MediaItem(
        id: id,
        title: title,
        playUrl: 'https://example.com/$id',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'panel',
        streamId: id,
        tmdbId: tmdbId,
      );

      final seed = row('en', 'EN| SampleTitle - 2026', tmdbId: 999001);
      final pool = [
        seed,
        row('fr', 'FR| SampleTitle - 2026'),
        row('pt', 'PT| SampleTitle - The Maze - 2026'),
        row('br', 'BR| SampleTitle: A Non-Place - 2026 [HDTS]'),
        row('am', 'EN| OtherTitle - 2024'),
        row('done', 'ALB| SampleTitle - 2026', tmdbId: 999001),
      ];

      final hits = VodGrouping.likelyMissingTmdbSiblings(
        seed: seed,
        pool: pool,
      );
      final ids = hits.map((m) => m.id).toSet();
      expect(ids, containsAll(['fr', 'pt', 'br']));
      expect(ids, isNot(contains('am')));
      expect(ids, isNot(contains('done')));
      expect(ids, isNot(contains('en')));
    },
  );

  test('groupKey uses imdb when tmdb missing', () {
    final item = MediaItem(
      id: 'imdb-row',
      title: 'Belle',
      playUrl: 'https://example.com/b',
      kind: MediaKind.vod,
      origin: MediaOrigin.jellyfin,
      imdbId: 'tt1234567',
    );
    expect(VodGrouping.groupKey(item), 'imdb:tt1234567');
  });

  test(
    'same-source yearless EN|/FR| multi-word editions share srcname key',
    () {
      final en = vod(
        'EN| Sample Film',
        group: '[EN] STREAM',
        sourceId: 'xtream',
      );
      final fr = vod(
        'FR| Sample Film',
        group: '[FR] STREAM',
        sourceId: 'xtream',
      );
      expect(VodGrouping.groupKey(en), VodGrouping.groupKey(fr));
      expect(VodGrouping.groupKey(en), 'srcname:xtream:sample film');
    },
  );

  test('yearless multi-word titles do not group across sources without id', () {
    final xt = vod('EN| Sample Film', sourceId: 'xtream', id: 'xt');
    final jf = vod(
      'Sample Film',
      sourceId: 'jelly',
      id: 'jf',
      origin: MediaOrigin.jellyfin,
    );
    expect(VodGrouping.groupKey(xt), isNot(VodGrouping.groupKey(jf)));
    expect(VodGrouping.groupKey(xt), 'srcname:xtream:sample film');
    expect(VodGrouping.groupKey(jf), 'srcname:jelly:sample film');
  });

  test('title + year groups across sources; different years stay separate', () {
    final a = MediaItem(
      id: 'a',
      title: 'EN| Sample Film',
      playUrl: 'https://example.com/a',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'xtream',
      year: 2024,
    );
    final b = MediaItem(
      id: 'b',
      title: 'Sample Film',
      playUrl: 'https://example.com/b',
      kind: MediaKind.vod,
      origin: MediaOrigin.jellyfin,
      sourceId: 'jelly',
      year: 2024,
    );
    final older = MediaItem(
      id: 'c',
      title: 'Sample Film',
      playUrl: 'https://example.com/c',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'other',
      year: 2014,
    );
    expect(VodGrouping.groupKey(a), 'name:sample film|2024');
    expect(VodGrouping.groupKey(a), VodGrouping.groupKey(b));
    expect(VodGrouping.groupKey(a), isNot(VodGrouping.groupKey(older)));
  });

  test('Belle-like bare titles do not share a yearless name key', () {
    expect(VodGrouping.isAmbiguousBareTitle('belle'), isTrue);
    expect(VodGrouping.isAmbiguousBareTitle('her'), isTrue);
    expect(VodGrouping.isAmbiguousBareTitle('up'), isTrue);
    expect(VodGrouping.isAmbiguousBareTitle('sample film'), isFalse);
    expect(VodGrouping.groupKey(vod('Belle')), isNull);
    expect(VodGrouping.groupKey(vod('EN| Belle')), isNull);
    expect(
      VodGrouping.groupKey(vod('Belle', tmdbId: 1)),
      isNot(VodGrouping.groupKey(vod('Belle', tmdbId: 2))),
    );
    expect(
      VodGrouping.nameGroupKey(
        MediaItem(
          id: 'b2013',
          title: 'Belle',
          playUrl: 'https://example.com/b',
          kind: MediaKind.vod,
          origin: MediaOrigin.iptvXtream,
          year: 2013,
        ),
      ),
      'name:belle|2013',
    );
    expect(
      VodGrouping.nameGroupKey(
        MediaItem(
          id: 'b2021',
          title: 'Belle',
          playUrl: 'https://example.com/b2',
          kind: MediaKind.vod,
          origin: MediaOrigin.iptvXtream,
          year: 2021,
        ),
      ),
      'name:belle|2021',
    );
  });

  test('displayTitle and variantLabel', () {
    final item = vod('EN| Sample Film [MULTI-SUB]', group: '[EN] STREAM');
    expect(VodGrouping.displayTitle(item), 'Sample Film');
    expect(VodGrouping.variantLabel(item), contains('Audio EN'));
    expect(VodGrouping.variantLabel(item), contains('Multi-sub'));
  });

  test('variantLabel surfaces captions vs audio', () {
    final subbed = vod('EN| Drive [SUB]', group: '[EN] MOVIES');
    final french = vod('FR| Drive', group: '[FR] MOVIES');
    final raw = vod('EN| Drive [RAW]', group: '[EN] MOVIES');
    expect(VodGrouping.variantLabel(subbed), contains('Subbed'));
    expect(VodGrouping.variantLabel(french), contains('Audio FR'));
    expect(VodGrouping.captionLabel(french), isNull);
    expect(VodGrouping.variantLabel(raw), contains('No captions'));
    expect(
      VodGrouping.versionsSectionHint([subbed, french, raw]),
      contains('caption'),
    );
  });

  test('compareVariants prefers EN over FR by default', () {
    final en = vod('EN| Sample Drama', group: '[EN] STREAM');
    final fr = vod('FR| Sample Drama', group: '[FR] STREAM');
    expect(VodGrouping.compareVariants(en, fr), lessThan(0));
  });

  test('compareVariants prefers preferredLang over default EN bias', () {
    final en = vod('EN| Sample Drama', group: '[EN] STREAM');
    final fr = vod('FR| Sample Drama', group: '[FR] STREAM');
    expect(
      VodGrouping.compareVariants(en, fr, preferredLang: 'fr'),
      greaterThan(0),
    );
  });

  test('localeAffinity prefers audio match over subtitle-only', () {
    final dubbed = MediaItem(
      id: 'dub',
      title: 'Film',
      playUrl: 'https://example.com/a',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      audioLanguages: const ['fr'],
    );
    final subbed = MediaItem(
      id: 'sub',
      title: 'Film',
      playUrl: 'https://example.com/b',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      audioLanguages: const ['ja'],
      subtitleLanguages: const ['fr'],
    );
    expect(
      VodGrouping.localeAffinity(dubbed, preferredLangs: const ['fr']),
      greaterThan(
        VodGrouping.localeAffinity(subbed, preferredLangs: const ['fr']),
      ),
    );
  });

  test('groupHomeScore boosts locale-matching shelves', () {
    final frShelf = [
      vod('FR| Alpha', group: '[FR] STREAM', id: '1'),
      vod('FR| Beta', group: '[FR] STREAM', id: '2'),
      vod('FR| Gamma', group: '[FR] STREAM', id: '3'),
    ];
    final jpShelf = [
      vod('JP| Alpha', group: '[JP] ANIME', id: '4'),
      vod('JP| Beta', group: '[JP] ANIME', id: '5'),
      vod('JP| Gamma', group: '[JP] ANIME', id: '6'),
    ];
    expect(
      VodGrouping.groupHomeScore(
        '[FR] STREAM',
        frShelf,
        preferredLangs: const ['fr'],
      ),
      greaterThan(
        VodGrouping.groupHomeScore(
          '[JP] ANIME',
          jpShelf,
          preferredLangs: const ['fr'],
        ),
      ),
    );
  });

  test('compareForHome surfaces matching locales first', () {
    final en = vod('EN| Zulu', id: 'en', group: '[EN] MOVIES');
    final fr = vod('FR| Alpha', id: 'fr', group: '[FR] MOVIES');
    final sorted = [en, fr]
      ..sort(
        (a, b) =>
            VodGrouping.compareForHome(a, b, preferredLangs: const ['fr']),
      );
    expect(sorted.first.id, 'fr');
  });

  test('localeAffinity demotes ALB tag when prefs are fr', () {
    final alb = vod('ALB| Toy Story 5 - 2026', id: 'alb', group: '[ALB] FILMET');
    final fr = vod('FR| Toy Story 5 - 2026', id: 'fr', group: '[FR] FILMS');
    final untagged = vod('Toy Story 5 - 2026', id: 'raw', group: 'Films');
    expect(VodGrouping.languageFromTitle(alb.title), 'sq');
    expect(VodGrouping.languageFromCategory(alb.group!), 'sq');
    expect(
      VodGrouping.localeAffinity(alb, preferredLangs: const ['fr']),
      lessThan(0),
    );
    expect(
      VodGrouping.localeAffinity(untagged, preferredLangs: const ['fr']),
      0,
    );
    expect(
      VodGrouping.localeAffinity(fr, preferredLangs: const ['fr']),
      greaterThan(0),
    );
    final sorted = [alb, untagged, fr]
      ..sort(
        (a, b) =>
            VodGrouping.compareForHome(a, b, preferredLangs: const ['fr']),
      );
    expect(sorted.map((m) => m.id).toList(), ['fr', 'raw', 'alb']);
  });

  test('Europe fr_CA catalog prefers FR| over CA|', () {
    IptvLocaleHints.debugTimeZoneOffset(const Duration(hours: 2));
    const locale = Locale('fr', 'CA');
    final ca = vod('CA| Alpha', id: 'ca', group: 'CA | VOD');
    final fr = vod('FR| Zulu', id: 'fr', group: 'FR | VOD');
    expect(
      VodGrouping.localeAffinity(
        fr,
        preferredLangs: const ['fr'],
        locale: locale,
      ),
      greaterThan(
        VodGrouping.localeAffinity(
          ca,
          preferredLangs: const ['fr'],
          locale: locale,
        ),
      ),
    );
    expect(
      VodGrouping.groupHomeScore(
        'FR | VOD',
        [fr],
        preferredLangs: const ['fr'],
        locale: locale,
      ),
      greaterThan(
        VodGrouping.groupHomeScore(
          'CA | VOD',
          [ca],
          preferredLangs: const ['fr'],
          locale: locale,
        ),
      ),
    );
  });

  test('Québec fr_CA catalog prefers CA| over FR|', () {
    IptvLocaleHints.debugTimeZoneOffset(const Duration(hours: -5));
    const locale = Locale('fr', 'CA');
    final ca = vod('CA| Zulu', id: 'ca', group: 'CA | VOD');
    final fr = vod('FR| Alpha', id: 'fr', group: 'FR | VOD');
    expect(
      VodGrouping.localeAffinity(
        ca,
        preferredLangs: const ['fr'],
        locale: locale,
      ),
      greaterThan(
        VodGrouping.localeAffinity(
          fr,
          preferredLangs: const ['fr'],
          locale: locale,
        ),
      ),
    );
    expect(
      VodGrouping.groupHomeScore(
        'CA | VOD',
        [ca],
        preferredLangs: const ['fr'],
        locale: locale,
      ),
      greaterThan(
        VodGrouping.groupHomeScore(
          'FR | VOD',
          [fr],
          preferredLangs: const ['fr'],
          locale: locale,
        ),
      ),
    );
  });

  test('compareDisplayTitle ignores EN| prefix and is stable', () {
    final a = vod('EN| Zulu', id: 'a', sourceId: 'xtream');
    final b = vod('FR| Alpha', id: 'b', sourceId: 'jelly');
    final c = vod('EN| Alpha', id: 'c', sourceId: 'xtream');
    final sorted = [a, b, c]..sort(VodGrouping.compareDisplayTitle);
    expect(sorted.map((m) => m.id).toList(), ['b', 'c', 'a']);
  });

  test('groupKey collapses same TMDB across sources', () {
    final iptv = vod(
      'EN| Atlas',
      tmdbId: 614933,
      sourceId: 'xtream-1',
      id: 'iptv',
    );
    final jf = vod(
      'Atlas',
      tmdbId: 614933,
      sourceId: 'jellyfin-1',
      id: 'jf',
      origin: MediaOrigin.jellyfin,
    );
    expect(VodGrouping.groupKey(iptv), VodGrouping.groupKey(jf));
  });

  test('nameGroupAliases cover yearless and year forms', () {
    final withYear = vod('EN| SampleTitle - 2022');
    expect(
      VodGrouping.nameGroupAliases(withYear),
      containsAll(['name:sampletitle', 'name:sampletitle|2022']),
    );
    expect(VodGrouping.nameGroupKey(withYear), 'name:sampletitle|2022');
    // Single-word yearless: no primary name key (aliases still used for linking).
    expect(VodGrouping.nameGroupKey(vod('FR| SampleTitle')), isNull);
    expect(VodGrouping.nameGroupAliases(vod('FR| SampleTitle')), [
      'name:sampletitle',
    ]);
    expect(
      VodGrouping.nameGroupAliases(
        MediaItem(
          id: 'fr',
          title: 'FR| Les SampleTitle',
          playUrl: 'https://example.com/fr',
          kind: MediaKind.vod,
          origin: MediaOrigin.iptvXtream,
          originalTitle: 'The SampleTitle',
          year: 2022,
        ),
      ),
      containsAll([
        'name:les sampletitle',
        'name:the sampletitle',
        'name:the sampletitle|2022',
      ]),
    );
  });

  test('compareVariants prefers media server over IPTV when language ties', () {
    final iptv = vod('Atlas', tmdbId: 1, sourceId: 'xtream-1', id: 'iptv');
    final jf = vod(
      'Atlas',
      tmdbId: 1,
      sourceId: 'jellyfin-1',
      id: 'jf',
      origin: MediaOrigin.jellyfin,
    );
    expect(VodGrouping.compareVariants(jf, iptv), lessThan(0));
    final ranked = [iptv, jf]..sort(VodGrouping.compareVariants);
    expect(ranked.first.id, 'jf');
  });

  test('variantLabel appends source when provided', () {
    final item = vod('EN| Drive', group: '[EN] MOVIES');
    expect(
      VodGrouping.variantLabel(item, sourceLabel: 'Home Jellyfin'),
      contains('Home Jellyfin'),
    );
  });

  test('searchHitSubtitle never pairs versions with sources', () {
    expect(
      VodGrouping.searchHitSubtitle(
        variantCount: 1,
        sourceCount: 1,
        versionsLabel: '2 versions',
        sourceLabel: 'Catalog A',
      ),
      'Catalog A',
    );
    expect(
      VodGrouping.searchHitSubtitle(
        variantCount: 2,
        sourceCount: 1,
        versionsLabel: '2 versions',
        sourceLabel: 'Panel',
      ),
      '2 versions',
    );
    expect(
      VodGrouping.searchHitSubtitle(
        variantCount: 2,
        sourceCount: 2,
        versionsLabel: '2 versions',
        sourceLabel: '2 sources',
      ),
      isNull,
    );
    expect(
      VodGrouping.uniqueSourceIds([
        vod('A', sourceId: 'cataloga'),
        vod('B', sourceId: 'catalogb'),
        vod('C', sourceId: 'cataloga'),
      ]),
      ['cataloga', 'catalogb'],
    );
  });

  test('yearFromTitle', () {
    expect(VodGrouping.yearFromTitle('EN| The Last House - 2026'), 2026);
    expect(VodGrouping.yearFromTitle('Drive'), isNull);
  });

  test('series name keys stay out of movie families', () {
    final movie = vod('EN| Always a Catch - 2024', tmdbId: null);
    final series = MediaItem(
      id: 's',
      title: 'EN| Always a Catch - 2024',
      playUrl: 'https://example.com/s',
      kind: MediaKind.series,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src',
      year: 2024,
    );
    expect(VodGrouping.groupKey(movie), 'name:always a catch|2024');
    expect(VodGrouping.groupKey(series), 'name:tv:always a catch|2024');
    expect(VodGrouping.groupKey(movie), isNot(VodGrouping.groupKey(series)));
  });

  test('same-source EN/FR collapse into one quality cluster', () {
    final en = vod('EN| Sample Film [MULTI-SUB]', id: 'en');
    final fr = vod('FR| Sample Film [MULTI-SUB]', id: 'fr');
    final layout = VodGrouping.familyLayout(
      [en, fr],
      preferredLangs: const ['fr', 'en'],
    );
    expect(layout.sources, hasLength(1));
    expect(layout.sources.first.qualities, hasLength(1));
    final cluster = layout.sources.first.qualities.first;
    expect(cluster.editions.map((e) => e.id).toSet(), {'en', 'fr'});
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: cluster.audioLanguages,
        subtitleLangs: cluster.subtitleLanguages,
        preferredLangs: const ['fr', 'en'],
      ),
      contains('Audio FR/EN'),
    );
    expect(cluster.editionForAudio('fr')?.id, 'fr');
    expect(cluster.editionForAudio('en')?.id, 'en');
  });

  test('identical MULTI rows from one source collapse to one encode', () {
    final a = vod('Movie [MULTI AUDIO] [MULTI SUB]', id: 'a');
    final b = vod('Movie [MULTI AUDIO] [MULTI-SUB]', id: 'b');
    final collapsed = VodGrouping.collapseIndistinguishableEditions([a, b]);
    expect(collapsed, hasLength(1));
    final layout = VodGrouping.familyLayout([a, b]);
    expect(layout.distinctEncodeCount, 1);
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: layout.sources.first.qualities.first.audioLanguages,
        subtitleLangs: layout.sources.first.qualities.first.subtitleLanguages,
        preferredLangs: const ['fr'],
      ),
      contains('Multi'),
    );
  });

  test('4K vs 1080 stay split; availability lists every audio language', () {
    final hd = MediaItem(
      id: 'hd',
      title: 'FR| Film 1080p',
      playUrl: 'https://example.com/hd',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src',
      resolution: '1080p',
    );
    final uhd = MediaItem(
      id: 'uhd',
      title: 'FR| Film 4K',
      playUrl: 'https://example.com/uhd',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'src',
      resolution: '4K',
    );
    final pt = vod('PT| Film 1080p', id: 'pt');
    final layout = VodGrouping.familyLayout(
      [hd, uhd, pt],
      preferredLangs: const ['fr'],
    );
    expect(layout.sources, hasLength(1));
    expect(layout.sources.first.qualities.length, greaterThanOrEqualTo(2));
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: const ['fr', 'pt'],
        subtitleLangs: const [],
        preferredLangs: const ['fr'],
      ),
      'Audio FR/PT',
    );
  });

  test('title page lists every audio and caption language', () {
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: const ['ja', 'jpn', 'fr'],
        subtitleLangs: const ['fr', 'en', 'es'],
        preferredLangs: const ['fr'],
      ),
      'Audio FR/JA · Subs FR/EN/ES',
    );
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: const ['ja'],
        subtitleLangs: const ['fr'],
        preferredLangs: const ['fr', 'en'],
      ),
      'Audio JA · Subs FR',
    );
  });

  test('same catalog playUrl is one encode even when tagged 4K and 1080', () {
    const url = 'https://cdn.example.com/movie.m3u8';
    final hd = MediaItem(
      id: 'hd',
      title: 'Film',
      playUrl: url,
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      sourceId: 'cat',
      resolution: '1080p',
      audioLanguages: const ['en'],
    );
    final uhd = MediaItem(
      id: 'uhd',
      title: 'Film',
      playUrl: url,
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      sourceId: 'cat',
      resolution: '4K',
      audioLanguages: const ['fr'],
    );
    final layout = VodGrouping.familyLayout(
      [hd, uhd],
      preferredLangs: const ['fr', 'en'],
    );
    expect(layout.distinctEncodeCount, 1);
    expect(layout.sources.single.qualities, hasLength(1));
    expect(
      VodGrouping.localeAvailabilityLabel(
        audioLangs: layout.sources.single.qualities.single.audioLanguages,
        subtitleLangs: const [],
        preferredLangs: const ['fr', 'en'],
      ),
      contains('Audio FR/EN'),
    );
  });

  test('same magnet with different torrentFile stays two encodes', () {
    const magnet = 'magnet:?xt=urn:btih:abc';
    MediaItem row(String id, String file) => MediaItem(
      id: id,
      title: 'Film',
      playUrl: magnet,
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      sourceId: 'cat',
      torrentFile: file,
    );
    final layout = VodGrouping.familyLayout([
      row('a', 'Film.1080p.mkv'),
      row('b', 'Film.2160p.mkv'),
    ]);
    expect(layout.distinctEncodeCount, 2);
  });

  test('episode playVariants with the same HLS url collapse', () {
    const url = 'https://cdn.example.com/s1e1.m3u8';
    final collapsed = VodGrouping.collapseEpisodeVariantsByStream([
      const EpisodePlayVariant(
        id: 'hd',
        label: '1080p',
        playUrl: url,
        resolution: '1080p',
        audioLanguages: ['en'],
        httpHeaders: {'Referer': 'https://a.example/'},
      ),
      const EpisodePlayVariant(
        id: 'uhd',
        label: '4K',
        playUrl: url,
        resolution: '4K',
        audioLanguages: ['ja'],
        httpHeaders: {'User-Agent': 'Bridge/1'},
      ),
    ]);
    expect(collapsed, hasLength(1));
    expect(collapsed.single.audioLanguages, ['ja', 'en']);
    expect(collapsed.single.httpHeaders['Referer'], 'https://a.example/');
    expect(collapsed.single.httpHeaders['User-Agent'], 'Bridge/1');
  });

  test('title page availability hides sources and unions all langs', () {
    final fr = MediaItem(
      id: 'fr',
      title: 'FR| Film 4K',
      playUrl: 'https://a.example/fr',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      sourceId: 'catalog-a',
      resolution: '4K',
      audioLanguages: const ['fr'],
    );
    final en = MediaItem(
      id: 'en',
      title: 'EN| Film 1080p',
      playUrl: 'https://b.example/en',
      kind: MediaKind.vod,
      origin: MediaOrigin.iptvXtream,
      sourceId: 'panel-b',
      resolution: '1080p',
      audioLanguages: const ['en'],
    );
    final layout = VodGrouping.familyLayout(
      [fr, en],
      preferredLangs: const ['fr', 'en'],
      sourceLabelFor: (item) => item.sourceId ?? '',
    );
    expect(layout.hasMultipleSources, isTrue);
    expect(
      layout.availabilityLabel(preferredLangs: const ['fr', 'en']),
      'Audio FR/EN · Up to 4K',
    );
    expect(
      layout.editionForAudio('en', preferNear: fr)?.id,
      'en',
    );
    final qualities = layout.qualityChoices(
      preferredLangs: const ['fr'],
      matchLangOf: fr,
    );
    expect(qualities.map((e) => e.id).toList(), ['fr', 'en']);
  });

  test('siblingSeriesShells prefers other catalogs over same-source encodes', () {
    MediaItem series(String id, String source) => MediaItem(
      id: id,
      title: 'Show',
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.customCatalog,
      sourceId: source,
    );
    final current = series('a-s1', 'catalog-a');
    final other = series('b-s1', 'catalog-b');
    final sameSourceEncode = series('a-s1-4k', 'catalog-a');
    final movie = MediaItem(
      id: 'movie',
      title: 'Show',
      playUrl: 'https://example.com/movie',
      kind: MediaKind.vod,
      origin: MediaOrigin.customCatalog,
      sourceId: 'catalog-c',
    );
    expect(
      VodGrouping.siblingSeriesShells(
        current: current,
        editions: [current, sameSourceEncode, other, movie],
      ).map((e) => e.id).toList(),
      ['b-s1', 'a-s1-4k'],
    );
  });
}
