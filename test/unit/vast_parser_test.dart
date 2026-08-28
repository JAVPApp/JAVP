import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javp/services/ads/vast_client.dart';
import 'package:javp/services/ads/vast_parser.dart';

const _inlineVast = '''
<VAST version="3.0">
  <Ad sequence="1">
    <InLine>
      <Impression><![CDATA[https://ads.example/imp?c=[CACHEBUSTER]]]></Impression>
      <Error><![CDATA[https://ads.example/error?c=[ERRORCODE]]]></Error>
      <Creatives>
        <Creative>
          <Linear skipoffset="00:00:05">
            <Duration>00:00:15</Duration>
            <TrackingEvents>
              <Tracking event="start"><![CDATA[https://ads.example/start]]></Tracking>
              <Tracking event="complete"><![CDATA[https://ads.example/complete]]></Tracking>
            </TrackingEvents>
            <VideoClicks>
              <ClickThrough><![CDATA[https://sponsor.example/landing]]></ClickThrough>
              <ClickTracking><![CDATA[https://ads.example/click]]></ClickTracking>
            </VideoClicks>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4" bitrate="800" width="1280" height="720">
                <![CDATA[https://cdn.example/ad-720.mp4]]>
              </MediaFile>
              <MediaFile delivery="progressive" type="video/mp4" bitrate="400" width="640" height="360">
                <![CDATA[https://cdn.example/ad-360.mp4]]>
              </MediaFile>
              <MediaFile type="application/javascript" apiFramework="VPAID">
                <![CDATA[https://cdn.example/vpaid.js]]>
              </MediaFile>
            </MediaFiles>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
''';

const _wrapperVast = '''
<VAST version="3.0">
  <Ad>
    <Wrapper>
      <VASTAdTagURI><![CDATA[https://ads.example/inner.xml]]></VASTAdTagURI>
      <Impression><![CDATA[https://ads.example/wrapper-imp]]></Impression>
    </Wrapper>
  </Ad>
</VAST>
''';

const _vmap = '''
<vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap" version="1.0">
  <vmap:AdBreak timeOffset="start" breakType="linear">
    <vmap:AdSource>
      <vmap:AdTagURI templateType="vast3"><![CDATA[https://ads.example/preroll.xml]]></vmap:AdTagURI>
    </vmap:AdSource>
  </vmap:AdBreak>
  <vmap:AdBreak timeOffset="00:05:00" breakType="linear">
    <vmap:AdSource>
      <vmap:AdTagURI><![CDATA[https://ads.example/midroll.xml]]></vmap:AdTagURI>
    </vmap:AdSource>
  </vmap:AdBreak>
</vmap:VMAP>
''';

