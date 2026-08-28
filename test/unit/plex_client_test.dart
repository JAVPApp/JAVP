import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/services/media_server/media_server_client.dart';
import 'package:javp/services/media_server/plex_client.dart';

void main() {
  final source = IptvSource(
    id: 'src-plex',
    name: 'Home',
    type: IptvSourceType.plex,
    createdAt: DateTime.utc(2026, 1, 1),
    serverUrl: 'http://plex.local:32400',
    password: 'tok',
  );

  const session = MediaServerSession(
    userId: 'plex',
    accessToken: 'tok',
    serverName: 'Home',
  );

  test('search collapses episodes into parent series shells', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/hubs/search');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Hub': [
                {
                  'type': 'movie',
                  'Metadata': [
                    {
                      'ratingKey': '10',
                      'type': 'movie',
                      'title': 'Sample Film',
                      'year': 2010,
                    },
                  ],
                },
                {
                  'type': 'show',
                  'Metadata': [
                    {
                      'ratingKey': '20',
                      'type': 'show',
                      'title': 'Sample Series',
                      'year': 2008,
                    },
                  ],
                },
                {
                  'type': 'episode',
                  'Metadata': [
                    {
                      'ratingKey': '201',
                      'type': 'episode',
                      'title': 'Pilot',
                      'parentIndex': 1,
                      'index': 1,
                      'grandparentRatingKey': '20',
                      'grandparentTitle': 'Sample Series',
                    },
                    {
                      'ratingKey': '301',
                      'type': 'episode',
                      'title': 'Winter Is Coming',
                      'parentIndex': 1,
                      'index': 1,
                      'grandparentRatingKey': '30',
                      'grandparentTitle': 'Sample Epic',
                      'grandparentThumb': '/library/metadata/30/thumb',
                      'year': 2011,
                    },
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final page = await client.browse(
      source,
      session,
      search: 'break',
      limit: 40,
    );

    expect(page.items, hasLength(3));
    expect(page.items.where((i) => i.kind == MediaKind.series), hasLength(2));
    expect(page.items.where((i) => i.isEpisode), isEmpty);

    final titles = page.items.map((i) => i.title).toSet();
    expect(
      titles,
      containsAll(['Sample Film', 'Sample Series', 'Sample Epic']),
    );

    final got = page.items.firstWhere((i) => i.title == 'Sample Epic');
    expect(got.kind, MediaKind.series);
    expect(got.serverItemId, '30');
  });

  test('streamUrl uses transcoder when quality is not original', () async {
    final client = PlexClient(
      httpClient: MockClient((_) async {
        fail('direct metadata should not be fetched for transcode');
      }),
    );

    final url = await client.streamUrl(
      source,
      session,
      '99',
      quality: MediaServerStreamQuality.medium,
    );

    expect(url, contains('/video/:/transcode/universal/start.m3u8'));
    expect(url, contains('maxVideoBitrate=8000'));
    expect(url, contains('videoResolution=1280x720'));
    expect(url, contains('path=%2Flibrary%2Fmetadata%2F99'));
    expect(url, contains('X-Plex-Token=tok'));
  });

  test('liveChannels maps DVR channels to MediaKind.live', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/livetv/dvrs') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Dvr': [
                  {
                    'key': '7',
                    'title': 'Home DVR',
                    'lineup':
                        'lineup://tv.plex.providers.epg.cloud/USA-DEFAULT',
                  },
                  {
                    'key': '1053C0CA',
                    'protocol': 'livetv',
                    'uuid': 'device://tv.plex.grabbers.hdhomerun/1053C0CA',
                  },
                ],
              },
            }),
            200,
          );
        }
        if (path == '/livetv/dvrs/7/channels') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Channel': [
                  {
                    'id': 'epg-abc',
                    'gridKey': 'epg-abc',
                    'vcn': '6.1',
                    'title': '365BLK',
                    'callSign': 'WGCECD',
                    'thumb': '/library/metadata/1/thumb',
                  },
                  {
                    'id': 'epg-def',
                    'gridKey': 'epg-def',
                    'deviceIdentifier': '7.1',
                    'title': 'News',
                    'callSign': 'NEWS',
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('nope', 404);
      }),
    );

    final channels = await client.liveChannels(source, session);
    expect(channels, hasLength(2));
    expect(channels.every((c) => c.kind == MediaKind.live), isTrue);
    expect(channels.every((c) => c.origin == MediaOrigin.plex), isTrue);

    final first = channels.firstWhere((c) => c.title == '365BLK');
    expect(first.channelId, '6.1');
    expect(first.group, 'Home DVR');
    expect(first.serverItemId, 'live:7:6.1');
    expect(first.epgChannelId, 'epg-abc');
    expect(first.playUrl, isEmpty);

    final second = channels.firstWhere((c) => c.title == 'News');
    expect(second.serverItemId, 'live:7:7.1');
  });

  test('liveChannels falls back to EPG provider path', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/livetv/dvrs') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Dvr': [
                  {
                    'key': '86',
                    'lineup': 'lineup://tv.plex.providers.epg.xmltv/guide.xml',
                  },
                ],
              },
            }),
            200,
          );
        }
        if (path == '/livetv/dvrs/86/channels') {
          return http.Response('forbidden', 403);
        }
        if (path == '/tv.plex.providers.epg.xmltv:86/lineups/dvr/channels') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Channel': [
                  {'id': 'ch-1', 'vcn': 'ch001', 'title': 'Local 1'},
                ],
              },
            }),
            200,
          );
        }
        return http.Response('nope', 404);
      }),
    );

    final channels = await client.liveChannels(source, session);
    expect(channels, hasLength(1));
    expect(channels.single.title, 'Local 1');
    expect(channels.single.serverItemId, 'live:86:ch001');
  });

  test('streamUrl tunes Live TV then returns session HLS', () async {
    var tuned = false;
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/livetv/dvrs/7/channels/6.1/tune');
        tuned = true;
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'live': true,
                  'Media': [
                    {'uuid': 'session-uuid-123'},
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final url = await client.streamUrl(
      source,
      session,
      PlexClient.liveServerItemId(dvrId: '7', channelId: '6.1'),
    );

    expect(tuned, isTrue);
    expect(url, contains('/video/:/transcode/universal/start.m3u8'));
    expect(url, contains('path=%2Flivetv%2Fsessions%2Fsession-uuid-123'));
    expect(url, contains('protocol=hls'));
    expect(url, contains('X-Plex-Token=tok'));
  });

  test(
    'streamUrl accepts single-object Metadata/Media tune payloads',
    () async {
      final client = PlexClient(
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          // PMS collapses one-element arrays into bare objects.
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'size': 1,
                'Metadata': {
                  'live': true,
                  'Media': {'uuid': 'dc30f95e-6379-44f7-8168-172ffc820496'},
                },
              },
            }),
            200,
          );
        }),
      );

      final url = await client.streamUrl(
        source,
        session,
        PlexClient.liveServerItemId(dvrId: '7', channelId: '6.1'),
      );
      expect(
        url,
        contains(
          'path=%2Flivetv%2Fsessions%2Fdc30f95e-6379-44f7-8168-172ffc820496',
        ),
      );
    },
  );

  test(
    'streamUrl falls back to /livetv/sessions when tune omits uuid',
    () async {
      final client = PlexClient(
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path.endsWith('/tune')) {
            return http.Response(
              jsonEncode({
                'MediaContainer': {
                  'size': 1,
                  'MediaGrabOperation': {
                    'status': 'inprogress',
                    'Metadata': {
                      'title': 'News',
                      'Media': {
                        'channelIdentifier': '6.1',
                        'protocol': 'livetv',
                      },
                    },
                  },
                },
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/livetv/sessions') {
            return http.Response(
              jsonEncode({
                'MediaContainer': {
                  'Metadata': {
                    'live': true,
                    'Media': {
                      'uuid': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                      'channelIdentifier': '6.1',
                    },
                  },
                },
              }),
              200,
            );
          }
          fail('Unexpected ${request.method} ${request.url}');
        }),
      );

      final url = await client.streamUrl(
        source,
        session,
        PlexClient.liveServerItemId(dvrId: '7', channelId: '6.1'),
      );
      expect(
        url,
        contains(
          'path=%2Flivetv%2Fsessions%2Faaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        ),
      );
    },
  );

  test('parseLiveServerItemId round-trips encoded channel ids', () {
    final id = PlexClient.liveServerItemId(dvrId: '7', channelId: 'a/b:c');
    final parsed = PlexClient.parseLiveServerItemId(id);
    expect(parsed?.dvrId, '7');
    expect(parsed?.channelId, 'a/b:c');
    expect(PlexClient.parseLiveServerItemId('99'), isNull);
  });

  test('parseLiveServerItemId round-trips optional startAt', () {
    final start = DateTime.utc(2026, 3, 4, 5, 6, 7);
    final id = PlexClient.liveServerItemId(
      dvrId: '7',
      channelId: '6.1',
      startAt: start,
    );
    final parsed = PlexClient.parseLiveServerItemId(id);
    expect(parsed?.startAt, start);
  });

  test(
    'streamUrl closes prior live session then retunes with offset',
    () async {
      final paths = <String>[];
      final client = PlexClient(
        httpClient: MockClient((request) async {
          paths.add('${request.method} ${request.url.path}');
          if (request.method == 'DELETE') {
            return http.Response('', 200);
          }
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {
                    'Media': [
                      {'uuid': 'sess-new'},
                    ],
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
      client.lastLiveSessionKey = '/livetv/sessions/sess-old';

      final start = DateTime.now().toUtc().subtract(
        const Duration(minutes: 12),
      );
      final url = await client.streamUrl(
        source,
        session,
        PlexClient.liveServerItemId(
          dvrId: '7',
          channelId: '6.1',
          startAt: start,
        ),
      );

      expect(paths.first, 'DELETE /livetv/sessions/sess-old');
      expect(paths, contains('POST /livetv/dvrs/7/channels/6.1/tune'));
      expect(url, contains('offset='));
      expect(client.lastLiveSessionKey, '/livetv/sessions/sess-new');
    },
  );

  test('closeLiveSession deletes the tuner session', () async {
    var deleted = false;
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/livetv/sessions/sess-1');
        deleted = true;
        return http.Response('', 200);
      }),
    );
    client.lastLiveSessionKey = '/livetv/sessions/sess-1';
    await client.closeLiveSession(source);
    expect(deleted, isTrue);
    expect(client.lastLiveSessionKey, isNull);
  });

  test('liveChannels throws when DVR list fails', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/livetv/dvrs');
        return http.Response('nope', 503);
      }),
    );

    await expectLater(
      client.liveChannels(source, session),
      throwsA(isA<Exception>()),
    );
  });

  test('liveGuide maps beginsAt/endsAt programmes', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/tv.plex.providers.epg.cloud:7/grid');
        expect(request.url.queryParameters['channelGridKey'], 'epg-abc');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'title': 'Morning News',
                  'summary': 'Local news.',
                  'Media': [
                    {'beginsAt': 1700000000, 'endsAt': 1700003600},
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final programs = await client.liveGuide(
      source,
      dvrId: '7',
      channelGridKey: 'epg-abc',
      lineup: 'lineup://tv.plex.providers.epg.cloud/USA',
    );

    expect(programs, isNotEmpty);
    expect(programs.first.title, 'Morning News');
    expect(programs.first.channelId, 'epg-abc');
    expect(
      programs.first.start,
      DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
    );
  });

  test('streamUrl uses configured clientIdentifier', () async {
    final client = PlexClient(
      clientIdentifier: 'device-xyz',
      httpClient: MockClient((request) async {
        expect(request.headers['X-Plex-Client-Identifier'], 'device-xyz');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'Media': [
                    {'uuid': 'sess-1'},
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final url = await client.streamUrl(
      source,
      session,
      PlexClient.liveServerItemId(dvrId: '7', channelId: '6.1'),
    );
    expect(url, contains('X-Plex-Client-Identifier=device-xyz'));
    expect(client.lastLiveSessionKey, '/livetv/sessions/sess-1');
  });

  test('details loads seasons and episodes for a show', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/library/metadata/20') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {
                    'ratingKey': '20',
                    'type': 'show',
                    'title': 'Sample Series',
                    'year': 2008,
                    'summary': 'A chemistry teacher.',
                  },
                ],
              },
            }),
            200,
          );
        }
        if (path == '/library/metadata/20/children') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {
                    'ratingKey': '21',
                    'type': 'season',
                    'title': 'Season 1',
                    'index': 1,
                  },
                ],
              },
            }),
            200,
          );
        }
        if (path == '/library/metadata/21/children') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {
                    'ratingKey': '201',
                    'type': 'episode',
                    'title': 'Pilot',
                    'index': 1,
                    'summary': 'Walter White.',
                    'duration': 3600000,
                  },
                  {
                    'ratingKey': '202',
                    'type': 'episode',
                    'title': "Cat's in the Bag...",
                    'index': 2,
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('nope', 404);
      }),
    );

    final details = await client.details(source, session, '20');
    expect(details, isNotNull);
    expect(details!.seasons, hasLength(1));
    expect(details.seasons.single.episodes, hasLength(2));
    expect(details.seasons.single.episodes.first.id, '201');
    expect(details.seasons.single.episodes.first.title, 'Pilot');
  });

  test(
    'authenticate falls through to extraServerUrls when LAN fails',
    () async {
      final remote = source.copyWith(
        extraServerUrls: const ['https://abc.plex.direct:32400'],
      );
      final client = PlexClient(
        httpClient: MockClient((request) async {
          if (request.url.host == 'plex.local') {
            throw Exception('unreachable');
          }
          if (request.url.host.contains('plex.direct') &&
              request.url.path.endsWith('/identity')) {
            return http.Response('{}', 200);
          }
          return http.Response('nope', 500);
        }),
      );

      final session = await client.authenticate(remote);
      expect(session.baseUrl, 'https://abc.plex.direct:32400');
      expect(
        await client.libraries(remote, session),
        isEmpty,
        reason: 'follow-up calls must reuse the remote base, not the LAN URL',
      );
    },
  );

  test('authenticate prefers the last-good base on this device', () async {
    final remote = source.copyWith(
      extraServerUrls: const ['https://abc.plex.direct:32400'],
    );
    final client = PlexClient(
      httpClient: MockClient((request) async {
        if (request.url.host.contains('plex.direct')) {
          return http.Response('{}', 200);
        }
        return http.Response('nope', 503);
      }),
    );

    final session = await client.authenticate(
      remote,
      preferredBase: 'https://abc.plex.direct:32400',
    );
    expect(session.baseUrl, 'https://abc.plex.direct:32400');
  });

  final fastSource = IptvSource(
    id: 'src-plex-fast',
    name: 'Plex Live TV',
    type: IptvSourceType.plex,
    createdAt: DateTime.utc(2026, 1, 1),
    serverUrl: PlexClient.fastProviderUrl,
    username: PlexClient.fastUsername,
    password: 'acct-tok',
  );

  test('parseFastServerItemId round-trips compound channel ids', () {
    const id = '5e20b730f2f8d5003d739db7-5fd115bab7ef8d002dcf181d';
    final encoded = PlexClient.fastServerItemId(id);
    expect(encoded, startsWith('fast:'));
    expect(PlexClient.parseFastServerItemId(encoded), id);
    expect(PlexClient.parseLiveServerItemId(encoded), isNull);
    expect(PlexClient.normalizeFastChannelId(id), '5fd115bab7ef8d002dcf181d');
  });

  test('isFastProvider matches cloud EPG URL or username', () {
    expect(PlexClient.isFastProvider(fastSource), isTrue);
    expect(PlexClient.isFastProvider(source), isFalse);
    expect(
      PlexClient.isFastProvider(
        source.copyWith(username: PlexClient.fastUsername),
      ),
      isTrue,
    );
  });

  test('authenticate for FAST hits lineup, not PMS identity', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.host, 'epg.provider.plex.tv');
        expect(request.url.path, '/lineups/plex/channels');
        expect(request.headers['X-Plex-Token'], 'acct-tok');
        expect(request.headers['X-Plex-Provider-Version'], '6.5.0');
        expect(request.url.queryParameters['X-Plex-Container-Size'], '0');
        return http.Response('{"MediaContainer":{"size":0}}', 200);
      }),
    );

    final auth = await client.authenticate(fastSource);
    expect(auth.userId, PlexClient.fastUsername);
    expect(auth.accessToken, 'acct-tok');
  });

  test('libraries for FAST hits vod provider sections', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'vod.provider.plex.tv');
        expect(request.url.path, '/library/sections');
        expect(request.headers['X-Plex-Token'], 'acct-tok');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Directory': [
                {
                  'key': 'movies',
                  'title': 'Movies',
                  'type': 'movie',
                  'count': 10,
                },
                {'key': 'tv', 'title': 'TV Shows', 'type': 'show', 'count': 5},
              ],
            },
          }),
          200,
        );
      }),
    );

    final libs = await client.libraries(fastSource, session);
    expect(libs, hasLength(2));
    expect(libs.first.id, 'movies');
    expect(libs.first.collectionType, 'movie');
    expect(libs.last.id, 'tv');
  });

  test('libraries for FAST falls back when vod sections fail', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'vod.provider.plex.tv');
        expect(request.url.path, '/library/sections');
        return http.Response('nope', 503);
      }),
    );

    final libs = await client.libraries(fastSource, session);
    expect(libs.map((l) => l.id), ['movies', 'tv']);
    expect(libs.first.collectionType, 'movie');
    expect(libs.last.collectionType, 'show');
  });

  test('browse FAST without parent stays empty', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        fail('FAST root browse should not hit ${request.url}');
      }),
    );

    final page = await client.browse(fastSource, session);
    expect(page.items, isEmpty);
  });

  test('browse FAST movies hits vod with availabilityType=free', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'vod.provider.plex.tv');
        expect(request.url.path, '/library/sections/movies/all');
        expect(request.url.queryParameters['availabilityType'], 'free');
        expect(request.url.queryParameters['includeGuids'], '1');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'totalSize': 3,
              'Metadata': [
                {
                  'ratingKey': '5d776825a091de001f2e9b1c',
                  'title': 'Free Movie',
                  'type': 'movie',
                  'year': 2020,
                  'thumb': '/library/metadata/5d776825a091de001f2e9b1c/thumb',
                  'Media': [
                    {
                      'protocol': 'dash',
                      'videoCodec': 'h264',
                      'container': 'mp4',
                      'duration': 5400000,
                    },
                  ],
                },
                {
                  'ratingKey': 'poster-only',
                  'title': 'Poster Only',
                  'type': 'movie',
                  'year': 1999,
                },
                {
                  'ratingKey': 'streamco-only',
                  'title': 'Watch Elsewhere',
                  'type': 'movie',
                  'Availability': [
                    {'platform': 'streamco', 'offerType': 'subscription'},
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final page = await client.browse(fastSource, session, parentId: 'movies');
    expect(page.items, hasLength(1));
    expect(page.items.single.title, 'Free Movie');
    expect(page.items.single.kind, MediaKind.vod);
    expect(page.items.single.serverItemId, '5d776825a091de001f2e9b1c');
    expect(page.scannedCount, 3);
    expect(page.hasMore, isFalse);
    expect(
      page.items.single.thumbnailUrl,
      startsWith(
        'https://vod.provider.plex.tv/library/metadata/5d776825a091de001f2e9b1c/thumb',
      ),
    );
    expect(page.items.single.httpHeaders['Origin'], 'https://watch.plex.tv');
  });

  test(
    'browse FAST movies reports scanned rows when none are playable',
    () async {
      final client = PlexClient(
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['X-Plex-Container-Start'], '200');
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'totalSize': 400,
                'Metadata': [
                  {'ratingKey': 'a', 'type': 'movie', 'title': 'No File A'},
                  {'ratingKey': 'b', 'type': 'movie', 'title': 'No File B'},
                ],
              },
            }),
            200,
          );
        }),
      );

      final page = await client.browse(
        fastSource,
        session,
        parentId: 'movies',
        startIndex: 200,
        limit: 200,
      );
      expect(page.items, isEmpty);
      expect(page.scannedCount, 2);
      expect(page.consumedCount, 2);
      expect(page.hasMore, isTrue);
    },
  );

  test('browse FAST search hits discover provider', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'discover.provider.plex.tv');
        expect(request.url.path, '/library/search');
        expect(request.url.queryParameters['searchProviders'], 'PLEXAVOD');
        expect(request.url.queryParameters['query'], 'sample film');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'SearchResults': [
                {
                  'SearchResult': [
                    {
                      'Metadata': {
                        'ratingKey': '10',
                        'type': 'movie',
                        'title': 'Sample Film',
                        'year': 2010,
                        'Media': [
                          {'protocol': 'hls', 'videoCodec': 'h264'},
                        ],
                      },
                    },
                    {
                      'Metadata': {
                        'ratingKey': '11',
                        'type': 'movie',
                        'title': 'Metadata Only',
                        'year': 2011,
                      },
                    },
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final page = await client.browse(fastSource, session, search: 'sample film');
    expect(page.items, hasLength(1));
    expect(page.items.single.title, 'Sample Film');
  });

  test('streamUrl for FAST VOD uses vod transcode HLS', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        fail('VOD stream URL should not need HTTP ${request.url}');
      }),
    );

    final url = await client.streamUrl(
      fastSource,
      session,
      '5d776825a091de001f2e9b1c',
    );
    expect(url, contains('vod.provider.plex.tv'));
    expect(url, contains('/video/:/transcode/universal/start.m3u8'));
    expect(
      url,
      contains('path=%2Flibrary%2Fmetadata%2F5d776825a091de001f2e9b1c'),
    );
    expect(url, contains('protocol=hls'));
    expect(url, contains('X-Plex-Token=acct-tok'));
  });

  test('details for FAST VOD hits vod metadata', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'vod.provider.plex.tv');
        expect(request.url.path, '/library/metadata/99');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'ratingKey': '99',
                  'type': 'movie',
                  'title': 'Cloud Movie',
                  'year': 2021,
                  'summary': 'A free title.',
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final details = await client.details(fastSource, session, '99');
    expect(details, isNotNull);
    expect(details!.title, 'Cloud Movie');
    expect(details.plot, 'A free title.');
  });

  test('details skips FAST live channel ids', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        fail('live channel details should not hit ${request.url}');
      }),
    );

    expect(
      await client.details(
        fastSource,
        session,
        PlexClient.fastServerItemId('abc'),
      ),
      isNull,
    );
  });

  test('liveChannels maps plex.tv FAST lineup to MediaKind.live', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/lineups/plex/channels');
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Channel': [
                {
                  'id': '5e20b730f2f8d5003d739db7-5fd115bab7ef8d002dcf181d',
                  'gridKey': '5fd115bab7ef8d002dcf181d',
                  'title': '365BLK',
                  'vcn': '100',
                  'thumb':
                      'https://provider-static.plex.tv/epg/images/ott_channels/logos/365.png',
                },
                {
                  'id': 'abc-def',
                  'gridKey': 'news1',
                  'title': 'News',
                  'callSign': 'NEWS',
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final channels = await client.liveChannels(fastSource, session);
    expect(channels, hasLength(2));
    expect(channels.every((c) => c.kind == MediaKind.live), isTrue);
    expect(channels.every((c) => c.origin == MediaOrigin.plex), isTrue);
    expect(channels.every((c) => c.catchupDays == 0), isTrue);
    expect(channels.every((c) => c.group == 'Plex Live TV'), isTrue);

    final first = channels.firstWhere((c) => c.title == '365BLK');
    expect(first.epgChannelId, '5fd115bab7ef8d002dcf181d');
    expect(
      first.serverItemId,
      PlexClient.fastServerItemId(
        '5e20b730f2f8d5003d739db7-5fd115bab7ef8d002dcf181d',
      ),
    );
    expect(
      first.thumbnailUrl,
      'https://provider-static.plex.tv/epg/images/ott_channels/logos/365.png',
    );
  });

  test('streamUrl for FAST tunes then returns parts HLS', () async {
    var tuned = false;
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/channels/5e20b730f2f8d5003d739db7-5fd115bab7ef8d002dcf181d/tune',
        );
        tuned = true;
        return http.Response('{}', 200);
      }),
    );

    final url = await client.streamUrl(
      fastSource,
      session,
      PlexClient.fastServerItemId(
        '5e20b730f2f8d5003d739db7-5fd115bab7ef8d002dcf181d',
      ),
    );

    expect(tuned, isTrue);
    expect(
      url,
      contains(
        '/library/parts/5e20b730f2f8d5003d739db7-5fd115bab7ef8d002dcf181d.m3u8',
      ),
    );
    expect(url, contains('includeAllStreams=1'));
    expect(url, contains('X-Plex-Token=acct-tok'));
    expect(url, isNot(contains('/livetv/sessions/')));
  });

  test('liveGuide for FAST hits cloud /grid', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'epg.provider.plex.tv');
        expect(request.url.path, '/grid');
        expect(request.url.queryParameters['channelGridKey'], 'news1');
        expect(request.url.queryParameters['date'], isNotEmpty);
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {
                  'title': 'Morning News',
                  'summary': 'Headlines',
                  'Media': [
                    {'beginsAt': 1700000000, 'endsAt': 1700003600},
                  ],
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final programs = await client.liveGuide(
      fastSource,
      dvrId: '',
      channelGridKey: 'news1',
    );
    expect(programs, isNotEmpty);
    expect(programs.first.title, 'Morning News');
    expect(programs.first.channelId, 'news1');
  });

  test('dvrRecordings is empty for FAST without DVR calls', () async {
    final client = PlexClient(
      httpClient: MockClient((request) async {
        fail('FAST recordings should not hit ${request.url}');
      }),
    );
    expect(await client.dvrRecordings(fastSource, session), isEmpty);
  });
}
