import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:javp/models/media_item.dart';
import 'package:javp/services/network/transient_network_error.dart';
import 'package:javp/services/playback/hls_master.dart';
import 'package:path/path.dart' as p;

/// One media segment (or init map) from an HLS media playlist.
class HlsMediaSegment {
  const HlsMediaSegment({
    required this.uri,
    required this.extInfLine,
    this.isMap = false,
  });

  final Uri uri;
  /// Original `#EXTINF:…,` or `#EXT-X-MAP:…` line to keep in the rewrite.
  final String extInfLine;
  final bool isMap;
}

/// Parsed VOD media playlist (`#EXT-X-ENDLIST` required).
class HlsMediaPlaylist {
  const HlsMediaPlaylist({
    required this.headerLines,
    required this.segments,
    required this.hasEndList,
    required this.encrypted,
  });

  final List<String> headerLines;
  final List<HlsMediaSegment> segments;
  final bool hasEndList;
  final bool encrypted;
}

/// Downloads an HLS master/media playlist into a local offline package.
class HlsDownloader {
  HlsDownloader({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const _defaultHeaders = {
    'User-Agent': 'JAVP',
    'Accept': '*/*',
  };

  /// Download [remoteUrl] into [saveDir], returning the entry `.m3u8` path.
  Future<String> download({
    required String remoteUrl,
    required Directory saveDir,
    Map<String, String>? httpHeaders,
    void Function(double progress)? onProgress,
    void Function(String detail)? onDetail,
    bool Function()? isCancelled,
  }) async {
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }
    final headers = <String, String>{..._defaultHeaders, ...?httpHeaders};
    final rootUri = Uri.parse(remoteUrl);
    final body = await _getText(rootUri, headers);
    _throwIfCancelled(isCancelled);

    final master = HlsMaster.parseMasterPlaylist(body, base: rootUri);
    if (master != null) {
      return _downloadMaster(
        master: master,
        masterUrl: remoteUrl,
        saveDir: saveDir,
        headers: headers,
        onProgress: onProgress,
        onDetail: onDetail,
        isCancelled: isCancelled,
      );
    }

    final media = parseMediaPlaylist(body, base: rootUri);
    _validateMediaPlaylist(media);
    onDetail?.call('Downloading ${media.segments.length} segments…');
    final playlistFile = File(p.join(saveDir.path, 'playlist.m3u8'));
    await _downloadMediaPlaylist(
      media: media,
      playlistBase: rootUri,
      outPlaylist: playlistFile,
      segmentDir: Directory(p.join(saveDir.path, 'segments')),
      segmentUrlPrefix: 'segments/',
      headers: headers,
      onProgress: onProgress,
      isCancelled: isCancelled,
      progressStart: 0,
      progressWeight: 1,
    );
    return playlistFile.path;
  }

  Future<String> _downloadMaster({
    required HlsMasterPlaylist master,
    required String masterUrl,
    required Directory saveDir,
    required Map<String, String> headers,
    void Function(double progress)? onProgress,
    void Function(String detail)? onDetail,
    bool Function()? isCancelled,
  }) async {
    final variant = master.bestVariant;
    if (variant == null) {
      throw Exception('HLS master has no video variants');
    }

    final audio = _pickDefaultAudio(master.audioTracks);
    final sub = _pickDefaultSubtitle(master.subtitles);
    final demuxed = audio != null;

    // Progress weights: video dominates; audio/subs are smaller shares.
    final hasAudio = demuxed;
    final hasSub = sub != null;
    final videoWeight = hasAudio ? 0.75 : (hasSub ? 0.95 : 1.0);
    final audioWeight = hasAudio ? 0.2 : 0.0;
    final subWeight = hasSub ? (hasAudio ? 0.05 : 0.05) : 0.0;

    onDetail?.call(
      demuxed
          ? 'Downloading ${variant.qualityLabel} + audio…'
          : 'Downloading ${variant.qualityLabel}…',
    );

    final videoDir = Directory(p.join(saveDir.path, 'video'));
    final videoPlaylist = File(p.join(videoDir.path, 'playlist.m3u8'));
    final videoBody = await _getText(variant.uri, headers);
    _throwIfCancelled(isCancelled);
    final videoMedia = parseMediaPlaylist(videoBody, base: variant.uri);
    _validateMediaPlaylist(videoMedia);
    await _downloadMediaPlaylist(
      media: videoMedia,
      playlistBase: variant.uri,
      outPlaylist: videoPlaylist,
      segmentDir: Directory(p.join(videoDir.path, 'segments')),
      segmentUrlPrefix: 'segments/',
      headers: headers,
      onProgress: onProgress,
      isCancelled: isCancelled,
      progressStart: 0,
      progressWeight: videoWeight,
    );

    String? audioRel;
    if (audio != null) {
      _throwIfCancelled(isCancelled);
      onDetail?.call('Downloading audio…');
      final audioDir = Directory(p.join(saveDir.path, 'audio'));
      final audioPlaylist = File(p.join(audioDir.path, 'playlist.m3u8'));
      final audioUri = Uri.parse(audio.url);
      final audioBody = await _getText(audioUri, headers);
      final audioMedia = parseMediaPlaylist(audioBody, base: audioUri);
      _validateMediaPlaylist(audioMedia);
      await _downloadMediaPlaylist(
        media: audioMedia,
        playlistBase: audioUri,
        outPlaylist: audioPlaylist,
        segmentDir: Directory(p.join(audioDir.path, 'segments')),
        segmentUrlPrefix: 'segments/',
        headers: headers,
        onProgress: onProgress,
        isCancelled: isCancelled,
        progressStart: videoWeight,
        progressWeight: audioWeight,
      );
      audioRel = 'audio/playlist.m3u8';
    }

    String? subRel;
    if (sub != null) {
      _throwIfCancelled(isCancelled);
      onDetail?.call('Downloading subtitles…');
      final subUri = Uri.parse(sub.url);
      final bytes = await _getBytes(subUri, headers);
      final ext = _subtitleExt(subUri, sub.format);
      final subFile = File(p.join(saveDir.path, 'subs$ext'));
      await subFile.writeAsBytes(bytes, flush: true);
      subRel = 'subs$ext';
      onProgress?.call(videoWeight + audioWeight + subWeight);
    }

    if (demuxed) {
      final masterFile = File(p.join(saveDir.path, 'master.m3u8'));
      await masterFile.writeAsString(
        buildLocalDemuxedMaster(
          videoPlaylistRel: 'video/playlist.m3u8',
          audioPlaylistRel: audioRel!,
          audioLanguage: audio.language,
          audioLabel: audio.label,
          subtitleRel: subRel,
          subtitleLanguage: sub?.language,
          subtitleLabel: sub?.label,
          bandwidth: variant.bandwidth,
          width: variant.width,
          height: variant.height,
          codecs: variant.codecs,
        ),
        flush: true,
      );
      onProgress?.call(1);
      return masterFile.path;
    }

    // Muxed multi-variant / single-variant master: entry is the video playlist.
    // If we saved a subtitle, keep a tiny master so offline still has captions.
    if (subRel != null) {
      final masterFile = File(p.join(saveDir.path, 'master.m3u8'));
      await masterFile.writeAsString(
        buildLocalMuxedMasterWithSubs(
          videoPlaylistRel: 'video/playlist.m3u8',
          subtitleRel: subRel,
          subtitleLanguage: sub?.language,
          subtitleLabel: sub?.label,
          bandwidth: variant.bandwidth,
          width: variant.width,
          height: variant.height,
          codecs: variant.codecs,
        ),
        flush: true,
      );
      onProgress?.call(1);
      return masterFile.path;
    }

    onProgress?.call(1);
    return videoPlaylist.path;
  }

  Future<void> _downloadMediaPlaylist({
    required HlsMediaPlaylist media,
    required Uri playlistBase,
    required File outPlaylist,
    required Directory segmentDir,
    required String segmentUrlPrefix,
    required Map<String, String> headers,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    required double progressStart,
    required double progressWeight,
  }) async {
    if (!await segmentDir.exists()) {
      await segmentDir.create(recursive: true);
    }
    final total = media.segments.length;
    if (total == 0) {
      throw Exception('HLS playlist has no segments');
    }

    final rewritten = <String>[...media.headerLines];
    var done = 0;
    for (final seg in media.segments) {
      _throwIfCancelled(isCancelled);
      final name = _segmentFileName(seg.uri, done);
      final file = File(p.join(segmentDir.path, name));
      if (!await file.exists()) {
        final bytes = await _getBytes(seg.uri, headers);
        await file.writeAsBytes(bytes, flush: true);
      }
      final localUri = '$segmentUrlPrefix$name';
      if (seg.isMap) {
        rewritten.add(_rewriteMapUri(seg.extInfLine, localUri));
      } else {
        rewritten.add(seg.extInfLine);
        rewritten.add(localUri);
      }
      done++;
      if (progressWeight > 0) {
        onProgress?.call(progressStart + progressWeight * (done / total));
      }
    }
    if (!rewritten.any((l) => l.toUpperCase().startsWith('#EXT-X-ENDLIST'))) {
      rewritten.add('#EXT-X-ENDLIST');
    }
    if (!await outPlaylist.parent.exists()) {
      await outPlaylist.parent.create(recursive: true);
    }
    await outPlaylist.writeAsString('${rewritten.join('\n')}\n', flush: true);
  }

  static void _validateMediaPlaylist(HlsMediaPlaylist media) {
    if (media.encrypted) {
      throw Exception('Encrypted HLS is not supported for offline download');
    }
    if (!media.hasEndList) {
      throw Exception(
        'Live / sliding-window HLS cannot be downloaded offline',
      );
    }
    if (media.segments.isEmpty) {
      throw Exception('HLS playlist has no segments');
    }
  }

  static ExternalAudio? _pickDefaultAudio(List<ExternalAudio> tracks) {
    if (tracks.isEmpty) return null;
    for (final a in tracks) {
      if (a.isDefault && a.url.isNotEmpty) return a;
    }
    for (final a in tracks) {
      if (a.url.isNotEmpty) return a;
    }
    return null;
  }

  static ExternalSubtitle? _pickDefaultSubtitle(List<ExternalSubtitle> tracks) {
    if (tracks.isEmpty) return null;
    // Prefer default non-forced.
    for (final s in tracks) {
      if (s.isDefault && !s.forced && s.url.isNotEmpty) return s;
    }
    for (final s in tracks) {
      if (!s.forced && s.url.isNotEmpty) return s;
    }
    return null;
  }

  /// Parse a VOD media playlist into headers + segment list.
  static HlsMediaPlaylist parseMediaPlaylist(String body, {required Uri base}) {
    final lines = body
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trimRight())
        .toList();

    final header = <String>[];
    final segments = <HlsMediaSegment>[];
    var hasEndList = false;
    var encrypted = false;
    String? pendingExtInf;
    String? pendingMap;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();

      if (upper.startsWith('#EXT-X-KEY')) {
        // METHOD=NONE is fine; anything else is encryption.
        final method = RegExp(
          r'METHOD=([^,]+)',
          caseSensitive: false,
        ).firstMatch(line)?.group(1)?.toUpperCase();
        if (method != null && method != 'NONE') {
          encrypted = true;
        }
        header.add(line);
        continue;
      }
      if (upper.startsWith('#EXT-X-ENDLIST')) {
        hasEndList = true;
        continue;
      }
      if (upper.startsWith('#EXT-X-STREAM-INF')) {
        // Caller should have used the master parser.
        continue;
      }
      if (upper.startsWith('#EXT-X-MAP:')) {
        pendingMap = line;
        final uri = _attrUri(line, 'URI');
        if (uri != null && uri.isNotEmpty) {
          segments.add(
            HlsMediaSegment(
              uri: base.resolve(uri),
              extInfLine: line,
              isMap: true,
            ),
          );
          pendingMap = null;
        }
        continue;
      }
      if (upper.startsWith('#EXTINF:')) {
        pendingExtInf = line;
        continue;
      }
      if (line.startsWith('#')) {
        // Keep playlist-level tags; skip segment-only tags we already handled.
        if (pendingExtInf == null && pendingMap == null) {
          header.add(line);
        }
        continue;
      }

      // URI line
      if (pendingExtInf != null) {
        segments.add(
          HlsMediaSegment(
            uri: base.resolve(line),
            extInfLine: pendingExtInf,
          ),
        );
        pendingExtInf = null;
      } else if (pendingMap != null) {
        segments.add(
          HlsMediaSegment(
            uri: base.resolve(line),
            extInfLine: pendingMap,
            isMap: true,
          ),
        );
        pendingMap = null;
      }
    }

