import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/playback/hls_master.dart';

void main() {
  const demuxedHlsMaster = '''
#EXTM3U
#EXT-X-VERSION:3

#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Français",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="fr",URI="audio_fr/playlist.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=NO,AUTOSELECT=NO,LANGUAGE="en",URI="audio_en/playlist.m3u8"

#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,LANGUAGE="eng",URI="subs_eng.vtt"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Français",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,LANGUAGE="fre",URI="subs_fre.vtt"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Français (Forced)",DEFAULT=YES,AUTOSELECT=YES,FORCED=YES,LANGUAGE="fre",URI="subs_fre_forced.vtt"

#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"
720p/playlist.m3u8
''';

  const multiQualityMuxed = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
1080p.m3u8
''';

  group('HlsMaster.parseMasterPlaylist', () {
    test('parses demuxed-audio master like demuxedHls', () {
      final master = HlsMaster.parseMasterPlaylist(
        demuxedHlsMaster,
        base: Uri.parse(
          'https://cdn.example/movies/1083381-brkdh/master.m3u8',
        ),
      );
      expect(master, isNotNull);
      expect(master!.hasDemuxedAudio, isTrue);
      expect(master.variants, hasLength(1));
      expect(
        master.bestVariant!.uri.toString(),
        'https://cdn.example/movies/1083381-brkdh/720p/playlist.m3u8',
      );
      expect(master.bestVariant!.width, 1280);
      expect(master.bestVariant!.height, 720);
      expect(master.audioTracks, hasLength(2));
      expect(master.audioTracks.first.language, 'fr');
      expect(master.audioTracks.first.isDefault, isTrue);
      expect(
        master.audioTracks.first.url,
        'https://cdn.example/movies/1083381-brkdh/audio_fr/playlist.m3u8',
      );
      expect(master.subtitles, hasLength(3));
      expect(master.subtitles.where((s) => s.forced).length, 1);
      expect(master.subtitles.first.format, 'vtt');
    });

    test('picks highest resolution variant', () {
      final master = HlsMaster.parseMasterPlaylist(
        multiQualityMuxed,
        base: Uri.parse('https://cdn.example.com/master.m3u8'),
      );
      expect(
        master!.bestVariant!.uri.toString(),
        'https://cdn.example.com/1080p.m3u8',
      );
      expect(master.hasDemuxedAudio, isFalse);
      expect(master.variantsByQuality.map((v) => v.height), [1080, 720, 360]);
    });

    test('resolves parent-relative variant URIs against the master', () {
      const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080,CODECS="avc1.4d4028,mp4a.40.2"
../../../manifest/sc-tpa1jkfv5hc4x/0.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
../../../manifest/sc-tpa1jkfv5hc4x/1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=960x540,CODECS="avc1.4d401e,mp4a.40.2"
../../../manifest/sc-tpa1jkfv5hc4x/2.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
../../../manifest/sc-tpa1jkfv5hc4x/3.m3u8
''';
      final master = HlsMaster.parseMasterPlaylist(
        body,
        base: Uri.parse(
          'https://sis-global.prod.samsungtv.plus/v1/tvpprd/sc-tpa1jkfv5hc4x.m3u8?ads=1',
        ),
      );
      expect(master, isNotNull);
      expect(master!.hasDemuxedAudio, isFalse);
      expect(master.variantsByQuality.map((v) => v.uri.toString()).toList(), [
        'https://sis-global.prod.samsungtv.plus/manifest/sc-tpa1jkfv5hc4x/0.m3u8',
        'https://sis-global.prod.samsungtv.plus/manifest/sc-tpa1jkfv5hc4x/1.m3u8',
        'https://sis-global.prod.samsungtv.plus/manifest/sc-tpa1jkfv5hc4x/2.m3u8',
        'https://sis-global.prod.samsungtv.plus/manifest/sc-tpa1jkfv5hc4x/3.m3u8',
      ]);
    });

    test('returns null for media playlists', () {
      const body = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:12
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.0,
segment-000.ts
#EXT-X-ENDLIST
''';
      expect(
        HlsMaster.parseMasterPlaylist(
          body,
          base: Uri.parse('https://cdn.example.com/720p/playlist.m3u8'),
        ),
        isNull,
      );
    });
  });

  group('HlsMaster.planFromMaster', () {
    test('demuxed master opens best media playlist, not the master', () {
      final master = HlsMaster.parseMasterPlaylist(
        demuxedHlsMaster,
        base: Uri.parse(
          'https://cdn.example/movies/1083381-brkdh/master.m3u8',
        ),
      )!;
      final plan = HlsMaster.planFromMaster(
        master,
        masterUrl:
            'https://cdn.example/movies/1083381-brkdh/master.m3u8',
      )!;
      expect(plan.demuxedAudio, isTrue);
      expect(plan.openMasterForAbr, isFalse);
      expect(
        plan.openUrl,
        'https://cdn.example/movies/1083381-brkdh/720p/playlist.m3u8',
      );
      expect(plan.hasMultipleQualities, isFalse);
    });

    test('muxed multi-quality master stays on master for Auto ABR', () {
      final master = HlsMaster.parseMasterPlaylist(
        multiQualityMuxed,
        base: Uri.parse('https://cdn.example.com/master.m3u8'),
      )!;
      final plan = HlsMaster.planFromMaster(
        master,
        masterUrl: 'https://cdn.example.com/master.m3u8',
      )!;
      expect(plan.demuxedAudio, isFalse);
      expect(plan.openMasterForAbr, isTrue);
      expect(plan.openUrl, 'https://cdn.example.com/master.m3u8');
      expect(plan.hasMultipleQualities, isTrue);
      expect(plan.variants, hasLength(3));
      expect(plan.variants.first.qualityLabel, '1080p');
      expect(
        plan.variants.first.trackId,
        'hls:https://cdn.example.com/1080p.m3u8',
      );
    });
  });

  group('HlsMaster.shouldProbeHls / resolvePlaybackPlan', () {
    test('probes catalog /play resolvers that have no .m3u8 in the URL', () {
      expect(
        HlsMaster.shouldProbeHls(
          'https://catalog.example/catalogs/samsung/play/FRBD410000783',
        ),
        isTrue,
      );
      expect(
        HlsMaster.shouldProbeHls('https://cdn.example.com/master.m3u8'),
        isTrue,
      );
      expect(
        HlsMaster.shouldProbeHls('https://cdn.example.com/movie.mp4'),
        isFalse,
      );
    });

    test('uses the post-redirect URL as master and variant base', () async {
      const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080
../../../manifest/sc-tpa1jkfv5hc4x/0.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3500000,RESOLUTION=1280x720
../../../manifest/sc-tpa1jkfv5hc4x/1.m3u8
''';
      const playUrl = 'https://catalog.example/catalogs/samsung/play/FRBD410000783';
      final finalUri = Uri.parse(
        'https://sis-global.prod.samsungtv.plus/v1/tvpprd/sc-tpa1jkfv5hc4x.m3u8?ads=1',
      );
      final client = MockClient((request) async {
        expect(request.url.toString(), playUrl);
        return http.Response(body, 200, request: http.Request('GET', finalUri));
      });
      final plan = await HlsMaster.resolvePlaybackPlan(playUrl, client: client);
      expect(plan, isNotNull);
      expect(plan!.openMasterForAbr, isTrue);
      expect(plan.sourceUrl, playUrl);
      expect(plan.masterUrl, finalUri.toString());
      expect(plan.openUrl, finalUri.toString());
      expect(plan.variants, hasLength(2));
      expect(
        plan.variants.first.uri.toString(),
        'https://sis-global.prod.samsungtv.plus/manifest/sc-tpa1jkfv5hc4x/0.m3u8',
      );
    });
  });

  group('HlsQualitySwitch', () {
    final master = HlsMaster.parseMasterPlaylist(
      multiQualityMuxed,
      base: Uri.parse('https://cdn.example.com/master.m3u8'),
    )!;
    final v1080 = master.variantsByQuality.first;
    final v720 = master.variantsByQuality.firstWhere((v) => v.height == 720);

    test('muxed master on the same URL switches in place', () {
      expect(
        HlsQualitySwitch.canSwitchInPlace(
          openMasterForAbr: true,
          onMaster: true,
        ),
        isTrue,
      );
      expect(
        HlsQualitySwitch.canSwitchInPlace(
          openMasterForAbr: true,
          onMaster: false,
        ),
        isFalse,
      );
      expect(
        HlsQualitySwitch.canSwitchInPlace(
          openMasterForAbr: false,
          onMaster: true,
        ),
        isFalse,
      );
    });

    test(
      'multiple lavf vids mean we are on the master even if URLs differ',
      () {
        expect(
          HlsQualitySwitch.canSwitchInPlace(
            openMasterForAbr: true,
            onMaster: false,
            demuxerVideoCount: 4,
          ),
          isTrue,
        );
        expect(
          HlsQualitySwitch.canSwitchInPlace(
            openMasterForAbr: false,
            onMaster: false,
            demuxerVideoCount: 4,
          ),
          isFalse,
        );
      },
    );

    test('waits while lavf has only published the selected program', () {
      expect(
        HlsQualitySwitch.shouldWaitForDemuxerTracks(const [
          HlsDemuxerVideo(id: '1', height: 1080),
        ], variantCount: 4),
        isTrue,
      );
      expect(
        HlsQualitySwitch.shouldWaitForDemuxerTracks(const [
          HlsDemuxerVideo(id: '1', height: 1080),
          HlsDemuxerVideo(id: '2', height: 720),
        ], variantCount: 4),
        isFalse,
      );
      expect(
        HlsQualitySwitch.shouldWaitForDemuxerTracks(const [], variantCount: 1),
        isFalse,
      );
    });

    test('locks in place only when a demuxer vid matches', () {
      expect(HlsQualitySwitch.canLockInPlace(hasDemuxerMatch: false), isFalse);
      expect(HlsQualitySwitch.canLockInPlace(hasDemuxerMatch: true), isTrue);
    });

    test('muxed lock does not reload once vid was set', () {
      expect(
        HlsQualitySwitch.shouldReloadMuxedLock(issuedVidSwitch: true),
        isFalse,
      );
      expect(
        HlsQualitySwitch.shouldReloadMuxedLock(issuedVidSwitch: false),
        isTrue,
      );
    });

    test('verify window covers a typical live HLS segment', () {
      expect(
        HlsQualitySwitch.applyVerifyWait,
        greaterThanOrEqualTo(const Duration(seconds: 10)),
      );
    });

    test('lock without BANDWIDTH uses max/min by rank', () {
      final noBr = HlsMaster.parseMasterPlaylist('''
#EXTM3U
#EXT-X-STREAM-INF:RESOLUTION=640x360
360p.m3u8
#EXT-X-STREAM-INF:RESOLUTION=1920x1080
1080p.m3u8
''', base: Uri.parse('https://cdn.example.com/master.m3u8'))!;
      expect(
        HlsQualitySwitch.bitratePropertyForLock(
          noBr.variantsByQuality.first,
          all: noBr.variantsByQuality,
        ),
        'max',
      );
      expect(
        HlsQualitySwitch.bitratePropertyForLock(
          noBr.variantsByQuality.last,
          all: noBr.variantsByQuality,
        ),
        'min',
      );
    });

    test('hls-bitrate is no for Auto and the variant rate when locked', () {
      expect(
        HlsQualitySwitch.bitrateProperty(auto: true, bandwidth: 6000000),
        'no',
      );
      expect(
        HlsQualitySwitch.bitrateProperty(auto: false, bandwidth: 3000000),
        '3000000',
      );
    });

    test('matches demuxer tracks by height when several vids exist', () {
      const tracks = [
        HlsDemuxerVideo(id: '1', height: 1080, bitrate: 6000000),
        HlsDemuxerVideo(id: '2', height: 720, bitrate: 3000000),
        HlsDemuxerVideo(id: '3', height: 360, bitrate: 800000),
      ];
      expect(HlsQualitySwitch.matchDemuxerTrack(v1080, tracks)?.id, '1');
      expect(HlsQualitySwitch.matchDemuxerTrack(v720, tracks)?.id, '2');
    });

    test('does not match a single ABR video track', () {
      const tracks = [HlsDemuxerVideo(id: '1', height: 1080, bitrate: 6000000)];
      expect(HlsQualitySwitch.matchDemuxerTrack(v1080, tracks), isNull);
    });

    test('matches coded height close to the playlist RESOLUTION', () {
      const tracks = [
        HlsDemuxerVideo(id: '1', height: 1088, bitrate: 6000000),
        HlsDemuxerVideo(id: '2', height: 720, bitrate: 3000000),
      ];
      expect(HlsQualitySwitch.matchDemuxerTrack(v1080, tracks)?.id, '1');
    });

    test('matches by quality rank when counts line up', () {
      const tracks = [
        HlsDemuxerVideo(id: '1', height: 1100, bitrate: 1),
        HlsDemuxerVideo(id: '2', height: 800, bitrate: 1),
        HlsDemuxerVideo(id: '3', height: 400, bitrate: 1),
      ];
      expect(
        HlsQualitySwitch.matchDemuxerTrack(
          v720,
          tracks,
          all: master.variantsByQuality,
        )?.id,
        '2',
      );
    });

    test('sameMasterUrl ignores query tokens', () {
      expect(
        HlsQualitySwitch.sameMasterUrl(
          'https://cdn.example.com/master.m3u8?token=a',
          'https://cdn.example.com/master.m3u8?token=b',
        ),
        isTrue,
      );
      expect(
        HlsQualitySwitch.sameMasterUrl(
          'https://cdn.example.com/720p.m3u8',
          'https://cdn.example.com/master.m3u8',
        ),
        isFalse,
      );
    });

    test(
      'sameMasterUrl treats trailing slash and encoding as the same path',
      () {
        expect(
          HlsQualitySwitch.sameMasterUrl(
            'https://cdn.example.com/v1/master/show.m3u8/',
            'https://cdn.example.com/v1/master/show.m3u8',
          ),
          isTrue,
        );
        expect(
          HlsQualitySwitch.sameMasterUrl(
            'https://cdn.example.com/v1/master/show%20a.m3u8',
            'https://cdn.example.com/v1/master/show a.m3u8',
          ),
          isTrue,
        );
      },
    );

    test('matches Samsung-style 1080/720/540/360 programs by height', () {
      const samsung = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080
0.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3500000,RESOLUTION=1280x720
1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=960x540
2.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360
3.m3u8
''';
      final parsed = HlsMaster.parseMasterPlaylist(
        samsung,
        base: Uri.parse('https://cdn.example.com/master.m3u8'),
      )!;
      const tracks = [
        HlsDemuxerVideo(id: '1', height: 1080, bitrate: 6500000),
        HlsDemuxerVideo(id: '2', height: 720, bitrate: 3500000),
        HlsDemuxerVideo(id: '3', height: 540, bitrate: 2000000),
        HlsDemuxerVideo(id: '4', height: 360, bitrate: 1000000),
      ];
      final v540 = parsed.variantsByQuality.firstWhere((v) => v.height == 540);
      expect(HlsQualitySwitch.matchDemuxerTrack(v540, tracks)?.id, '3');
    });

    test('heightMatchesLock allows coded-height slop', () {
      expect(HlsQualitySwitch.heightMatchesLock(1080, 1080), isTrue);
      expect(HlsQualitySwitch.heightMatchesLock(1088, 1080), isTrue);
      expect(HlsQualitySwitch.heightMatchesLock(720, 1080), isFalse);
      expect(HlsQualitySwitch.heightMatchesLock(null, 1080), isFalse);
      expect(HlsQualitySwitch.heightMatchesLock(0, 360), isFalse);
    });

    test('isAutoVid treats auto / no / empty as Adaptive', () {
      expect(HlsQualitySwitch.isAutoVid('auto'), isTrue);
      expect(HlsQualitySwitch.isAutoVid('AUTO'), isTrue);
      expect(HlsQualitySwitch.isAutoVid('no'), isTrue);
      expect(HlsQualitySwitch.isAutoVid(''), isTrue);
      expect(HlsQualitySwitch.isAutoVid('4'), isFalse);
      expect(HlsQualitySwitch.isAutoVid(null), isFalse);
    });

    test('describe helpers stay compact for diagnostics', () {
      expect(
        HlsQualitySwitch.describeVariants(master.variantsByQuality),
        contains('1080p'),
      );
      expect(
        HlsQualitySwitch.describeDemuxer(const [
          HlsDemuxerVideo(id: '1', height: 1080, bitrate: 6000000),
          HlsDemuxerVideo(id: '4', height: 360),
        ]),
        'vid=1 h=1080 br=6000000, vid=4 h=360',
      );
      expect(HlsQualitySwitch.describeDemuxer(const []), '(none)');
    });
  });

  group('HlsMaster.merge*Tracks', () {
    test('keeps catalog tracks and appends new master URLs', () {
      const existing = [
        ExternalAudio(url: 'https://a/existing.m3u8', language: 'ja'),
      ];
      const fromMaster = [
        ExternalAudio(url: 'https://a/existing.m3u8', language: 'ja'),
        ExternalAudio(url: 'https://a/en.m3u8', language: 'en'),
      ];
      final merged = HlsMaster.mergeAudioTracks(existing, fromMaster);
      expect(merged, hasLength(2));
      expect(merged.last.language, 'en');
    });
  });
}
