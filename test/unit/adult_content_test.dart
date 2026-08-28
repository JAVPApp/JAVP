import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/parental_lock_provider.dart';
import 'package:javp/services/parental/adult_content.dart';
import 'package:javp/services/storage/parental_controls_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('adult_content helpers', () {
    test('truthyAdultFlag parses 0/1/bool/strings', () {
      expect(truthyAdultFlag(1), isTrue);
      expect(truthyAdultFlag(true), isTrue);
      expect(truthyAdultFlag('1'), isTrue);
      expect(truthyAdultFlag('true'), isTrue);
      expect(truthyAdultFlag(0), isFalse);
      expect(truthyAdultFlag(false), isFalse);
      expect(truthyAdultFlag(null), isFalse);
      expect(truthyAdultFlag(''), isFalse);
    });

    test('content ratings mark explicit adult only', () {
      expect(isAdultContentRating('XXX'), isTrue);
      expect(isAdultContentRating('AO'), isTrue);
      expect(isAdultContentRating('18+'), isTrue);
      expect(isAdultContentRating('NC-17'), isTrue);
      expect(isAdultContentRating('TV-MA'), isFalse);
      expect(isAdultContentRating('PG-13'), isFalse);
      expect(isAdultContentRating(null), isFalse);
    });

    test('label tokens avoid false positives like adultery', () {
      expect(isAdultLabelToken('Adult'), isTrue);
      expect(isAdultLabelToken('xxx'), isTrue);
      expect(isAdultLabelToken('adultery'), isFalse);
      expect(isAdultLabelToken('Comedy'), isFalse);
    });

    test('resolveIsAdult combines signals', () {
      expect(resolveIsAdult(flag: 1), isTrue);
      expect(resolveIsAdult(contentRating: 'XXX'), isTrue);
      expect(resolveIsAdult(genres: ['Adult']), isTrue);
      expect(resolveIsAdult(tags: ['nsfw']), isTrue);
      expect(
        resolveIsAdult(contentRating: 'TV-MA', genres: ['Drama']),
        isFalse,
      );
    });
  });

  group('MediaItem isAdult json', () {
    test('round-trips isAdult', () {
      const item = MediaItem(
        id: 'a',
        title: 'A',
        playUrl: 'http://x',
        kind: MediaKind.vod,
        origin: MediaOrigin.customCatalog,
        isAdult: true,
      );
      final copy = MediaItem.fromJson(item.toJson());
      expect(copy.isAdult, isTrue);
      expect(
        MediaItem.fromJson({
          ...item.toJson(),
          'isAdult': false,
          'adult': true,
        }).isAdult,
        isTrue,
      );
    });
  });

  group('ParentalLockProvider adult filter', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('locked session hides adult items when hideSourceAdult is on',
        () async {
      final store = ParentalControlsStore(profileId: 'test');
      await store.setPin('1234');
      final parental = ParentalLockProvider(profileId: 'test');
      await parental.load();
      expect(parental.hasPin, isTrue);
      expect(parental.isContentLocked, isTrue);
      expect(parental.hideSourceAdult, isTrue);

      const adult = MediaItem(
        id: 'adult-1',
        title: 'Adult',
        playUrl: 'http://x',
        kind: MediaKind.live,
        origin: MediaOrigin.iptvXtream,
        group: 'News',
        isAdult: true,
      );
      const safe = MediaItem(
        id: 'safe-1',
        title: 'Safe',
        playUrl: 'http://x',
        kind: MediaKind.live,
        origin: MediaOrigin.iptvXtream,
        group: 'News',
      );

      expect(parental.isLiveChannelHidden(adult), isTrue);
      expect(parental.isLiveChannelHidden(safe), isFalse);
      expect(parental.isItemHidden(adult), isTrue);

      await parental.unlock('1234');
      expect(parental.isLiveChannelHidden(adult), isFalse);

      parental.lockSession();
      await parental.setHideSourceAdult(false);
      expect(parental.isAdultItemHidden(adult), isFalse);
    });

    test('adult categories are filtered when locked', () async {
      final store = ParentalControlsStore(profileId: 'cats');
      await store.setPin('9999');
      final parental = ParentalLockProvider(profileId: 'cats');
      await parental.load();
      expect(parental.isContentLocked, isTrue);

      final cats = [
        const IptvCategory(
          id: '1',
          name: 'News',
          kind: IptvCategoryKind.live,
        ),
        const IptvCategory(
          id: '2',
          name: 'XXX',
          kind: IptvCategoryKind.live,
          isAdult: true,
        ),
      ];
      final filtered = parental.filterLiveCategories(cats);
      expect(filtered.map((c) => c.id), ['1']);
    });
  });

  group('ParentalLockProvider hidden sources', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('locked session hides items from hidden source ids', () async {
      final store = ParentalControlsStore(profileId: 'src');
      await store.setPin('1234');
      final parental = ParentalLockProvider(profileId: 'src');
      await parental.load();
      expect(parental.isContentLocked, isTrue);

      await parental.unlock('1234');
      await parental.setHiddenSourceIds({'adult-src'});
      parental.lockSession();

      const hidden = MediaItem(
        id: 'h1',
        title: 'Hidden',
        playUrl: 'http://x',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'adult-src',
      );
      const visible = MediaItem(
        id: 'v1',
        title: 'Visible',
        playUrl: 'http://x',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'family-src',
      );

      expect(parental.isSourceIdHidden('adult-src'), isTrue);
      expect(parental.isSourceIdHidden('family-src'), isFalse);
      expect(parental.isItemHidden(hidden), isTrue);
      expect(parental.isItemHidden(visible), isFalse);

      final before = parental.lockFilterStamp;
      await parental.unlock('1234');
      expect(parental.isItemHidden(hidden), isFalse);
      expect(parental.lockFilterStamp, 'unlocked');
      expect(before, isNot(equals(parental.lockFilterStamp)));
    });

    test('filterCategories drops categories from hidden sources', () async {
      final store = ParentalControlsStore(profileId: 'src-cats');
      await store.setPin('5555');
      final parental = ParentalLockProvider(profileId: 'src-cats');
      await parental.load();
      await parental.unlock('5555');
      await parental.setHiddenSourceIds({'bad'});
      parental.lockSession();

      final cats = [
        const IptvCategory(
          id: '1',
          name: 'Movies',
          kind: IptvCategoryKind.vod,
          sourceId: 'good',
        ),
        const IptvCategory(
          id: '2',
          name: 'Adult',
          kind: IptvCategoryKind.vod,
          sourceId: 'bad',
        ),
      ];
      final filtered = parental.filterCategories(cats);
      expect(filtered.map((c) => c.id), ['1']);
    });

    test('hidden source ids persist across load', () async {
      final store = ParentalControlsStore(profileId: 'persist');
      await store.setPin('1111');
      await store.saveHiddenSourceIds(['a', 'b']);

      final parental = ParentalLockProvider(profileId: 'persist');
      await parental.load();
      expect(parental.hiddenSourceIds, {'a', 'b'});
      expect(parental.lockFilterStamp, contains('src:a,b'));
    });
  });
}
