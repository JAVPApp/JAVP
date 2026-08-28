import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';
import 'package:javp/services/pairing/device_pairing_client.dart';
import 'package:javp/services/pairing/source_pairing_server.dart';
import 'package:javp/services/storage/sources_export.dart';

/// Lightweight stand-in so pairing HTTP can be exercised without full storage.
class _FakeLibrary extends Fake implements LibraryProvider {
  final added = <Map<String, dynamic>>[];
  List<IptvSource> storedSources = [];
  SourcesExportDocument? lastImported;
  SourcesImportMode? lastImportMode;

  @override
  List<IptvSource> get sources => storedSources;

  @override
  Future<void> addCustomCatalogSource({
    required String name,
    required String catalogUrl,
    String? authToken,
    String? vastUrl,
  }) async {
    added.add({
      'type': 'custom',
      'name': name,
      'url': catalogUrl,
      'authToken': authToken,
      'vastUrl': vastUrl,
    });
  }

  @override
  Future<void> addM3uSource({
    required String name,
    required String playlistUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    bool acceptXtreamPlaylistExport = false,
  }) async {
    added.add({
      'type': 'm3u',
      'name': name,
      'url': playlistUrl,
      'epg': epgUrl,
      'epgSourceId': epgSourceId,
      'epgEnabled': epgEnabled,
    });
  }

  @override
  Future<void> addXtreamSource({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
    String? alternateServerUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    bool vodEnabled = true,
  }) async {
    added.add({
      'type': 'xtream',
      'name': name,
      'server': serverUrl,
      'user': username,
      'epg': epgUrl,
      'epgSourceId': epgSourceId,
      'epgEnabled': epgEnabled,
      'vodEnabled': vodEnabled,
    });
  }

  @override
  Future<void> addMediaServerSource({
    required String name,
    required IptvSourceType type,
    required String serverUrl,
    String? username,
    String? password,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
  }) async {
    added.add({
      'type': type.name,
      'name': name,
      'server': serverUrl,
      'epg': epgUrl,
      'epgSourceId': epgSourceId,
      'epgEnabled': epgEnabled,
    });
  }

  @override
  Future<SourcesExportDocument> buildSourcesExport({
    required SourcesSecretsMode secretsMode,
    String? passphrase,
    Set<String>? sourceIds,
  }) {
    final list = sourceIds == null
        ? storedSources
        : storedSources
            .where((s) => sourceIds.contains(s.id))
            .toList(growable: false);
    return SourcesExportDocument.create(
      sources: list,
      secretsMode: secretsMode,
      passphrase: passphrase,
    );
  }

  @override
  Future<int> importSourcesDocument({
    required SourcesExportDocument document,
    required SourcesImportMode mode,
    String? passphrase,
  }) async {
    lastImported = document;
    lastImportMode = mode;
    storedSources = List<IptvSource>.from(document.sources);
    return storedSources.length;
  }
}

class _FakeProfiles extends Fake implements ProfileProvider {
  SyncSettings syncSettings = SyncSettings.disabled;
  SyncSettings? lastUpdated;
  String lastUpdatedProfileId = 'default';
  final created = <Profile>[];
  List<IptvSource> lastCreatedSources = const [];

  @override
  String get activeProfileId => 'default';

  @override
  Future<void> updateSyncSettings(SyncSettings settings) async {
    await updateSyncSettingsFor(activeProfileId, settings);
  }

  @override
  Future<void> updateSyncSettingsFor(
    String profileId,
    SyncSettings settings,
  ) async {
    lastUpdatedProfileId = profileId;
    lastUpdated = settings;
    syncSettings = settings;
  }

  @override
  Future<Profile> createProfile(String name) async {
    final profile = Profile(
      id: 'paired-${created.length}',
      name: name,
      createdAt: DateTime.utc(2026),
    );
    created.add(profile);
    return profile;
  }

  @override
  Future<Profile> createProfileWithSources({
    required String name,
    required List<IptvSource> sources,
  }) async {
    lastCreatedSources = sources;
    return createProfile(name);
  }
}

