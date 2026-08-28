import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryProvider library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    library = LibraryProvider(store: LibraryStore(prefs: prefs));
    await library.bootstrap();
    library.sources = [
      IptvSource(
        id: 'customcat',
        name: 'Catalog',
        type: IptvSourceType.custom,
        playlistUrl: 'https://example.com/catalog',
        createdAt: DateTime.utc(2024),
      ),
    ];
  });

  tearDown(() => library.dispose());

  test(
    'episodeMediaItem returns a stub for unresolved custom catalog rows',
    () {
      final series = MediaItem(
        id: 'anilist-201817',
        title: 'Show',
        playUrl: '',
        kind: MediaKind.series,
        origin: MediaOrigin.customCatalog,
        sourceId: 'customcat',
        anilistId: 201817,
      );
      const episode = SeriesEpisode(
        id: 'anilist-201817-s1e8',
        episodeNum: 8,
        seasonNumber: 1,
        title: 'Episode 8',
        containerExtension: 'mkv',
      );

      final item = library.episodeMediaItem(series: series, episode: episode);
      expect(item, isNotNull);
      expect(item!.id, episode.id);
      expect(item.playUrl, isEmpty);
      expect(item.seasonNumber, 1);
      expect(item.episodeNumber, 8);
      expect(item.seriesId, series.id);
      expect(item.origin, MediaOrigin.customCatalog);
    },
  );
}
