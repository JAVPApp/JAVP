import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/storage/parental_controls_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryProvider library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    library = LibraryProvider(store: LibraryStore(prefs: prefs));
    await library.bootstrap();
  });

  tearDown(() => library.dispose());

  test(
    'parental lock busts live / continue-watching / VOD preview caches',
    () async {
      const sourceId = 'adult-src';
      library.sources = [
        IptvSource(
          id: sourceId,
          name: 'Adult',
          type: IptvSourceType.xtream,
          createdAt: DateTime.utc(2026, 1, 1),
          serverUrl: 'http://example.com',
          username: 'u',
          password: 'p',
        ),
      ];
      final vod = MediaItem(
        id: 'vod-1',
        title: 'Hidden movie',
        playUrl: 'http://example.com/vod.mp4',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: sourceId,
      );
      final live = MediaItem(
        id: 'live-1',
        title: 'Hidden channel',
        playUrl: 'http://example.com/live.ts',
        kind: MediaKind.live,
        origin: MediaOrigin.iptvXtream,
        sourceId: sourceId,
      );
      library.catalog = [vod, live];
      library.history = [
        vod.copyWith(progress: 0.4, lastWatchedAt: DateTime.utc(2026, 8, 1)),
      ];
      library.debugSeedVodStreamCache([vod]);

      final store = ParentalControlsStore(profileId: 'shelves');
      await store.setPin('1234');
      final parental = ParentalLockProvider(profileId: 'shelves');
      await parental.load();
      await parental.unlock('1234');
      library.parentalLock = parental;

      expect(library.liveChannels.map((e) => e.id), contains('live-1'));
      expect(library.continueWatching.map((e) => e.id), contains('vod-1'));
      expect(
        library.vodPreview(series: false).map((e) => e.id),
        contains('vod-1'),
      );
      final unlockedStamp = library.homeShelfContentStamp;

      await parental.setHiddenSourceIds({sourceId});
      parental.lockSession();
      library.invalidateParentalLiveCaches();

      expect(library.isSourceContentVisible(sourceId), isFalse);
      expect(library.liveChannels, isEmpty);
      expect(library.continueWatching, isEmpty);
      expect(library.vodPreview(series: false), isEmpty);
      expect(library.homeShelfContentStamp, isNot(unlockedStamp));
    },
  );
}