SourcePairingServer _server(
  _FakeLibrary library, {
  _FakeProfiles? profiles,
  int port = 18787,
}) {
  return SourcePairingServer(
    library: library,
    profiles: profiles ?? _FakeProfiles(),
    port: port,
  );
}

void main() {
  test('pairing server accepts custom catalog over LAN form API', () async {
    final library = _FakeLibrary();
    final server = _server(library, port: 18787);
    await server.start();
    addTearDown(server.dispose);

    final uri = server.pairingUri;
    expect(uri, isNotNull);
    expect(server.token, isNotNull);
    expect(server.pin, isNotNull);
    expect(server.pin!.length, 6);
    expect(server.appPairUri, isNotNull);
    expect(server.appPairUri!.scheme, 'javp');
    expect(server.httpsPairUri, isNotNull);
    expect(server.httpsPairUri!.scheme, 'https');
    expect(server.httpsPairUri!.host, 'javp.app');
    expect(server.httpsPairUri!.path, '/pair');
    expect(server.qrPayloadUri, server.httpsPairUri);

    final client = HttpClient();
    addTearDown(client.close);

    final form = await client.getUrl(uri!);
    final formRes = await form.close();
    expect(formRes.statusCode, 200);
    final html = await formRes.transform(utf8.decoder).join();
    expect(html, contains('Pair with this device'));
    expect(html, contains('xtream'));
    expect(html, contains('javp://add'));
    expect(html, contains('Open in JAVP'));
    expect(html, contains('javp-sources'));
    expect(html, contains('Download sources JSON'));
    expect(html, isNot(contains('Quick add')));
    expect(html, isNot(contains('SecretBrand')));

    // Bare home URL asks for the PIN instead of "session expired".
    final home = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.boundPort}/'),
    );
    final homeRes = await home.close();
    expect(homeRes.statusCode, 200);
    final unlock = await homeRes.transform(utf8.decoder).join();
    expect(unlock, contains('Enter pairing code'));
    expect(unlock, contains('name="c"'));
    expect(unlock, isNot(contains('Session expired')));

    final bad = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.boundPort}/pair?c=NOPE12'),
    );
    final badRes = await bad.close();
    expect(badRes.statusCode, 200);
    final badHtml = await badRes.transform(utf8.decoder).join();
    expect(badHtml, contains('invalid'));

    final pinUnlock = await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${server.boundPort}/pair?c=${server.pin}',
      ),
    );
    final pinRes = await pinUnlock.close();
    expect(pinRes.statusCode, 200);
    final pinHtml = await pinRes.transform(utf8.decoder).join();
    expect(pinHtml, contains('Pair with this device'));
    expect(pinHtml, contains('Download sources JSON'));

    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/add'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'token': server.token,
        'type': 'custom',
        'name': 'Demo',
        'url': 'https://example.com/catalog.json',
      }),
    );
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    expect(res.statusCode, 200);
    expect(body['ok'], isTrue);
    expect(library.added.single['type'], 'custom');
    expect(library.added.single['url'], 'https://example.com/catalog.json');
  });

  test('pairing server accepts javp://add link payload', () async {
    final library = _FakeLibrary();
    final server = _server(library, port: 18789);
    await server.start();
    addTearDown(server.dispose);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/add'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'token': server.token,
        'javpLink':
            'javp://add?type=custom&url=https%3A%2F%2Fexample.com%2Fcatalog.json&name=Demo',
      }),
    );
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    expect(res.statusCode, 200);
    expect(body['ok'], isTrue);
    expect(body['name'], 'Demo');
    expect(library.added.single['url'], 'https://example.com/catalog.json');
  });

  test('pairing server rejects bad token', () async {
    final library = _FakeLibrary();
    final server = _server(library, port: 18788);
    await server.start();
    addTearDown(server.dispose);

    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.boundPort}/api/add'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'token': 'nope',
        'type': 'm3u',
        'url': 'https://example.com/a.m3u',
      }),
    );
    final res = await req.close();
    expect(res.statusCode, 401);
    expect(library.added, isEmpty);
  });

  test('pairing server import/export over PIN + client', () async {
    final library = _FakeLibrary();
    library.storedSources = [
      IptvSource(
        id: 's1',
        name: 'Demo',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2026, 1, 1),
        playlistUrl: 'https://example.com/c.json',
        password: 'secret-token',
      ),
    ];
    final server = _server(library, port: 18791);
    await server.start();
    addTearDown(server.dispose);

    final request = JavpPairRequest(
      host: '127.0.0.1',
      port: server.boundPort,
      token: server.token!,
      pin: server.pin,
    );
    final guestLib = _FakeLibrary();
    guestLib.storedSources = [
      IptvSource(
        id: 'phone1',
        name: 'Phone catalog',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2026, 1, 2),
        playlistUrl: 'https://phone.example/c.json',
        password: 'phone-secret',
      ),
    ];

    final client = DevicePairingClient(request: request);
    addTearDown(client.close);

    final session = await client.fetchSession();
    expect(session.sourceCount, 1);
    expect(session.sources, hasLength(1));
    expect(session.sources.single.name, 'Demo');
    expect(session.sources.single.type, 'custom');
    expect(session.syncConfigured, isFalse);

    final pull = await client.pullSources();
    expect(pull.sourceCount, 1);
    expect(pull.document.sources.single.password, 'secret-token');

    final filtered = await client.pullSources(sourceIds: {'missing-id'});
    expect(filtered.sourceCount, 0);

    final onlyDemo = await client.pullSources(sourceIds: {'s1'});
    expect(onlyDemo.sourceCount, 1);
    expect(onlyDemo.document.sources.single.id, 's1');

    final doc = await guestLib.buildSourcesExport(
      secretsMode: SourcesSecretsMode.plaintext,
    );
    final pushed = await client.pushSources(
      document: doc,
      mode: SourcesImportMode.merge,
    );
    expect(pushed.count, 1);
    expect(library.lastImported, isNotNull);
    expect(library.lastImportMode, SourcesImportMode.merge);
    expect(library.sources.single.name, 'Phone catalog');

    // PIN alone also authorizes.
    final pinClient = DevicePairingClient(
      request: JavpPairRequest(
        host: '127.0.0.1',
        port: server.boundPort,
        token: '',
        pin: server.pin,
      ),
    );
    addTearDown(pinClient.close);
    final pinSession = await pinClient.fetchSession();
    expect(pinSession.sourceCount, 1);
  });

  test('pairing session exposes syncConfigured without secrets', () async {
    final library = _FakeLibrary();
    final profiles = _FakeProfiles()
      ..syncSettings = const SyncSettings(
        backend: SyncBackend.webdav,
        webdavUrl: 'https://dav.example/remote.php/dav',
        password: 'dav-secret',
      );
    final server = _server(library, profiles: profiles, port: 18792);
    await server.start();
    addTearDown(server.dispose);

    final client = DevicePairingClient(
      request: JavpPairRequest(
        host: '127.0.0.1',
        port: server.boundPort,
        token: server.token!,
      ),
    );
    addTearDown(client.close);

    final session = await client.fetchSession();
    expect(session.syncConfigured, isTrue);
    expect(session.syncBackend, SyncBackend.webdav);
  });

  test('pairing export/import round-trips syncSettings; folder skips path',
      () async {
    final library = _FakeLibrary();
    library.storedSources = [
      IptvSource(
        id: 's1',
        name: 'Demo',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2026, 1, 1),
        playlistUrl: 'https://example.com/c.json',
      ),
    ];
    final hostProfiles = _FakeProfiles()
      ..syncSettings = const SyncSettings(
        backend: SyncBackend.webdav,
        webdavUrl: 'https://dav.example/remote.php/dav',
        username: 'u',
        password: 'dav-pass',
        syncOnOpen: true,
      );
    final server = _server(library, profiles: hostProfiles, port: 18793);
    await server.start();
    addTearDown(server.dispose);

    final client = DevicePairingClient(
      request: JavpPairRequest(
        host: '127.0.0.1',
        port: server.boundPort,
        token: server.token!,
      ),
    );
    addTearDown(client.close);

    final pulled = await client.pullSources(includeSyncSettings: true);
    expect(pulled.syncSettings, isNotNull);
    expect(pulled.syncSettings!.password, 'dav-pass');
    expect(pulled.syncSettings!.webdavUrl, contains('dav.example'));

    final noSync = await client.pullSources(includeSyncSettings: false);
    expect(noSync.syncSettings, isNull);

    final guestDoc = await SourcesExportDocument.create(
      sources: [
        IptvSource(
          id: 'phone1',
          name: 'Phone',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2026, 1, 2),
          playlistUrl: 'https://phone.example/c.json',
        ),
      ],
      secretsMode: SourcesSecretsMode.plaintext,
    );
    final pushed = await client.pushSources(
      document: guestDoc,
      mode: SourcesImportMode.merge,
      syncSettings: const SyncSettings(
        backend: SyncBackend.folder,
        folderPath: r'/phone/sync/path',
      ),
    );
    expect(pushed.syncApply, isNotNull);
    expect(pushed.syncApply!.needsLocalFolderSetup, isTrue);
    expect(pushed.syncApply!.applied, isFalse);
    // Host kept its WebDAV settings — folder path from peer was not applied.
    expect(hostProfiles.syncSettings.backend, SyncBackend.webdav);
    expect(hostProfiles.lastUpdated, isNull);

    final drivePush = await client.pushSources(
      document: guestDoc,
      mode: SourcesImportMode.merge,
      syncSettings: const SyncSettings(
        backend: SyncBackend.googleDrive,
        googleAccessToken: 'atok',
        googleRefreshToken: 'rtok',
      ),
    );
    expect(drivePush.syncApply!.applied, isTrue);
    expect(hostProfiles.syncSettings.backend, SyncBackend.googleDrive);
    expect(hostProfiles.syncSettings.googleRefreshToken, 'rtok');
  });

  test('push can create a new host profile instead of the active one',
      () async {
    final library = _FakeLibrary();
    library.storedSources = [
      IptvSource(
        id: 'tv1',
        name: 'TV',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2026, 1, 1),
        playlistUrl: 'https://tv.example/c.json',
      ),
    ];
    final hostProfiles = _FakeProfiles();
    final server = _server(library, profiles: hostProfiles, port: 18794);
    await server.start();
    addTearDown(server.dispose);

    final client = DevicePairingClient(
      request: JavpPairRequest(
        host: '127.0.0.1',
        port: server.boundPort,
        token: server.token!,
      ),
    );
    addTearDown(client.close);

    final guestDoc = await SourcesExportDocument.create(
      sources: [
        IptvSource(
          id: 'phone1',
          name: 'Phone',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2026, 1, 2),
          playlistUrl: 'https://phone.example/c.json',
        ),
      ],
      secretsMode: SourcesSecretsMode.plaintext,
    );
    final pushed = await client.pushSources(
      document: guestDoc,
      mode: SourcesImportMode.merge,
      addAsNewProfile: true,
      profileName: 'Kids',
      syncSettings: const SyncSettings(
        backend: SyncBackend.webdav,
        webdavUrl: 'https://dav.example/remote.php/dav',
        password: 'p',
      ),
    );
    expect(pushed.profileName, 'Kids');
    expect(hostProfiles.created.single.name, 'Kids');
    expect(hostProfiles.lastCreatedSources.single.id, 'phone1');
    expect(hostProfiles.lastUpdatedProfileId, 'paired-0');
    expect(hostProfiles.syncSettings.backend, SyncBackend.webdav);
    // Active TV library is untouched.
    expect(library.storedSources.single.id, 'tv1');
  });
}
