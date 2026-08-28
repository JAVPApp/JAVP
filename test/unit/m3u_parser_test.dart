import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/m3u_parser.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:path/path.dart' as p;

void main() {
  test('parses EXTINF entries, groups, logos, and catchup days', () {
    const playlist = '''
#EXTM3U url-tvg="https://example.com/epg.xml"
#EXTINF:-1 tvg-id="news1" tvg-logo="https://img/logo.png" group-title="News" catchup-days="3",World News
https://cdn.example.com/live/news1.m3u8
#EXTINF:-1 group-title="Movies VOD",Example Film
https://cdn.example.com/movie/1.mp4
''';

    final result = M3uParser().parse(playlist, sourceId: 'src-1');

    expect(result.epgUrl, 'https://example.com/epg.xml');
    expect(result.items, hasLength(2));

    final live = result.items.first;
    expect(live.title, 'World News');
    expect(live.group, 'News');
    expect(live.thumbnailUrl, 'https://img/logo.png');
    expect(live.epgChannelId, 'news1');
    expect(live.catchupDays, 3);
    expect(live.kind, MediaKind.live);
    expect(live.sourceId, 'src-1');

    expect(result.items.last.kind, MediaKind.vod);
  });

  test('parses TMDB / IMDb ids on VOD EXTINF rows', () {
    const playlist = '''
#EXTM3U
#EXTINF:-1 tmdb-id="550" group-title="Movies VOD",US| Sample Film {tmdb-550}
https://cdn.example.com/movie/1.mp4
#EXTINF:-1 imdb="tt1375666" group-title="Movies VOD",FR| Sample Film
https://cdn.example.com/movie/2.mp4
#EXTINF:-1 tvg-id="news1" tvg-logo="https://img/logo.png" group-title="News",World News
https://cdn.example.com/live/news1.m3u8
''';

    final result = M3uParser().parse(playlist, sourceId: 'src-1');
    expect(result.items[0].kind, MediaKind.vod);
    expect(result.items[0].tmdbId, 550);
    expect(result.items[1].imdbId, 'tt1375666');
    expect(result.items[2].kind, MediaKind.live);
    expect(result.items[2].tmdbId, isNull);
  });

  test('keeps comma-separated x-tvg-url list intact for multi-feed load', () {
    const playlist = '''
#EXTM3U x-tvg-url="https://a.example/guide.xml.gz,https://b.example/guide.xml.gz"
#EXTINF:-1 tvg-id="ch1",Channel One
https://cdn.example.com/live/ch1.m3u8
''';

    final result = M3uParser().parse(playlist, sourceId: 'src-1');
    expect(
      result.epgUrl,
      'https://a.example/guide.xml.gz,https://b.example/guide.xml.gz',
    );
  });

  test('keeps live movie channels as live despite movie in the URL', () {
    const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="CH.632" tvg-name="Movie Plus" tvg-logo="https://img/movie_plus.png",Movie Plus
https://cdn.example.com/stream/jp/movie_plus/stream-output.m3u8?mode=hls
#EXTINF:-1 tvg-id="rch_34" tvg-name="Mubi Drama",Mubi Drama
https://cdn.example.com/linear/amg-moviecmaf-rakutenjp/playlist.m3u8
#EXTINF:-1 group-title="VOD Movies",On Demand Film
https://cdn.example.com/movie/42.mp4
''';

    final result = M3uParser().parse(playlist, sourceId: 'jp');
    expect(result.items[0].kind, MediaKind.live);
    expect(result.items[1].kind, MediaKind.live);
    expect(result.items[2].kind, MediaKind.vod);
  });

  test('treats genre group titles on guide-backed channels as live', () {
    // iptv-org shape: Pluto single-show channels filed under genre categories.
    const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="AlerteaMalibu.us@France" group-title="Series",Alerte à Malibu
https://jmp2.uk/plu-60afaa535580be0007ac9ee4.m3u8
#EXTINF:-1 tvg-id="PlutoTV90sClassics.de@FR" group-title="Movies;Series",Pluto TV 90's Classics
https://jmp2.uk/plu-66b4990746762a00084c2f78.m3u8
#EXTINF:-1 group-title="Series",Some Show S01E01
https://cdn.example.com/library/show.mkv
''';

    final result = M3uParser().parse(playlist, sourceId: 'fr');
    expect(result.items[0].kind, MediaKind.live);
    expect(result.items[1].kind, MediaKind.live);
    expect(result.items[2].kind, MediaKind.vod);
  });

  test('a stated runtime marks the entry as on-demand', () {
    const playlist = '''
#EXTM3U
#EXTINF:5400 tvg-id="film1" group-title="Cinema",Some Film
https://cdn.example.com/library/film.mp4
''';

    final result = M3uParser().parse(playlist, sourceId: 'src-1');
    expect(result.items.single.kind, MediaKind.vod);
  });

  test('parses basic URL-only M3U without EXTINF', () {
    const playlist = '''
https://cdn.onlyhitsradio.net/onlyhits
https://cdn.onlyhitsradio.net/gold
clips/demo.mp4
''';

    final result = M3uParser().parse(playlist, sourceId: 'radio');
    expect(result.items, hasLength(3));
    expect(result.items[0].playUrl, 'https://cdn.onlyhitsradio.net/onlyhits');
    expect(result.items[0].title, 'onlyhits');
    expect(result.items[0].kind, MediaKind.live);
    expect(result.items[0].isAudioOnly, isTrue);
    expect(result.items[1].title, 'gold');
    expect(result.items[1].isAudioOnly, isTrue);
    expect(result.items[2].playUrl, 'clips/demo.mp4');
    expect(result.items[2].title, 'demo.mp4');
    expect(result.items[2].isAudioOnly, isFalse);
  });

  test('parses EXTM3U header with URL lines and no EXTINF', () {
    const playlist = '''
#EXTM3U
https://cdn.example.com/a
https://cdn.example.com/b/stream.m3u8
''';

    final result = M3uParser().parse(playlist, sourceId: 'src-1');
    expect(result.items, hasLength(2));
    expect(result.items[0].title, 'a');
    expect(result.items[1].title, 'stream.m3u8');
  });

  test('skips EXTVLCOPT and applies EXTGRP between EXTINF and URL', () {
    const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="ch1",Channel One
#EXTVLCOPT:http-user-agent=VLC
#EXTGRP:News
#KODIPROP:inputstream=inputstream.adaptive
https://cdn.example.com/live/ch1.m3u8
#EXTGRP:Radio
https://cdn.example.com/radio
''';

    final result = M3uParser().parse(playlist, sourceId: 'src-1');
    expect(result.items, hasLength(2));
    expect(result.items[0].title, 'Channel One');
    expect(result.items[0].group, 'News');
    expect(result.items[0].playUrl, 'https://cdn.example.com/live/ch1.m3u8');
    expect(result.items[1].title, 'radio');
    expect(result.items[1].group, 'Radio');
    expect(result.items[1].isAudioOnly, isTrue);
    expect(result.items[0].isAudioOnly, isFalse);
  });

  test('parseBytes strips UTF-8 BOM and tolerates malformed bytes', () {
    final bom = [0xEF, 0xBB, 0xBF];
    final body = utf8.encode('''
#EXTM3U
#EXTINF:-1,Test
https://example.com/a.m3u8
''');
    final result = M3uParser.parseBytes([...bom, ...body], sourceId: 'bom');
    expect(result.items, hasLength(1));
    expect(result.items.single.title, 'Test');
  });

  test('parseM3uBytesInIsolate parses and resolves relative URLs', () async {
    const playlist = '''
#EXTM3U url-tvg="https://example.com/epg.xml"
#EXTINF:-1 tvg-id="news1",World News
https://cdn.example.com/live/news1.m3u8
#EXTINF:-1,Relative Film
movie.mp4
''';
    final result = await parseM3uBytesInIsolate(
      utf8.encode(playlist),
      sourceId: 'src-1',
      baseDir: '/media/iptv',
    );
    expect(result.epgUrl, 'https://example.com/epg.xml');
    expect(result.items, hasLength(2));
    expect(
      result.items.first.playUrl,
      'https://cdn.example.com/live/news1.m3u8',
    );
    expect(
      result.items.last.playUrl,
      p.normalize(p.join('/media/iptv', 'movie.mp4')),
    );
    expect(result.items.last.title, 'Relative Film');
  });

  test('ingestM3uBytesInIsolate keeps live and VOD packed', () async {
    const playlist = '''
#EXTM3U url-tvg="https://example.com/epg.xml"
#EXTINF:-1 tvg-id="news1",World News
https://cdn.example.com/live/news1.m3u8
#EXTINF:-1 group-title="Movies VOD",Relative Film
movie.mp4
''';
    final result = await ingestM3uBytesInIsolate(
      utf8.encode(playlist),
      sourceId: 'src-1',
      baseDir: '/media/iptv',
    );
    expect(result.epgUrl, 'https://example.com/epg.xml');
    expect(result.liveCount, 1);
    expect(result.vodCount, 1);
    expect(result.live.channelRows.single['title'], 'World News');
    expect(result.live.listingRows, hasLength(1));
    expect(result.vod.rows.single['title'], 'Relative Film');
    expect(
      result.vod.rows.single['play_url'],
      p.normalize(p.join('/media/iptv', 'movie.mp4')),
    );
    expect(result.vod.rows.single['group_name'], 'Movies VOD');
    expect(result.vod.families, isNotEmpty);
  });

  test(
    'ingestM3uBytesInIsolate streams a large live playlist as maps',
    () async {
      final buf = StringBuffer(
        '#EXTM3U url-tvg="https://example.com/epg.xml"\n',
      );
      for (var i = 0; i < 850; i++) {
        buf.writeln('#EXTINF:-1 tvg-id="ch$i",Channel $i');
        buf.writeln('https://cdn.example.com/live/$i.m3u8');
      }
      final result = await ingestM3uBytesInIsolate(
        utf8.encode(buf.toString()),
        sourceId: 'src-big',
      );
      expect(result.epgUrl, 'https://example.com/epg.xml');
      expect(result.liveCount, 850);
      expect(result.vod.rows, isEmpty);
      expect(result.live.channelRows.first['title'], 'Channel 0');
      expect(result.live.channelRows.last['title'], 'Channel 849');
      // Quality-token titles (e.g. "Channel 720") collapse into one listing.
      expect(result.live.listingRows.length, lessThanOrEqualTo(850));
      expect(result.live.listingRows, isNotEmpty);
    },
  );

  test(
    'ingestM3uBytesInIsolate streams a large VOD playlist as maps',
    () async {
      final buf = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 850; i++) {
        buf.writeln('#EXTINF:-1 group-title="Movies VOD",Film $i');
        buf.writeln('https://cdn.example.com/vod/$i.mp4');
      }
      final result = await ingestM3uBytesInIsolate(
        utf8.encode(buf.toString()),
        sourceId: 'src-vod-big',
      );
      expect(result.liveCount, 0);
      expect(result.vodCount, 850);
      expect(result.vod.rows.first['title'], 'Film 0');
      expect(result.vod.rows.last['title'], 'Film 849');
      expect(result.vod.families, isNotEmpty);
    },
  );

  test('parseM3uBytesInIsolate streams large playlists in chunks', () async {
    final buf = StringBuffer('#EXTM3U url-tvg="https://example.com/epg.xml"\n');
    for (var i = 0; i < 850; i++) {
      buf.writeln('#EXTINF:-1 tvg-id="ch$i",Channel $i');
      buf.writeln('https://cdn.example.com/live/$i.m3u8');
    }
    final result = await parseM3uBytesInIsolate(
      utf8.encode(buf.toString()),
      sourceId: 'src-big',
    );
    expect(result.epgUrl, 'https://example.com/epg.xml');
    expect(result.items, hasLength(850));
    expect(result.items.first.title, 'Channel 0');
    expect(result.items.last.title, 'Channel 849');
  });

  test('stores a DRM hint from KODIPROP license_type', () {
    const playlist = '''
#EXTM3U
#EXTINF:-1 group-title="Movies VOD",Protected Film
#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha
#KODIPROP:inputstream.adaptive.license_key=https://license.example/wv
https://cdn.example.com/movie.mpd
#EXTINF:-1 group-title="Movies VOD",Clear Film
https://cdn.example.com/movie.mp4
''';
    final result = M3uParser().parse(playlist, sourceId: 'src-1');
    expect(result.items, hasLength(2));
    expect(headersIndicateDrm(result.items.first.httpHeaders), isTrue);
    expect(result.items.first.httpHeaders[drmHintHeader], 'widevine');
    expect(headersIndicateDrm(result.items.last.httpHeaders), isFalse);
  });
}
