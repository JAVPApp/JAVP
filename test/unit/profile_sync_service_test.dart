import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/live_scrub_mode.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/models/sports_models.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/sync/profile_snapshot.dart';
import 'package:javp/services/sync/profile_sync_service.dart';
import 'package:javp/services/sync/sync_remote.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late Directory folder;
  late SyncRemote remote;

  final profile = Profile(id: 'p1', name: 'Me', createdAt: DateTime.utc(2026));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    folder = await Directory.systemTemp.createTemp('javp-sync-test');
    remote = LocalFolderRemote(folder.path);
  });

  tearDown(() async {
    remote.close();
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  /// Two installs of the app, each with its own storage namespace, both
  /// syncing the same profile through one folder.
  ProfileSyncService device(String name) {
    return ProfileSyncService(
      store: LibraryStore(prefs: prefs, profileId: 'device-$name'),
      profile: profile,
      deviceId: name,
    );
  }

  MediaItem watched(String id, {required DateTime at, double progress = 0}) {
    return MediaItem(
      id: id,
      title: id,
      playUrl: 'https://example.com/$id',
      kind: MediaKind.vod,
      origin: MediaOrigin.url,
      progress: progress,
      lastWatchedAt: at,
    );
  }

  IptvSource source(String id) => IptvSource(
    id: id,
    name: id,
    type: IptvSourceType.m3u,
    createdAt: DateTime.utc(2026),
    playlistUrl: 'https://example.com/$id.m3u',
  );

  test('probe rejects a folder that is not there', () async {
    final missing = LocalFolderRemote('${folder.path}/nope');

    expect(missing.probe(), throwsA(isA<SyncRemoteException>()));
  });

  test('first sync uploads without a remote to merge', () async {
    final phone = device('phone');
    await phone.store.saveSources([source('s1')]);

    final outcome = await phone.sync(remote);

    expect(outcome.pulled, isFalse);
    expect(outcome.pushed, isTrue);
    expect(
      await remote.read(ProfileSyncService.snapshotPath(profile.id)),
      isNotNull,
    );
  });

  test('applyLocal: false pushes without writing this device', () async {
    final phone = device('phone');
    await phone.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.2),
    ]);
    await phone.sync(remote);

    final tv = device('tv');
    await tv.store.saveHistory([
      watched('show', at: DateTime.utc(2026, 3, 2), progress: 0.8),
    ]);
    final push = await tv.sync(remote, applyLocal: false);
    expect(push.pushed, isTrue);
    expect((await tv.store.loadHistory()).single.id, 'show');
    expect(
      (await tv.store.loadHistory()).any((m) => m.id == 'movie'),
      isFalse,
      reason: 'playback push must not apply the remote merge yet',
    );

    final apply = await tv.sync(remote);
    expect((await tv.store.loadHistory()).map((m) => m.id).toSet(), {
      'movie',
      'show',
    });
    expect(apply.changedSections, contains(SnapshotSections.history));
  });

  test('a second device adopts what the first one uploaded', () async {
    final phone = device('phone');
    await phone.store.saveSources([source('s1')]);
    await phone.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.3),
    ]);
    await phone.sync(remote);

    final tv = device('tv');
    final outcome = await tv.sync(remote);

    expect(outcome.pulled, isTrue);
    expect((await tv.store.loadSources()).single.id, 's1');
    expect((await tv.store.loadHistory()).single.progress, 0.3);
  });

  test('a fresh device takes preferences it has never set itself', () async {
    final tv = device('tv');
    await tv.store.saveLiveScrubMode(LiveScrubMode.program);
    await tv.sync(remote);

    final phone = device('phone');
    await phone.sync(remote);

    expect(
      await phone.store.loadLiveScrubMode(),
      LiveScrubMode.program,
      reason: 'an untouched default must not outrank a chosen setting',
    );
  });

  test('proxy settings sync including auth across devices', () async {
    final tv = device('tv');
    await tv.store.saveProxySettings(
      const ProxySettings(
        enabled: true,
        type: ProxyType.socks5,
        host: 'proxy.example',
        port: 1080,
        username: 'u1',
        password: 'p1',
        routeTorrents: false,
      ),
    );
    await tv.sync(remote);

    final phone = device('phone');
    await phone.sync(remote);
    final pulled = await phone.store.loadProxySettings();
    expect(pulled.enabled, isTrue);
    expect(pulled.type, ProxyType.socks5);
    expect(pulled.host, 'proxy.example');
    expect(pulled.port, 1080);
    expect(pulled.username, 'u1');
    expect(pulled.password, 'p1');
    expect(pulled.routeTorrents, isFalse);

    final published = ProfileSnapshot.tryDecode(
      (await remote.read(ProfileSyncService.snapshotPath(profile.id)))!,
    )!;
    final wire = published.dataFor(SnapshotSections.proxySettings);
    expect(wire, isA<Map>());
    expect((wire as Map)['password'], 'p1');
  });

  test('Plex connection URLs and account token sync across devices', () async {
    final tv = device('tv');
    await tv.store.saveSources([
      IptvSource(
        id: 'plex-1',
        name: 'Home',
        type: IptvSourceType.plex,
        createdAt: DateTime.utc(2026, 1, 1),
        serverUrl: 'http://192.168.1.10:32400',
        alternateServerUrl: 'https://abc.plex.direct:32400',
        extraServerUrls: const ['https://relay.plex.direct:32400'],
        username: 'machine-1',
        password: 'server-token',
        plexAccountToken: 'plex-tv-token',
      ),
    ]);
    await tv.sync(remote);

    final phone = device('phone');
    await phone.sync(remote);
    final pulled = (await phone.store.loadSources()).single;
    expect(pulled.serverUrl, 'http://192.168.1.10:32400');
    expect(pulled.alternateServerUrl, 'https://abc.plex.direct:32400');
    expect(pulled.extraServerUrls, ['https://relay.plex.direct:32400']);
    expect(pulled.password, 'server-token');
    expect(pulled.plexAccountToken, 'plex-tv-token');

    final published = ProfileSnapshot.tryDecode(
      (await remote.read(ProfileSyncService.snapshotPath(profile.id)))!,
    )!;
    final wire =
        (published.dataFor(SnapshotSections.sources) as List).single as Map;
    expect(wire['password'], 'server-token');
    expect(wire['plexAccountToken'], 'plex-tv-token');
    expect(wire['extraServerUrls'], ['https://relay.plex.direct:32400']);
  });

  test('skip, speed cycle, and sports follows sync across devices', () async {
    final tv = device('tv');
    await tv.store.saveSkipSettings(
      const SkipSegmentSettings(autoSkipIntro: true, autoSkipCredits: true),
    );
    await tv.store.saveCyclePlaybackSpeeds(const [1.0, 1.5, 2.0]);
    await tv.store.saveSportsFollows(
      const SportsPrefs(followedLeagueIds: {'4328'}),
    );
    await tv.sync(remote);

    final phone = device('phone');
    await phone.sync(remote);

    final skip = await phone.store.loadSkipSettings();
    expect(skip.autoSkipIntro, isTrue);
    expect(skip.autoSkipCredits, isTrue);
    expect(await phone.store.loadCyclePlaybackSpeeds(), const [1.0, 1.5, 2.0]);
    final sports = await phone.store.loadSportsFollows();
    expect(sports.followedLeagueIds, {'4328'});
    expect(sports.apiKey, isEmpty);
  });

  test('a first sync that fails leaves this device a newcomer', () async {
    final tv = device('tv');
    await tv.store.saveSources([source('s1')]);
    await tv.sync(remote);

    // The phone's first sync dies after it has already looked at local disk.
    final phone = device('phone');
    await expectLater(
      phone.sync(_FailingWriteRemote(remote)),
      throwsA(isA<SyncRemoteException>()),
    );

    await phone.sync(remote);

    expect(
      (await phone.store.loadSources()).single.id,
      's1',
      reason: 'the retry must still adopt, not overwrite with nothing',
    );
    final published = ProfileSnapshot.tryDecode(
      (await remote.read(ProfileSyncService.snapshotPath(profile.id)))!,
    )!;
    expect(
      (published.dataFor(SnapshotSections.sources) as List),
      hasLength(1),
      reason: 'the folder must still hold the library it started with',
    );
  });

  test('a row this build cannot read does not fail the sync', () async {
    final tv = device('tv');
    await tv.store.saveSources([source('s1')]);
    await tv.sync(remote);

    // A newer build wrote a category kind this one has never heard of.
    final path = ProfileSyncService.snapshotPath(profile.id);
    final raw = jsonDecode((await remote.read(path))!) as Map<String, dynamic>;
    (raw['sections'] as Map<String, dynamic>)[SnapshotSections.categories] = {
      'updatedAt': DateTime.utc(2026, 4, 1).toIso8601String(),
      'data': [
        {'id': 'c1', 'name': 'Radio', 'kind': 'audio'},
      ],
    };
    await remote.write(path, jsonEncode(raw));

    final phone = device('phone');
    await phone.sync(remote);

    expect((await phone.store.loadSources()).single.id, 's1');
    expect(await phone.store.loadCategories(), isEmpty);
  });

  test('first sync with local data does not adopt an empty remote', () async {
    // Another install synced the shared default profile while still empty.
    final empty = device('empty');
    await empty.sync(remote);

    final phone = device('phone');
    await phone.store.saveSources([source('s1'), source('s2')]);
    await phone.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.5),
    ]);

    final outcome = await phone.sync(remote);

    expect((await phone.store.loadSources()).map((s) => s.id), ['s1', 's2']);
    expect((await phone.store.loadHistory()).single.id, 'movie');
    expect(outcome.pushed, isTrue);
    final remoteSnapshot = ProfileSnapshot.tryDecode(
      (await remote.read(ProfileSyncService.snapshotPath(profile.id)))!,
    )!;
    expect(
      (remoteSnapshot.dataFor(SnapshotSections.sources) as List).length,
      2,
    );
  });

  test('re-sync with unchanged playheads skips history rewrite', () async {
    final phone = device('phone');
    await phone.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.4),
    ]);
    final first = await phone.sync(remote);
    expect(first.pushed, isTrue);

    // Disk already matches what we would merge — apply must not list history
    // as changed (coalesce-only hash churn used to rewrite prefs and hitch Home).
    final second = await phone.sync(remote);
    expect(second.changedSections, isNot(contains(SnapshotSections.history)));
    expect((await phone.store.loadHistory()).single.progress, 0.4);
  });

  test('progress made on either device survives a round trip', () async {
    final phone = device('phone');
    final tv = device('tv');
    await phone.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.2),
    ]);
    await phone.sync(remote);
    await tv.sync(remote);

    // Each device watches something different, then both sync.
    await tv.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 5), progress: 0.9),
      watched('tv-only', at: DateTime.utc(2026, 3, 5)),
    ]);
    await phone.store.saveHistory([
      watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.2),
      watched('phone-only', at: DateTime.utc(2026, 3, 2)),
    ]);
    await tv.sync(remote);
    await phone.sync(remote);
    await tv.sync(remote);

    for (final d in [phone, tv]) {
      final history = await d.store.loadHistory();
      expect(
        history.map((e) => e.id),
        containsAll(['movie', 'tv-only', 'phone-only']),
        reason: '${d.deviceId} should hold every watched title',
      );
      expect(history.firstWhere((e) => e.id == 'movie').progress, 0.9);
    }
  });

  test(
    'remove from history is not resurrected by a peer that still has it',
    () async {
      final phone = device('phone');
      final tv = device('tv');
      await phone.store.saveHistory([
        watched('movie', at: DateTime.utc(2026, 3, 1), progress: 0.5),
        watched('keep', at: DateTime.utc(2026, 3, 2)),
      ]);
      await phone.sync(remote);
      await tv.sync(remote);

      await phone.store.saveHistory([
        watched('keep', at: DateTime.utc(2026, 3, 2)),
      ]);
      await phone.store.saveHistoryDeleted({
        'movie': DateTime.utc(2026, 3, 10, 12),
      });
      await phone.sync(remote);
      await tv.sync(remote);

      for (final d in [phone, tv]) {
        final history = await d.store.loadHistory();
        expect(history.map((e) => e.id), [
          'keep',
        ], reason: '${d.deviceId} must keep the delete');
        expect(
          (await d.store.loadHistoryDeleted()).containsKey('movie'),
          isTrue,
        );
      }
    },
  );

  test('an edit on one device does not revert an untouched section', () async {
    final phone = device('phone');
    final tv = device('tv');
    await phone.store.saveSources([source('s1')]);
    await phone.store.saveFavoriteChannelIds(['bbc']);
    await phone.sync(remote);
    await tv.sync(remote);

    // Only the TV changes favourites; the phone changes only sources.
    await tv.store.saveFavoriteChannelIds(['bbc', 'itv']);
    await tv.sync(remote);
    await phone.store.saveSources([source('s1'), source('s2')]);
    await phone.sync(remote);
    await tv.sync(remote);

    expect(await phone.store.loadFavoriteChannelIds(), ['bbc', 'itv']);
    expect((await tv.store.loadSources()).map((s) => s.id), ['s1', 's2']);
  });

  test('a deleted source stays deleted after the other device syncs', () async {
    final phone = device('phone');
    final tv = device('tv');
    await phone.store.saveSources([source('s1'), source('s2')]);
    await phone.sync(remote);
    await tv.sync(remote);

    await phone.store.saveSources([source('s1')]);
    await phone.sync(remote);
    await tv.sync(remote);

    expect((await tv.store.loadSources()).map((s) => s.id), ['s1']);
  });

  test(
    'syncing twice with no changes uploads nothing the second time',
    () async {
      final phone = device('phone');
      await phone.store.saveSources([source('s1')]);
      await phone.sync(remote);

      final second = await phone.sync(remote);

      expect(second.pushed, isFalse);
      expect(second.changedSections, isEmpty);
    },
  );

  test('derived caches are never written to the sync folder', () async {
    final phone = device('phone');
    await phone.sync(remote);

    final raw =
        await remote.read(ProfileSyncService.snapshotPath(profile.id)) ?? '';
    final snapshot = ProfileSnapshot.tryDecode(raw)!;

    expect(snapshot.sections.keys, unorderedEquals(SnapshotSections.all));
    expect(snapshot.section('catalog'), isNull);
    expect(snapshot.section('vodCache'), isNull);
  });

  test('a corrupt remote snapshot is replaced rather than applied', () async {
    final phone = device('phone');
    await phone.store.saveSources([source('s1')]);
    await remote.write(
      ProfileSyncService.snapshotPath(profile.id),
      'not json at all',
    );

    final outcome = await phone.sync(remote);

    expect(outcome.pulled, isFalse);
    expect(outcome.pushed, isTrue);
    expect((await phone.store.loadSources()).single.id, 's1');
  });

  test('remote profiles can be discovered by a new device', () async {
    await device('phone').sync(remote);

    final found = await ProfileSyncService.listRemoteProfiles(remote);

    expect(found.single.profileId, 'p1');
    expect(found.single.profileName, 'Me');
  });

  group('concurrent devices', () {
    test('a push that loses the race is retried against the winner', () async {
      final phone = device('phone');
      final tv = device('tv');
      await phone.store.saveHistory([
        watched('phone-movie', at: DateTime.utc(2026, 3, 1)),
      ]);
      await tv.store.saveHistory([
        watched('tv-movie', at: DateTime.utc(2026, 3, 2)),
      ]);

      // The TV completes a whole sync inside the phone's read-merge-write gap.
      var interfered = false;
      final racing = _RacingRemote(
        remote,
        onBeforeWrite: () async {
          if (interfered) return;
          interfered = true;
          await tv.sync(remote);
        },
      );

      await phone.sync(racing);

      expect(interfered, isTrue);
      expect(racing.writeAttempts, greaterThan(1), reason: 'first write lost');
      expect(
        (await phone.store.loadHistory()).map((e) => e.id),
        containsAll(['phone-movie', 'tv-movie']),
      );
      final published = ProfileSnapshot.tryDecode(
        (await remote.read(ProfileSyncService.snapshotPath(profile.id)))!,
      )!;
      expect(
        (published.dataFor(SnapshotSections.history) as List).map(
          (e) => e['id'],
        ),
        containsAll(['phone-movie', 'tv-movie']),
        reason: 'the winner must not lose the loser\'s entries',
      );
    });

    test(
      'gives up rather than clobbering a remote that never settles',
      () async {
        final phone = device('phone');
        final tv = device('tv');
        await tv.sync(remote);

        var round = 0;
        final racing = _RacingRemote(
          remote,
          onBeforeWrite: () async {
            // A different device rewrites the file before every attempt.
            await tv.store.saveFavoriteChannelIds(['ch${round++}']);
            await tv.sync(remote);
          },
        );

        await expectLater(
          phone.sync(racing, maxAttempts: 2),
          throwsA(isA<SyncRemoteException>()),
        );
        expect(racing.writeAttempts, 2);
      },
    );

    test('a stale revision is refused instead of overwriting', () async {
      const path = 'javp/profiles/p1.json';
      await remote.write(path, '{"v":1}');
      final stale = await remote.readWithRevision(path);
      await remote.write(path, '{"v":2}');

      final ok = await remote.writeIfUnchanged(
        path,
        '{"v":3}',
        expectedRevision: stale.revision,
      );

      expect(ok, isFalse);
      expect(await remote.read(path), '{"v":2}');
    });

    test('a source added during a slow remote read is kept', () async {
      final phone = device('phone');
      await phone.store.saveSources([source('s1')]);
      await phone.sync(remote);

      final slow = _SlowReadRemote(
        remote,
        onDuringRead: () async {
          await phone.store.saveSources([source('s1'), source('s2')]);
        },
      );

      await phone.sync(slow);

      expect((await phone.store.loadSources()).map((s) => s.id), ['s1', 's2']);
    });
  });

  group('damaged remote file', () {
    test('is kept aside instead of being silently replaced', () async {
      final phone = device('phone');
      await phone.store.saveSources([source('s1')]);
      await remote.write(
        ProfileSyncService.snapshotPath(profile.id),
        'not json at all',
      );

      await phone.sync(remote);

      final names = await remote.list(ProfileSyncService.profilesFolder);
      final backup = names.firstWhere((n) => n.endsWith('.json.bak'));
      expect(
        await remote.read('${ProfileSyncService.profilesFolder}/$backup'),
        'not json at all',
      );
    });

    test('the kept copy is not mistaken for a profile', () async {
      final phone = device('phone');
      await remote.write(
        ProfileSyncService.snapshotPath(profile.id),
        'not json at all',
      );
      await phone.sync(remote);

      final found = await ProfileSyncService.listRemoteProfiles(remote);

      expect(found.map((e) => e.profileId), ['p1']);
    });
  });
}

