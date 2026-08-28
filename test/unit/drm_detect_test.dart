import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:javp/services/playback/drm_manifest_probe.dart';
import 'package:javp/services/playback/hls_master.dart';

void main() {
  group('detectDrmInManifest HLS', () {
    test('ignores AES-128', () {
      const body = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key.bin"
#EXTINF:10.0,
segment.ts
''';
      expect(detectDrmInManifest(body), isNull);
    });

    test('ignores METHOD=NONE', () {
      expect(
        detectDrmInManifest('#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\na.ts\n'),
        isNull,
      );
    });

    test('flags SAMPLE-AES FairPlay', () {
      const body = '''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://item",KEYFORMAT="com.apple.streamingkeydelivery"
''';
      expect(detectDrmInManifest(body), DrmKind.fairplay);
    });

    test('flags SAMPLE-AES-CTR Widevine', () {
      const body = '''
#EXTM3U
#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed",URI="data:text/plain;base64,AAAA"
''';
      expect(detectDrmInManifest(body), DrmKind.widevine);
    });
  });

  group('detectDrmInManifest DASH', () {
    test('ignores clear DASH without ContentProtection', () {
      const mpd = '''
<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period><AdaptationSet><Representation id="1"/></AdaptationSet></Period>
</MPD>
''';
      expect(detectDrmInManifest(mpd), isNull);
    });

    test('flags Widevine ContentProtection', () {
      const mpd = '''
<MPD>
  <ContentProtection schemeIdUri="urn:uuid:EDEF8BA9-79D6-4ACE-A3C8-27DCD51D21ED">
    <cenc:pssh>AAAA</cenc:pssh>
  </ContentProtection>
</MPD>
''';
      expect(detectDrmInManifest(mpd), DrmKind.widevine);
    });

    test('flags PlayReady UUID', () {
      const mpd = '''
<MPD>
  <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"/>
</MPD>
''';
      expect(detectDrmInManifest(mpd), DrmKind.playready);
    });
  });

  group('catalog / kodi / headers', () {
    test('reads drm and licenseUrl from catalog JSON', () {
      expect(drmKindFromCatalogJson({'drm': 'widevine'}), DrmKind.widevine);
      expect(
        drmKindFromCatalogJson({
          'licenseUrl': 'https://license.example/widevine',
        }),
        DrmKind.widevine,
      );
      expect(
        drmKindFromCatalogJson({
          'drm': {'scheme': 'playready', 'licenseUrl': 'https://pr.example'},
        }),
        DrmKind.playready,
      );
      expect(drmKindFromCatalogJson({'drm': 'none'}), isNull);
      expect(drmKindFromCatalogJson({'title': 'Clear'}), isNull);
      expect(drmKindFromCatalogJson({'type': 'movie', 'kind': 'vod'}), isNull);
    });

    test('reads KODIPROP license_type', () {
      expect(
        drmKindFromKodiprop(
          '#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha',
        ),
        DrmKind.widevine,
      );
      expect(
        drmKindFromKodiprop('#KODIPROP:inputstreamaddon=inputstream.adaptive'),
        isNull,
      );
    });

    test('strips the hint header before HTTP', () {
      final cleaned = withoutDrmHintHeaders({
        drmHintHeader: 'widevine',
        'Authorization': 'Bearer x',
      });
      expect(cleaned, {'Authorization': 'Bearer x'});
      expect(headersIndicateDrm({drmHintHeader: 'widevine'}), isTrue);
    });
  });

  group('player error mapping', () {
    test('maps libmpv decrypt noise', () {
      expect(
        looksLikePlayerDrmError('Failed to decrypt packet (cenc).'),
        isTrue,
      );
      expect(looksLikePlayerDrmError('Could not open codec.'), isFalse);
      expect(
        surfacePlayerError(
          const UnsupportedDrmException(kind: DrmKind.widevine),
        ),
        drmProtectedUserMessage,
      );
    });
  });

  test('looksLikeDashUrl', () {
    expect(looksLikeDashUrl('https://cdn.example/movie.mpd'), isTrue);
    expect(looksLikeDashUrl('https://cdn.example/dash/stream?token=1'), isTrue);
    expect(looksLikeDashUrl('https://cdn.example/dashboard/list'), isFalse);
    expect(looksLikeDashUrl('https://cdn.example/movie.m3u8'), isFalse);
  });

  test('HlsMaster.resolvePlaybackPlan throws on Widevine master', () async {
    const body = '''
#EXTM3U
#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="com.widevine.alpha",URI="data:text/plain;base64,AAAA"
#EXT-X-STREAM-INF:BANDWIDTH=1000000
720p.m3u8
''';
    final client = MockClient((request) async => http.Response(body, 200));
    expect(
      () => HlsMaster.resolvePlaybackPlan(
        'https://cdn.example/master.m3u8',
        client: client,
      ),
      throwsA(isA<UnsupportedDrmException>()),
    );
  });

  test(
    'HlsMaster still plans clear AES-128 media playlists as null master',
    () async {
      const body = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key.bin"
#EXTINF:10.0,
seg.ts
#EXT-X-ENDLIST
''';
      final client = MockClient((request) async => http.Response(body, 200));
      expect(
        await HlsMaster.resolvePlaybackPlan(
          'https://cdn.example/media.m3u8',
          client: client,
        ),
        isNull,
      );
    },
  );

  test('DrmManifestProbe throws on Widevine MPD', () async {
    const mpd = '''
<MPD>
  <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
</MPD>
''';
    final client = MockClient((request) async => http.Response(mpd, 200));
    await expectLater(
      DrmManifestProbe.throwIfProtected(
        'https://cdn.example/movie.mpd',
        client: client,
      ),
      throwsA(isA<UnsupportedDrmException>()),
    );
  });
}
