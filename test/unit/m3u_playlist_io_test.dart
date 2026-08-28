import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/m3u_parser.dart';
import 'package:javp/services/iptv/m3u_playlist_io.dart';
import 'package:path/path.dart' as p;

void main() {
  group('M3uPlaylistIo.tryLocalFilePath', () {
    test('returns null for http(s) URLs', () {
      expect(
        M3uPlaylistIo.tryLocalFilePath('https://example.com/list.m3u'),
        isNull,
      );
      expect(
        M3uPlaylistIo.tryLocalFilePath('http://example.com/list.m3u'),
        isNull,
      );
      expect(M3uPlaylistIo.isRemotePlaylistUrl('https://x/y.m3u'), isTrue);
    });

    test('accepts bare absolute paths and file:// URIs', () {
      expect(
        M3uPlaylistIo.tryLocalFilePath('/home/user/channels.m3u'),
        '/home/user/channels.m3u',
      );
      expect(
        M3uPlaylistIo.tryLocalFilePath(r'C:\IPTV\list.m3u'),
        r'C:\IPTV\list.m3u',
      );
      expect(
        M3uPlaylistIo.tryLocalFilePath('file:///tmp/playlist.m3u'),
        p.fromUri(Uri.parse('file:///tmp/playlist.m3u')),
      );
    });

    test('accepts relative *.m3u / *.m3u8 paths', () {
      expect(
        M3uPlaylistIo.tryLocalFilePath('playlists/home.m3u'),
        'playlists/home.m3u',
      );
      expect(
        M3uPlaylistIo.tryLocalFilePath('local.m3u8'),
        'local.m3u8',
      );
    });

    test('rejects other schemes', () {
      expect(
        M3uPlaylistIo.tryLocalFilePath('content://media/external/file'),
        isNull,
      );
      expect(M3uPlaylistIo.tryLocalFilePath('rtsp://host/stream'), isNull);
    });
  });

  group('M3uPlaylistIo.resolveEntryUrl', () {
    test('leaves absolute remote and rooted paths unchanged', () {
      const base = '/media/iptv';
      expect(
        M3uPlaylistIo.resolveEntryUrl(
          'https://cdn.example.com/live.m3u8',
          baseDir: base,
        ),
        'https://cdn.example.com/live.m3u8',
      );
      expect(
        M3uPlaylistIo.resolveEntryUrl('rtsp://box/stream', baseDir: base),
        'rtsp://box/stream',
      );
      expect(
        M3uPlaylistIo.resolveEntryUrl('/abs/video.mp4', baseDir: base),
        '/abs/video.mp4',
      );
      expect(
        M3uPlaylistIo.resolveEntryUrl(r'D:\Videos\a.mkv', baseDir: base),
        r'D:\Videos\a.mkv',
      );
    });

    test('resolves relative entries against the playlist directory', () {
      final resolved = M3uPlaylistIo.resolveEntryUrl(
        'movies/film.mp4',
        baseDir: '/home/user/iptv',
      );
      expect(resolved, p.normalize('/home/user/iptv/movies/film.mp4'));
    });

    test('no-ops when baseDir is null', () {
      expect(
        M3uPlaylistIo.resolveEntryUrl('movies/film.mp4', baseDir: null),
        'movies/film.mp4',
      );
    });
  });

  test('local playlist load + relative URL resolution end-to-end', () async {
    final dir = await Directory.systemTemp.createTemp('javp_m3u_');
    addTearDown(() => dir.delete(recursive: true));

    final playlistPath = p.join(dir.path, 'library.m3u');
    await File(playlistPath).writeAsString('''
#EXTM3U
#EXTINF:120 group-title="Local",Relative Clip
clips/demo.mp4
#EXTINF:-1 tvg-id="news",Remote News
https://cdn.example.com/news.m3u8
''');

    expect(M3uPlaylistIo.tryLocalFilePath(playlistPath), playlistPath);
    expect(await File(playlistPath).exists(), isTrue);

    final bytes = await File(playlistPath).readAsBytes();
    final parsed = M3uParser.parseBytes(bytes, sourceId: 'local-1');
    final baseDir = M3uPlaylistIo.localBaseDir(playlistPath);
    final items = M3uPlaylistIo.resolveEntryUrls(
      parsed.items,
      baseDir: baseDir,
    );

    expect(items, hasLength(2));
    expect(items[0].playUrl, p.normalize(p.join(dir.path, 'clips/demo.mp4')));
    expect(items[0].kind, MediaKind.vod);
    expect(items[1].playUrl, 'https://cdn.example.com/news.m3u8');
    expect(items[1].kind, MediaKind.live);
  });
}
