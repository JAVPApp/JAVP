import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/simkl_models.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/simkl/simkl_match.dart';
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
  });

  tearDown(() => library.dispose());

  test('Simkl watching shell labels as SIMKL, never URL', () {
    final shell = simklLibraryShell(
      SimklLibraryItem(
        title: 'Example Show',
        isShow: true,
        ids: const SimklIds(simkl: '1'),
        watchedEpisodes: 11,
        totalEpisodes: 13,
      ),
    );
    expect(shell.origin, MediaOrigin.url);
    expect(isSimklWatchingShell(shell), isTrue);
    expect(library.sourceLabelFor(shell), 'SIMKL');
    expect(library.shelfSourceLabelFor(shell), 'SIMKL');
    expect(library.sourceLabelFor(shell), isNot('URL'));
  });

  test('custom catalog series prefers real source name over placeholder', () {
    library.sources = [
      IptvSource(
        id: 'pur',
        name: 'ExampleCatalog',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2024),
        playlistUrl: 'https://cataloga.example/catalog',
      ),
      IptvSource(
        id: 'demo',
        name: 'Demo',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2024),
        playlistUrl: 'asset:demo',
        enabled: false,
      ),
    ];
    // Linked Watching row: catalog series id (not simkl:…), no shell tag —
    // only Simkl progress subtitle / id remain.
    final series = MediaItem(
      id: 'series-1',
      title: 'Example Show',
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.customCatalog,
      sourceId: 'pur',
      subtitle: '11/13 eps',
      simklId: '1',
      progress: 11 / 13,
    );
    expect(isTrackerListShell(series), isFalse);
    expect(library.sourceLabelFor(series), 'ExampleCatalog');
    expect(library.shelfSourceLabelFor(series), 'ExampleCatalog');
  });

  test(
    'placeholder Custom catalog + Simkl progress falls back to SIMKL on shelf',
    () {
      library.sources = [
        IptvSource(
          id: 'a',
          name: 'Custom catalog',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2024),
          playlistUrl: '',
        ),
        IptvSource(
          id: 'b',
          name: 'Custom catalog',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2024),
          playlistUrl: '',
        ),
      ];
      final series = MediaItem(
        id: 'series-orphan',
        title: 'Example Show',
        playUrl: '',
        kind: MediaKind.series,
        origin: MediaOrigin.customCatalog,
        // Ambiguous / missing source — would previously paint "Custom catalog".
        subtitle: '11/13 eps',
        simklId: '9',
        progress: 11 / 13,
      );
      expect(isTrackerListShell(series), isFalse);
      expect(library.sourceLabelFor(series), 'Custom catalog');
      expect(library.shelfSourceLabelFor(series), 'SIMKL');
    },
  );

  test('placeholder source name uses catalog URL host', () {
    library.sources = [
      IptvSource(
        id: 'pur',
        name: 'Custom catalog',
        type: IptvSourceType.custom,
        createdAt: DateTime.utc(2024),
        playlistUrl: 'https://catalog.example/api/catalog',
      ),
    ];
    final series = MediaItem(
      id: 'series-host',
      title: 'Example Show',
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.customCatalog,
      sourceId: 'pur',
    );
    expect(library.sourceLabelFor(series), 'catalog.example');
  });

  test(
    'orphaned customCatalog magnet with tracker labels as catalog host',
    () {
      library.sources = [
        IptvSource(
          id: 'customcat-live',
          name: 'Custom catalog',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2024),
          playlistUrl: 'https://catalog.example/magnet/catalog',
        ),
        IptvSource(
          id: 'pur',
          name: 'ExampleCatalog',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2024),
          playlistUrl: 'https://cataloga.example/catalog',
        ),
      ];
      const magnet =
          'magnet:?xt=urn:btih:b61cd0003fe68a75ff5b1718ecadec28a08510d7'
          '&dn=Sample%20Show'
          '&tr=http%3A%2F%2Ftracker.example%3A7777%2Fannounce';
      final episode = MediaItem(
        id: 'anilist-147105-s1e7',
        title: 'Episode 7',
        playUrl: magnet,
        kind: MediaKind.vod,
        origin: MediaOrigin.customCatalog,
        // Old Custom catalog UUID after re-add — not in sources above.
        sourceId: '379b776b-0fa1-4006-b9e8-36b5887a120f',
        seriesId: 'anilist-147105',
        seasonNumber: 1,
        episodeNumber: 7,
        anilistId: 147105,
        simklId: '1885096',
        progress: 0.85,
        lastWatchedAt: DateTime.utc(2026, 8, 11, 22, 22),
      );
      expect(library.sourceLabelFor(episode), 'catalog.example');
      expect(library.shelfSourceLabelFor(episode), 'catalog.example');

      // Continue Watching series shell: empty playUrl, same orphaned sourceId.
      library.history = [episode];
      final shell = MediaItem(
        id: 'anilist-147105',
        title: 'Sample Show',
        playUrl: '',
        kind: MediaKind.series,
        origin: MediaOrigin.customCatalog,
        sourceId: '379b776b-0fa1-4006-b9e8-36b5887a120f',
        streamId: 'anilist-147105',
        seasonNumber: 1,
        episodeNumber: 7,
        anilistId: 147105,
        simklId: '1885096',
        progress: 0.85,
        subtitle: 'S01E07',
      );
      expect(library.sourceLabelFor(shell), 'catalog.example');
      expect(library.shelfSourceLabelFor(shell), 'catalog.example');
    },
  );

  test(
    'orphaned customCatalog magnet without matching catalog falls back to Torrent',
    () {
      // Two enabled customs ⇒ no sole-source shortcut; orphan stays unresolved.
      library.sources = [
        IptvSource(
          id: 'pur',
          name: 'ExampleCatalog',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2024),
          playlistUrl: 'https://cataloga.example/catalog',
        ),
        IptvSource(
          id: 'other',
          name: 'Other dump',
          type: IptvSourceType.custom,
          createdAt: DateTime.utc(2024),
          playlistUrl: 'https://other.example/catalog.json',
        ),
      ];
      final episode = MediaItem(
        id: 'ep-1',
        title: 'Episode 1',
        playUrl:
            'magnet:?xt=urn:btih:abc&dn=Show&tr=http%3A%2F%2Ftracker.example%3A7777%2Fannounce',
        kind: MediaKind.vod,
        origin: MediaOrigin.customCatalog,
        sourceId: 'dead-source',
        seriesId: 'show-1',
        seasonNumber: 1,
        episodeNumber: 1,
      );
      expect(library.sourceLabelFor(episode), 'Torrent');
    },
  );
}
