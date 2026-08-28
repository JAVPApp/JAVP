import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/source_content_sniff.dart';

void main() {
  group('sniffSourceContent', () {
    test('detects IPTV M3U channel lists', () {
      const peek = '''
#EXTM3U url-tvg="https://example.com/epg.xml"
#EXTINF:-1 tvg-id="fr2" group-title="FR",Channel Two
https://cdn.example.com/fr2.ts
#EXTINF:-1 tvg-id="fr3" group-title="FR",Channel Three
https://cdn.example.com/fr3.ts
''';
      expect(sniffSourceContent(peek), SourceContentKind.iptvM3u);
    });

    test('detects HLS master playlists', () {
      const peek = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000
https://cdn.example.com/mid.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000
https://cdn.example.com/hi.m3u8
''';
      expect(sniffSourceContent(peek), SourceContentKind.hlsPlaylist);
    });

    test('detects HLS media playlists', () {
      const peek = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:9.0,
seg0.ts
#EXTINF:9.0,
seg1.ts
''';
      expect(sniffSourceContent(peek), SourceContentKind.hlsPlaylist);
    });

    test('detects JSON catalog object and bare array', () {
      expect(
        sniffSourceContent('''
{"name":"Home","version":1,"items":[{"id":"1","title":"A","playUrl":"https://x/a.mp4"}]}
'''),
        SourceContentKind.jsonCatalog,
      );
      expect(
        sniffSourceContent('''
[{"title":"Live","url":"https://cdn.example.com/live.m3u8","kind":"live"}]
'''),
        SourceContentKind.jsonCatalog,
      );
      expect(
        sniffSourceContent('''
{"name":"Big","version":2,"capabilities":["search","browse"],"itemCount":10000}
'''),
        SourceContentKind.jsonCatalog,
      );
    });

    test('detects HTML and XMLTV', () {
      expect(
        sniffSourceContent('<!DOCTYPE html><html><body>login</body></html>'),
        SourceContentKind.html,
      );
      expect(
        sniffSourceContent('''
<?xml version="1.0"?>
<tv generator-info-name="xmltv">
  <channel id="fr2"><display-name>Channel Two</display-name></channel>
  <programme start="20200101000000 +0000" stop="20200101010000 +0000" channel="fr2">
    <title>News</title>
  </programme>
</tv>
'''),
        SourceContentKind.xmlEpg,
      );
    });

    test('mismatch exception exposes switch flags', () {
      final jsonOnM3u = SourceKindMismatchException(
        expected: SourceContentExpectation.m3uPlaylist,
        detected: SourceContentKind.jsonCatalog,
        message: mismatchMessageFor(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: SourceContentKind.jsonCatalog,
        ),
      );
      expect(jsonOnM3u.canSwitchToJsonCatalog, isTrue);
      expect(jsonOnM3u.canSwitchToM3uPlaylist, isFalse);

      final m3uOnJson = SourceKindMismatchException(
        expected: SourceContentExpectation.jsonCatalog,
        detected: SourceContentKind.iptvM3u,
        message: mismatchMessageFor(
          expected: SourceContentExpectation.jsonCatalog,
          detected: SourceContentKind.iptvM3u,
        ),
      );
      expect(m3uOnJson.canSwitchToM3uPlaylist, isTrue);
      expect(m3uOnJson.canSwitchToJsonCatalog, isFalse);

      final xtreamOnM3u = SourceKindMismatchException(
        expected: SourceContentExpectation.m3uPlaylist,
        detected: SourceContentKind.xtreamCodes,
        message: mismatchMessageFor(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: SourceContentKind.xtreamCodes,
        ),
      );
      expect(xtreamOnM3u.canSwitchToXtream, isTrue);
      expect(xtreamOnM3u.allowsContinueAsM3u, isFalse);
      expect(xtreamOnM3u.canSwitchToJsonCatalog, isFalse);

      final softXtream = SourceKindMismatchException(
        expected: SourceContentExpectation.m3uPlaylist,
        detected: SourceContentKind.xtreamCodes,
        softSuggest: true,
        message: mismatchMessageFor(
          expected: SourceContentExpectation.m3uPlaylist,
          detected: SourceContentKind.xtreamCodes,
        ),
      );
      expect(softXtream.canSwitchToXtream, isTrue);
      expect(softXtream.allowsContinueAsM3u, isTrue);
    });

    test('detects Xtream player_api JSON payloads', () {
      expect(
        sniffSourceContent('''
{"user_info":{"username":"joe","auth":1},"server_info":{"url":"panel.example"}}
'''),
        SourceContentKind.xtreamCodes,
      );
      expect(
        looksLikeXtreamPlayerApiResponse(
          '{"user_info":{"auth":"1","username":"a"},"server_info":{}}',
        ),
        isTrue,
      );
      expect(
        looksLikeXtreamPlayerApiResponse('{"items":[{"title":"A"}]}'),
        isFalse,
      );
    });

    test('detects basic URL-only M3U playlists', () {
      const peek = '''
https://cdn.onlyhitsradio.net/onlyhits
https://cdn.onlyhitsradio.net/gold
''';
      expect(sniffSourceContent(peek), SourceContentKind.iptvM3u);
      expect(looksLikeBasicM3uPlaylist(peek), isTrue);
    });

    test('does not treat HLS media playlists as basic M3U', () {
      const peek = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:9.0,
seg0.ts
''';
      expect(sniffSourceContent(peek), SourceContentKind.hlsPlaylist);
    });

    test('rejects random prose as basic M3U', () {
      expect(
        sniffSourceContent('hello world\nthis is not a playlist'),
        SourceContentKind.unknown,
      );
    });
  });
}