/// Wraps a remote so another device can slip a write in between our read and
/// our write — the exact window a compare-and-swap has to notice.
class _RacingRemote implements SyncRemote {
  _RacingRemote(this._inner, {required this.onBeforeWrite});

  final SyncRemote _inner;
  final Future<void> Function() onBeforeWrite;
  int writeAttempts = 0;

  @override
  String get label => _inner.label;

  @override
  Future<void> probe({bool requireWrite = true}) =>
      _inner.probe(requireWrite: requireWrite);

  @override
  Future<List<String>> list(String dir) => _inner.list(dir);

  @override
  Future<String?> read(String path) => _inner.read(path);

  @override
  Future<RemoteRead> readWithRevision(String path) =>
      _inner.readWithRevision(path);

  @override
  Future<void> write(String path, String contents) =>
      _inner.write(path, contents);

  @override
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  }) async {
    writeAttempts++;
    await onBeforeWrite();
    return _inner.writeIfUnchanged(
      path,
      contents,
      expectedRevision: expectedRevision,
    );
  }

  @override
  Future<void> delete(String path) => _inner.delete(path);

  @override
  void close() => _inner.close();
}

/// Reads fine, but every write dies — the network dropping halfway through a
/// sync, which must not leave the device thinking it has synced before.
class _FailingWriteRemote implements SyncRemote {
  _FailingWriteRemote(this._inner);

