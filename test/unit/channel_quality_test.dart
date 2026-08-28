import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/channel_quality.dart';

MediaItem live({
  required String id,
  required String title,
  String? epg,
  String? channelName,
  String sourceId = 'src1',
  int catchupDays = 0,
  String? streamId,
}) {
  return MediaItem(
    id: id,
    title: title,
    playUrl: 'http://example.com/live/$id.ts',
    kind: MediaKind.live,
    origin: MediaOrigin.iptvXtream,
    epgChannelId: epg,
    channelName: channelName,
    sourceId: sourceId,
    streamId: streamId ?? id,
    catchupDays: catchupDays,
  );
}

void main() {
  test('preferenceKey uses official name when provided', () {
    expect(
      ChannelQuality.preferenceKey(
        live(id: '1', title: 'UK: News One FHD', epg: 'news1.uk'),
        officialName: 'News One',
      ),
      'src1|name:news one',
    );
    expect(
      ChannelQuality.preferenceKey(
        live(id: '2', title: 'News One HD', epg: 'news1'),
        officialName: 'News One',
      ),
      'src1|name:news one',
    );
  });

  test('preferenceKey prefers cleaned title over distinct epg ids', () {
    expect(
      ChannelQuality.preferenceKey(live(id: '1', title: 'NewsNet FHD')),
      'src1|name:newsnet',
    );
    // Quality siblings with different tvg-ids must share a family.
    expect(
      ChannelQuality.preferenceKey(
        live(id: '1', title: 'News One HD', epg: 'news1.hd'),
      ),
      ChannelQuality.preferenceKey(
        live(id: '2', title: 'News One FHD', epg: 'news1.fhd'),
      ),
    );
    expect(
      ChannelQuality.preferenceKey(
        live(id: '1', title: 'News One HD', epg: 'news1.hd'),
      ),
      'src1|name:news one',
    );
    // No usable title → tvg-name, then epg id.
    expect(
      ChannelQuality.preferenceKey(
        live(id: '1', title: '   ', channelName: 'National Geographic'),
      ),
      'src1|name:national geographic',
    );
    expect(
      ChannelQuality.preferenceKey(live(id: '1', title: '   ', epg: 'news1')),
      'src1|epg:news1',
    );
  });

  test('preferenceKey strips quality from official / tvg-name', () {
    expect(
      ChannelQuality.preferenceKey(
        live(id: '1', title: 'ignore', channelName: 'News One HD'),
        officialName: 'News One FHD',
      ),
      'src1|name:news one',
    );
    expect(
      ChannelQuality.preferenceKey(
        live(id: '1', title: '   ', channelName: 'Sky News HD'),
      ),
      'src1|name:sky news',
    );
  });

  test('baseTitle strips quality and region prefixes', () {
    expect(ChannelQuality.baseTitle('UK: News One FHD'), 'News One');
    expect(ChannelQuality.baseTitle('NewsNet [HD]'), 'NewsNet');
    expect(ChannelQuality.baseTitle('Discovery HEVC'), 'Discovery');
    expect(ChannelQuality.baseTitle('Nat Geo 4K'), 'Nat Geo');
    expect(ChannelQuality.baseTitle('2 - Channel Two (auto)'), 'Channel Two');
    expect(ChannelQuality.baseTitle('2 - Channel Two (HD)'), 'Channel Two');
    expect(ChannelQuality.baseTitle('2 - Channel Two (standard)'), 'Channel Two');
    expect(ChannelQuality.baseTitle('7 - Arte (bas débit)'), 'Arte');
    expect(ChannelQuality.baseTitle('FR| ChannelA FHD'), 'ChannelA');
    expect(ChannelQuality.baseTitle('FR-CAR| ChannelA'), 'ChannelA');
    expect(ChannelQuality.baseTitle('US | NewsNet'), 'NewsNet');
  });

  test('displayTitle prefers official then cleaned title', () {
    final item = live(id: '1', title: 'US | NewsNet FHD', channelName: 'NewsNet');
    expect(ChannelQuality.displayTitle(item), 'NewsNet');
    expect(
      ChannelQuality.displayTitle(
        live(id: '2', title: 'UK: Sky News HD'),
        epgDisplayName: 'Sky News',
      ),
      'Sky News',
    );
    expect(
      ChannelQuality.displayTitle(live(id: '3', title: 'Arena Sports 1 HD')),
      'Arena Sports 1',
    );
  });

  test('displayTitle strips regional prefixes from tvg-name', () {
    // Preferred FHD stream can still carry a regional sibling's tvg-name.
    expect(
      ChannelQuality.displayTitle(
        live(id: '1', title: 'FR| ChannelA FHD', channelName: 'FR-CAR| ChannelA'),
      ),
      'ChannelA',
    );
    expect(
      ChannelQuality.displayTitle(
        live(id: '2', title: 'FR| ChannelA HD', channelName: 'FR| ChannelA'),
      ),
      'ChannelA',
    );
  });

  test('ChannelA / FR-CAR family shares preferenceKey and display name', () {
    final fhd = live(id: '1', title: 'FR| ChannelA FHD');
    final hd = live(id: '2', title: 'FR| ChannelA HD');
    final uhd = live(id: '3', title: 'FR| ChannelA UHD');
    final car = live(id: '4', title: 'FR-CAR| ChannelA', channelName: 'FR-CAR| ChannelA');
    final variants = [fhd, hd, uhd, car];

    expect(
      ChannelQuality.preferenceKey(fhd),
      ChannelQuality.preferenceKey(car),
    );
    expect(ChannelQuality.preferenceKey(fhd), 'src1|name:channela');

    expect(ChannelQuality.familyBaseTitle(variants), 'ChannelA');
    expect(ChannelQuality.familyDisplayTitle(fhd, variants), 'ChannelA');
    expect(ChannelQuality.familyDisplayTitle(hd, variants), 'ChannelA');
    expect(ChannelQuality.familyDisplayTitle(uhd, variants), 'ChannelA');
    // DOM TOM sibling has no quality tag — family base still ChannelA.
    expect(ChannelQuality.familyDisplayTitle(car, variants), 'ChannelA');

    // Outlier tvg-name on the preferred stream must not win the heading.
    final fhdWeirdName = live(
      id: '5',
      title: 'FR| ChannelA FHD',
      channelName: 'FR-CAR| ChannelA',
    );
    expect(
      ChannelQuality.familyDisplayTitle(fhdWeirdName, [
        fhdWeirdName,
        hd,
        uhd,
        car,
      ]),
      'ChannelA',
    );
  });

  test('displayTitle strips numbered quality parentheses', () {
    expect(
      ChannelQuality.displayTitle(live(id: '1', title: '2 - Channel Two (HD)')),
      'Channel Two',
    );
    expect(
      ChannelQuality.displayTitle(live(id: '2', title: '2 - Channel Two (auto)')),
      'Channel Two',
    );
    expect(
      ChannelQuality.displayTitle(live(id: '3', title: '7 - Arte (bas débit)')),
      'Arte',
    );
    expect(
      ChannelQuality.displayTitle(
        live(id: '4', title: '2 - Channel Two (standard)'),
      ),
      'Channel Two',
    );
  });

  test('withQualityParentheses is for pickers, not list titles', () {
    expect(
      ChannelQuality.withQualityParentheses(
        'Channel Two',
        live(id: '1', title: '2 - Channel Two (HD)'),
      ),
      'Channel Two (HD)',
    );
    expect(
      ChannelQuality.withQualityParentheses(
        'ChannelA',
        live(id: '2', title: 'FR| ChannelA FHD'),
      ),
      'ChannelA (FHD)',
    );
  });

  test('compareVariants prefers quality tags (catchup is not a live rank)', () {
    final sd = live(id: '1', title: 'News SD', epg: 'n', catchupDays: 3);
    final hdNoCatchup = live(id: '2', title: 'News HD', epg: 'n');
    final uhdCatchup = live(
      id: '3',
      title: 'News UHD',
      epg: 'n',
      catchupDays: 1,
    );
    final sorted = [sd, hdNoCatchup, uhdCatchup]
      ..sort(ChannelQuality.compareVariants);
    expect(sorted.map((c) => c.id).toList(), ['3', '2', '1']);
  });

  test('pickCatchupSibling prefers quality then longest archive', () {
    final fhd = live(id: '1', title: 'News FHD', epg: 'n');
    final sd = live(id: '2', title: 'News SD', epg: 'n', catchupDays: 7);
    final hd = live(id: '3', title: 'News HD', epg: 'n', catchupDays: 3);
    final picked = ChannelQuality.pickCatchupSibling([fhd, sd, hd]);
    expect(picked?.id, '3'); // HD over SD despite fewer days
    final sdOnly = ChannelQuality.pickCatchupSibling([
      fhd,
      live(id: '4', title: 'News SD', epg: 'n', catchupDays: 2),
      live(id: '5', title: 'News SD Alt', epg: 'n', catchupDays: 9),
    ]);
    expect(sdOnly?.id, '5'); // longest days among equal quality
    expect(ChannelQuality.pickCatchupSibling([fhd]), isNull);
  });

  test('pickVariant Auto skips UHD when allowUhd is false', () {
    final sd = live(id: '1', title: 'News SD', epg: 'n');
    final fhd = live(id: '2', title: 'News FHD', epg: 'n');
    final uhd = live(id: '3', title: 'News UHD', epg: 'n');
    final ranked = [sd, fhd, uhd]..sort(ChannelQuality.compareVariants);
    expect(ranked.first.id, '3');
    expect(ChannelQuality.pickVariant(ranked, allowUhd: false).id, '2');
    expect(
      ChannelQuality.pickVariant(
        ranked,
        sessionStreamId: '3',
        allowUhd: false,
      ).id,
      '3',
    );
  });

  test('detailLine includes stream id and catchup', () {
    final item = live(
      id: '9',
      title: 'Film FHD',
      epg: 'f',
      catchupDays: 7,
      streamId: '22807',
    );
    expect(ChannelQuality.detailLine(item), 'ID 22807 · FHD · 7d catchup');
    expect(
      ChannelQuality.detailLine(item, sourceLabel: 'Demo Xtream'),
      'Demo Xtream · ID 22807 · FHD · 7d catchup',
    );
  });

  test('nextVariantAfter skips tried stream ids in quality order', () {
    final ranked = [
      live(id: 'u', title: 'News One UHD', streamId: '1'),
      live(id: 'f', title: 'News One FHD', streamId: '2'),
      live(id: 'h', title: 'News One HD', streamId: '3'),
      live(id: 's', title: 'News One SD', streamId: '4'),
    ]..sort(ChannelQuality.compareVariants);

    expect(
      ChannelQuality.nextVariantAfter(ranked, triedStreamIds: {})?.streamId,
      '1',
    );
    expect(
      ChannelQuality.nextVariantAfter(
        ranked,
        triedStreamIds: {'1'},
      )?.streamId,
      '2',
    );
    expect(
      ChannelQuality.nextVariantAfter(
        ranked,
        triedStreamIds: {'1', '2', '3'},
      )?.streamId,
      '4',
    );
    expect(
      ChannelQuality.nextVariantAfter(
        ranked,
        triedStreamIds: {'1', '2', '3', '4'},
      ),
      isNull,
    );
  });
}
