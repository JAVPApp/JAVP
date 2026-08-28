import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/xtream_play_url.dart';

void main() {
  final source = IptvSource(
    id: 'src-1',
    name: 'Test',
    type: IptvSourceType.xtream,
    createdAt: DateTime.utc(2026, 1, 1),
    serverUrl: 'http://example.com',
    username: 'user',
    password: 'pass',
  );

  group('xtreamStoredStreamUrl', () {
    test('omits credentials from live / movie / series paths', () {
      expect(
        xtreamStoredStreamUrl(
          base: 'http://example.com/',
          kind: 'live',
          streamId: '22807',
          extension: 'ts',
        ),
        'http://example.com/live/22807.ts',
      );
      expect(
        xtreamStoredStreamUrl(
          base: 'http://example.com',
          kind: 'movie',
          streamId: '9',
          extension: '.mkv',
        ),
        'http://example.com/movie/9.mkv',
      );
      expect(
        xtreamStoredStreamUrl(
          base: 'http://example.com',
          kind: 'series',
          streamId: '1453778',
          extension: 'mp4',
        ),
        'http://example.com/series/1453778.mp4',
      );
    });
  });

  group('stripXtreamCredentials / injectXtreamCredentials', () {
    test('strips and restores live path credentials', () {
      const full = 'http://example.com/live/user/pass/22807.ts';
      const stored = 'http://example.com/live/22807.ts';
      expect(stripXtreamCredentials(full), stored);
      expect(injectXtreamCredentials(stored, source), full);
      expect(injectXtreamCredentials(full, source), full);
    });

    test('strips and restores movie and series paths', () {
      expect(
        stripXtreamCredentials('http://example.com/movie/user/pass/9.mkv'),
        'http://example.com/movie/9.mkv',
      );
      expect(
        injectXtreamCredentials(
          'http://example.com/series/1453778.mp4',
          source,
        ),
        'http://example.com/series/user/pass/1453778.mp4',
      );
    });

    test('strips and restores timeshift path credentials', () {
      const stamp = '2026-08-07:20-30';
      const full = 'http://example.com/timeshift/user/pass/45/$stamp/22807.ts';
      const stored = 'http://example.com/timeshift/45/$stamp/22807.ts';
      expect(stripXtreamCredentials(full), stored);
      expect(injectXtreamCredentials(stored, source), full);
    });

    test('strips and restores php query credentials', () {
      const stamp = '2026-08-07:20-30';
      final full =
          'http://example.com/streaming/timeshift.php?'
          'username=user&password=pass&stream=22807&start=${Uri.encodeQueryComponent(stamp)}&duration=45';
      final stripped = stripXtreamCredentials(full);
      expect(stripped, isNot(contains('username=')));
      expect(stripped, isNot(contains('password=')));
      expect(stripped, contains('stream=22807'));
      final restored = injectXtreamCredentials(stripped, source);
      expect(restored, contains('username=user'));
      expect(restored, contains('password=pass'));
      expect(restored, contains('stream=22807'));
    });

    test('leaves unrelated URLs alone', () {
      const other = 'https://cdn.example/playlist.m3u8';
      expect(stripXtreamCredentials(other), other);
      expect(injectXtreamCredentials(other, source), other);
    });
  });

  group('MediaItem JSON strips Xtream credentials only', () {
    test('iptvXtream playUrl loses panel user/pass on round-trip', () {
      const full = 'http://example.com/live/user/pass/22807.ts';
      final item = MediaItem(
        id: 'x1',
        title: 'Xtream',
        playUrl: full,
        kind: MediaKind.live,
        origin: MediaOrigin.iptvXtream,
      );
      final json = item.toJson();
      expect(json['playUrl'], 'http://example.com/live/22807.ts');
      final restored = MediaItem.fromJson(json);
      expect(restored.playUrl, 'http://example.com/live/22807.ts');
    });

    test('iptvM3u Xtream-shaped paths keep embedded credentials', () {
      const full = 'http://example.com/live/user/pass/22807.ts';
      final item = MediaItem(
        id: 'm1',
        title: 'M3U',
        playUrl: full,
        kind: MediaKind.live,
        origin: MediaOrigin.iptvM3u,
      );
      final json = item.toJson();
      expect(json['playUrl'], full);
      final restored = MediaItem.fromJson(json);
      expect(restored.playUrl, full);
    });
  });

  group('isXtreamStreamUrl / isXtreamTimeshiftUrl / xtreamUrlExtension', () {
    test('detects live, movie, series, timeshift, and php forms', () {
      expect(isXtreamStreamUrl('http://example.com/live/22807.ts'), isTrue);
      expect(
        isXtreamStreamUrl('http://example.com/movie/user/pass/9.mkv'),
        isTrue,
      );
      expect(
        isXtreamStreamUrl('http://example.com/series/1453778.mp4'),
        isTrue,
      );
      expect(
        isXtreamStreamUrl(
          'http://example.com/streaming/timeshift.php?stream=22807',
        ),
        isTrue,
      );
      expect(isXtreamStreamUrl('https://cdn.example/video.mp4'), isFalse);
    });

    test('detects timeshift paths', () {
      expect(
        isXtreamTimeshiftUrl(
          'http://example.com/timeshift/45/2026-08-07:20-30/22807.ts',
        ),
        isTrue,
      );
      expect(isXtreamTimeshiftUrl('http://example.com/live/22807.ts'), isFalse);
    });

    test('reads the file extension', () {
      expect(xtreamUrlExtension('http://example.com/live/22807.ts'), 'ts');
      expect(xtreamUrlExtension('http://example.com/movie/9.mkv'), 'mkv');
      expect(xtreamUrlExtension('http://example.com/live/22807'), isNull);
    });
  });
}
