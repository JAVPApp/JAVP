import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/services/media_server/jellyfin_client.dart';
import 'package:javp/services/media_server/media_server_client.dart';

void main() {
  final source = IptvSource(
    id: 'src-jf',
    name: 'Home',
    type: IptvSourceType.jellyfin,
    createdAt: DateTime.utc(2026, 1, 1),
    serverUrl: 'http://jellyfin.local:8096',
    username: 'demo',
    password: 'secret',
  );

  const session = MediaServerSession(
    userId: 'user-1',
    accessToken: 'tok',
    serverName: 'Home',
  );

  test('details loads seasons and episodes for a series', () async {
    final client = JellyfinClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        final parentId = request.url.queryParameters['ParentId'];

        if (path == '/Users/user-1/Items/series-1' && parentId == null) {
          return http.Response(
            jsonEncode({
              'Id': 'series-1',
              'Name': 'Sample Series',
              'Type': 'Series',
              'Overview': 'A chemistry teacher.',
              'ProductionYear': 2008,
              'ImageTags': {'Primary': 'poster'},
              'ProviderIds': {'Tmdb': '1396'},
            }),
            200,
          );
        }

        if (path == '/Users/user-1/Items' && parentId == 'series-1') {
          return http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'season-1',
                  'Name': 'Season 1',
                  'Type': 'Season',
                  'IndexNumber': 1,
                  'ImageTags': {'Primary': 's1'},
                },
              ],
            }),
            200,
          );
        }

        if (path == '/Users/user-1/Items' && parentId == 'season-1') {
          return http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'ep-201',
                  'Name': 'Pilot',
                  'Type': 'Episode',
                  'IndexNumber': 1,
                  'Overview': 'Walter White.',
                  'RunTimeTicks': 36000000000, // 1 hour
                  'ImageTags': {'Primary': 'ep'},
                },
              ],
            }),
            200,
          );
        }

        fail('Unexpected request: ${request.url}');
      }),
    );

    final details = await client.details(source, session, 'series-1');
    expect(details, isNotNull);
    expect(details!.title, 'Sample Series');
    expect(details.seasons, hasLength(1));
    expect(details.seasons.first.seasonNumber, 1);
    expect(details.seasons.first.episodes, hasLength(1));

    final ep = details.seasons.first.episodes.first;
    expect(ep.id, 'ep-201');
    expect(ep.episodeNumber, 1);
    expect(ep.title, 'Pilot');
    expect(ep.playUrl, isNull);
    expect(ep.duration, const Duration(hours: 1));
    expect(ep.thumbnailUrl, contains('/Items/ep-201/Images/Primary'));
  });

  test('browse keeps video type filter and drops music rows', () async {
    final client = JellyfinClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/Users/user-1/Items');
        expect(
          request.url.queryParameters['IncludeItemTypes'],
          'Movie,Series,Episode',
        );
        expect(request.url.queryParameters['ParentId'], 'lib-music');
        expect(request.url.queryParameters['Recursive'], 'true');
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'album-1',
                'Name': 'Random Access Memories',
                'Type': 'MusicAlbum',
              },
              {
                'Id': 'movie-1',
                'Name': 'Sample Film',
                'Type': 'Movie',
                'ProductionYear': 2010,
              },
              {
                'Id': 'artist-1',
                'Name': 'Daft Punk',
                'Type': 'MusicArtist',
              },
            ],
            'TotalRecordCount': 3,
          }),
          200,
        );
      }),
    );

    final page = await client.browse(
      source,
      session,
      parentId: 'lib-music',
    );
    expect(page.items, hasLength(1));
    expect(page.items.single.title, 'Sample Film');
  });

  test('streamUrl uses HLS when quality is not original', () async {
    final client = JellyfinClient(
      httpClient: MockClient((_) async {
        fail('streamUrl should not hit the network');
      }),
    );

    final url = await client.streamUrl(
      source,
      session,
      '99',
      quality: MediaServerStreamQuality.medium,
    );

    expect(url, contains('/Videos/99/master.m3u8'));
    expect(url, contains('MaxStreamingBitrate='));
    expect(url, contains('api_key=tok'));
  });

  test('IptvSourceType helpers classify media servers vs live IPTV', () {
    expect(IptvSourceType.jellyfin.isMediaServer, isTrue);
    expect(IptvSourceType.emby.isMediaServer, isTrue);
    expect(IptvSourceType.plex.isMediaServer, isTrue);
    expect(IptvSourceType.m3u.isMediaServer, isFalse);
    expect(IptvSourceType.xtream.isLiveIptv, isTrue);
    expect(IptvSourceType.jellyfin.isLiveIptv, isFalse);
    expect(IptvSourceType.jellyfin.supportsLive, isTrue);
    expect(IptvSourceType.emby.supportsLive, isTrue);
    expect(IptvSourceType.plex.supportsLive, isTrue);
    expect(IptvSourceType.xmltv.supportsLive, isFalse);
    expect(IptvSourceType.xmltv.isEpgOnly, isTrue);
  });

  test('parseLiveServerItemId round-trips optional startAt', () {
    final id = JellyfinClient.liveServerItemId(
      'ch-1',
      startAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );
    final parsed = JellyfinClient.parseLiveServerItemId(id);
    expect(parsed?.channelId, 'ch-1');
    expect(parsed?.startAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(JellyfinClient.parseLiveServerItemId('vod-9'), isNull);
  });

  test('liveChannels maps Live TV rows', () async {
    final client = JellyfinClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/LiveTv/Channels');
        return http.Response(
          jsonEncode({
            'Items': [
              {
                'Id': 'ch-9',
                'Name': 'News',
                'ChannelNumber': '9.1',
                'ImageTags': {'Primary': 'tag'},
                'CurrentProgram': {'Name': 'Evening'},
              },
            ],
          }),
          200,
        );
      }),
    );

    final channels = await client.liveChannels(source, session);
    expect(channels, hasLength(1));
    expect(channels.single.title, 'News');
    expect(channels.single.kind.name, 'live');
    expect(channels.single.serverItemId, 'live:ch-9');
    expect(channels.single.catchupDays, 1);
  });

  test('streamUrl opens Live TV then returns HLS', () async {
    var closed = false;
    var opened = false;
    final client = JellyfinClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/LiveStreams/Close') {
          closed = true;
          return http.Response('', 204);
        }
        if (request.url.path == '/LiveStreams/Open') {
          opened = true;
          return http.Response(
            jsonEncode({
              'MediaSource': {
                'LiveStreamId': 'ls-1',
                'TranscodingUrl': '/videos/live/master.m3u8?session=1',
              },
            }),
            200,
          );
        }
        fail('Unexpected ${request.method} ${request.url}');
      }),
    );
    client.lastLiveStreamId = 'ls-old';

    final url = await client.streamUrl(
      source,
      session,
      JellyfinClient.liveServerItemId('ch-9'),
    );
    expect(closed, isTrue);
    expect(opened, isTrue);
    expect(url, contains('/videos/live/master.m3u8'));
    expect(client.lastLiveStreamId, 'ls-1');
  });
}
