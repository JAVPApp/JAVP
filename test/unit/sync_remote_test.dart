import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/services/sync/google_drive_remote.dart';
import 'package:javp/services/sync/sync_remote.dart';

void main() {
  group('LocalFolderRemote', () {
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('javp-remote-test');
    });

    tearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });

    test('writes, reads, lists, and deletes nested files', () async {
      final remote = LocalFolderRemote(folder.path);

      await remote.write('javp/profiles/p1.json', '{"a":1}');

      expect(await remote.read('javp/profiles/p1.json'), '{"a":1}');
      expect(await remote.list('javp/profiles'), ['p1.json']);

      await remote.delete('javp/profiles/p1.json');
      expect(await remote.read('javp/profiles/p1.json'), isNull);
    });

    test('reading a missing file returns null instead of throwing', () async {
      final remote = LocalFolderRemote(folder.path);

      expect(await remote.read('javp/profiles/ghost.json'), isNull);
      expect(await remote.list('javp/nothing-here'), isEmpty);
    });

    test('leaves no partial file behind for a sync client to pick up',
        () async {
      final remote = LocalFolderRemote(folder.path);
      await remote.write('javp/profiles/p1.json', '{"first":true}');

      await remote.write('javp/profiles/p1.json', '{"second":true}');

      final names = await remote.list('javp/profiles');
      expect(names, ['p1.json'], reason: 'the .tmp file must be renamed away');
    });

    test('overlapping writes do not collide on a shared temp name', () async {
      final remote = LocalFolderRemote(folder.path);

      await Future.wait([
        for (var i = 0; i < 12; i++)
          remote.write('javp/profiles/p1.json', '{"writer":$i}'),
      ]);

      expect(await remote.list('javp/profiles'), ['p1.json']);
      expect(await remote.read('javp/profiles/p1.json'), startsWith('{"writer"'));
    });

    test('a compare-and-swap only writes against the version it read',
        () async {
      final remote = LocalFolderRemote(folder.path);
      await remote.write('javp/profiles/p1.json', '{"v":1}');
      final read = await remote.readWithRevision('javp/profiles/p1.json');

      final first = await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{"v":2}',
        expectedRevision: read.revision,
      );
      final second = await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{"v":3}',
        expectedRevision: read.revision,
      );

      expect(first, isTrue);
      expect(second, isFalse, reason: 'the revision is stale by now');
      expect(await remote.read('javp/profiles/p1.json'), '{"v":2}');
    });

    test('creating a file expects it to be absent', () async {
      final remote = LocalFolderRemote(folder.path);

      final created = await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{"v":1}',
        expectedRevision: null,
      );
      final again = await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{"v":2}',
        expectedRevision: null,
      );

      expect(created, isTrue);
      expect(again, isFalse, reason: 'someone else created it first');
    });
  });

  group('WebDavRemote', () {
    Uri base() => Uri.parse('https://cloud.example.com/dav');

    test('sends basic auth and PUTs to the resolved path', () async {
      final seen = <String, String>{};
      final remote = WebDavRemote(
        baseUrl: base(),
        username: 'me',
        password: 'secret',
        client: MockClient((request) async {
          seen[request.method] = request.url.path;
          seen['auth'] = request.headers['authorization'] ?? '';
          return http.Response('', 201);
        }),
      );

      await remote.write('javp/profiles/p1.json', '{}');

      expect(seen['PUT'], '/dav/javp/profiles/p1.json');
      expect(
        seen['auth'],
        'Basic ${base64Encode(utf8.encode('me:secret'))}',
      );
    });

    test('creates parent collections before uploading', () async {
      final created = <String>[];
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((request) async {
          if (request.method == 'MKCOL') created.add(request.url.path);
          return http.Response('', 201);
        }),
      );

      await remote.write('javp/profiles/p1.json', '{}');

      expect(created, ['/dav/javp', '/dav/javp/profiles']);
    });

    test('treats a missing file as null rather than an error', () async {
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((_) async => http.Response('nope', 404)),
      );

      expect(await remote.read('javp/profiles/p1.json'), isNull);
      expect(await remote.list('javp/profiles'), isEmpty);
    });

    test('reports bad credentials as a sync error', () async {
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((_) async => http.Response('denied', 401)),
      );

      expect(remote.probe(), throwsA(isA<SyncRemoteException>()));
    });

    test('pins a conditional write to the ETag it read', () async {
      final headers = <String, String>{};
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response('{"v":1}', 200, headers: {'etag': '"abc123"'});
          }
          if (request.method == 'PUT') headers.addAll(request.headers);
          return http.Response('', 204);
        }),
      );

      final read = await remote.readWithRevision('javp/profiles/p1.json');
      await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{"v":2}',
        expectedRevision: read.revision,
      );

      expect(read.revision, '"abc123"');
      expect(headers['if-match'], '"abc123"');
    });

    test('creating a snapshot requires that nobody else already did', () async {
      final headers = <String, String>{};
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((request) async {
          if (request.method == 'PUT') headers.addAll(request.headers);
          return http.Response('', 201);
        }),
      );

      await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{}',
        expectedRevision: null,
      );

      expect(headers['if-none-match'], '*');
    });

    test('a rejected precondition is a lost race, not a failure', () async {
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((request) async {
          if (request.method == 'PUT') return http.Response('', 412);
          return http.Response('', 201);
        }),
      );

      expect(
        await remote.writeIfUnchanged(
          'javp/profiles/p1.json',
          '{}',
          expectedRevision: '"abc123"',
        ),
        isFalse,
      );
    });

    test('a server with no ETag still yields a usable revision', () async {
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((_) async => http.Response('{"v":1}', 200)),
      );

      final read = await remote.readWithRevision('javp/profiles/p1.json');

      expect(read.revision, isNotNull);
      expect(read.revision, fingerprint('{"v":1}'));
    });

    test('parses file names out of a PROPFIND listing', () async {
      const body = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/javp/profiles/</d:href></d:response>
  <d:response><d:href>/dav/javp/profiles/p1.json</d:href></d:response>
  <d:response><d:href>/dav/javp/profiles/kids%20profile.json</d:href></d:response>
</d:multistatus>''';
      final remote = WebDavRemote(
        baseUrl: base(),
        client: MockClient((_) async => http.Response(body, 207)),
      );

      expect(
        await remote.list('javp/profiles'),
        ['p1.json', 'kids profile.json'],
        reason: 'collections are skipped and names are URL-decoded',
      );
    });
  });

  group('GoogleDriveRemote', () {
    GoogleDriveRemote remoteWith(MockClient client) {
      return GoogleDriveRemote(
        accessToken: 'access',
        refreshToken: 'refresh',
        clientId: 'client.apps.googleusercontent.com',
        tokenExpiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
        client: client,
      );
    }

    test('probes Drive with about.get', () async {
      final remote = remoteWith(
        MockClient((request) async {
          expect(request.url.path, '/drive/v3/about');
          return http.Response('{"user":{"displayName":"Test"}}', 200);
        }),
      );

      await remote.probe();
      remote.close();
    });

    test('a conditional write goes through when nothing moved', () async {
      var stored = '{"v":1}';
      final remote = remoteWith(
        MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.queryParameters['alt'] == 'media') {
            return http.Response(stored, 200);
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/files/file1') &&
              request.url.queryParameters['fields'] != null) {
            return http.Response('{"md5Checksum":"abc","version":"1"}', 200);
          }
          if (request.method == 'GET') {
            return http.Response(
              '{"files":[{"id":"file1","name":"p1.json","createdTime":"2026-01-01T00:00:00Z"}]}',
              200,
            );
          }
          if (request.method == 'PATCH') {
            stored = request.body;
            return http.Response('', 204);
          }
          return http.Response('unexpected ${request.method} ${request.url}', 500);
        }),
      );

      final read = await remote.readWithRevision('javp/profiles/p1.json');
      final ok = await remote.writeIfUnchanged(
        'javp/profiles/p1.json',
        '{"v":2}',
        expectedRevision: read.revision,
      );

      expect(ok, isTrue);
      expect(read.revision, 'abc');
      expect(stored, '{"v":2}');
      remote.close();
    });

    // Drive v3 accepts If-Match and ignores it, so the check has to happen
    // here: a file that changed since we read it is a lost race, not a write.
    test('a file that changed under us is not overwritten', () async {
      final remote = remoteWith(
        MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/files/file1') &&
              request.url.queryParameters['fields'] != null) {
            return http.Response('{"md5Checksum":"other","version":"2"}', 200);
          }
          if (request.method == 'GET') {
            return http.Response(
              '{"files":[{"id":"file1","name":"p1.json","createdTime":"2026-01-01T00:00:00Z"}]}',
              200,
            );
          }
          return http.Response('unexpected ${request.method} ${request.url}', 500);
        }),
      );

      expect(
        await remote.writeIfUnchanged(
          'javp/profiles/p1.json',
          '{}',
          expectedRevision: 'abc',
        ),
        isFalse,
      );
      remote.close();
    });

    test('a snapshot deleted under us is recreated, not failed', () async {
      var created = false;
      final remote = remoteWith(
        MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.queryParameters['alt'] == 'media') {
            return http.Response('{"v":1}', 200);
          }
          if (request.method == 'GET' &&
              request.url.path.contains('/files/file1') &&
              request.url.queryParameters['fields'] != null) {
            return http.Response('{"md5Checksum":"abc","version":"1"}', 200);
          }
          if (request.method == 'GET') {
            return http.Response(
              '{"files":[{"id":"file1","name":"p1.json","createdTime":"2026-01-01T00:00:00Z"}]}',
              200,
            );
          }
          // Another device emptied the trash between our read and our write.
          if (request.method == 'PATCH') return http.Response('', 404);
          if (request.method == 'POST') {
            created = true;
            return http.Response('{"id":"file2"}', 200);
          }
          return http.Response('unexpected ${request.method} ${request.url}', 500);
        }),
      );

      await remote.write('javp/profiles/p1.json', '{"v":2}');

      expect(created, isTrue);
      remote.close();
    });
  });

  group('SyncSettings', () {
    test('is not configured until the chosen backend has a target', () {
      expect(const SyncSettings().isConfigured, isFalse);
      expect(
        const SyncSettings(backend: SyncBackend.folder).isConfigured,
        isFalse,
      );
      expect(
        const SyncSettings(backend: SyncBackend.folder, folderPath: '/tmp/x')
            .isConfigured,
        isTrue,
      );
      expect(
        const SyncSettings(backend: SyncBackend.webdav, webdavUrl: 'nonsense')
            .isConfigured,
        isFalse,
      );
      expect(
        const SyncSettings(
          backend: SyncBackend.googleDrive,
          googleClientId: 'client.apps.googleusercontent.com',
        ).isConfigured,
        isFalse,
      );
      expect(
        const SyncSettings(
          backend: SyncBackend.googleDrive,
          googleClientId: 'client.apps.googleusercontent.com',
          googleRefreshToken: 'refresh',
        ).isConfigured,
        isTrue,
      );
    });

    test('builds the remote that matches the backend', () {
      final folder = const SyncSettings(
        backend: SyncBackend.folder,
        folderPath: '/tmp/x',
      ).createRemote();
      final dav = const SyncSettings(
        backend: SyncBackend.webdav,
        webdavUrl: 'https://cloud.example.com/dav',
      ).createRemote();
      final drive = const SyncSettings(
        backend: SyncBackend.googleDrive,
        googleClientId: 'client.apps.googleusercontent.com',
        googleAccessToken: 'access',
        googleRefreshToken: 'refresh',
      ).createRemote();

      expect(folder, isA<LocalFolderRemote>());
      expect(dav, isA<WebDavRemote>());
      expect(drive, isA<GoogleDriveRemote>());
      expect(const SyncSettings().createRemote(), isNull);
      folder?.close();
      dav?.close();
      drive?.close();
    });

    test('survives a round trip through JSON', () {
      final settings = SyncSettings(
        backend: SyncBackend.googleDrive,
        googleClientId: 'client.apps.googleusercontent.com',
        googleAccessToken: 'access',
        googleRefreshToken: 'refresh',
        googleTokenExpiresAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
        syncOnOpen: false,
      );

      final restored = SyncSettings.fromJson(settings.toJson());

      expect(restored.backend, SyncBackend.googleDrive);
      expect(restored.googleRefreshToken, 'refresh');
      expect(restored.googleTokenExpiresAt, settings.googleTokenExpiresAt);
      expect(restored.syncOnOpen, isFalse);
    });
  });
}
