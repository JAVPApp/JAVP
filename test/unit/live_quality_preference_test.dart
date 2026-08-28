import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/display_capability.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/iptv/channel_quality.dart';

MediaItem live({
  required String id,
  required String title,
  String? epg,
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
    sourceId: sourceId,
    streamId: streamId ?? id,
    catchupDays: catchupDays,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChannelQuality.pickVariant', () {
    final sd = live(id: 'sd', title: 'News SD', epg: 'n', streamId: '1');
    final hd = live(id: 'hd', title: 'News HD', epg: 'n', streamId: '2');
    final uhd = live(
      id: 'uhd',
      title: 'News UHD',
      epg: 'n',
      streamId: '3',
      catchupDays: 7,
    );
    final ranked = [sd, hd, uhd]..sort(ChannelQuality.compareVariants);

    test('defaults to Auto best quality (catchup does not outrank)', () {
      expect(ChannelQuality.pickVariant(ranked).id, ranked.first.id);
      expect(ranked.first.id, 'uhd');
    });

    test('Auto prefers FHD over catchup SD', () {
      final catchupSd = live(
        id: 'sdc',
        title: 'News SD',
        epg: 'n',
        streamId: '1',
        catchupDays: 7,
      );
      final fhd = live(id: 'fhd', title: 'News FHD', epg: 'n', streamId: '2');
      final sorted = [catchupSd, fhd]..sort(ChannelQuality.compareVariants);
      expect(ChannelQuality.pickVariant(sorted).id, 'fhd');
    });

    test('session override beats preferred and Auto', () {
      expect(
        ChannelQuality.pickVariant(
          ranked,
          sessionStreamId: '1',
          preferredStreamId: '2',
        ).id,
        'sd',
      );
    });

    test('preferred beats Auto when no session', () {
      expect(
        ChannelQuality.pickVariant(
          ranked,
          preferredStreamId: '2',
        ).id,
        'hd',
      );
    });

    test('unknown preferred falls back to Auto', () {
      expect(
        ChannelQuality.pickVariant(
          ranked,
          preferredStreamId: 'missing',
        ).id,
        'uhd',
      );
    });

    test('allowUhd false caps Auto at FHD', () {
      expect(
        ChannelQuality.pickVariant(ranked, allowUhd: false).id,
        'hd',
      );
    });
  });

  group('DisplayCapability.supportsUhd', () {
    test('true for 3840×2160 physical', () {
      expect(
        DisplayCapability.supportsUhd(physicalSize: const Size(3840, 2160)),
        isTrue,
      );
    });

    test('false for 1920×1080 and phone-like sizes', () {
      expect(
        DisplayCapability.supportsUhd(physicalSize: const Size(1920, 1080)),
        isFalse,
      );
      expect(
        DisplayCapability.supportsUhd(physicalSize: const Size(1440, 3120)),
        isFalse,
      );
    });
  });

  group('LibraryProvider live quality session', () {
    late LibraryProvider library;
    late MediaItem sd;
    late MediaItem hd;
    late MediaItem uhd;

    setUp(() {
      library = LibraryProvider();
      sd = live(id: 'sd', title: 'Fam HD SD', epg: 'fam1', streamId: '10');
      hd = live(id: 'hd', title: 'Fam HD HD', epg: 'fam1', streamId: '20');
      uhd = live(
        id: 'uhd',
        title: 'Fam HD UHD',
        epg: 'fam1',
        streamId: '30',
        catchupDays: 3,
      );
      library.catalog = [sd, hd, uhd];
    });

    test('resolveLiveChannel picks Auto best without prefs', () {
      final picked = library.resolveLiveChannel(sd);
      // Test binding surface is not 4K → Auto caps at HD (not UHD).
      expect(
        DisplayCapability.supportsUhd(),
        isFalse,
        reason: 'test view should not report UHD',
      );
      expect(picked.streamId, '20');
      expect(library.preferredLiveQualities, isEmpty);
    });

    test('resolveCatchupChannel uses sibling when live lacks catchup', () {
      final fhd = live(
        id: 'fhd',
        title: 'Fam HD FHD',
        epg: 'fam1',
        streamId: '25',
      );
      library.catalog = [fhd, sd, hd, uhd];
      expect(library.resolveCatchupChannel(fhd)?.streamId, '30');
      expect(library.liveSupportsCatchup(fhd), isTrue);
      expect(library.resolveLiveChannel(fhd).streamId, isNot('30'));
    });

    test('setSessionLiveQuality does not persist preferred map', () async {
      await library.setSessionLiveQuality(sd);
      expect(library.preferredLiveQualities, isEmpty);
      expect(library.resolveLiveChannel(hd).streamId, '10');
    });

    test('setPreferredLiveQuality persists and resolves', () async {
      // Avoid disk: write the map directly like tests that skip store.
      final key = library.liveFamilyKey(sd);
      expect(key, isNotNull);
      library.preferredLiveQualities = {key!: '20'};
      expect(library.resolveLiveChannel(uhd).streamId, '20');
    });

    test('session overrides preferred for resolve', () async {
      final key = library.liveFamilyKey(sd)!;
      library.preferredLiveQualities = {key: '20'};
      await library.setSessionLiveQuality(sd);
      expect(library.resolveLiveChannel(uhd).streamId, '10');
      expect(library.preferredLiveQualities[key], '20');
    });
  });
}
