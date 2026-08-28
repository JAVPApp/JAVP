import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/download/download_manager.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryProvider library;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    library = LibraryProvider(store: LibraryStore(prefs: prefs));
    await library.bootstrap();
    library.sources = [
      IptvSource(
        id: 'nyaa',
        name: 'Catalog',
        type: IptvSourceType.custom,
        playlistUrl: 'https://example.com/catalog',
        createdAt: DateTime.utc(2024),
      ),
    ];
    tempDir = Directory.systemTemp.createTempSync('javp_offline_ep_');
  });

  tearDown(() {
    library.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  final series = MediaItem(
    id: 'anilist-201817',
    title: 'Show',
    playUrl: '',
    kind: MediaKind.series,
    origin: MediaOrigin.customCatalog,
    sourceId: 'nyaa',
    anilistId: 201817,
  );
  const episode = SeriesEpisode(
    id: 'anilist-201817-s1e8',
    episodeNum: 8,
    seasonNumber: 1,
    title: 'Episode 8',
    containerExtension: 'mkv',
  );

  test(
    'ensureEpisodePlayable uses restored download instead of catalog resolve',
    () async {
      final file = File('${tempDir.path}/ep.mkv')..writeAsStringSync('x');
      final stub = library.episodeMediaItem(series: series, episode: episode);
      expect(stub, isNotNull);
      expect(stub!.playUrl, isEmpty);

      library.downloads.tasks.add(
        DownloadTask(
          id: 'task-1',
          item: stub,
          remoteUrl: 'magnet:?xt=urn:btih:abc',
          localPath: file.path,
          status: DownloadStatus.completed,
          progress: 1,
        ),
      );

      expect(
        library.hasOfflineCopyForEpisode(series: series, episode: episode),
        isTrue,
      );
      final sameSession = await library.ensureEpisodePlayable(
        series: series,
        episode: episode,
      );
      expect(sameSession, isNotNull);
      expect(sameSession!.playUrl, file.path);
      expect(sameSession.origin, MediaOrigin.download);

      // Restart: only the local asLocalItem row is persisted.
      final persisted = library.downloads.completedItems;
      library.downloads.tasks.clear();
      library.downloads.restoreCompletedItems(persisted);

      expect(
        library.hasOfflineCopyForEpisode(series: series, episode: episode),
        isTrue,
      );
      final afterRestart = await library.ensureEpisodePlayable(
        series: series,
        episode: episode,
      );
      expect(afterRestart, isNotNull);
      expect(afterRestart!.playUrl, file.path);
      expect(afterRestart.origin, MediaOrigin.download);
    },
  );
}
