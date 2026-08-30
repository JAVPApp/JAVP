import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/iptv/live_ingest_plan.dart';
import 'package:javp/services/iptv/xtream_client.dart';

import 'package:javp/services/iptv/xtream_client.dart';

XtreamClient xtreamTestClient(MockClient httpClient) => XtreamClient(
  httpClient: httpClient,
  debugForwardDumpBytesToWorker: true,
);

void main() {
  final source = IptvSource(
    id: 'src-1',
    name: 'Test',
    type: IptvSourceType.xtream,
    createdAt: DateTime.utc(2026, 1, 1),
    serverUrl: 'http://example.com',
    alternateServerUrl: 'http://fallback.example.com',
    username: 'user',
    password: 'pass',
  );

  test('syncCatalog maps categories, catchup, and epg tvg-id', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == null) {
          return http.Response(
            jsonEncode({
              'user_info': {'auth': 1, 'status': 'Active'},
              'server_info': {'url': 'example.com'},
            }),
            200,
          );
        }
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {
                'category_id': '11',
                'category_name': 'AR | ART',
                'parent_id': 0,
              },
            ]),
            200,
          );
        }
        if (action == 'get_vod_categories' ||
            action == 'get_series_categories') {
          return http.Response(jsonEncode([]), 200);
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'ART| ALKASS 2 HD',
                'stream_id': 22807,
                'stream_icon': 'https://img/a.png',
                'epg_channel_id': 'alkasstwo.qa',
                'category_id': '11',
                'tv_archive': 1,
                'tv_archive_duration': '2',
                'container_extension': 'ts',
              },
              {
                'name': 'No EPG',
                'stream_id': 1,
                'category_id': '11',
                'tv_archive': 0,
                'tv_archive_duration': 0,
                'epg_channel_id': null,
              },
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
    }));

    final result = await client.syncCatalog(source);
    expect(result.live, hasLength(2));
    expect(result.epgUrl, contains('/xmltv.php?'));

    final catchup = result.live.firstWhere((c) => c.streamId == '22807');
    expect(catchup.supportsCatchup, isTrue);
    expect(catchup.catchupDays, 2);
    expect(catchup.epgChannelId, 'alkasstwo.qa');
    expect(catchup.group, 'AR | ART');
    expect(catchup.playUrl, contains('/live/22807.ts'));
    expect(catchup.playUrl, isNot(contains('/live/user/pass/')));

    final plain = result.live.firstWhere((c) => c.streamId == '1');
    expect(plain.supportsCatchup, isFalse);
    expect(plain.epgChannelId, isNull);
  });

  test('loadCategoryLivePacked writes SQL maps without MediaItems', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'News 1',
                'stream_id': 9,
                'stream_icon': 'https://img/n.png',
                'epg_channel_id': 'news.tv',
                'category_id': '11',
                'tv_archive': 1,
                'tv_archive_duration': '3',
                'container_extension': 'ts',
              },
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
    }));

    final packed = await client.loadCategoryLivePacked(
      source,
      category: IptvCategory(
        id: '11',
        name: 'News',
        kind: IptvCategoryKind.live,
        sourceId: source.id,
      ),
    );
    expect(packed, hasLength(1));
    expect(packed.single['id'], 'xtream-live-${source.id}-9');
    expect(packed.single['title'], 'News 1');
    expect(packed.single['group_name'], 'News');
    expect(packed.single['catchup_days'], 3);
    expect(packed.single['epg_channel_id'], 'news.tv');
    expect('${packed.single['play_url']}', contains('/live/9.ts'));
    expect(
      packed.single.keys.toSet().difference(liveChannelSqlColumns),
      isEmpty,
      reason: 'sqflite INSERT treats extra keys as columns',
    );
    expect(packed.single.containsKey('subtitle'), isFalse);
    expect(packed.single.containsKey('extra_json'), isFalse);
  });

  test('syncCatalog includeLiveStreams:false skips get_live_streams', () async {
    final actions = <String?>[];
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        actions.add(action);
        if (action == null) {
          return http.Response(
            jsonEncode({
              'user_info': {'auth': 1, 'status': 'Active'},
              'server_info': {'url': 'example.com'},
            }),
            200,
          );
        }
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '11', 'category_name': 'News', 'parent_id': 0},
            ]),
            200,
          );
        }
        if (action == 'get_vod_categories' ||
            action == 'get_series_categories') {
          return http.Response(jsonEncode([]), 200);
        }
        if (action == 'get_live_streams') {
          fail('get_live_streams should not be called');
        }
        return http.Response('[]', 200);
    }));

    final result = await client.syncCatalog(source, includeLiveStreams: false);
    expect(result.live, isEmpty);
    expect(result.liveCategories, hasLength(1));
    expect(result.liveCategories.first.name, 'News');
    expect(result.epgUrl, contains('/xmltv.php?'));
    expect(actions, isNot(contains('get_live_streams')));
  });

  test('epgCandidateUrls prefers epgZip before xmltv.php', () {
    final client = XtreamClient(
      httpClient: MockClient((_) async {
        return http.Response('{}', 200);
    }));
    final urls = client.epgCandidateUrls(source);
    expect(urls, hasLength(2));
    expect(urls.first, 'http://example.com/epgZip.xml');
    expect(urls.last, contains('/xmltv.php?'));
  });

  test('syncCatalog maps is_adult on categories and streams', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == null) {
          return http.Response(
            jsonEncode({
              'user_info': {'auth': 1, 'status': 'Active'},
              'server_info': {'url': 'example.com'},
            }),
            200,
          );
        }
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {
                'category_id': '1',
                'category_name': 'News',
                'parent_id': 0,
                'is_adult': 0,
              },
              {
                'category_id': '99',
                'category_name': 'Adult',
                'parent_id': 0,
                'is_adult': '1',
              },
            ]),
            200,
          );
        }
        if (action == 'get_vod_categories' ||
            action == 'get_series_categories') {
          return http.Response(jsonEncode([]), 200);
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'NewsNet',
                'stream_id': 10,
                'category_id': '1',
                'is_adult': 0,
                'container_extension': 'ts',
              },
              {
                'name': 'Flagged stream',
                'stream_id': 11,
                'category_id': '1',
                'is_adult': 1,
                'container_extension': 'ts',
              },
              {
                'name': 'Adult cat stream',
                'stream_id': 12,
                'category_id': '99',
                'is_adult': 0,
                'container_extension': 'ts',
              },
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
    }));

    final result = await client.syncCatalog(source);
    expect(
      result.liveCategories.firstWhere((c) => c.id == '99').isAdult,
      isTrue,
    );
    expect(
      result.liveCategories.firstWhere((c) => c.id == '1').isAdult,
      isFalse,
    );
    expect(result.live.firstWhere((c) => c.streamId == '10').isAdult, isFalse);
    expect(result.live.firstWhere((c) => c.streamId == '11').isAdult, isTrue);
    // Category-level is_adult marks all streams in that category.
    expect(result.live.firstWhere((c) => c.streamId == '12').isAdult, isTrue);
  });

  test('fetchChannelEpg prefers get_short_epg then falls back', () async {
    final title = base64.encode(utf8.encode('Evening News'));
    var calls = 0;
    final client = xtreamTestClient(MockClient((request) async {
        calls++;
        final action = request.url.queryParameters['action'];
        if (action == 'get_short_epg') {
          return http.Response(jsonEncode({'epg_listings': []}), 200);
        }
        expect(action, 'get_simple_data_table');
        return http.Response(
          jsonEncode({
            'epg_listings': [
              {
                'id': 1,
                'title': title,
                'description': '',
                'channel_id': 'alkasstwo.qa',
                'start_timestamp': 1785790800,
                'stop_timestamp': 1785792600,
                'has_archive': 1,
              },
            ],
          }),
          200,
        );
    }));

    final programs = await client.fetchChannelEpg(source, streamId: '22807');
    expect(calls, 2);
    expect(programs, hasLength(1));
    expect(programs.first.title, 'Evening News');
    expect(programs.first.channelId, 'alkasstwo.qa');
    expect(programs.first.hasArchive, isTrue);
    expect(programs.first.duration, const Duration(minutes: 30));
  });

  test('fetchChannelEpg uses short epg when present', () async {
    final title = base64.encode(utf8.encode('JT 20h'));
    final client = xtreamTestClient(MockClient((request) async {
        expect(request.url.queryParameters['action'], 'get_short_epg');
        expect(request.url.queryParameters['limit'], '24');
        return http.Response(
          jsonEncode({
            'epg_listings': [
              {
                'id': 9,
                'title': title,
                'description': '',
                'channel_id': 'channela.fr',
                'start_timestamp': 1786212000,
                'stop_timestamp': 1786214700,
                'has_archive': 0,
              },
            ],
          }),
          200,
        );
    }));

    final programs = await client.fetchChannelEpg(source, streamId: '154');
    expect(programs, hasLength(1));
    expect(programs.first.title, 'JT 20h');
  });

  test(
    'fetchChannelEpg preferArchive merges short + simple data table',
    () async {
      final shortTitle = base64.encode(utf8.encode('Now Show'));
      final pastTitle = base64.encode(utf8.encode('Past Show'));
      final actions = <String>[];
      final client = XtreamClient(
        httpClient: MockClient((request) async {
          final action = request.url.queryParameters['action']!;
          actions.add(action);
          if (action == 'get_short_epg') {
            return http.Response(
              jsonEncode({
                'epg_listings': [
                  {
                    'id': 2,
                    'title': shortTitle,
                    'description': '',
                    'channel_id': 'channela.fr',
                    'start_timestamp': 1786212000,
                    'stop_timestamp': 1786214700,
                    'has_archive': 0,
                  },
                ],
              }),
              200,
            );
          }
          expect(action, 'get_simple_data_table');
          return http.Response(
            jsonEncode({
              'epg_listings': [
                {
                  'id': 1,
                  'title': pastTitle,
                  'description': '',
                  'channel_id': 'channela.fr',
                  'start_timestamp': 1785790800,
                  'stop_timestamp': 1785792600,
                  'has_archive': 1,
                },
                {
                  'id': 2,
                  'title': shortTitle,
                  'description': 'From archive',
                  'channel_id': 'channela.fr',
                  'start_timestamp': 1786212000,
                  'stop_timestamp': 1786214700,
                  'has_archive': 1,
                },
              ],
            }),
            200,
          );
        }),
      );

      final programs = await client.fetchChannelEpg(
        source,
        streamId: '154',
        preferArchive: true,
      );
      expect(actions, ['get_short_epg', 'get_simple_data_table']);
      expect(programs, hasLength(2));
      expect(programs.first.title, 'Past Show');
      expect(programs.first.hasArchive, isTrue);
      expect(programs.last.title, 'Now Show');
      expect(programs.last.hasArchive, isTrue);
      expect(programs.last.description, 'From archive');
    },
  );

  test('mergeEpgPrograms keeps richer duplicate', () {
    final a = EpgProgram(
      channelId: 'ch',
      title: 'Show',
      start: DateTime.utc(2026, 1, 1, 12),
      end: DateTime.utc(2026, 1, 1, 13),
    );
    final b = EpgProgram(
      channelId: 'ch',
      title: 'Show',
      start: DateTime.utc(2026, 1, 1, 12),
      end: DateTime.utc(2026, 1, 1, 13),
      description: 'Desc',
      hasArchive: true,
      imageUrl: 'https://img/x.png',
    );
    final merged = XtreamClient.mergeEpgPrograms([a], [b]);
    expect(merged, hasLength(1));
    expect(merged.single.hasArchive, isTrue);
    expect(merged.single.description, 'Desc');
  });

  test('loadCategoryStreams filters by category_id', () async {
    final client = xtreamTestClient(MockClient((request) async {
        expect(request.url.queryParameters['category_id'], '1016');
        return http.Response(
          jsonEncode([
            {
              'name': 'Movie A',
              'stream_id': 9,
              'category_id': '1016',
              'container_extension': 'mkv',
            },
          ]),
          200,
        );
    }));

    final items = await client.loadCategoryStreams(
      source,
      category: const IptvCategory(
        id: '1016',
        name: 'IT| Cinema',
        kind: IptvCategoryKind.vod,
      ),
    );
    expect(items, hasLength(1));
    expect(items.first.group, 'IT| Cinema');
    expect(items.first.playUrl, contains('/movie/9.mkv'));
    expect(items.first.playUrl, isNot(contains('/movie/user/pass/')));
  });

  test('catchupUrl prefers progressive; candidates lead with HLS VOD', () {
    final client = XtreamClient(
      httpClient: MockClient((_) async {
        return http.Response('{}', 200);
    }));
    final start = DateTime.utc(2026, 8, 7, 20, 30, 0);
    final url = client.catchupUrl(
      source: source,
      streamId: '22807',
      start: start,
      duration: const Duration(minutes: 45),
    );
    const stamp = '2026-08-07:20-30';
    expect(
      url,
      'http://example.com/streaming/timeshift.php?'
      'username=user&password=pass&stream=22807&start=${Uri.encodeQueryComponent(stamp)}&duration=45',
    );
    expect(url.toLowerCase().contains('.m3u8'), isFalse);

    final candidates = client.catchupUrlCandidates(
      source: source,
      streamId: '22807',
      start: start,
      duration: const Duration(minutes: 45),
    );
    expect(
      candidates.first,
      'http://example.com/timeshift/user/pass/45/${Uri.encodeComponent(stamp)}/22807.m3u8',
    );
    expect(candidates, contains(url));
    expect(
      candidates,
      contains(
        'http://example.com/timeshift/user/pass/45/${Uri.encodeComponent(stamp)}/22807.ts',
      ),
    );
  });

  test('liveUrlFromTimeshift recovers live URL from php and path forms', () {
    const stamp = '2026-08-07:20-30';
    final phpUrl =
        'http://example.com/streaming/timeshift.php?'
        'username=user&password=pass&stream=22807&start=${Uri.encodeQueryComponent(stamp)}&duration=45';
    expect(
      XtreamClient.liveUrlFromTimeshift(phpUrl),
      'http://example.com/live/user/pass/22807.ts',
    );

    final pathUrl =
        'http://example.com/timeshift/user/pass/45/${Uri.encodeComponent(stamp)}/22807.ts';
    expect(
      XtreamClient.liveUrlFromTimeshift(pathUrl),
      'http://example.com/live/user/pass/22807.ts',
    );

    final hlsUrl =
        'http://example.com/timeshift/user/pass/45/${Uri.encodeComponent(stamp)}/22807.m3u8';
    expect(
      XtreamClient.liveUrlFromTimeshift(hlsUrl),
      'http://example.com/live/user/pass/22807.m3u8',
    );

    expect(
      XtreamClient.liveStreamUrl(source: source, streamId: '22807'),
      'http://example.com/live/user/pass/22807.ts',
    );

    final strippedTimeshift =
        'http://example.com/timeshift/45/${Uri.encodeComponent(stamp)}/22807.ts';
    expect(
      XtreamClient.liveUrlFromTimeshift(strippedTimeshift),
      'http://example.com/live/22807.ts',
    );
    final strippedPhp =
        'http://example.com/streaming/timeshift.php?'
        'stream=22807&start=${Uri.encodeQueryComponent(stamp)}&duration=45';
    expect(
      XtreamClient.liveUrlFromTimeshift(strippedPhp),
      'http://example.com/live/22807.ts',
    );
  });

  test('fetchSeriesInfo maps seasons and episodes', () async {
    final client = xtreamTestClient(MockClient((request) async {
        expect(request.url.queryParameters['action'], 'get_series_info');
        expect(request.url.queryParameters['series_id'], '62277');
        return http.Response(
          jsonEncode({
            'info': {
              'name': 'EN| Justice, USA',
              'plot': 'A documentary.',
              'cover': 'https://img/cover.jpg',
              'genre': 'Documentary',
              'rating': 6,
            },
            'seasons': [
              {
                'season_number': 1,
                'name': 'Miniseries',
                'cover': 'https://img/s1.jpg',
              },
            ],
            'episodes': {
              '1': [
                {
                  'id': 1453778,
                  'episode_num': 1,
                  'title': 'Presumed Guilty',
                  'container_extension': 'mp4',
                  'info': {
                    'plot': 'Episode plot',
                    'movie_image': 'https://img/e1.jpg',
                    'duration_secs': 3600,
                  },
                },
                {
                  'id': 1453779,
                  'episode_num': 2,
                  'title': 'Freedom',
                  'container_extension': 'mp4',
                  'info': {},
                },
              ],
            },
          }),
          200,
        );
    }));

    final info = await client.fetchSeriesInfo(source, seriesId: '62277');
    expect(info.title, 'EN| Justice, USA');
    expect(info.seasons, hasLength(1));
    expect(info.seasons.first.name, 'Miniseries');
    expect(info.seasons.first.episodes, hasLength(2));
    expect(info.seasons.first.episodes.first.shortLabel, 'S01E01');
    expect(
      client.seriesEpisodeUrl(
        source: source,
        episodeId: '1453778',
        extension: 'mp4',
      ),
      'http://example.com/series/user/pass/1453778.mp4',
    );
  });

  test('loadCategoryStreams maps series kind', () async {
    final client = xtreamTestClient(MockClient((request) async {
        return http.Response(
          jsonEncode([
            {
              'name': 'EN| Show',
              'series_id': 9,
              'category_id': '837',
              'cover': 'https://img/s.jpg',
              'genre': 'Drama',
              'seasons': [
                {'season_number': 1},
                {'season_number': 2},
              ],
            },
          ]),
          200,
        );
    }));

    final items = await client.loadCategoryStreams(
      source,
      category: const IptvCategory(
        id: '837',
        name: '[EN] Drama',
        kind: IptvCategoryKind.series,
      ),
    );
    expect(items, hasLength(1));
    expect(items.first.isSeries, isTrue);
    expect(items.first.playUrl, isEmpty);
    expect(items.first.subtitle, contains('2 seasons'));
  });

  test(
    'loadCategoryStreams maps TMDB from field, float, and {tmdb-id} name',
    () async {
      final client = XtreamClient(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode([
              {
                'name': 'US| Sample Film {tmdb-550}',
                'stream_id': 11,
                'category_id': '1',
                'container_extension': 'mp4',
                'tmdb_id': 550.0,
                'o_name': 'Sample Film',
              },
              {
                'name': 'FR| Sample Film',
                'stream_id': 12,
                'category_id': '1',
                'container_extension': 'mkv',
                'info': {'tmdb_id': '550'},
              },
            ]),
            200,
          );
        }),
      );

      final items = await client.loadCategoryStreams(
        source,
        category: const IptvCategory(
          id: '1',
          name: 'Movies',
          kind: IptvCategoryKind.vod,
        ),
      );
      expect(items, hasLength(2));
      expect(items[0].tmdbId, 550);
      expect(items[0].originalTitle, 'Sample Film');
      expect(items[1].tmdbId, 550);
    },
  );

  test('fetchVodInfo reads tmdb from info and movie_data', () async {
    final client = xtreamTestClient(MockClient((request) async {
        expect(request.url.queryParameters['action'], 'get_vod_info');
        return http.Response(
          jsonEncode({
            'info': {'name': 'FR| Sample Film', 'plot': 'Soap', 'tmdb': '550'},
            'movie_data': {'stream_id': 11},
          }),
          200,
        );
    }));
    final info = await client.fetchVodInfo(source, vodId: '11');
    expect(info?.tmdbId, 550);
    expect(info?.plot, 'Soap');
  });

  test(
    'fetchOnDemandCatalogPlan packs movies and series as SQL maps',
    () async {
      final client = xtreamTestClient(MockClient((request) async {
          final action = request.url.queryParameters['action'];
          if (action == null) {
            return http.Response(
              jsonEncode({
                'user_info': {'auth': 1, 'status': 'Active'},
                'server_info': {'url': 'example.com'},
              }),
              200,
            );
          }
          if (action == 'get_vod_categories') {
            return http.Response(
              jsonEncode([
                {'category_id': '1', 'category_name': 'Movies'},
              ]),
              200,
            );
          }
          if (action == 'get_series_categories') {
            return http.Response(
              jsonEncode([
                {'category_id': '2', 'category_name': 'Shows'},
              ]),
              200,
            );
          }
          if (action == 'get_vod_streams') {
            return http.Response(
              jsonEncode([
                {
                  'name': 'Alpha',
                  'stream_id': 11,
                  'category_id': '1',
                  'container_extension': 'mp4',
                  'rating': '8.1',
                  'year': '2024',
                },
              ]),
              200,
            );
          }
          if (action == 'get_series') {
            return http.Response(
              jsonEncode([
                {
                  'name': 'Beta',
                  'series_id': 22,
                  'category_id': '2',
                  'cover': 'https://img/b.png',
                },
              ]),
              200,
            );
          }
          return http.Response('[]', 200);
      }));

      final plan = await client.fetchOnDemandCatalogPlan(source);
      expect(plan.vodCount, 2);
      final ids = [for (final row in plan.rows) '${row['id']}'];
      expect(ids, contains('xtream-vod-src-1-11'));
      expect(ids, contains('xtream-series-src-1-22'));
      expect(
        plan.rows.any(
          (row) => row['group_name'] == 'Movies' && row['kind'] == 'vod',
        ),
        isTrue,
      );
      expect(
        plan.rows.any(
          (row) => row['group_name'] == 'Shows' && row['kind'] == 'series',
        ),
        isTrue,
      );
    },
  );

  test('streamOnDemandCatalog skipIf avoids copying SQL rows', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == null) {
          return http.Response(
            jsonEncode({
              'user_info': {'auth': 1, 'status': 'Active'},
              'server_info': {'url': 'example.com'},
            }),
            200,
          );
        }
        if (action == 'get_vod_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '1', 'category_name': 'Movies'},
            ]),
            200,
          );
        }
        if (action == 'get_series_categories') {
          return http.Response(jsonEncode([]), 200);
        }
        if (action == 'get_vod_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'Alpha',
                'stream_id': 11,
                'category_id': '1',
                'container_extension': 'mp4',
              },
            ]),
            200,
          );
        }
        if (action == 'get_series') {
          return http.Response(jsonEncode([]), 200);
        }
        return http.Response('[]', 200);
    }));

    final copied = <int>[];
    final dumped = await client.streamOnDemandCatalog(
      source,
      skipIf: (fp, n) async {
        expect(fp, isNotEmpty);
        expect(n, 1);
        return true;
      },
      onSqlChunk: (chunk) async => copied.add(chunk.length),
    );
    expect(dumped.skipped, isTrue);
    expect(copied, isEmpty);
    expect(dumped.sqlCount, 1);
  });

  test('fetchAllLivePacked returns SQL maps from the unscoped dump', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '11', 'category_name': 'News'},
            ]),
            200,
          );
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'News 1',
                'stream_id': 9,
                'category_id': '11',
                'tv_archive': 1,
                'tv_archive_duration': '3',
                'container_extension': 'ts',
              },
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
    }));

    final packed = await client.fetchAllLivePacked(source);
    expect(packed, hasLength(1));
    expect(packed.single['id'], 'xtream-live-src-1-9');
    expect(packed.single['group_name'], 'News');
    expect(packed.single['catchup_days'], 3);
  });

  test('streamLiveCatalog skipIf avoids copying SQL rows', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '11', 'category_name': 'News'},
            ]),
            200,
          );
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'News 1',
                'stream_id': 9,
                'category_id': '11',
                'tv_archive': 1,
                'tv_archive_duration': '3',
                'container_extension': 'ts',
              },
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
    }));

    final copied = <int>[];
    final dumped = await client.streamLiveCatalog(
      source,
      skipIf: (fp, n) async {
        expect(fp, isNotEmpty);
        expect(n, 1);
        return true;
      },
      onSqlChunk: (chunk) async => copied.add(chunk.length),
    );
    expect(dumped.skipped, isTrue);
    expect(copied, isEmpty);
    expect(dumped.sqlCount, 1);
  });

  test('streamLiveCatalog streams listings without concatenating SQL', () async {
    final client = xtreamTestClient(MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'get_live_categories') {
          return http.Response(
            jsonEncode([
              {'category_id': '11', 'category_name': 'News'},
            ]),
            200,
          );
        }
        if (action == 'get_live_streams') {
          return http.Response(
            jsonEncode([
              {
                'name': 'News 1',
                'stream_id': 9,
                'category_id': '11',
                'container_extension': 'ts',
              },
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
    }));

    final sql = <Map<String, Object?>>[];
    final listings = <Map<String, Object?>>[];
    final dumped = await client.streamLiveCatalog(
      source,
      onSqlChunk: (chunk) async => sql.addAll(chunk),
      onListingChunk: (chunk) async => listings.addAll(chunk),
    );
    expect(dumped.skipped, isFalse);
    expect(sql, hasLength(1));
    expect(listings, isNotEmpty);
    expect(dumped.indexFingerprint, isNotEmpty);
  });
}
