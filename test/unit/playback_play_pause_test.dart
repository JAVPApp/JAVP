import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('togglePlayPause flips playing immediately without an engine', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final library = LibraryProvider(store: LibraryStore(prefs: prefs));
    final playback = PlaybackProvider(library: library);
    addTearDown(() {
      playback.dispose();
      library.dispose();
    });

    playback.debugAttachSession(
      MediaItem(
        id: 'vod-1',
        title: 'Clip',
        playUrl: 'https://cdn.example.com/movie.mkv',
        kind: MediaKind.vod,
        origin: MediaOrigin.url,
      ),
      minimized: false,
    );
    expect(playback.playing, isFalse);

    final future = playback.togglePlayPause();
    expect(
      playback.playing,
      isTrue,
      reason: 'chrome should not wait on media_kit',
    );
    await future;
    expect(playback.playing, isTrue);

    await playback.togglePlayPause();
    expect(playback.playing, isFalse);
  });
}
