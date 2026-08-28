import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rqbit_engine/rqbit_engine.dart';

void main() {
  group('rqbitSocksProxyUrl', () {
    test('builds socks5 with and without auth', () {
      expect(
        rqbitSocksProxyUrl(
          enabled: true,
          type: 'socks5',
          host: '127.0.0.1',
          port: 1080,
        ),
        'socks5://127.0.0.1:1080',
      );
      expect(
        rqbitSocksProxyUrl(
          enabled: true,
          type: 'socks5',
          host: 'socks.example',
          port: 1080,
          username: 'u',
          password: 'p@ss',
        ),
        'socks5://u:p%40ss@socks.example:1080',
      );
    });

    test('returns null for HTTP or inactive settings', () {
      expect(
        rqbitSocksProxyUrl(
          enabled: true,
          type: 'http',
          host: 'proxy.example',
          port: 8080,
        ),
        isNull,
      );
      expect(
        rqbitSocksProxyUrl(
          enabled: false,
          type: 'socks5',
          host: '127.0.0.1',
          port: 1080,
        ),
        isNull,
      );
    });
  });

  group('injectTrackers', () {
    test('appends missing tr= entries', () {
      const magnet = 'magnet:?xt=urn:btih:abc';
      final out = injectTrackers(magnet, [
        'udp://tracker.example:80',
        'udp://tracker.example:80',
      ]);
      expect(out, contains('tr='));
      expect('tr='.allMatches(out).length, 1);
    });
  });

  group('RqbitTorrent JSON', () {
    test('parses add response with id 0', () {
      final t = RqbitTorrent.fromAddJson({
        'id': 0,
        'output_folder': '/tmp/out',
        'details': {
          'id': 0,
          'info_hash': 'aa' * 20,
          'name': 'Demo',
          'output_folder': '/tmp/out',
          'files': [
            {
              'name': 'video/ep01.mkv',
              'components': ['video', 'ep01.mkv'],
              'length': 1234,
              'included': true,
            },
          ],
        },
      });
      expect(t.id, 0);
      expect(t.name, 'Demo');
      expect(t.files, hasLength(1));
      expect(t.files.first.name, 'ep01.mkv');
      expect(t.files.first.path, 'video/ep01.mkv');
      expect(t.files.first.length, 1234);
    });

    test('parses stats v1', () {
      final s = RqbitStats.fromJson({
        'state': 'live',
        'progress_bytes': 50,
        'total_bytes': 100,
        'finished': false,
        'file_progress': [50],
      });
      expect(s.progress, 0.5);
      expect(s.finished, isFalse);
      expect(s.isError, isFalse);
      expect(s.acceptsOnlyFilesUpdate, isTrue);
    });

    test('stats initializing cannot update only_files', () {
      final s = RqbitStats.fromJson({
        'state': 'initializing',
        'progress_bytes': 0,
        'total_bytes': 0,
        'finished': false,
      });
      expect(s.acceptsOnlyFilesUpdate, isFalse);
      expect(
        RqbitStats.fromJson({
          'state': 'paused',
          'progress_bytes': 0,
          'total_bytes': 1,
          'finished': false,
        }).acceptsOnlyFilesUpdate,
        isTrue,
      );
      expect(
        RqbitApiException(
          statusCode: 500,
          path: '/torrents/0/update_only_files',
          body:
              '{"human_readable":"error updating only_files\\n\\nCaused by:\\n    can\'t update initializing torrent"}',
        ).isInitializingOnlyFiles,
        isTrue,
      );
    });
  });

  group('RqbitClient HTTP', () {
    late HttpServer server;
    late RqbitClient client;
    var added = 0;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        final body = await utf8.decoder.bind(request).join();
        Map<String, Object?> json;
        if (request.method == 'POST' && path == '/torrents') {
          added += 1;
          json = {
            'id': 0,
            'output_folder': '/tmp/out',
            'details': {
              'id': 0,
              'info_hash': 'bb' * 20,
              'name': body.startsWith('magnet:') ? 'FromMagnet' : 'FromFile',
              'files': [
                {
                  'name': 'movie.mp4',
                  'components': ['movie.mp4'],
                  'length': 99,
                  'included': true,
                },
              ],
            },
          };
        } else if (path == '/torrents/0') {
          json = {
            'id': 0,
            'info_hash': 'bb' * 20,
            'name': 'FromMagnet',
            'output_folder': '/tmp/out',
            'files': [
              {
                'name': 'movie.mp4',
                'components': ['movie.mp4'],
                'length': 99,
                'included': true,
              },
            ],
          };
        } else if (path == '/torrents/0/stats/v1') {
          json = {
            'state': 'live',
            'progress_bytes': 10,
            'total_bytes': 99,
            'finished': false,
            'file_progress': [10],
          };
        } else if (path == '/torrents/0/update_only_files' ||
            path == '/torrents/0/forget' ||
            path == '/torrents/0/delete') {
          json = {};
        } else {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(json));
        await request.response.close();
      });
      client = RqbitClient(baseUrl: 'http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    test('adds a magnet and builds a stream URL', () async {
      final t = await client.addMagnet('magnet:?xt=urn:btih:abc');
      expect(t.id, 0);
      expect(t.name, 'FromMagnet');
      expect(added, 1);
      expect(client.streamUrl(t.id, 0), endsWith('/torrents/0/stream/0'));
      final details = await client.details(0);
      expect(details.files.single.name, 'movie.mp4');
      final stats = await client.stats(0);
      expect(stats.progressBytes, 10);
      await client.updateOnlyFiles(0, [0]);
      await client.delete(0, deleteFiles: false);
    });
  });

  test('native cdylib starts a loopback HTTP API', () async {
    final so = File(
      'packages/rqbit_engine/rust/target/release/librqbit_engine.so',
    );
    if (!so.existsSync()) {
      return;
    }
    final dir = await Directory.systemTemp.createTemp('rqbit_engine_test_');
    late final RqbitEngine engine;
    addTearDown(() async {
      engine.stop();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    engine = await RqbitEngine.start(
      savePath: dir.path,
      native: RqbitNative.load(so.absolute.path),
    );
    expect(engine.client.baseUrl, contains('127.0.0.1'));
    final uri = Uri.parse(engine.client.baseUrl);
    final http = HttpClient();
    addTearDown(http.close);
    final req = await http.getUrl(uri);
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    expect(res.statusCode, 200);
    expect(body, contains('torrents'));
  });

  test('failed restart keeps the previous loopback API', () async {
    final so = File(
      'packages/rqbit_engine/rust/target/release/librqbit_engine.so',
    );
    if (!so.existsSync()) {
      return;
    }
    final dir = await Directory.systemTemp.createTemp('rqbit_engine_keep_');
    late final RqbitEngine engine;
    addTearDown(() async {
      engine.stop();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    engine = await RqbitEngine.start(
      savePath: dir.path,
      native: RqbitNative.load(so.absolute.path),
    );
    final uri = Uri.parse(engine.client.baseUrl);
    final oldPort = uri.port;
    expect(oldPort, greaterThan(0));

    await expectLater(
      RqbitEngine.start(savePath: '/dev/null/rqbit-fail'),
      throwsA(isA<StateError>()),
    );
    expect(engine.client.baseUrl, 'http://127.0.0.1:$oldPort');

    final http = HttpClient();
    addTearDown(http.close);
    final req = await http.getUrl(uri);
    final res = await req.close();
    expect(res.statusCode, 200);
  });
}
