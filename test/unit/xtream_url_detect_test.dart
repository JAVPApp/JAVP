import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/iptv/xtream_url_detect.dart';
import 'package:javp/services/source_content_sniff.dart';

void main() {
  group('tryDetectXtreamUrl', () {
    test('detects player_api.php and extracts base + credentials', () {
      final detected = tryDetectXtreamUrl(
        'http://panel.example:8080/player_api.php?username=joe&password=s3cret',
      );
      expect(detected, isNotNull);
      expect(detected!.shape, XtreamUrlShape.playerApi);
      expect(detected.blocksM3uImport, isTrue);
      expect(detected.baseUrl, 'http://panel.example:8080');
      expect(detected.username, 'joe');
      expect(detected.password, 's3cret');
    });

    test('detects nested player_api path prefix', () {
      final detected = tryDetectXtreamUrl(
        'https://cdn.example/iptv/player_api.php?user=a&pass=b',
      );
      expect(detected, isNotNull);
      expect(detected!.baseUrl, 'https://cdn.example/iptv');
      expect(detected.username, 'a');
      expect(detected.password, 'b');
    });

    test('detects get.php playlist export without blocking M3U', () {
      final detected = tryDetectXtreamUrl(
        'http://dns.example:8080/get.php?username=u1&password=p1&type=m3u_plus&output=ts',
      );
      expect(detected, isNotNull);
      expect(detected!.shape, XtreamUrlShape.playlistExport);
      expect(detected.blocksM3uImport, isFalse);
      expect(detected.baseUrl, 'http://dns.example:8080');
      expect(detected.username, 'u1');
      expect(detected.password, 'p1');
    });

    test('detects /live/user/pass/stream paths', () {
      final detected = tryDetectXtreamUrl(
        'http://x.example:25461/live/alice/secret/12345.ts',
      );
      expect(detected, isNotNull);
      expect(detected!.shape, XtreamUrlShape.streamPath);
      expect(detected.blocksM3uImport, isTrue);
      expect(detected.baseUrl, 'http://x.example:25461');
      expect(detected.username, 'alice');
      expect(detected.password, 'secret');
    });

    test('detects panel URL with username/password query', () {
      final detected = tryDetectXtreamUrl(
        'http://line.example:8080/?username=bob&password=hunter2',
      );
      expect(detected, isNotNull);
      expect(detected!.shape, XtreamUrlShape.credentialsQuery);
      expect(detected.blocksM3uImport, isTrue);
      expect(detected.baseUrl, 'http://line.example:8080');
      expect(detected.username, 'bob');
      expect(detected.password, 'hunter2');
    });

    test('ignores plain M3U URLs', () {
      expect(
        tryDetectXtreamUrl('https://cdn.example.com/channels.m3u'),
        isNull,
      );
      expect(
        tryDetectXtreamUrl('http://example.com/get.php'),
        isNull,
      );
    });
  });

  group('SourceKindMismatchException Xtream', () {
    test('exposes canSwitchToXtream and soft continue', () {
      final mismatch = SourceKindMismatchException(
        expected: SourceContentExpectation.m3uPlaylist,
        detected: SourceContentKind.xtreamCodes,
        message: mismatchMessageFor(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: SourceContentKind.xtreamCodes,
        ),
      );
      expect(mismatch.canSwitchToXtream, isTrue);
      expect(mismatch.allowsContinueAsM3u, isFalse);
      expect(mismatch.canSwitchToJsonCatalog, isFalse);

      final soft = SourceKindMismatchException(
        expected: SourceContentExpectation.m3uPlaylist,
        detected: SourceContentKind.xtreamCodes,
        softSuggest: true,
        message: mismatchMessageFor(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: SourceContentKind.xtreamCodes,
        ),
      );
      expect(soft.allowsContinueAsM3u, isTrue);
    });
  });
}
