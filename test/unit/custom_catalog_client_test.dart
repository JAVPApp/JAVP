import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/services/catalog/custom_catalog_client.dart';
import 'package:javp/services/playback/drm_detect.dart';

void main() {
  final client = CustomCatalogClient();

  test('parses named catalog object with items', () {
    const body = '''
{
  "name": "Demo Shelf",
  "items": [
    {
      "id": "bbb",
      "title": "Big Buck Bunny",
      "playUrl": "https://example.com/bbb.mp4",
      "kind": "vod",
      "thumbnailUrl": "https://example.com/bbb.jpg",
      "group": "Open Source",
      "subtitle": "2008",
      "durationMs": 596000
    }
  ]
}
''';

    final result = client.parse(body, sourceId: 'src-custom');
    expect(result.name, 'Demo Shelf');
    expect(result.items, hasLength(1));
    final item = result.items.single;
    expect(item.id, 'bbb');
    expect(item.title, 'Big Buck Bunny');
    expect(item.playUrl, 'https://example.com/bbb.mp4');
    expect(item.kind, MediaKind.vod);
    expect(item.origin, MediaOrigin.customCatalog);
    expect(item.group, 'Open Source');
    expect(item.duration, const Duration(milliseconds: 596000));
    expect(item.sourceId, 'src-custom');
  });

  test('parses catalog and item VAST urls', () {
    const body = '''
{
  "name": "Ads Shelf",
  "vastUrl": "https://ads.example/catalog.xml",
  "items": [
    {
      "title": "With override",
      "playUrl": "https://cdn.example/a.mp4",
      "vastUrl": "https://ads.example/item.xml"
    },
    {
      "title": "Opt out",
      "playUrl": "https://cdn.example/b.mp4",
      "vastUrl": false
    },
    {
      "title": "Inherit",
      "playUrl": "https://cdn.example/c.mp4"
    }
  ]
}
''';
    final result = client.parse(body, sourceId: 'src');
    expect(result.vastUrl, 'https://ads.example/catalog.xml');
    expect(result.items[0].vastUrl, 'https://ads.example/item.xml');
    expect(result.items[1].vastUrl, '');
    expect(result.items[2].vastUrl, isNull);
  });

  test('marks DRM catalog rows via drm / licenseUrl', () {
    const body = '''
{
  "items": [
    {
      "title": "Protected",
      "playUrl": "https://cdn.example/a.mpd",
      "drm": "widevine",
      "licenseUrl": "https://license.example/wv"
    },
    {
      "title": "Clear",
      "playUrl": "https://cdn.example/b.mp4"
    }
  ]
}
''';
    final result = client.parse(body, sourceId: 'src');
    expect(headersIndicateDrm(result.items[0].httpHeaders), isTrue);
    expect(result.items[0].httpHeaders[drmHintHeader], 'widevine');
    expect(headersIndicateDrm(result.items[1].httpHeaders), isFalse);
  });

  test('accepts bare array and url alias', () {
    const body = '''
[
  {"title": "Live News", "url": "https://example.com/news.m3u8", "kind": "live"}
]
''';
    final result = client.parse(body, sourceId: 's1');
    expect(result.name, isNull);
    expect(result.items.single.kind, MediaKind.live);
    expect(result.items.single.playUrl, 'https://example.com/news.m3u8');
  });

  test('skips incomplete rows', () {
    const body = '''
{"items":[{"title":"No URL"},{"playUrl":"https://x"},{"title":"Ok","playUrl":"https://ok"}]}
''';
    final result = client.parse(body, sourceId: 's1');
    expect(result.items, hasLength(1));
    expect(result.items.single.title, 'Ok');
  });

  test('parses audio languages and external subtitles', () {
    const body = '''
{
  "items": [
    {
      "id": "anime-1",
      "title": "Example",
      "playUrl": "https://example.com/ep.mkv",
      "audioLanguages": ["ja", "en"],
      "subtitleLanguages": "en,fr",
      "subtitles": [
        {
          "url": "https://example.com/en.vtt",
          "language": "en",
          "label": "English",
          "default": true,
          "sdh": true
        },
        "https://example.com/fr.srt"
      ]
    }
  ]
}
''';
    final item = client.parse(body, sourceId: 'src').items.single;
    expect(item.audioLanguages, ['ja', 'en']);
    expect(item.subtitleLanguages, ['en', 'fr']);
    expect(item.subtitles, hasLength(2));
    expect(item.subtitles.first.url, 'https://example.com/en.vtt');
    expect(item.subtitles.first.language, 'en');
    expect(item.subtitles.first.isDefault, isTrue);
    expect(item.subtitles.first.hearingImpaired, isTrue);
    expect(item.subtitles.last.url, 'https://example.com/fr.srt');
    expect(item.hasExternalSubtitles, isTrue);
  });

  test('allows series shells without playUrl and nested seasons', () {
    const body = '''
{
  "items": [
    {
      "id": "show-1",
      "title": "Example Show",
      "kind": "series",
      "plot": "A show",
      "cast": [{"name": "Ada", "character": "Lead"}],
      "trailerUrl": "https://example.com/trailer.mp4",
      "seasons": [
        {
          "seasonNumber": 1,
          "episodes": [
            {
              "id": "e1",
              "episodeNumber": 1,
              "title": "Pilot",
              "playUrl": "https://example.com/e1.mp4",
              "durationMs": 1000
            }
          ]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(1));
    final shell = parsed.items.single;
    expect(shell.kind, MediaKind.series);
    expect(shell.playUrl, isEmpty);
    final details = parsed.details['show-1'];
    expect(details, isNotNull);
    expect(details!.seasons, hasLength(1));
    expect(
      details.seasons.single.episodes.single.playUrl,
      'https://example.com/e1.mp4',
    );
    expect(details.cast.single.name, 'Ada');
    expect(details.trailerUrl, 'https://example.com/trailer.mp4');
  });

  test('parses episode still aliases into thumbnailUrl', () {
    const body = '''
{
  "items": [
    {
      "id": "show-1",
      "title": "Example Show",
      "kind": "series",
      "seasons": [
        {
          "seasonNumber": 1,
          "episodes": [
            {
              "id": "e1",
              "episodeNumber": 1,
              "title": "Pilot",
              "still": "https://example.com/e1-still.jpg",
              "playUrl": "https://example.com/e1.mp4"
            }
          ]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    final ep = parsed.details['show-1']!.seasons.single.episodes.single;
    expect(ep.thumbnailUrl, 'https://example.com/e1-still.jpg');
  });

  test('links flat episodes via seriesId', () {
    const body = '''
{
  "items": [
    {"id": "show-1", "title": "Show", "kind": "series"},
    {
      "id": "ep1",
      "title": "Pilot",
      "playUrl": "https://example.com/ep1.mp4",
      "seriesId": "show-1",
      "seasonNumber": 1,
      "episodeNumber": 1
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(2));
    expect(parsed.details['show-1']!.seasons.single.episodes.single.id, 'ep1');
  });

  test('expands playVariants and parses headers/segments/audio', () {
    const body = '''
{
  "items": [
    {
      "id": "movie-1",
      "title": "Film",
      "playVariants": [
        {
          "id": "hd",
          "label": "1080p",
          "playUrl": "https://example.com/1080.mp4",
          "resolution": "1080p"
        },
        {
          "id": "uhd",
          "label": "4K",
          "playUrl": "https://example.com/4k.mp4",
          "resolution": "4K",
          "hdr": "HDR10"
        }
      ],
      "httpHeaders": {"Referer": "https://example.com/"},
      "audioTracks": [
        {"url": "https://example.com/ja.mka", "language": "ja", "default": true}
      ],
      "segments": [
        {"type": "intro", "startMs": 1000, "endMs": 5000}
      ],
      "contentRating": "PG",
      "studio": "Blender",
      "tags": "open,demo"
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(2));
    expect(parsed.items.map((e) => e.id), ['hd', 'uhd']);
    expect(parsed.items.first.httpHeaders['Referer'], 'https://example.com/');
    expect(parsed.items.first.audioTracks.single.language, 'ja');
    expect(parsed.items.first.segments.single.type, MediaSegmentType.intro);
    expect(parsed.items.first.contentRating, 'PG');
    expect(parsed.items.first.studio, 'Blender');
    expect(parsed.items.first.tags, ['open', 'demo']);
    expect(parsed.items.last.hdr, 'HDR10');
  });

  test('playVariant audio and subtitle languages override the parent', () {
    const body = '''
{
  "items": [
    {
      "id": "movie-1",
      "title": "Film",
      "audioLanguages": ["en"],
      "playVariants": [
        {
          "id": "ja",
          "label": "Japanese",
          "playUrl": "https://example.com/ja.mp4",
          "audioLanguages": ["ja"],
          "subtitleLanguages": ["en", "fr"]
        },
        {
          "id": "fr",
          "label": "French",
          "playUrl": "https://example.com/fr.mp4",
          "audioLanguages": ["fr"]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(2));
    final ja = parsed.items.firstWhere((e) => e.id == 'ja');
    final fr = parsed.items.firstWhere((e) => e.id == 'fr');
    expect(ja.audioLanguages, ['ja']);
    expect(ja.subtitleLanguages, ['en', 'fr']);
    expect(fr.audioLanguages, ['fr']);
    expect(fr.subtitleLanguages, isEmpty);
  });

  test('parses userAgent and catalog-root playHeaders onto playUrl', () {
    const body = '''
{
  "name": "CDN",
  "userAgent": "MyBridge/1.0",
  "playHeaders": {"Referer": "https://cdn.example.com/"},
  "items": [
    {
      "id": "movie-1",
      "title": "Film",
      "playUrl": "https://cdn.example.com/film.mp4"
    },
    {
      "id": "movie-2",
      "title": "Other",
      "playUrl": "https://cdn.example.com/other.mp4",
      "userAgent": "OtherUA/2",
      "httpHeaders": {"X-Token": "abc"}
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.playHeaders['User-Agent'], 'MyBridge/1.0');
    expect(parsed.playHeaders['Referer'], 'https://cdn.example.com/');
    expect(parsed.items, hasLength(2));
    expect(parsed.items.first.httpHeaders['User-Agent'], 'MyBridge/1.0');
    expect(
      parsed.items.first.httpHeaders['Referer'],
      'https://cdn.example.com/',
    );
    expect(parsed.items.last.httpHeaders['User-Agent'], 'OtherUA/2');
    expect(parsed.items.last.httpHeaders['X-Token'], 'abc');
    expect(
      parsed.items.last.httpHeaders['Referer'],
      'https://cdn.example.com/',
    );
  });

  test('playVariant userAgent overlays item headers', () {
    const body = '''
{
  "items": [
    {
      "id": "movie-1",
      "title": "Film",
      "httpHeaders": {"Referer": "https://example.com/"},
      "playVariants": [
        {
          "id": "hd",
          "label": "1080p",
          "playUrl": "https://example.com/1080.mp4",
          "ua": "VariantUA/1"
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items.single.httpHeaders['User-Agent'], 'VariantUA/1');
    expect(parsed.items.single.httpHeaders['Referer'], 'https://example.com/');
  });

  test('nested episode headers and userAgent reach playVariants', () {
    const body = '''
{
  "userAgent": "CatalogUA/1",
  "items": [
    {
      "id": "show-1",
      "title": "Show",
      "kind": "series",
      "seasons": [
        {
          "seasonNumber": 1,
          "episodes": [
            {
              "id": "ep1",
              "episodeNumber": 1,
              "title": "Pilot",
              "playUrl": "https://cdn.example.com/ep1.mp4",
              "headers": {"Referer": "https://cdn.example.com/ep/"}
            },
            {
              "id": "ep2",
              "episodeNumber": 2,
              "title": "Next",
              "playVariants": [
                {
                  "id": "hd",
                  "label": "1080p",
                  "playUrl": "https://cdn.example.com/ep2.mp4",
                  "userAgent": "EpisodeUA/2"
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items.single.httpHeaders['User-Agent'], 'CatalogUA/1');
    final eps = parsed.details['show-1']!.seasons.single.episodes;
    expect(eps, hasLength(2));
    expect(eps.first.httpHeaders['User-Agent'], 'CatalogUA/1');
    expect(eps.first.httpHeaders['Referer'], 'https://cdn.example.com/ep/');
    expect(
      eps.last.playVariants.single.httpHeaders['User-Agent'],
      'EpisodeUA/2',
    );
    expect(
      eps.last.playVariants.single.httpHeaders['User-Agent'],
      isNot(equals('CatalogUA/1')),
    );
  });

  test('same HLS playUrl in playVariants collapses to one movie row', () {
    const body = '''
{
  "items": [
    {
      "id": "movie-1",
      "title": "Film",
      "playVariants": [
        {
          "id": "hd",
          "label": "1080p",
          "playUrl": "https://cdn.example.com/film.m3u8",
          "resolution": "1080p"
        },
        {
          "id": "uhd",
          "label": "4K",
          "playUrl": "https://cdn.example.com/film.m3u8",
          "resolution": "4K"
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(1));
    expect(parsed.items.single.playUrl, 'https://cdn.example.com/film.m3u8');
    expect(parsed.items.single.resolution, '4K');
  });

  test('parses adult / is_adult flags onto MediaItem.isAdult', () {
    const body = '''
{
  "items": [
    {
      "id": "safe",
      "title": "Safe",
      "playUrl": "https://example.com/safe.mp4",
      "kind": "vod"
    },
    {
      "id": "flagged",
      "title": "Flagged",
      "playUrl": "https://example.com/a.mp4",
      "kind": "vod",
      "adult": true
    },
    {
      "id": "snake",
      "title": "Snake",
      "playUrl": "https://example.com/b.mp4",
      "kind": "vod",
      "is_adult": 1
    },
    {
      "id": "xxx-rating",
      "title": "Rated",
      "playUrl": "https://example.com/c.mp4",
      "kind": "vod",
      "contentRating": "XXX"
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items.firstWhere((e) => e.id == 'safe').isAdult, isFalse);
    expect(parsed.items.firstWhere((e) => e.id == 'flagged').isAdult, isTrue);
    expect(parsed.items.firstWhere((e) => e.id == 'snake').isAdult, isTrue);
    expect(
      parsed.items.firstWhere((e) => e.id == 'xxx-rating').isAdult,
      isTrue,
    );
  });

  test('detects v2 descriptor without items', () {
    const body = '''
{
  "name": "Huge",
  "version": 2,
  "capabilities": ["search", "browse"],
  "itemCount": 100000
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.isQueryApi, isTrue);
    expect(parsed.supportsSearch, isTrue);
    expect(parsed.version, 2);
    expect(parsed.capabilities, ['search', 'browse']);
    expect(parsed.itemCount, 100000);
    expect(parsed.items, isEmpty);
  });

  test('parses catalog root epgUrl for live XMLTV', () {
    const body = '''
{
  "name": "Live TV",
  "version": 2,
  "capabilities": ["browse", "epg"],
  "epgUrl": "https://example.com/epg.xml",
  "items": [
    {
      "id": "ch1",
      "title": "News",
      "kind": "live",
      "playUrl": "https://example.com/news.m3u8",
      "epgChannelId": "news.1"
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.epgUrl, 'https://example.com/epg.xml');
    expect(parsed.capabilities, contains('epg'));
    expect(parsed.items.single.kind, MediaKind.live);
    expect(parsed.items.single.epgChannelId, 'news.1');
  });

  test('catalog epg aliases and relative resolve', () {
    expect(
      catalogEpgUrlFromJson({'epg': 'https://example.com/guide.xml'}),
      'https://example.com/guide.xml',
    );
    expect(
      catalogEpgUrlFromJson({'xmltvUrl': 'https://example.com/tv.xml'}),
      'https://example.com/tv.xml',
    );
    expect(catalogEpgUrlFromJson({'name': 'No guide'}), isNull);
    expect(
      resolveCatalogEpgUrl(
        'epg?region=fr',
        catalogUrl: 'https://example.com/catalogs/live/catalog?region=fr',
      ),
      'https://example.com/catalogs/live/epg?region=fr',
    );
    expect(
      resolveCatalogEpgUrl('https://cdn.example/guide.xml.gz'),
      'https://cdn.example/guide.xml.gz',
    );
  });

  test('v2 without search capability does not support remote search', () {
    const body = '''
{
  "name": "Simple Dump",
  "version": 2,
  "capabilities": ["browse"],
  "items": []
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.isQueryApi, isTrue);
    expect(parsed.supportsSearch, isFalse);
  });

  test('v1 bulk dump does not support remote search', () {
    const body = '''
{
  "name": "ExampleCatalog",
  "version": 1,
  "items": [
    {"id": "1", "title": "Demo", "playUrl": "https://example.com/a.mp4", "kind": "vod"}
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.isQueryApi, isFalse);
    expect(parsed.supportsSearch, isFalse);
  });

  test('parses optional min_version without gating when app is new enough', () {
    const body = '''
{
  "name": "Needs 0.4.3",
  "version": 1,
  "min_version": "0.4.3",
  "items": [
    {"id": "1", "title": "Demo", "playUrl": "https://example.com/a.mp4", "kind": "vod"}
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src', appVersion: '0.4.3+57');
    expect(parsed.minVersion, '0.4.3');
    expect(parsed.items, hasLength(1));
  });

  test('accepts minVersion camelCase alias', () {
    const body = '''
{
  "name": "Huge",
  "version": 2,
  "minVersion": "0.5.0",
  "capabilities": ["search"],
  "itemCount": 10
}
''';
    final parsed = client.parse(body, sourceId: 'src', appVersion: '0.5.1');
    expect(parsed.minVersion, '0.5.0');
    expect(parsed.isQueryApi, isTrue);
  });

  test('omits min_version when the field is missing', () {
    const body = '{"name":"Old","version":1,"items":[]}';
    final parsed = client.parse(body, sourceId: 'src', appVersion: '0.1.0');
    expect(parsed.minVersion, isNull);
  });

  test('throws when the app is older than min_version', () {
    const body = '''
{
  "name": "Needs newer JAVP",
  "version": 2,
  "min_version": "0.5.0",
  "capabilities": ["search"]
}
''';
    expect(
      () => client.parse(body, sourceId: 'src', appVersion: '0.4.3'),
      throwsA(
        isA<CatalogMinVersionException>()
            .having((e) => e.minVersion, 'minVersion', '0.5.0')
            .having((e) => e.appVersion, 'appVersion', '0.4.3')
            .having(
              (e) => e.toString(),
              'message',
              contains('requires JAVP 0.5.0 or later'),
            ),
      ),
    );
  });

  test('0.4.3-dev satisfies min_version 0.4.3', () {
    const body = '''
{"name":"Lib","version":1,"min_version":"0.4.3","items":[]}
''';
    final parsed = client.parse(
      body,
      sourceId: 'src',
      appVersion: '0.4.3-dev+56',
    );
    expect(parsed.minVersion, '0.4.3');
  });

  test('skips min_version check when appVersion is omitted', () {
    const body = '''
{"name":"Lib","version":2,"min_version":"99.0.0","capabilities":["search"]}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.minVersion, '99.0.0');
  });

  test('ignores unparseable min_version', () {
    const body = '''
{"name":"Lib","version":1,"min_version":"latest","items":[]}
''';
    expect(
      () => client.parse(body, sourceId: 'src', appVersion: '0.4.3'),
      returnsNormally,
    );
  });

  test('min_version with +build matches that app build', () {
    const body =
        '{"name":"Lib","version":1,"min_version":"0.4.3+57","items":[]}';
    expect(
      () => client.parse(body, sourceId: 'src', appVersion: '0.4.3+57'),
      returnsNormally,
    );
    expect(
      () => client.parse(body, sourceId: 'src', appVersion: '0.4.3'),
      throwsA(isA<CatalogMinVersionException>()),
    );
  });

  test('compareJavpVersions orders pubspec-style versions', () {
    expect(compareJavpVersions('0.4.3', '0.4.2'), greaterThan(0));
    expect(compareJavpVersions('0.4.2', '0.4.3'), lessThan(0));
    expect(compareJavpVersions('0.4.3', '0.4.3'), 0);
    expect(compareJavpVersions('0.4.3+57', '0.4.3'), 0);
    expect(compareJavpVersions('0.4.3+57', '0.4.3+57'), 0);
    expect(compareJavpVersions('0.4.3', '0.4.3+57'), lessThan(0));
    expect(compareJavpVersions('0.4.3+56', '0.4.3+57'), lessThan(0));
    expect(compareJavpVersions('0.5.0', '0.4.9'), greaterThan(0));
    expect(compareJavpVersions('1.0.0', '0.9.9'), greaterThan(0));
    expect(compareJavpVersions('0.4', '0.4.0'), 0);
  });

  test('fetchRoot throws CatalogMinVersionException when too old', () async {
    final httpClient = MockClient((_) async {
      return http.Response(
        '{"name":"Private","version":2,"min_version":"0.9.0","capabilities":["search"]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    await expectLater(
      catalog.fetchRoot(
        'https://premium.example/catalog',
        sourceId: 'src',
        appVersion: '0.4.3',
      ),
      throwsA(isA<CatalogMinVersionException>()),
    );
  });

  test('throws CatalogUnsupportedException when platforms do not match', () {
    const body = '''
{"name":"TV only","version":2,"platforms":["tizen","webos"],"capabilities":["search"]}
''';
    expect(
      () => client.parse(
        body,
        sourceId: 'src',
        profile: const CatalogClientProfile(
          appVersion: '0.4.3',
          platform: 'linux',
          device: 'desktop',
        ),
      ),
      throwsA(
        isA<CatalogUnsupportedException>().having(
          (e) => e.reason,
          'reason',
          CatalogClientMismatch.platform,
        ),
      ),
    );
  });

  test('throws when catalog requires torrents on a TV without them', () {
    const body = '''
{"name":"P2P","version":1,"requires":["torrents"],"items":[]}
''';
    expect(
      () => client.parse(
        body,
        sourceId: 'src',
        profile: const CatalogClientProfile(platform: 'tizen', device: 'tv'),
      ),
      throwsA(isA<CatalogUnsupportedException>()),
    );
  });

  test('skips items and variants that are gated for this client', () {
    const body = '''
{
  "name": "Mixed",
  "version": 1,
  "sources": [
    {"id": "http"},
    {"id": "p2p", "requires": ["torrents"]}
  ],
  "items": [
    {"id": "http-only", "title": "HTTP", "playUrl": "https://cdn.example/a.mp4", "source": "http"},
    {"id": "p2p-only", "title": "Torrent", "playUrl": "magnet:?xt=urn:btih:abc", "source": "p2p"},
    {
      "id": "both",
      "title": "Both",
      "playVariants": [
        {"id": "h", "label": "HTTP", "playUrl": "https://cdn.example/b.mp4", "source": "http"},
        {"id": "t", "label": "Torrent", "playUrl": "magnet:?xt=urn:btih:def", "source": "p2p"}
      ]
    },
    {"id": "tv-only", "title": "TV", "playUrl": "https://cdn.example/tv.mp4", "platforms": ["tv"]}
  ]
}
''';
    const tvNoTorrents = CatalogClientProfile(
      appVersion: '0.4.3',
      platform: 'tizen',
      device: 'tv',
    );
    final parsed = client.parse(body, sourceId: 'src', profile: tvNoTorrents);
    final ids = parsed.items.map((i) => i.id).toSet();
    expect(ids, containsAll(['http-only', 'h']));
    expect(ids, isNot(contains('p2p-only')));
    expect(ids, isNot(contains('t')));
    expect(ids, contains('tv-only'));
    expect(parsed.namedSources, hasLength(2));
  });

  test('skips magnet playUrls when the client has no torrents', () {
    const body = '''
{
  "name": "Lib",
  "version": 1,
  "items": [
    {"id": "m", "title": "Magnet", "playUrl": "magnet:?xt=urn:btih:abc"},
    {"id": "h", "title": "HTTP", "playUrl": "https://cdn.example/a.mp4"}
  ]
}
''';
    final parsed = client.parse(
      body,
      sourceId: 'src',
      profile: const CatalogClientProfile(platform: 'tizen', device: 'tv'),
    );
    expect(parsed.items.map((i) => i.id), ['h']);
  });

  test('keeps magnets when torrents capability is present', () {
    const body = '''
{"name":"Lib","version":1,"items":[{"id":"m","title":"Magnet","playUrl":"magnet:?xt=urn:btih:abc"}]}
''';
    final parsed = client.parse(
      body,
      sourceId: 'src',
      profile: const CatalogClientProfile(
        platform: 'android',
        device: 'mobile',
        capabilities: ['torrents'],
      ),
    );
    expect(parsed.items, hasLength(1));
  });

  test(
    'keeps android-gated magnets on Windows when torrents are advertised',
    () {
      const body = '''
{
  "name": "Mixed",
  "version": 1,
  "sources": [
    {"id": "p2p", "requires": ["torrents"], "platforms": ["android"]}
  ],
  "items": [
    {"id": "ep1", "title": "Episode 1", "playUrl": "magnet:?xt=urn:btih:abc", "source": "p2p"}
  ]
}
''';
      final parsed = client.parse(
        body,
        sourceId: 'src',
        profile: const CatalogClientProfile(
          platform: 'windows',
          device: 'desktop',
          capabilities: ['torrents'],
        ),
      );
      expect(parsed.items.map((i) => i.id), ['ep1']);
    },
  );

  test('skips item min_version without failing the catalog', () {
    const body = '''
{
  "name": "Lib",
  "version": 1,
  "items": [
    {"id": "old", "title": "Old", "playUrl": "https://cdn.example/a.mp4"},
    {"id": "new", "title": "New", "playUrl": "https://cdn.example/b.mp4", "min_version": "0.9.0"}
  ]
}
''';
    final parsed = client.parse(
      body,
      sourceId: 'src',
      profile: const CatalogClientProfile(
        appVersion: '0.4.3',
        platform: 'android',
        device: 'mobile',
      ),
    );
    expect(parsed.items.map((i) => i.id), ['old']);
  });

  test('fetchRoot sends client identity headers and query', () async {
    Uri? seen;
    Map<String, String>? seenHeaders;
    final httpClient = MockClient((request) async {
      seen = request.url;
      seenHeaders = request.headers;
      return http.Response(
        '{"name":"Lib","version":2,"capabilities":["search"]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(
      httpClient: httpClient,
      profile: const CatalogClientProfile(
        appVersion: '0.4.3+57',
        platform: 'android',
        device: 'tv',
        capabilities: ['torrents'],
      ),
    );
    await catalog.fetchRoot('https://premium.example/catalog', sourceId: 'src');
    expect(seen!.queryParameters['javp_platform'], 'android');
    expect(seen!.queryParameters['javp_device'], 'tv');
    expect(seen!.queryParameters['javp_version'], '0.4.3+57');
    expect(seen!.queryParameters['javp_capabilities'], 'torrents');
    expect(seenHeaders!['X-JAVP-Platform'], 'android');
    expect(seenHeaders!['X-JAVP-Device'], 'tv');
    expect(seenHeaders!['X-JAVP-Capabilities'], contains('torrents'));
  });

  test('fetchRoot appends identity without rewriting signed query', () async {
    late String rawUrl;
    final httpClient = MockClient((request) async {
      rawUrl = request.url.toString();
      return http.Response(
        '{"name":"Lib","version":2,"capabilities":["search"]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(
      httpClient: httpClient,
      profile: const CatalogClientProfile(
        appVersion: '0.4.3+57',
        platform: 'android',
        device: 'mobile',
      ),
    );
    await catalog.fetchRoot(
      'https://premium.example/catalog?token=a+b/c&sig=1',
      sourceId: 'src',
    );
    expect(rawUrl, contains('token=a+b/c'));
    expect(rawUrl, contains('sig=1'));
    expect(rawUrl, contains('javp_version='));
  });

  test('keeps series shells without playUrl', () {
    const body = '''
{
  "version": 2,
  "capabilities": ["search"],
  "items": [
    {
      "id": "s1",
      "title": "Shell Show",
      "kind": "series",
      "posterUrl": "https://example.com/p.jpg"
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(1));
    expect(parsed.items.single.kind, MediaKind.series);
    expect(parsed.items.single.playUrl, isEmpty);
  });

  test('series shell ignores playVariants; seasons drive episode UI', () {
    const body = '''
{
  "items": [
    {
      "id": "anilist-154587",
      "title": "Sample Anime",
      "kind": "series",
      "anilistId": 154587,
      "playUrl": "magnet:?xt=urn:btih:shell",
      "playVariants": [
        {"id": "batch", "label": "1080p", "playUrl": "magnet:?xt=urn:btih:batch"}
      ],
      "seasons": [
        {
          "seasonNumber": 1,
          "episodes": [
            {
              "id": "anilist-154587-s1e1",
              "episodeNumber": 1,
              "title": "The Journey's End",
              "playUrl": "magnet:?xt=urn:btih:batch",
              "torrentFile": "Sample Anime - 01",
              "playVariants": [
                {
                  "id": "groupa",
                  "label": "GroupA · 1080p",
                  "playUrl": "magnet:?xt=urn:btih:groupa",
                  "resolution": "1080p"
                },
                {
                  "id": "groupb",
                  "label": "GroupB · 1080p",
                  "playUrl": "magnet:?xt=urn:btih:groupb",
                  "resolution": "1080p"
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    expect(parsed.items, hasLength(1));
    final shell = parsed.items.single;
    expect(shell.kind, MediaKind.series);
    expect(shell.playUrl, isEmpty);
    expect(shell.anilistId, 154587);
    final details = parsed.details['anilist-154587']!;
    expect(details.anilistId, 154587);
    expect(details.seasons, hasLength(1));
    expect(details.seasons.single.episodes, hasLength(1));
    expect(
      details.seasons.single.episodes.single.playUrl,
      contains('btih:batch'),
    );
    expect(details.seasons.single.episodes.single.torrentFile, 'Sample Anime - 01');
    expect(details.seasons.single.episodes.single.playVariants, hasLength(2));
    expect(
      details.seasons.single.episodes.single.playVariants.first.label,
      contains('GroupA'),
    );
  });

  test('episode playVariants with the same HLS url collapse', () {
    const body = '''
{
  "items": [
    {
      "id": "show-1",
      "title": "Show",
      "kind": "series",
      "seasons": [
        {
          "seasonNumber": 1,
          "episodes": [
            {
              "id": "ep1",
              "episodeNumber": 1,
              "title": "Pilot",
              "playVariants": [
                {
                  "id": "hd",
                  "label": "1080p",
                  "playUrl": "https://cdn.example.com/e1.m3u8",
                  "resolution": "1080p"
                },
                {
                  "id": "uhd",
                  "label": "4K",
                  "playUrl": "https://cdn.example.com/e1.m3u8",
                  "resolution": "4K"
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    final ep = parsed.details['show-1']!.seasons.single.episodes.single;
    expect(ep.playVariants, hasLength(1));
    expect(ep.playVariants.single.playUrl, contains('e1.m3u8'));
  });

  test('parses episode stubs without playUrl for progressive detail', () {
    const body = '''
{
  "items": [
    {
      "id": "anilist-154587",
      "title": "Sample Anime",
      "kind": "series",
      "plot": "A journey",
      "cast": [{"name": "Sample Anime"}],
      "seasons": [
        {
          "seasonNumber": 1,
          "episodes": [
            {
              "id": "anilist-154587-s1e1",
              "episodeNumber": 1,
              "title": "The Journey's End"
            },
            {
              "id": "anilist-154587-s1e2",
              "episodeNumber": 2,
              "title": "It… Has to Be an Illusion"
            }
          ]
        }
      ]
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'src');
    final details = parsed.details['anilist-154587']!;
    expect(details.plot, 'A journey');
    expect(details.cast.single.name, 'Sample Anime');
    expect(details.seasons.single.episodes, hasLength(2));
    expect(details.seasons.single.episodes.first.playUrl, isNull);
    expect(details.seasons.single.episodes.first.playVariants, isEmpty);
    expect(details.seasons.single.episodes.first.id, 'anilist-154587-s1e1');
  });

  test('resolves query endpoints under /catalog descriptor URLs', () {
    expect(
      client
          .resolveEndpoint('https://catalog.example/catalog/catalog', '/search')
          .toString(),
      'https://catalog.example/catalog/search',
    );
    expect(
      client
          .resolveEndpoint('https://catalog.example/catalog/catalog/', '/browse')
          .toString(),
      'https://catalog.example/catalog/browse',
    );
    expect(
      client.resolveEndpoint('https://catalog.example/catalog', '/search').toString(),
      'https://catalog.example/catalog/search',
    );
    expect(
      client
          .resolveEndpoint('https://example.com/api/catalog.json', '/groups')
          .toString(),
      'https://example.com/api/groups',
    );
    expect(
      client
          .resolveEndpoint('https://catalog.example/catalog/catalog', '/items/anilist-21')
          .toString(),
      'https://catalog.example/catalog/items/anilist-21',
    );
  });

  test('fetchItem passes locale on progressive episode resolve', () async {
    late Uri seen;
    final httpClient = MockClient((request) async {
      seen = request.url;
      return http.Response(
        '{"id":"ep-1","title":"Ep 1","playUrl":"magnet:?xt=urn:btih:abc","kind":"vod"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    final result = await catalog.fetchItem(
      baseUrl: 'https://catalog.example/catalog/catalog',
      sourceId: 'src',
      id: 'anilist-21-s1e1',
      locale: 'fr',
    );
    expect(result, isNotNull);
    expect(result!.item.playUrl, startsWith('magnet:'));
    expect(seen.path, '/catalog/items/anilist-21-s1e1');
    expect(seen.queryParameters['locale'], 'fr');
  });

  test('fetchItem advertises torrent capabilities on Windows', () async {
    late Uri seen;
    final httpClient = MockClient((request) async {
      seen = request.url;
      return http.Response(
        '{"id":"ep-1","title":"Ep 1","playUrl":"magnet:?xt=urn:btih:abc"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(
      httpClient: httpClient,
      profile: const CatalogClientProfile(
        platform: 'windows',
        device: 'desktop',
        capabilities: ['torrents'],
      ),
    );
    final result = await catalog.fetchItem(
      baseUrl: 'https://catalog.example/catalog/catalog',
      sourceId: 'src',
      id: 'ep-1',
    );
    expect(result, isNotNull);
    expect(result!.item.playUrl, startsWith('magnet:'));
    expect(seen.queryParameters['javp_platform'], 'windows');
    expect(seen.queryParameters['javp_capabilities'], 'torrents');
  });

  test('fetchItem surfaces catalog error when playUrl is missing', () async {
    final httpClient = MockClient((request) async {
      return http.Response(
        '{"error":"unable to create url for the episode"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    expect(
      () => catalog.fetchItem(
        baseUrl: 'https://host/catalog',
        sourceId: 'src',
        id: 'ep-1',
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('unable to create url for the episode'),
        ),
      ),
    );
  });

  test('authHeaders builds Bearer and preserves existing Bearer prefix', () {
    expect(CustomCatalogClient.authHeaders(null), isNull);
    expect(CustomCatalogClient.authHeaders(''), isNull);
    expect(CustomCatalogClient.authHeaders('secret-key'), {
      'Authorization': 'Bearer secret-key',
    });
    expect(CustomCatalogClient.authHeaders('Bearer already'), {
      'Authorization': 'Bearer already',
    });
  });

  test('fetchRoot sends Authorization when headers are provided', () async {
    late http.BaseRequest seen;
    final httpClient = MockClient((request) async {
      seen = request;
      return http.Response(
        '{"name":"Private","version":2,"capabilities":["search"],"items":[]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    await catalog.fetchRoot(
      'https://premium.example/catalog',
      sourceId: 'src',
      headers: CustomCatalogClient.authHeaders('tok_abc'),
    );
    expect(seen.headers['Authorization'], 'Bearer tok_abc');
  });

  test('fetchRoot playHeaders are inherited by fetchItem', () async {
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/catalog') ||
          request.url.path == '/catalog') {
        return http.Response(
          jsonEncode({
            'name': 'CDN',
            'version': 2,
            'capabilities': ['search'],
            'userAgent': 'CatalogUA/1',
            'playHeaders': {'Referer': 'https://cdn.example.com/'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'movie-1',
          'title': 'Film',
          'playUrl': 'https://cdn.example.com/film.mp4',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    await catalog.fetchRoot('https://host/catalog', sourceId: 'src');
    final item = await catalog.fetchItem(
      baseUrl: 'https://host/catalog',
      sourceId: 'src',
      id: 'movie-1',
    );
    expect(item, isNotNull);
    expect(item!.item.httpHeaders['User-Agent'], 'CatalogUA/1');
    expect(item.item.httpHeaders['Referer'], 'https://cdn.example.com/');
  });

  test('search and episodes include locale query', () async {
    final seen = <Uri>[];
    final httpClient = MockClient((request) async {
      seen.add(request.url);
      if (request.url.path.endsWith('/episodes')) {
        return http.Response('{"season":1,"episodes":[]}', 200);
      }
      return http.Response(
        '{"items":[],"page":1,"limit":50,"total":0}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    await catalog.search(
      baseUrl: 'https://host/api/catalog',
      sourceId: 'src',
      query: 'bunny',
      locale: 'ja',
    );
    await catalog.fetchEpisodes(
      baseUrl: 'https://host/api/catalog',
      id: 'show-1',
      season: 2,
      locale: 'ja',
    );
    expect(seen[0].queryParameters['locale'], 'ja');
    expect(seen[0].queryParameters['q'], 'bunny');
    expect(seen[1].queryParameters['locale'], 'ja');
    expect(seen[1].queryParameters['season'], '2');
    expect(seen[1].queryParameters.containsKey('resolve'), isFalse);
  });

  test(
    'fetchEpisodes resolve=1 sends capped limit and parses magnets',
    () async {
      final seen = <Uri>[];
      final httpClient = MockClient((request) async {
        seen.add(request.url);
        return http.Response(
          jsonEncode({
            'season': 1,
            'resolved': true,
            'episodes': [
              {
                'id': 'anilist-1-s1e1',
                'episodeNumber': 1,
                'title': 'Ep 1',
                'playUrl': 'magnet:?xt=urn:btih:abc',
              },
              {
                'id': 'anilist-1-s1e2',
                'episodeNumber': 2,
                'title': 'Ep 2',
                'playUrl': 'magnet:?xt=urn:btih:def',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final catalog = CustomCatalogClient(httpClient: httpClient);
      final seasons = await catalog.fetchEpisodes(
        baseUrl: 'https://catalog.example/catalog',
        id: 'anilist-1',
        season: 1,
        locale: 'fr',
        resolve: true,
        limit: 12,
      );
      expect(seen.single.queryParameters['locale'], 'fr');
      expect(seen.single.queryParameters['season'], '1');
      expect(seen.single.queryParameters['resolve'], '1');
      expect(seen.single.queryParameters['limit'], '12');
      expect(seasons, hasLength(1));
      expect(seasons.first.episodes, hasLength(2));
      expect(seasons.first.episodes.first.playUrl, startsWith('magnet:'));
      expect(seasons.first.episodes[1].playUrl, startsWith('magnet:'));
    },
  );

  test('fetchEpisodes resolve limit is hard-capped at 24', () async {
    Uri? seen;
    final httpClient = MockClient((request) async {
      seen = request.url;
      return http.Response('{"season":1,"episodes":[]}', 200);
    });
    final catalog = CustomCatalogClient(httpClient: httpClient);
    await catalog.fetchEpisodes(
      baseUrl: 'https://host/api',
      id: 'show',
      season: 1,
      resolve: true,
      limit: 999,
      offset: 40,
    );
    expect(seen!.queryParameters['resolve'], '1');
    expect(seen!.queryParameters['limit'], '24');
    expect(seen!.queryParameters['offset'], '40');
  });

  test('search 404 throws CatalogSearchUnsupportedException', () async {
    final httpClient = MockClient((_) async => http.Response('not found', 404));
    final catalog = CustomCatalogClient(httpClient: httpClient);
    await expectLater(
      catalog.search(
        baseUrl: 'https://host/api',
        sourceId: 'src',
        query: 'bunny',
      ),
      throwsA(isA<CatalogSearchUnsupportedException>()),
    );
  });

  test('reads anilistId from anilist- prefixed catalog id', () {
    const body = '''
{
  "items": [
    {
      "id": "anilist-201817",
      "title": "Always a Catch!",
      "kind": "series",
      "year": 2026,
      "posterUrl": "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx201817.jpg"
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'customcat');
    expect(parsed.items.single.anilistId, 201817);
    expect(parsed.details['anilist-201817']!.anilistId, 201817);
  });

  test('reads tmdbId from string field, alias, nested ids, and tmdb: tag', () {
    const body = '''
{
  "items": [
    {
      "id": "anilist-201817",
      "title": "Always a Catch!",
      "kind": "series",
      "tmdbId": "304820",
      "tags": ["mal:62893"]
    },
    {
      "id": "show-2",
      "title": "Other",
      "kind": "series",
      "tmdb_id": 99
    },
    {
      "id": "show-3",
      "title": "Tagged",
      "kind": "series",
      "tags": ["tmdb:12345"]
    },
    {
      "id": "show-4",
      "title": "US| SampleTitle {tmdb-550}",
      "kind": "vod",
      "playUrl": "https://cdn.example/a.mp4",
      "ids": { "tmdb": 550, "imdb": "tt1375666" }
    },
    {
      "id": "movie-tmdb-64-fr",
      "title": "FR| Drive",
      "kind": "vod",
      "playUrl": "https://cdn.example/b.mp4"
    }
  ]
}
''';
    final parsed = client.parse(body, sourceId: 'customcat');
    expect(parsed.items[0].tmdbId, 304820);
    expect(parsed.items[1].tmdbId, 99);
    expect(parsed.items[2].tmdbId, 12345);
    expect(parsed.items[3].tmdbId, 550);
    expect(parsed.items[3].imdbId, 'tt1375666');
    expect(parsed.items[4].tmdbId, 64);
  });

  test('parses popularity heat and inverted popularityRank', () {
    const body = '''
[
  {"id": "a", "title": "A", "playUrl": "https://x/a", "popularity": 9000},
  {"id": "b", "title": "B", "playUrl": "https://x/b", "heat": 12.5},
  {"id": "c", "title": "C", "playUrl": "https://x/c", "popularityRank": 2},
  {"id": "d", "title": "D", "playUrl": "https://x/d", "popularity": 5, "popularityRank": 1},
  {"id": "e", "title": "E", "playUrl": "https://x/e", "rank": 1},
  {"id": "f", "title": "F", "playUrl": "https://x/f", "popularity": -3},
  {"id": "g", "title": "G", "playUrl": "https://x/g", "pop": "80"}
]
''';
    final parsed = client.parse(body, sourceId: 'src');
    MediaItem byId(String id) => parsed.items.firstWhere((e) => e.id == id);
    expect(byId('a').popularity, 9000);
    expect(byId('b').popularity, 12.5);
    expect(byId('c').popularity, closeTo(0.5, 1e-9));
    expect(byId('d').popularity, 5);
    expect(byId('e').popularity, isNull);
    expect(byId('f').popularity, isNull);
    expect(byId('g').popularity, 80);
  });

  test('parseCatalogBodyInIsolate matches in-process parse', () async {
    const body = '''
{
  "name": "Iso Shelf",
  "items": [
    {"id": "a", "title": "Alpha", "playUrl": "https://x/a"},
    {"id": "b", "title": "Beta", "playUrl": "https://x/b"}
  ]
}
''';
    final direct = client.parse(body, sourceId: 'src');
    final isolated = await parseCatalogBodyInIsolate(
      utf8.encode(body),
      sourceId: 'src',
    );
    expect(isolated.name, direct.name);
    expect(isolated.items.map((e) => e.id), direct.items.map((e) => e.id));
    expect(isolated.items.map((e) => e.title), ['Alpha', 'Beta']);
    expect(isolated.vod, isNull);
  });

  test('parseCatalogBodyInIsolate packs a large dump as SQL maps', () async {
    final items = [
      for (var i = 0; i < 1500; i++)
        '{"id":"t$i","title":"Title $i","playUrl":"https://x/$i"}',
    ].join(',');
    final body = '{"name":"Big Shelf","items":[$items]}';
    expect(utf8.encode(body).length, greaterThan(64 * 1024));
    final isolated = await parseCatalogBodyInIsolate(
      utf8.encode(body),
      sourceId: 'src',
    );
    expect(isolated.name, 'Big Shelf');
    expect(isolated.items, isEmpty);
    expect(isolated.vod, isNotNull);
    expect(isolated.vod!.vodCount, 1500);
    expect(isolated.vod!.rows.first['title'], 'Title 0');
    expect(isolated.vod!.rows.last['title'], 'Title 1499');
  });
}
