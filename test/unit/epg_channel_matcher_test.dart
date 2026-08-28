import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/services/iptv/epg_channel_matcher.dart';

EpgProgram _p({
  required String channelId,
  String title = 'Show',
  DateTime? start,
}) {
  final s = start ?? DateTime.utc(2026, 8, 8, 12);
  return EpgProgram(
    channelId: channelId,
    title: title,
    start: s,
    end: s.add(const Duration(hours: 1)),
  );
}

void main() {
  group('normalizeId', () {
    test('case-folds and strips quality suffixes', () {
      expect(EpgChannelMatcher.normalizeId('NEWS1.UK.HD'), 'news1.uk');
      expect(EpgChannelMatcher.normalizeId('newsnet-us-FHD'), 'newsnet-us');
      expect(EpgChannelMatcher.normalizeId('  News_One  '), 'news.one');
    });

    test('strips common prefixes', () {
      expect(EpgChannelMatcher.normalizeId('tvg.NEWS1.uk'), 'news1.uk');
      expect(EpgChannelMatcher.normalizeId('channel-ChannelTwo'), 'channeltwo');
      expect(EpgChannelMatcher.normalizeId('epg.arte.de'), 'arte.de');
    });
  });

  group('looseId', () {
    test('strips trailing country segment', () {
      expect(EpgChannelMatcher.looseId('NEWS1.uk'), 'news1');
      expect(EpgChannelMatcher.looseId('arte.de'), 'arte');
    });
  });

  group('programmesFor', () {
    test('exact tvg-id wins', () {
      final index = EpgChannelMatcher.buildIndex(
        programs: [_p(channelId: 'NEWS1.uk', title: 'Exact')],
        channelNames: const {'NEWS1.uk': 'News One'},
      );
      final hit = index.programmesFor(epgChannelId: 'NEWS1.uk');
      expect(hit, hasLength(1));
      expect(hit.single.title, 'Exact');
    });

    test('normalized id matches across case and quality suffix', () {
      final index = EpgChannelMatcher.buildIndex(
        programs: [_p(channelId: 'news1.uk', title: 'Norm')],
        channelNames: const {'news1.uk': 'News One'},
      );
      final hit = index.programmesFor(epgChannelId: 'NEWS1.UK.HD');
      expect(hit.single.title, 'Norm');
    });

    test('loose country suffix only when unique', () {
      final unique = EpgChannelMatcher.buildIndex(
        programs: [_p(channelId: 'newsnet.us', title: 'NewsNet')],
        channelNames: const {'newsnet.us': 'NewsNet'},
      );
      expect(unique.programmesFor(epgChannelId: 'newsnet').single.title, 'NewsNet');

      final ambiguous = EpgChannelMatcher.buildIndex(
        programs: [
          _p(channelId: 'newsnet.us', title: 'US'),
          _p(channelId: 'newsnet.uk', title: 'UK'),
        ],
        channelNames: const {'newsnet.us': 'NewsNet US', 'newsnet.uk': 'NewsNet UK'},
      );
      // Playlist id "newsnet" would loose-match both — refuse.
      expect(ambiguous.programmesFor(epgChannelId: 'newsnet'), isEmpty);
      // Exact / normalized still work.
      expect(
        ambiguous.programmesFor(epgChannelId: 'NewsNet.US').single.title,
        'US',
      );
    });

    test('fuzzy name match when unique enough', () {
      final index = EpgChannelMatcher.buildIndex(
        programs: [_p(channelId: 'ch-42', title: 'Named')],
        channelNames: const {'ch-42': 'Channel Two HD'},
      );
      final hit = index.programmesFor(channelTitle: 'Channel Two FHD');
      expect(hit.single.title, 'Named');
    });

    test('refuses ambiguous name matches', () {
      final index = EpgChannelMatcher.buildIndex(
        programs: [
          _p(channelId: 'a', title: 'A'),
          _p(channelId: 'b', title: 'B'),
        ],
        channelNames: const {'a': 'Sport 1', 'b': 'Sport 1 HD'},
      );
      // Both normalize to "sport 1" — don't guess.
      expect(index.programmesFor(channelTitle: 'Sport 1'), isEmpty);
    });

    test('prefers id match over name', () {
      final index = EpgChannelMatcher.buildIndex(
        programs: [
          _p(channelId: 'id-a', title: 'ById'),
          _p(channelId: 'id-b', title: 'ByName'),
        ],
        channelNames: const {'id-a': 'Other', 'id-b': 'My Channel'},
      );
      final hit = index.programmesFor(
        epgChannelId: 'id-a',
        channelTitle: 'My Channel',
      );
      expect(hit.single.title, 'ById');
    });

    test('merges programmes across feeds that share normalized id', () {
      final index = EpgChannelMatcher.buildIndex(
        programs: [
          _p(
            channelId: 'NEWS1.uk',
            title: 'Morning',
            start: DateTime.utc(2026, 8, 8, 8),
          ),
          _p(
            channelId: 'news1.uk',
            title: 'Evening',
            start: DateTime.utc(2026, 8, 8, 20),
          ),
        ],
        channelNames: const {'NEWS1.uk': 'News One', 'news1.uk': 'News One'},
      );
      final hit = index.programmesFor(epgChannelId: 'NEWS1.UK');
      expect(hit.map((p) => p.title), ['Morning', 'Evening']);
    });
  });

  group('mergeProgrammes', () {
    test('dedupes identical rows and sorts', () {
      final a = _p(
        channelId: 'x',
        title: 'Same',
        start: DateTime.utc(2026, 8, 8, 10),
      );
      final b = _p(
        channelId: 'x',
        title: 'Same',
        start: DateTime.utc(2026, 8, 8, 10),
      );
      final c = _p(
        channelId: 'x',
        title: 'Later',
        start: DateTime.utc(2026, 8, 8, 12),
      );
      final merged = EpgChannelMatcher.mergeProgrammes([c, a, b]);
      expect(merged, hasLength(2));
      expect(merged.first.title, 'Same');
      expect(merged.last.title, 'Later');
    });

    test('mergeProgrammesYielding matches the sync merge', () async {
      final programs = [
        for (var i = 0; i < 80; i++)
          _p(
            channelId: 'ch-${i % 7}',
            title: 'Show $i',
            start: DateTime.utc(2026, 8, 8, 10).add(Duration(minutes: i)),
          ),
        _p(
          channelId: 'ch-1',
          title: 'Show 1',
          start: DateTime.utc(2026, 8, 8, 10).add(const Duration(minutes: 1)),
        ),
      ];
      final sync = EpgChannelMatcher.mergeProgrammes(programs);
      final async = await EpgChannelMatcher.mergeProgrammesYielding(programs);
      expect(async.map((p) => p.title), sync.map((p) => p.title));
      expect(async.map((p) => p.channelId), sync.map((p) => p.channelId));
    });
  });

  test('buildYielding matches sync index lookups', () async {
    final programs = [
      _p(
        channelId: 'NEWS1.UK',
        title: 'Morning',
        start: DateTime.utc(2026, 8, 8, 8),
      ),
      _p(
        channelId: 'NEWS1.UK',
        title: 'Evening',
        start: DateTime.utc(2026, 8, 8, 20),
      ),
      _p(
        channelId: 'newsnet.us',
        title: 'News',
        start: DateTime.utc(2026, 8, 8, 9),
      ),
    ];
    const names = {'NEWS1.UK': 'News One', 'newsnet.us': 'NewsNet'};
    final sync = EpgLookupIndex.build(programs: programs, channelNames: names);
    final async = await EpgLookupIndex.buildYielding(
      programs: programs,
      channelNames: names,
    );
    expect(
      async.programmesFor(epgChannelId: 'NEWS1.UK').map((p) => p.title),
      sync.programmesFor(epgChannelId: 'NEWS1.UK').map((p) => p.title),
    );
    expect(
      async.displayNameFor(epgChannelId: 'newsnet.us'),
      sync.displayNameFor(epgChannelId: 'newsnet.us'),
    );
  });

  group('EpgChannelAliasIndex', () {
    test('resolves exact, normalized, and unique name', () {
      final index = EpgChannelAliasIndex.fromChannelNames(const {
        'NEWS1.uk': 'News One',
        'newsnet.us': 'NewsNet',
      });
      expect(index.resolve(epgChannelId: 'NEWS1.uk'), 'NEWS1.uk');
      expect(index.resolve(epgChannelId: 'NEWS1.UK.HD'), 'NEWS1.uk');
      expect(index.resolve(channelTitle: 'NewsNet'), 'newsnet.us');
      expect(index.displayNameFor(epgChannelId: 'news1.uk'), 'News One');
    });

    test('refuses ambiguous loose country ids', () {
      final index = EpgChannelAliasIndex.fromChannelNames(const {
        'newsnet.us': 'NewsNet US',
        'newsnet.uk': 'NewsNet UK',
      });
      expect(index.resolve(epgChannelId: 'newsnet'), isNull);
      expect(index.resolve(epgChannelId: 'NewsNet.US'), 'newsnet.us');
    });
  });
}