    // Ensure we always start with #EXTM3U.
    if (header.isEmpty || !header.first.toUpperCase().startsWith('#EXTM3U')) {
      header.insert(0, '#EXTM3U');
    }

    return HlsMediaPlaylist(
      headerLines: header,
      segments: segments,
      hasEndList: hasEndList,
      encrypted: encrypted,
    );
  }

  /// Local demuxed master for offline playback (relative URIs).
  static String buildLocalDemuxedMaster({
    required String videoPlaylistRel,
    required String audioPlaylistRel,
    String? audioLanguage,
    String? audioLabel,
    String? subtitleRel,
    String? subtitleLanguage,
    String? subtitleLabel,
    int? bandwidth,
    int? width,
    int? height,
    String? codecs,
  }) {
    final buf = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln(
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",'
        'NAME="${_esc(audioLabel ?? audioLanguage ?? 'Audio')}",'
        'DEFAULT=YES,AUTOSELECT=YES,'
        'LANGUAGE="${_esc(audioLanguage ?? '')}",'
        'URI="$audioPlaylistRel"',
      );
    if (subtitleRel != null && subtitleRel.isNotEmpty) {
      buf.writeln(
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",'
        'NAME="${_esc(subtitleLabel ?? subtitleLanguage ?? 'Subtitles')}",'
        'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,'
        'LANGUAGE="${_esc(subtitleLanguage ?? '')}",'
        'URI="$subtitleRel"',
      );
    }
    final attrs = <String>[
      'BANDWIDTH=${bandwidth ?? 1}',
      if (width != null && height != null) 'RESOLUTION=${width}x$height',
      if (codecs != null && codecs.isNotEmpty) 'CODECS="${_esc(codecs)}"',
      'AUDIO="audio"',
      if (subtitleRel != null) 'SUBTITLES="subs"',
    ];
    buf
      ..writeln('#EXT-X-STREAM-INF:${attrs.join(',')}')
      ..writeln(videoPlaylistRel);
    return buf.toString();
  }

  static String buildLocalMuxedMasterWithSubs({
    required String videoPlaylistRel,
    required String subtitleRel,
    String? subtitleLanguage,
    String? subtitleLabel,
    int? bandwidth,
    int? width,
    int? height,
    String? codecs,
  }) {
    final buf = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln(
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",'
        'NAME="${_esc(subtitleLabel ?? subtitleLanguage ?? 'Subtitles')}",'
        'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,'
        'LANGUAGE="${_esc(subtitleLanguage ?? '')}",'
        'URI="$subtitleRel"',
      );
    final attrs = <String>[
      'BANDWIDTH=${bandwidth ?? 1}',
      if (width != null && height != null) 'RESOLUTION=${width}x$height',
      if (codecs != null && codecs.isNotEmpty) 'CODECS="${_esc(codecs)}"',
      'SUBTITLES="subs"',
    ];
    buf
      ..writeln('#EXT-X-STREAM-INF:${attrs.join(',')}')
      ..writeln(videoPlaylistRel);
    return buf.toString();
  }

  /// Rewrite a media playlist body so segment URIs use [segmentUrlPrefix]+filename.
  /// Exposed for unit tests.
  static String rewriteMediaPlaylistForLocal({
    required HlsMediaPlaylist media,
    required List<String> localSegmentNames,
    required String segmentUrlPrefix,
  }) {
    if (localSegmentNames.length != media.segments.length) {
      throw ArgumentError('segment name count mismatch');
    }
    final out = <String>[...media.headerLines];
    for (var i = 0; i < media.segments.length; i++) {
      final seg = media.segments[i];
      final localUri = '$segmentUrlPrefix${localSegmentNames[i]}';
      if (seg.isMap) {
        out.add(_rewriteMapUri(seg.extInfLine, localUri));
      } else {
        out.add(seg.extInfLine);
        out.add(localUri);
      }
    }
    out.add('#EXT-X-ENDLIST');
    return '${out.join('\n')}\n';
  }

  static String _rewriteMapUri(String mapLine, String localUri) {
    if (RegExp(r'URI="[^"]*"', caseSensitive: false).hasMatch(mapLine)) {
      return mapLine.replaceFirst(
        RegExp(r'URI="[^"]*"', caseSensitive: false),
        'URI="$localUri"',
      );
    }
    return '#EXT-X-MAP:URI="$localUri"';
  }

  static String _esc(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  static String? _attrUri(String line, String key) {
    final match = RegExp(
      '$key="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(line);
    return match?.group(1);
  }

  static String _segmentFileName(Uri uri, int index) {
    final base = p.basename(uri.path);
    if (base.isNotEmpty && base.contains('.')) {
      // Keep extension; prefix index for uniqueness / order.
      final safe = base.replaceAll(RegExp(r'[^\w.\-]+'), '_');
      return '${index.toString().padLeft(5, '0')}_$safe';
    }
    return '${index.toString().padLeft(5, '0')}.ts';
  }

  static String _subtitleExt(Uri uri, String? format) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.vtt')) return '.vtt';
    if (path.endsWith('.srt')) return '.srt';
    if (path.endsWith('.ass')) return '.ass';
    if (path.endsWith('.ssa')) return '.ssa';
    final f = (format ?? '').toLowerCase();
    if (f == 'vtt' || f == 'srt' || f == 'ass' || f == 'ssa') return '.$f';
    return '.vtt';
  }

  static const _maxRequestAttempts = 4;

  Future<String> _getText(Uri uri, Map<String, String> headers) async {
    return _withTransientRetries(() async {
      final response = await _http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HLS fetch failed (${response.statusCode}) for $uri');
      }
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    });
  }

  Future<List<int>> _getBytes(Uri uri, Map<String, String> headers) async {
    return _withTransientRetries(() async {
      final response = await _http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HLS segment failed (${response.statusCode}) for $uri');
      }
      if (response.bodyBytes.isEmpty) {
        throw Exception('Empty HLS segment: $uri');
      }
      return response.bodyBytes;
    });
  }

  Future<T> _withTransientRetries<T>(Future<T> Function() action) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxRequestAttempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        lastError = e;
        if (!isTransientNetworkError(e) || attempt >= _maxRequestAttempts) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
    throw lastError ?? Exception('HLS request failed');
  }

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw _HlsDownloadCancelled();
    }
  }
}

class _HlsDownloadCancelled implements Exception {
  @override
  String toString() => 'HLS download cancelled';
}
