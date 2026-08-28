import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/playback/hls_native_dvr.dart';
import 'package:javp/services/playback/live_edge_seek.dart';

void main() {
  group('looksLikeHlsPlaylistUrl', () {
    test('accepts m3u8 playlists', () {
      expect(looksLikeHlsPlaylistUrl('https://cdn/live/1.m3u8'), isTrue);
      expect(
        looksLikeHlsPlaylistUrl('https://panel/live/u/p/1.m3u8?token=x'),
        isTrue,
      );
    });

    test('rejects progressive MPEG-TS', () {
      expect(looksLikeHlsPlaylistUrl('https://cdn/live/1.ts'), isFalse);
      expect(looksLikeHlsPlaylistUrl('https://cdn/live/1.m2ts'), isFalse);
    });
  });

  group('hlsNativeDvrEnabled', () {
    test('matches Clappr hlsMinimumDvrSize of 60s', () {
      expect(
        hlsNativeDvrEnabled(
          isLive: true,
          playUrl: 'https://cdn/live.m3u8',
          playableDuration: const Duration(seconds: 59),
        ),
        isFalse,
      );
      expect(
        hlsNativeDvrEnabled(
          isLive: true,
          playUrl: 'https://cdn/live.m3u8',
          playableDuration: kHlsMinimumDvrSize,
        ),
        isTrue,
      );
    });

    test('ignores VOD and non-HLS live', () {
      expect(
        hlsNativeDvrEnabled(
          isLive: false,
          playUrl: 'https://cdn/vod.m3u8',
          playableDuration: const Duration(minutes: 5),
        ),
        isFalse,
      );
      expect(
        hlsNativeDvrEnabled(
          isLive: true,
          playUrl: 'https://cdn/live.ts',
          playableDuration: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });
  });

  group('hlsNativeDvrAtLiveEdge', () {
    test('treats within 3s of duration as live (Clappr)', () {
      const duration = Duration(seconds: 120);
      expect(
        hlsNativeDvrAtLiveEdge(
          position: const Duration(seconds: 117),
          duration: duration,
        ),
        isTrue,
      );
      expect(
        hlsNativeDvrAtLiveEdge(
          position: const Duration(seconds: 116),
          duration: duration,
        ),
        isFalse,
      );
      expect(kLiveEdgeSeekMargin, const Duration(seconds: 3));
    });

    test('unknown duration is treated as live', () {
      expect(
        hlsNativeDvrAtLiveEdge(
          position: Duration.zero,
          duration: Duration.zero,
        ),
        isTrue,
      );
    });
  });

  group('hlsNativeDvrSeekPosition', () {
    final now = DateTime(2026, 8, 15, 21, 0);
    const window = Duration(minutes: 2);

    test('near now jumps to live', () {
      expect(
        hlsNativeDvrSeekPosition(
          target: now.subtract(const Duration(seconds: 2)),
          now: now,
          window: window,
        ),
        isNull,
      );
    });

    test('maps wall-clock delay onto 0…duration', () {
      expect(
        hlsNativeDvrSeekPosition(
          target: now.subtract(const Duration(seconds: 40)),
          now: now,
          window: window,
        ),
        window - const Duration(seconds: 40),
      );
    });

    test('clamps older than the window to the oldest segment', () {
      expect(
        hlsNativeDvrSeekPosition(
          target: now.subtract(const Duration(hours: 1)),
          now: now,
          window: window,
        ),
        Duration.zero,
      );
    });
  });

  group('hlsNativeDvrContains', () {
    final now = DateTime(2026, 8, 15, 21, 0);
    const window = Duration(minutes: 2);

    test('true inside the playlist, false beyond it', () {
      expect(
        hlsNativeDvrContains(
          target: now.subtract(const Duration(seconds: 90)),
          now: now,
          window: window,
        ),
        isTrue,
      );
      expect(
        hlsNativeDvrContains(
          target: now.subtract(const Duration(minutes: 5)),
          now: now,
          window: window,
        ),
        isFalse,
      );
    });

    test('false when the window is below the DVR threshold', () {
      expect(
        hlsNativeDvrContains(
          target: now.subtract(const Duration(seconds: 20)),
          now: now,
          window: const Duration(seconds: 30),
        ),
        isFalse,
      );
    });
  });

  test('progress and delay follow the playlist window', () {
    const duration = Duration(seconds: 100);
    const position = Duration(seconds: 75);
    expect(hlsNativeDvrProgress(position: position, duration: duration), 0.75);
    expect(
      hlsNativeDvrDelay(position: position, duration: duration),
      const Duration(seconds: 25),
    );
  });
}