void main() {
  test('parses linear preroll and prefers higher mp4', () {
    final doc = parseVastXml(_inlineVast);
    expect(doc.ads, hasLength(1));
    final ad = doc.ads.single;
    expect(ad.mediaUrl, 'https://cdn.example/ad-720.mp4');
    expect(ad.duration, const Duration(seconds: 15));
    expect(ad.skipOffset, const Duration(seconds: 5));
    expect(ad.clickThroughUrl, 'https://sponsor.example/landing');
    expect(ad.impressions.single, contains('CACHEBUSTER'));
    expect(ad.tracking['start'], ['https://ads.example/start']);
    expect(ad.clickTracking, ['https://ads.example/click']);
  });

  test('parses skipoffset percent against duration', () {
    expect(
      parseVastSkipOffset('25%', const Duration(seconds: 40)),
      const Duration(seconds: 10),
    );
    expect(
      parseVastSkipOffset('00:00:03.500', null),
      const Duration(milliseconds: 3500),
    );
    expect(parseVastSkipOffset(null, const Duration(seconds: 10)), isNull);
  });

  test('replaces VAST macros', () {
    final out = replaceVastMacros(
      'https://x.test/t?c=[CACHEBUSTER]&p=[CONTENTPLAYHEAD]&e=[ERRORCODE]',
      now: DateTime.utc(2026, 1, 2, 3, 4, 5),
      playhead: const Duration(seconds: 4, milliseconds: 12),
      errorCode: '303',
    );
    expect(out, contains('p=00%3A00%3A04.012'));
    expect(out, contains('e=303'));
    expect(out.contains('[CACHEBUSTER]'), isFalse);
  });

  test('vastUrlFromJson reads root, nested ads, and item opt-out', () {
    expect(
      vastUrlFromJson({'vastUrl': 'https://ads.example/vast.xml'}),
      'https://ads.example/vast.xml',
    );
    expect(
      vastUrlFromJson({
        'ads': {'vast': 'https://ads.example/a.xml'},
      }),
      'https://ads.example/a.xml',
    );
    expect(vastUrlFromJson({'title': 'x'}), isNull);
    expect(vastUrlFromJson({'vastUrl': false}, allowEmpty: true), '');
    expect(vastUrlFromJson({'vastUrl': ''}, allowEmpty: true), '');
    expect(vastUrlFromJson({'vastUrl': 'javascript:alert(1)'}), isNull);
  });

  test('VMAP keeps only preroll AdTagURI', () {
    final doc = parseVastXml(_vmap);
    expect(doc.vmapPrerollTagUrls, ['https://ads.example/preroll.xml']);
    expect(doc.ads, isEmpty);
  });

  test('client follows wrapper and merges impressions', () async {
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('wrapper.xml')) {
        return http.Response(_wrapperVast, 200);
      }
      if (request.url.path.endsWith('inner.xml')) {
        return http.Response(_inlineVast, 200);
      }
      return http.Response('nope', 404);
    });
    final client = VastClient(httpClient: httpClient);
    final ads = await client.fetchPrerolls('https://ads.example/wrapper.xml');
    expect(ads, hasLength(1));
    expect(ads.single.impressions, contains('https://ads.example/wrapper-imp'));
    expect(ads.single.mediaUrl, 'https://cdn.example/ad-720.mp4');
  });

  test('client fail-opens on HTTP error', () async {
    final client = VastClient(
      httpClient: MockClient((_) async => http.Response('nope', 500)),
    );
    expect(await client.fetchPrerolls('https://ads.example/vast.xml'), isEmpty);
  });

  test('parses VAST 4.2 icons, companion, progress, viewability', () {
    final doc = parseVastXml(_vast42);
    expect(doc.ads, hasLength(1));
    final ad = doc.ads.single;
    expect(ad.mediaUrl, 'https://cdn.example/ad-4.mp4');
    expect(ad.progressCues, isNotEmpty);
    expect(ad.progressCues.first.offset, const Duration(seconds: 10));
    expect(ad.icons, hasLength(1));
    expect(ad.icons.single.program, 'AdChoices');
    expect(ad.companions.single.staticUrl, 'https://cdn.example/companion.jpg');
    expect(ad.viewable, ['https://ads.example/viewable']);
    expect(ad.verifications, isNotEmpty);
    expect(ad.verifications.single.notExecuted, isNotEmpty);
    expect(ad.captions.single.language, 'en');
    expect(ad.tracking['loaded'], ['https://ads.example/loaded']);
  });

  test('wrapper ClickThrough is used when InLine omits it', () async {
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('wrapper.xml')) {
        return http.Response(_wrapperClickVast, 200);
      }
      return http.Response(_inlineNoClickVast, 200);
    });
    final ads = await VastClient(
      httpClient: httpClient,
    ).fetchPrerolls('https://ads.example/wrapper.xml');
    expect(ads.single.clickThroughUrl, 'https://wrapper.example/landing');
  });

  test('empty VAST pings error 303', () async {
    final pings = <Uri>[];
    final httpClient = MockClient((request) async {
      pings.add(request.url);
      if (request.url.path.endsWith('empty.xml')) {
        return http.Response(_emptyVast, 200);
      }
      return http.Response('', 200);
    });
    final ads = await VastClient(
      httpClient: httpClient,
    ).fetchPrerolls('https://ads.example/empty.xml');
    expect(ads, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(pings.any((u) => u.toString().contains('c=303')), isTrue);
  });

  test('VMAP schedule splits preroll, midroll, and postroll', () async {
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('vmap.xml')) {
        return http.Response(_vmap, 200);
      }
      return http.Response(_inlineVast, 200);
    });
    final schedule = await VastClient(
      httpClient: httpClient,
    ).fetchSchedule('https://ads.example/vmap.xml');
    expect(schedule.prerolls, hasLength(1));
    expect(schedule.midrolls, hasLength(1));
    expect(schedule.midrolls.single.offset.time, const Duration(minutes: 5));
    expect(schedule.postrolls, isEmpty);
  });
}

