import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/download/download_manager.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('javp_dl_match_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  MediaItem episode({
    required String id,
    required int episode,
    String playUrl = 'magnet:?xt=urn:btih:SAMEPACK',
  }) {
    return MediaItem(
      id: id,
      title: 'Ep $episode',
      playUrl: playUrl,
      kind: MediaKind.vod,
      origin: MediaOrigin.torrent,
      seriesId: 'show',
      seasonNumber: 1,
      episodeNumber: episode,
      sourceId: 'src1',
    );
  }

  test('shared magnet does not make every episode show the same download', () {
    final file = File('${tempDir.path}/a.mkv')..writeAsStringSync('x');
    final ep1 = episode(id: 'ep-1', episode: 1);
    final ep2 = episode(id: 'ep-2', episode: 2);
    final dm = DownloadManager();
    dm.tasks.add(
      DownloadTask(
        id: 'task-1',
        item: ep1,
        remoteUrl: ep1.playUrl,
        localPath: file.path,
        status: DownloadStatus.downloading,
        progress: 0.4,
      ),
    );

    expect(dm.bestTaskFor(ep1)?.id, 'task-1');
    expect(dm.bestTaskFor(ep2), isNull);
  });
}
