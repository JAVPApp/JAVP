import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/stalker_client.dart';

void main() {
  final source = IptvSource(
    id: 'src-stalker',
    name: 'Portal',
    type: IptvSourceType.stalker,
    createdAt: DateTime.utc(2026, 1, 1),
    serverUrl: 'http://portal.example/c/',
    username: '00:1A:79:12:34:56',
    password: 'SN123',
  );

  test('normalizeMac uppercases and inserts colons', () {
    expect(StalkerClient.normalizeMac('001a79123456'), '00:1A:79:12:34:56');
    expect(
      StalkerClient.normalizeMac('00-1a-79-12-34-56'),
      '00:1A:79:12:34:56',
    );
  });

  test('normalizeMac rejects invalid input', () {
    expect(() => StalkerClient.normalizeMac('bad'), throwsA(isA<Exception>()));
  });

  test('syncCatalog maps handshake, genres, and live channels', () async {
    final client = StalkerClient(
      httpClient: MockClient((request) async {
        final action = request.url.queryParameters['action'];
        final type = request.url.queryParameters['type'];
        if (action == 'handshake') {
          return http.Response(
            jsonEncode({
              'js': {'token': 'tok-abc'},
            }),
            200,
          );
        }
        if (action == 'get_profile') {
          return http.Response(jsonEncode({'js': {}}), 200);
        }
        if (type == 'itv' && action == 'get_genres') {
          return http.Response(
            jsonEncode({
              'js': [
                {'id': '7', 'title': 'Sports'},
              ],
            }),
            200,
          );
        }
        if (type == 'itv' && action == 'get_all_channels') {
          return http.Response(
            jsonEncode({
              'js': {
                'data': [
                  {
                    'id': '101',
                    'name': 'News One',
                    'cmd': 'ffrt http://localhost/ch/101',
                    'tv_genre_id': '7',
                    'logo': 'http://img/logo.png',
                    'xmltv_id': 'news.one',
                  },
                ],
              },
            }),
            200,
          );
        }
        if ((type == 'vod' || type == 'series') && action == 'get_categories') {
          return http.Response(
            jsonEncode({
              'js': [
                {
                  'id': type == 'vod' ? 'v1' : 's1',
                  'title': type == 'vod' ? 'Movies' : 'Shows',
                },
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'js': {}}), 200);
      }),
    );

    final result = await client.syncCatalog(source);
    expect(result.live, hasLength(1));
    final ch = result.live.single;
    expect(ch.title, 'News One');
    expect(ch.group, 'Sports');
    expect(ch.origin, MediaOrigin.iptvStalker);
    expect(ch.epgChannelId, 'news.one');
    expect(ch.playUrl, 'ffrt http://localhost/ch/101');
    expect(result.liveCategories, hasLength(1));
    expect(result.liveCategories.single.name, 'Sports');
    expect(result.vodCategories, hasLength(1));
    expect(result.vodCategories.single.name, 'Movies');
    expect(result.seriesCategories, hasLength(1));
    expect(result.seriesCategories.single.name, 'Shows');
    expect(result.vod, isEmpty);
    expect(result.series, isEmpty);
  });

  test('createLink strips ffmpeg prefix from portal response', () async {
    final client = StalkerClient(
      httpClient: MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'handshake') {
          return http.Response(
            jsonEncode({
              'js': {'token': 'tok-abc'},
            }),
            200,
          );
        }
        if (action == 'get_profile') {
          return http.Response(jsonEncode({'js': {}}), 200);
        }
        if (action == 'create_link') {
          return http.Response(
            jsonEncode({
              'js': {'cmd': 'ffmpeg http://stream.example/live/101.ts'},
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'js': {}}), 200);
      }),
    );

    final url = await client.createLink(
      source,
      cmd: 'ffrt http://localhost/ch/101',
      isLive: true,
    );
    expect(url, 'http://stream.example/live/101.ts');
  });

  test('createLink reuses handshake within the session TTL', () async {
    var handshakes = 0;
    final client = StalkerClient(
      httpClient: MockClient((request) async {
        final action = request.url.queryParameters['action'];
        if (action == 'handshake') {
          handshakes += 1;
          return http.Response(
            jsonEncode({
              'js': {'token': 'tok-abc'},
            }),
            200,
          );
        }
        if (action == 'get_profile') {
          return http.Response(jsonEncode({'js': {}}), 200);
        }
        if (action == 'create_link') {
          return http.Response(
            jsonEncode({
              'js': {'cmd': 'ffmpeg http://stream.example/live/101.ts'},
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'js': {}}), 200);
      }),
    );

    Future<String> play() => client.createLink(
      source,
      cmd: 'ffrt http://localhost/ch/101',
      isLive: true,
    );

    expect(await play(), 'http://stream.example/live/101.ts');
    expect(await play(), 'http://stream.example/live/101.ts');
    expect(handshakes, 1);
  });
}