const _vast42 = '''
<VAST version="4.2">
  <Ad>
    <InLine>
      <AdSystem>JAVP Test</AdSystem>
      <AdTitle>Linear 4.2</AdTitle>
      <Impression><![CDATA[https://ads.example/imp]]></Impression>
      <ViewableImpression>
        <Viewable><![CDATA[https://ads.example/viewable]]></Viewable>
        <NotViewable><![CDATA[https://ads.example/not-viewable]]></NotViewable>
        <ViewUndetermined><![CDATA[https://ads.example/undetermined]]></ViewUndetermined>
      </ViewableImpression>
      <AdVerifications>
        <Verification vendor="omid">
          <JavaScriptResource apiFramework="omid"><![CDATA[https://ads.example/omid.js]]></JavaScriptResource>
          <TrackingEvents>
            <Tracking event="verificationNotExecuted"><![CDATA[https://ads.example/ver-skip?r=[REASON]]]></Tracking>
          </TrackingEvents>
        </Verification>
      </AdVerifications>
      <Creatives>
        <Creative>
          <Linear skipoffset="00:00:05">
            <Duration>00:00:15</Duration>
            <TrackingEvents>
              <Tracking event="loaded"><![CDATA[https://ads.example/loaded]]></Tracking>
              <Tracking event="start"><![CDATA[https://ads.example/start]]></Tracking>
              <Tracking event="progress" offset="00:00:10"><![CDATA[https://ads.example/progress]]></Tracking>
            </TrackingEvents>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4" width="1920" height="1080">
                <![CDATA[https://cdn.example/ad-4.mp4]]>
              </MediaFile>
              <ClosedCaptionFiles>
                <ClosedCaptionFile type="text/vtt" language="en">
                  <![CDATA[https://cdn.example/ad.vtt]]>
                </ClosedCaptionFile>
              </ClosedCaptionFiles>
            </MediaFiles>
            <Icons>
              <Icon program="AdChoices" width="40" height="40" xPosition="right" yPosition="top">
                <StaticResource creativeType="image/png"><![CDATA[https://cdn.example/adchoices.png]]></StaticResource>
                <IconClicks>
                  <IconClickThrough><![CDATA[https://ads.example/choices]]></IconClickThrough>
                </IconClicks>
              </Icon>
            </Icons>
          </Linear>
        </Creative>
        <Creative>
          <CompanionAds>
            <Companion width="300" height="60">
              <StaticResource creativeType="image/jpeg"><![CDATA[https://cdn.example/companion.jpg]]></StaticResource>
              <CompanionClickThrough><![CDATA[https://sponsor.example/banner]]></CompanionClickThrough>
            </Companion>
          </CompanionAds>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
''';

const _wrapperClickVast = '''
<VAST version="4.2">
  <Ad>
    <Wrapper>
      <VASTAdTagURI><![CDATA[https://ads.example/inner.xml]]></VASTAdTagURI>
      <Creatives>
        <Creative>
          <Linear>
            <VideoClicks>
              <ClickThrough><![CDATA[https://wrapper.example/landing]]></ClickThrough>
            </VideoClicks>
          </Linear>
        </Creative>
      </Creatives>
    </Wrapper>
  </Ad>
</VAST>
''';

const _inlineNoClickVast = '''
<VAST version="4.2">
  <Ad>
    <InLine>
      <Impression><![CDATA[https://ads.example/imp]]></Impression>
      <Creatives>
        <Creative>
          <Linear>
            <Duration>00:00:05</Duration>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4" width="640" height="360">
                <![CDATA[https://cdn.example/ad.mp4]]>
              </MediaFile>
            </MediaFiles>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
''';

const _emptyVast = '''
<VAST version="4.2">
  <Error><![CDATA[https://ads.example/error?c=[ERRORCODE]]]></Error>
</VAST>
''';