  final SyncRemote _inner;

  @override
  String get label => _inner.label;

  @override
  Future<void> probe({bool requireWrite = true}) =>
      _inner.probe(requireWrite: requireWrite);

  @override
  Future<List<String>> list(String dir) => _inner.list(dir);

  @override
  Future<String?> read(String path) => _inner.read(path);

  @override
  Future<RemoteRead> readWithRevision(String path) =>
      _inner.readWithRevision(path);

  @override
  Future<void> write(String path, String contents) async {
    throw SyncRemoteException('the network went away');
  }

  @override
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  }) async {
    throw SyncRemoteException('the network went away');
  }

  @override
  Future<void> delete(String path) => _inner.delete(path);

  @override
  void close() => _inner.close();
}

/// Delays the remote read so local edits can land while sync is in flight —
/// the race that used to wipe a just-added source on apply.
class _SlowReadRemote implements SyncRemote {
  _SlowReadRemote(this._inner, {required this.onDuringRead});

  final SyncRemote _inner;
  final Future<void> Function() onDuringRead;
  var _fired = false;

  @override
  String get label => _inner.label;

  @override
  Future<void> probe({bool requireWrite = true}) =>
      _inner.probe(requireWrite: requireWrite);

  @override
  Future<List<String>> list(String dir) => _inner.list(dir);

  @override
  Future<String?> read(String path) => _inner.read(path);

  @override
  Future<RemoteRead> readWithRevision(String path) async {
    if (!_fired) {
      _fired = true;
      await onDuringRead();
    }
    return _inner.readWithRevision(path);
  }

  @override
  Future<void> write(String path, String contents) =>
      _inner.write(path, contents);

  @override
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  }) => _inner.writeIfUnchanged(
    path,
    contents,
    expectedRevision: expectedRevision,
  );

  @override
  Future<void> delete(String path) => _inner.delete(path);

  @override
  void close() => _inner.close();
}
