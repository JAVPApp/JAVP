import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/sync/profile_snapshot.dart';

void main() {
  ProfileSnapshot snapshot({
    required String deviceId,
    required Map<String, (DateTime, Object?)> sections,
    DateTime? updatedAt,
  }) {
    return ProfileSnapshot(
      profileId: 'p1',
      profileName: 'Me',
      deviceId: deviceId,
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
      sections: {
        for (final e in sections.entries)
          e.key: SnapshotSection(updatedAt: e.value.$1, data: e.value.$2),
      },
    );
  }

  Map<String, dynamic> watched(String id, {String? at, double progress = 0}) {
    return {
      'id': id,
      'title': id,
      'playUrl': 'https://example.com/$id',
      'kind': 'vod',
      'origin': 'url',
      'progress': progress,
      'lastWatchedAt': at,
    };
  }

  test('round-trips through JSON', () {
    final original = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.watchlist: (DateTime.utc(2026, 2, 1), [watched('a')]),
        SnapshotSections.liveScrubMode: (DateTime.utc(2026, 2, 2), 'dvr'),
      },
    );

    final decoded = ProfileSnapshot.tryDecode(original.encode());

    expect(decoded, isNotNull);
    expect(decoded!.profileId, 'p1');
    expect(decoded.dataFor(SnapshotSections.liveScrubMode), 'dvr');
    expect(
      decoded.section(SnapshotSections.watchlist)!.updatedAt,
      DateTime.utc(2026, 2, 1),
    );
  });

  test('rejects a snapshot written by a newer schema', () {
    final future = {
      ...snapshot(deviceId: 'phone', sections: const {}).toJson(),
      'schema': ProfileSnapshot.currentSchema + 1,
    };

    expect(ProfileSnapshot.tryFromJson(future), isNull);
  });

  test('each section resolves on its own timestamp', () {
    final phone = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.sources: (DateTime.utc(2026, 3, 5), ['phone-source']),
        SnapshotSections.watchlist: (DateTime.utc(2026, 3, 1), ['phone-list']),
      },
    );
    final tv = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.sources: (DateTime.utc(2026, 3, 2), ['tv-source']),
        SnapshotSections.watchlist: (DateTime.utc(2026, 3, 9), ['tv-list']),
      },
    );

    final merged = phone.mergedWith(tv);

    expect(merged.dataFor(SnapshotSections.sources), ['phone-source']);
    expect(merged.dataFor(SnapshotSections.watchlist), ['tv-list']);
  });

  test('a section only one device knows about survives the merge', () {
    final phone = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.playlists: (DateTime.utc(2026, 3, 1), ['mix']),
      },
    );
    final tv = snapshot(deviceId: 'tv', sections: const {});

    expect(phone.mergedWith(tv).dataFor(SnapshotSections.playlists), ['mix']);
    expect(tv.mergedWith(phone).dataFor(SnapshotSections.playlists), ['mix']);
  });

  test('removals propagate through last-write-wins sections', () {
    final phone = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.favoriteChannels: (DateTime.utc(2026, 3, 1), ['a', 'b']),
      },
    );
    final tv = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.favoriteChannels: (DateTime.utc(2026, 3, 4), ['a']),
      },
    );

    expect(
      phone.mergedWith(tv).dataFor(SnapshotSections.favoriteChannels),
      ['a'],
    );
  });

  test('history merges per entry instead of picking a winning device', () {
    final phone = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 1),
          [
            watched('movie', at: '2026-03-01T10:00:00Z', progress: 0.2),
            watched('only-on-phone', at: '2026-02-01T10:00:00Z'),
          ],
        ),
      },
    );
    final tv = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 3),
          [
            watched('movie', at: '2026-03-02T10:00:00Z', progress: 0.8),
            watched('only-on-tv', at: '2026-03-03T10:00:00Z'),
          ],
        ),
      },
    );

    final history =
        phone.mergedWith(tv).dataFor(SnapshotSections.history) as List;

    expect(history.length, 3);
    final movie = history.firstWhere((e) => e['id'] == 'movie');
    expect(movie['progress'], 0.8, reason: 'furthest watched wins');
    expect(
      history.map((e) => e['id']),
      ['only-on-tv', 'movie', 'only-on-phone'],
      reason: 'most recently watched first',
    );
  });

  test('cleared history with a newer stamp is not resurrected by merge', () {
    final cleared = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 10),
          <Object>[],
        ),
      },
    );
    final remote = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 1),
          [
            watched('movie', at: '2026-03-01T10:00:00Z', progress: 0.5),
          ],
        ),
      },
    );

    expect(cleared.mergedWith(remote).dataFor(SnapshotSections.history), isEmpty);
    expect(remote.mergedWith(cleared).dataFor(SnapshotSections.history), isEmpty);
  });

  test('watches after a clear still merge onto the empty side', () {
    final cleared = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 5),
          <Object>[],
        ),
      },
    );
    final newerWatch = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 8),
          [
            watched('after-clear', at: '2026-03-08T10:00:00Z'),
          ],
        ),
      },
    );

    final history =
        cleared.mergedWith(newerWatch).dataFor(SnapshotSections.history) as List;
    expect(history.single['id'], 'after-clear');
  });

  test('history merge is symmetric', () {
    final a = [watched('x', at: '2026-03-02T10:00:00Z', progress: 0.9)];
    final b = [watched('x', at: '2026-03-01T10:00:00Z', progress: 0.1)];

    expect(
      ProfileSnapshot.mergeHistory(a, b).single['progress'],
      ProfileSnapshot.mergeHistory(b, a).single['progress'],
    );
    expect(ProfileSnapshot.mergeHistory(b, a).single['progress'], 0.9);
  });

  test('seededWith keeps local data when remote section is empty', () {
    final local = snapshot(
      deviceId: 'phone',
      updatedAt: DateTime.utc(2026, 3, 10),
      sections: {
        SnapshotSections.sources: (
          DateTime.utc(2026, 3, 10),
          ['phone-source'],
        ),
        SnapshotSections.watchlist: (DateTime.utc(2026, 3, 10), <Object>[]),
      },
    );
    final remote = snapshot(
      deviceId: 'tv',
      updatedAt: DateTime.utc(2026, 3, 1),
      sections: {
        SnapshotSections.sources: (DateTime.utc(2026, 3, 1), <Object>[]),
        SnapshotSections.watchlist: (
          DateTime.utc(2026, 3, 1),
          ['remote-list'],
        ),
      },
    );

    final seeded = local.seededWith(remote);

    expect(seeded.dataFor(SnapshotSections.sources), ['phone-source']);
    expect(seeded.dataFor(SnapshotSections.watchlist), ['remote-list']);
  });

  test('history entries without a timestamp lose to ones that have it', () {
    final merged = ProfileSnapshot.mergeHistory(
      [watched('x', progress: 0.9)],
      [watched('x', at: '2026-03-01T10:00:00Z', progress: 0.1)],
    );

    expect(merged.single['progress'], 0.1);
  });

  test('removed history stays gone when the peer still has the entry', () {
    final phone = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 10),
          HistorySyncData(
            items: [watched('keep', at: '2026-03-09T10:00:00Z')],
            deleted: {
              'movie': DateTime.utc(2026, 3, 10, 12),
            },
          ).toWire(),
        ),
      },
    );
    final tv = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 1),
          [
            watched('movie', at: '2026-03-01T10:00:00Z', progress: 0.5),
            watched('keep', at: '2026-03-01T09:00:00Z'),
          ],
        ),
      },
    );

    final merged = HistorySyncData.parse(
      phone.mergedWith(tv).dataFor(SnapshotSections.history),
    );
    expect(merged.items.map((e) => e['id']), ['keep']);
    expect(merged.deleted.keys, ['movie']);
  });

  test('a watch after remove resurrects the history entry', () {
    final deleted = HistorySyncData(
      items: const [],
      deleted: {'movie': DateTime.utc(2026, 3, 10, 12)},
    ).toWire();
    final watchedAgain = [
      watched('movie', at: '2026-03-11T10:00:00Z', progress: 0.1),
    ];

    final merged = ProfileSnapshot.mergeHistoryData(deleted, watchedAgain);
    expect(merged.items.single['id'], 'movie');
    expect(merged.deleted, isEmpty);
  });

  test('URL tombstone drops sibling history ids with the same playUrl', () {
    const url = 'https://free.example/movies/1083381-brkdh/master.m3u8';
    final phone = HistorySyncData(
      items: const [],
      deleted: {
        HistorySyncData.urlTombstoneKey(url)!: DateTime.utc(2026, 8, 11, 12),
        'azeaze': DateTime.utc(2026, 8, 11, 12),
      },
    ).toWire();
    final drive = [
      watched('azeaze', at: '2026-08-10T13:00:00Z', progress: 0.01)
        ..['playUrl'] = url
        ..['title'] = 'azeaze',
      watched('bac', at: '2026-08-10T03:00:00Z', progress: 0.02)
        ..['playUrl'] = url
        ..['title'] = 'bac',
      watched('keep', at: '2026-08-10T12:00:00Z'),
    ];

    final merged = ProfileSnapshot.mergeHistoryData(phone, drive);
    expect(merged.items.map((e) => e['id']), ['keep']);
    expect(
      merged.deleted.containsKey(HistorySyncData.urlTombstoneKey(url)),
      isTrue,
    );
  });

  test('slimHistoryItem drops catalog fat and keeps CW fields', () {
    final fat = {
      'id': 'm1',
      'title': 'Show',
      'playUrl': 'https://example.com/m1',
      'kind': 'vod',
      'origin': 'url',
      'progress': 0.4,
      'lastWatchedAt': '2026-03-01T10:00:00Z',
      'tmdbId': 42,
      'seasonNumber': 2,
      'episodeNumber': 5,
      'seriesId': 's1',
      'posterUrl': 'https://cdn/poster.jpg',
      'thumbnailUrl': 'https://cdn/thumb.jpg',
      'plot': 'A very long plot ' * 40,
      'genres': ['Drama', 'Sci-Fi'],
      'tags': ['hdr', 'atmos'],
      'httpHeaders': {'Authorization': 'secret'},
      'segments': [
        {'type': 'intro', 'startMs': 0, 'endMs': 90000},
      ],
      'audioTracks': [
        {'url': 'https://cdn/ja.m3u8', 'language': 'ja'},
      ],
      'subtitles': [
        {'url': 'https://cdn/en.srt', 'language': 'en'},
      ],
    };

    final slim = ProfileSnapshot.slimHistoryItem(fat);
    expect(slim['id'], 'm1');
    expect(slim['progress'], 0.4);
    expect(slim['tmdbId'], 42);
    expect(slim['seasonNumber'], 2);
    expect(slim['posterUrl'], 'https://cdn/poster.jpg');
    expect(slim.containsKey('plot'), isFalse);
    expect(slim.containsKey('genres'), isFalse);
    expect(slim.containsKey('tags'), isFalse);
    expect(slim.containsKey('httpHeaders'), isFalse);
    expect(slim.containsKey('segments'), isFalse);
    expect(slim.containsKey('audioTracks'), isFalse);
    expect(slim.containsKey('thumbnailUrl'), isFalse);
  });

  test('forWire keeps id and url: history tombstones while sliming items', () {
    const url = 'https://free.example/movies/azeaze/master.m3u8';
    final original = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 8, 11, 12),
          HistorySyncData(
            items: [
              {
                'id': 'keep',
                'title': 'Keep',
                'playUrl': 'https://example.com/keep',
                'kind': 'vod',
                'origin': 'url',
                'progress': 0.1,
                'lastWatchedAt': '2026-08-11T11:00:00Z',
                'plot': 'drop me',
              },
            ],
            deleted: {
              'azeaze': DateTime.utc(2026, 8, 11, 12),
              HistorySyncData.urlTombstoneKey(url)!:
                  DateTime.utc(2026, 8, 11, 12),
            },
          ).toWire(),
        ),
      },
    );

    final wire = HistorySyncData.parse(
      original.forWire().dataFor(SnapshotSections.history),
    );
    expect(wire.items.single['id'], 'keep');
    expect(wire.items.single.containsKey('plot'), isFalse);
    expect(wire.deleted.keys, containsAll([
      'azeaze',
      HistorySyncData.urlTombstoneKey(url),
    ]));

    // Drive fat sibling under another id still dies on merge.
    final merged = ProfileSnapshot.mergeHistoryData(
      wire.toWire(),
      [
        {
          'id': 'bac',
          'title': 'bac',
          'playUrl': url,
          'kind': 'vod',
          'origin': 'url',
          'progress': 0.02,
          'lastWatchedAt': '2026-08-10T03:00:00Z',
        },
      ],
    );
    expect(merged.items.map((e) => e['id']), ['keep']);
  });

  test('forWire slims history, empties categories, filters tracker statuses', () {
    final original = snapshot(
      deviceId: 'phone',
      sections: {
        SnapshotSections.categories: (
          DateTime.utc(2026, 3, 1),
          [
            {'id': '1', 'name': 'Movies', 'kind': 'vod'},
          ],
        ),
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 2),
          [
            {
              'id': 'm1',
              'title': 'Movie',
              'playUrl': 'https://example.com/m1',
              'kind': 'vod',
              'origin': 'url',
              'progress': 0.5,
              'lastWatchedAt': '2026-03-02T10:00:00Z',
              'plot': 'fat',
              'genres': ['Action'],
            },
          ],
        ),
        SnapshotSections.trackerStatuses: (
          DateTime.utc(2026, 3, 3),
          [
            {
              'source': 'simkl',
              'status': 'completed',
              'title': 'Done',
              'tmdbId': 1,
            },
            {
              'source': 'simkl',
              'status': 'dropped',
              'title': 'Nope',
              'tmdbId': 2,
            },
            {
              'source': 'simkl',
              'status': 'watching',
              'title': 'Now',
              'tmdbId': 3,
              'progress': 0.2,
            },
            {
              'source': 'simkl',
              'status': 'hold',
              'title': 'Later',
              'tmdbId': 4,
            },
          ],
        ),
      },
    );

    final wire = original.forWire();
    expect(wire.dataFor(SnapshotSections.categories), isEmpty);

    final history = wire.dataFor(SnapshotSections.history) as List;
    expect(history.single['plot'], isNull);
    expect(history.single['progress'], 0.5);

    final trackers = wire.dataFor(SnapshotSections.trackerStatuses) as List;
    expect(
      trackers.map((e) => e['status']),
      unorderedEquals(['dropped', 'watching', 'hold']),
    );
  });

  test('merge keeps fat poster when slim peer has newer progress', () {
    final slim = {
      'id': 'm1',
      'title': 'Movie',
      'playUrl': 'https://example.com/m1',
      'kind': 'vod',
      'origin': 'url',
      'progress': 0.9,
      'lastWatchedAt': '2026-03-05T10:00:00Z',
    };
    final fat = {
      'id': 'm1',
      'title': 'Movie',
      'playUrl': 'https://example.com/m1',
      'kind': 'vod',
      'origin': 'url',
      'progress': 0.2,
      'lastWatchedAt': '2026-03-01T10:00:00Z',
      'posterUrl': 'https://cdn/poster.jpg',
      'plot': 'long',
      'tmdbId': 99,
    };

    final merged = ProfileSnapshot.mergeHistory([slim], [fat]).single;
    expect(merged['progress'], 0.9);
    expect(merged['posterUrl'], 'https://cdn/poster.jpg');
    expect(merged['tmdbId'], 99);
    expect(merged['plot'], 'long');

    final slimmed = ProfileSnapshot.slimHistoryItem(merged);
    expect(slimmed['progress'], 0.9);
    expect(slimmed['posterUrl'], 'https://cdn/poster.jpg');
    expect(slimmed.containsKey('plot'), isFalse);
  });

  test('tryDecode still accepts a fat legacy history snapshot', () {
    final fat = snapshot(
      deviceId: 'tv',
      sections: {
        SnapshotSections.history: (
          DateTime.utc(2026, 3, 1),
          [
            {
              'id': 'm1',
              'title': 'Movie',
              'playUrl': 'https://example.com/m1',
              'kind': 'vod',
              'origin': 'url',
              'progress': 0.3,
              'lastWatchedAt': '2026-03-01T10:00:00Z',
              'plot': 'legacy plot',
              'genres': ['Drama'],
              'httpHeaders': {'X-Token': 'abc'},
            },
          ],
        ),
      },
    );

    final decoded = ProfileSnapshot.tryDecode(jsonEncode(fat.toJson()));
    expect(decoded, isNotNull);
    final item =
        (decoded!.dataFor(SnapshotSections.history) as List).single as Map;
    expect(item['plot'], 'legacy plot');
    expect(item['httpHeaders'], {'X-Token': 'abc'});

    final wired = ProfileSnapshot.tryDecode(fat.encode())!;
    final slimItem =
        (wired.dataFor(SnapshotSections.history) as List).single as Map;
    expect(slimItem.containsKey('plot'), isFalse);
    expect(slimItem['progress'], 0.3);
  });
}
