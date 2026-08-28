import 'package:http/http.dart' as http;
import 'package:javp/models/media_item.dart';
import 'package:javp/services/playback/drm_detect.dart';

/// One `#EXT-X-STREAM-INF` rendition from an HLS master playlist.
class HlsVariant {
  const HlsVariant({
    required this.uri,
    this.bandwidth,
    this.width,
    this.height,
    this.codecs,
    this.audioGroup,
    this.subtitleGroup,
  });

  final Uri uri;
  final int? bandwidth;
  final int? width;
  final int? height;
  final String? codecs;
  final String? audioGroup;
  final String? subtitleGroup;

  int get pixels => (width ?? 0) * (height ?? 0);

  /// Stable id for quality UI / [VideoTrack] bridging (`hls:<url>`).
  String get trackId => 'hls:$uri';

  String get qualityLabel {
    final h = height;
    if (h != null && h > 0) {
      if (h >= 2160) return '4K';
      if (h >= 1440) return '1440p';
      if (h >= 1080) return '1080p';
      if (h >= 720) return '720p';
      return '${h}p';
    }
    final br = bandwidth;
    if (br != null && br > 0) {
      if (br >= 1000000) {
        return '${(br / 1000000).toStringAsFixed(br >= 10000000 ? 0 : 1)} Mbps';
      }
      return '${(br / 1000).round()} kbps';
    }
    return 'Variant';
  }
}

/// Parsed HLS master (`#EXT-X-STREAM-INF` + optional `#EXT-X-MEDIA`).
class HlsMasterPlaylist {
  const HlsMasterPlaylist({
    required this.variants,
    this.audioTracks = const [],
    this.subtitles = const [],
  });

  final List<HlsVariant> variants;
  final List<ExternalAudio> audioTracks;
  final List<ExternalSubtitle> subtitles;

  /// True when alternate audio is a separate playlist (demuxed HLS).
  ///
  /// libmpv/FFmpeg often opens these masters as audio-only (video variant
  /// dropped while `#EXT-X-MEDIA:TYPE=AUDIO` playlists still play).
  bool get hasDemuxedAudio => audioTracks.any((a) => a.url.isNotEmpty);

  List<HlsVariant> get variantsByQuality {
    final sorted = [...variants]
      ..sort((a, b) {
        final byPixels = b.pixels.compareTo(a.pixels);
        if (byPixels != 0) return byPixels;
        return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
      });
    return sorted;
  }

  /// Highest resolution, then bandwidth.
  HlsVariant? get bestVariant {
    final sorted = variantsByQuality;
    return sorted.isEmpty ? null : sorted.first;
  }
}

/// How to open an HLS master for media_kit.
class HlsPlaybackPlan {
  const HlsPlaybackPlan({
    required this.masterUrl,
    required this.openUrl,
    required this.variants,
    required this.demuxedAudio,
    required this.openMasterForAbr,
    this.sourceUrl,
    this.audioTracks = const [],
    this.subtitles = const [],
  });

  /// Original master playlist URL (catalog / history identity).
  final String masterUrl;

  /// Catalog / resolver URL before redirects, when different from [masterUrl].
  final String? sourceUrl;

  /// URL passed to the player for the initial open (Auto).
  final String openUrl;

  final List<HlsVariant> variants;
  final List<ExternalAudio> audioTracks;
  final List<ExternalSubtitle> subtitles;

  /// Master uses separate audio playlists — must not rely on raw master open.
  final bool demuxedAudio;

  /// Open [openUrl] as the master so libmpv can ABR (`VideoTrack.auto`).
  final bool openMasterForAbr;

  bool get hasMultipleQualities => variants.length > 1;

  HlsVariant? get bestVariant {
    if (variants.isEmpty) return null;
    final sorted = [...variants]
      ..sort((a, b) {
        final byPixels = b.pixels.compareTo(a.pixels);
        if (byPixels != 0) return byPixels;
        return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
      });
    return sorted.first;
  }

  String urlForVariant(HlsVariant variant) => variant.uri.toString();
}

/// Demuxer video rendition (mpv `vid`) used to lock HLS quality in place.
class HlsDemuxerVideo {
  const HlsDemuxerVideo({required this.id, this.height, this.bitrate});

  final String id;
  final int? height;
  final int? bitrate;
}

/// How to apply an HLS quality pick without tearing down the player.
class HlsQualitySwitch {
  /// HLS program discovery on live masters often takes several seconds.
  static const Duration demuxerWait = Duration(seconds: 10);

  /// Poll interval while waiting for libmpv to publish every variant `vid`.
  static const Duration demuxerPoll = Duration(milliseconds: 150);

  /// HLS media segments are often 4–6s (sometimes 10s). Checking `vid` /
  /// coded height for less than one segment treats a pending switch as
  /// failure and `loadfile`s the variant — which hides the other programs
  /// so every later pick reloads.
  static const Duration applyVerifyWait = Duration(seconds: 12);

  /// Poll interval while confirming the decoder actually switched.
  static const Duration applyVerifyPoll = Duration(milliseconds: 200);

  /// Coded-height slop vs playlist `RESOLUTION` (same as [matchDemuxerTrack]).
  static const int heightMatchDelta = 48;

  /// Muxed master still loaded — switch rendition, do not `loadfile`.
  ///
  /// [demuxerVideoCount] ≥ 2 means lavf opened the master (URL matching
  /// against catalog `/play/` vs the CDN is not reliable).
  static bool canSwitchInPlace({
    required bool openMasterForAbr,
    required bool onMaster,
    int demuxerVideoCount = 0,
  }) => openMasterForAbr && (onMaster || demuxerVideoCount >= 2);

  /// A locked (non-Auto) pick can be applied without reopening.
  ///
  /// libmpv's `hls-bitrate` option only applies on open — setting it at
  /// runtime does nothing. In-place lock requires a real `vid` match.
  static bool canLockInPlace({required bool hasDemuxerMatch}) =>
      hasDemuxerMatch;

  /// After `vid` is set, lavf switches at the next segment. Reloading a
  /// media playlist would drop the master ladder.
  static bool shouldReloadMuxedLock({required bool issuedVidSwitch}) =>
      !issuedVidSwitch;

  /// Keep polling when lavf has not published every HLS program yet.
  ///
  /// A single `vid` is the selected program, not a complete track list —
  /// do not treat that as "ready" or we fall back to `loadfile`.
  static bool shouldWaitForDemuxerTracks(
    List<HlsDemuxerVideo> tracks, {
    required int variantCount,
  }) {
    if (variantCount < 2) return false;
    return tracks.length < 2;
  }

  /// True when [active] is still the muxed master (ignore query tokens).
  static bool sameMasterUrl(String? active, String? master) {
    if (active == null || master == null) return false;
    if (active.isEmpty || master.isEmpty) return false;
    if (active == master) return true;
    final a = Uri.tryParse(active);
    final m = Uri.tryParse(master);
    if (a == null || m == null) return false;
    return a.scheme == m.scheme &&
        a.host.toLowerCase() == m.host.toLowerCase() &&
        a.port == m.port &&
        _normPath(a.path) == _normPath(m.path);
  }

  static String _normPath(String path) {
    var p = path;
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    try {
      p = Uri.decodeComponent(p);
    } catch (_) {}
    return p;
  }

  /// mpv `hls-bitrate` value (`no` = ABR).
  static String bitrateProperty({required bool auto, int? bandwidth}) {
    if (auto) return 'no';
    if (bandwidth != null && bandwidth > 0) return '$bandwidth';
    return 'no';
  }

  /// Lock value for a variant: numeric bandwidth, or min/max by rank.
  static String? bitratePropertyForLock(
    HlsVariant variant, {
    required List<HlsVariant> all,
  }) {
    final br = variant.bandwidth;
    if (br != null && br > 0) return '$br';
    if (all.isEmpty) return null;
    final ranked = [...all]
      ..sort((a, b) {
        final byPixels = b.pixels.compareTo(a.pixels);
        if (byPixels != 0) return byPixels;
        return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
      });
    if (variant.uri == ranked.first.uri) return 'max';
    if (variant.uri == ranked.last.uri) return 'min';
    return null;
  }

  /// Match a parsed `#EXT-X-STREAM-INF` row to libmpv video tracks.
  ///
  /// Returns null when the demuxer only exposes one video stream (ABR is
  /// internal — reopen the master with [bitrateProperty] instead).
  static HlsDemuxerVideo? matchDemuxerTrack(
    HlsVariant variant,
    List<HlsDemuxerVideo> tracks, {
    List<HlsVariant>? all,
  }) {
    final real = [
      for (final t in tracks)
        if (t.id != 'auto' && t.id != 'no') t,
    ];
    if (real.length < 2) return null;

    final height = variant.height;
    if (height != null && height > 0) {
      final byHeight = [
        for (final t in real)
          if (t.height == height) t,
      ];
      if (byHeight.length == 1) return byHeight.first;
      if (byHeight.length > 1) {
        return _closestBitrate(byHeight, variant.bandwidth) ?? byHeight.first;
      }
      final near = _closestHeight(real, height, maxDelta: 48);
      if (near != null) return near;
    }

    final br = variant.bandwidth;
    if (br != null && br > 0) {
      final exact = [
        for (final t in real)
          if (t.bitrate == br) t,
      ];
      if (exact.length == 1) return exact.first;
      final close = _closestBitrate(real, br);
      if (close != null) {
        final tb = close.bitrate ?? 0;
        final delta = (tb - br).abs();
        if (delta <= 250000 || delta <= (br * 0.25).round()) return close;
      }
    }

    if (all != null &&
        all.length == real.length &&
        real.every((t) => (t.height ?? 0) > 0 || (t.bitrate ?? 0) > 0)) {
      final rankedV = [...all]
        ..sort((a, b) {
          final byPixels = b.pixels.compareTo(a.pixels);
          if (byPixels != 0) return byPixels;
          return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
        });
      final rankedT = [...real]
        ..sort((a, b) {
          final byH = (b.height ?? 0).compareTo(a.height ?? 0);
          if (byH != 0) return byH;
          return (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
        });
      final vi = rankedV.indexWhere((v) => v.uri == variant.uri);
      if (vi >= 0 && vi < rankedT.length) return rankedT[vi];
    }
    return null;
  }

  static HlsDemuxerVideo? _closestHeight(
    List<HlsDemuxerVideo> tracks,
    int height, {
    required int maxDelta,
  }) {
    HlsDemuxerVideo? best;
    var bestDelta = maxDelta + 1;
    for (final t in tracks) {
      final h = t.height;
      if (h == null || h <= 0) continue;
      final delta = (h - height).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = t;
      }
    }
    return bestDelta <= maxDelta ? best : null;
  }

  static HlsDemuxerVideo? _closestBitrate(
    List<HlsDemuxerVideo> tracks,
    int? bandwidth,
  ) {
    if (bandwidth == null || bandwidth <= 0 || tracks.isEmpty) return null;
    HlsDemuxerVideo? best;
    var bestDelta = 1 << 30;
    for (final t in tracks) {
      final b = t.bitrate;
      if (b == null || b <= 0) continue;
      final delta = (b - bandwidth).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = t;
      }
    }
    return best;
  }

  /// True when the decoder height is the locked variant (or close).
  static bool heightMatchesLock(int? currentHeight, int? targetHeight) {
    if (currentHeight == null || currentHeight <= 0) return false;
    if (targetHeight == null || targetHeight <= 0) return false;
    return (currentHeight - targetHeight).abs() <= heightMatchDelta;
  }

  /// True when libmpv `vid` is Adaptive (`auto` / empty / `no`).
  static bool isAutoVid(String? vid) {
    if (vid == null) return false;
    final v = vid.trim().toLowerCase();
    return v == 'auto' || v == 'no' || v.isEmpty;
  }

  /// Compact variant list for diagnostics (`1080p br=6000000, 720p …`).
  static String describeVariants(List<HlsVariant> variants) {
    if (variants.isEmpty) return '(none)';
    return [
      for (final v in variants)
        [
          v.qualityLabel,
          if (v.bandwidth != null && v.bandwidth! > 0) 'br=${v.bandwidth}',
        ].join(' '),
    ].join(', ');
  }

  /// Compact demuxer list for diagnostics (`vid=1 h=1080 br=6000000, …`).
  static String describeDemuxer(List<HlsDemuxerVideo> tracks) {
    if (tracks.isEmpty) return '(none)';
    return [
      for (final t in tracks)
        [
          'vid=${t.id}',
          if (t.height != null && t.height! > 0) 'h=${t.height}',
          if (t.bitrate != null && t.bitrate! > 0) 'br=${t.bitrate}',
        ].join(' '),
    ].join(', ');
  }
}

/// Parse / resolve HLS master playlists for reliable media_kit playback.
class HlsMaster {
  /// Fetch [url] and, when it is an HLS master, return a playback plan.
  ///
  /// - Muxed multi-bitrate masters → open master (true ABR).
  /// - Demuxed-audio masters → open best media playlist (video actually plays);
  ///   quality switching re-opens other variants.
  ///
  /// Returns `null` when the URL should be opened as-is.
  static Future<HlsPlaybackPlan?> resolvePlaybackPlan(
    String url, {
    Map<String, String>? httpHeaders,
    http.Client? client,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (!_shouldProbeHls(url)) return null;

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(uri, headers: httpHeaders ?? const {})
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final body = response.body;
      final drm = detectDrmInManifest(body);
      if (drm != null) {
        throw UnsupportedDrmException(kind: drm, playUrl: url);
      }
      if (body.length > 512 * 1024) {
        final peek = body.substring(0, body.length < 4096 ? body.length : 4096);
        if (!_looksLikeMaster(peek)) return null;
      }
      // Catalog `/play/{id}` resolvers 302 to the real master. Relative
      // `#EXT-X-STREAM-INF` URIs are against that final URL, not the catalog.
      final finalUri = response.request?.url ?? uri;
      final master = parseMasterPlaylist(body, base: finalUri);
      if (master == null) return null;
      final resolvedMaster = finalUri.toString();
      return planFromMaster(
        master,
        masterUrl: resolvedMaster,
        sourceUrl: resolvedMaster == url ? null : url,
      );
    } on UnsupportedDrmException {
      rethrow;
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  /// Build a plan from an already-parsed master.
  static HlsPlaybackPlan? planFromMaster(
    HlsMasterPlaylist master, {
    required String masterUrl,
    String? sourceUrl,
  }) {
    final best = master.bestVariant;
    if (best == null) return null;
    final demuxed = master.hasDemuxedAudio;
    // Demuxed masters often play audio-only in libmpv — pin a media playlist.
    // Muxed masters keep the master URL so Auto can ABR.
    final openMaster = !demuxed;
    return HlsPlaybackPlan(
      masterUrl: masterUrl,
      sourceUrl: sourceUrl,
      openUrl: openMaster ? masterUrl : best.uri.toString(),
      variants: master.variantsByQuality,
      demuxedAudio: demuxed,
      openMasterForAbr: openMaster,
      audioTracks: master.audioTracks,
      subtitles: master.subtitles,
    );
  }

  /// Parse a master playlist body. Returns `null` when [body] is not a master.
  static HlsMasterPlaylist? parseMasterPlaylist(
    String body, {
    required Uri base,
  }) {
    if (!_looksLikeMaster(body)) return null;

    final lines = body
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final variants = <HlsVariant>[];
    final audio = <ExternalAudio>[];
    final subs = <ExternalSubtitle>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final upper = line.toUpperCase();
      if (upper.startsWith('#EXT-X-MEDIA:')) {
        final attrs = _parseAttrs(line.substring('#EXT-X-MEDIA:'.length));
        final type = (attrs['TYPE'] ?? '').toUpperCase();
        final mediaUri = attrs['URI'];
        if (mediaUri == null || mediaUri.isEmpty) continue;
        final resolved = base.resolve(mediaUri).toString();
        final language = attrs['LANGUAGE'];
        final name = attrs['NAME'];
        final isDefault = _isYes(attrs['DEFAULT']);
        if (type == 'AUDIO') {
          audio.add(
            ExternalAudio(
              url: resolved,
              language: language,
              label: name,
              isDefault: isDefault,
            ),
          );
        } else if (type == 'SUBTITLES') {
          subs.add(
            ExternalSubtitle(
              url: resolved,
              language: language,
              label: name,
              isDefault: isDefault,
              forced: _isYes(attrs['FORCED']),
              format: _subtitleFormatHint(resolved),
            ),
          );
        }
        continue;
      }

      if (upper.startsWith('#EXT-X-STREAM-INF:')) {
        final attrs = _parseAttrs(line.substring('#EXT-X-STREAM-INF:'.length));
        String? variantUri;
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].startsWith('#')) continue;
          variantUri = lines[j];
          i = j;
          break;
        }
        if (variantUri == null || variantUri.isEmpty) continue;
        final res = _parseResolution(attrs['RESOLUTION']);
        variants.add(
          HlsVariant(
            uri: base.resolve(variantUri),
            bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? ''),
            width: res?.$1,
            height: res?.$2,
            codecs: attrs['CODECS'],
            audioGroup: attrs['AUDIO'],
            subtitleGroup: attrs['SUBTITLES'],
          ),
        );
      }
    }

    if (variants.isEmpty) return null;
    return HlsMasterPlaylist(
      variants: variants,
      audioTracks: audio,
      subtitles: subs,
    );
  }

  /// Catalog v2 `/play/{id}` resolvers and explicit `.m3u8` URLs.
  static bool shouldProbeHls(String url) {
    if (_looksLikeHlsUrl(url)) return true;
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return path.contains('/play/');
  }

  static bool _shouldProbeHls(String url) => shouldProbeHls(url);

  static bool _looksLikeHlsUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('m3u8?') ||
        lower.contains('/m3u8');
  }

  static bool _looksLikeMaster(String body) {
    final upper = body.toUpperCase();
    return upper.contains('#EXT-X-STREAM-INF');
  }

  static bool _isYes(String? value) {
    if (value == null) return false;
    final v = value.trim().toUpperCase();
    return v == 'YES' || v == 'TRUE' || v == '1';
  }

  static (int, int)? _parseResolution(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.toLowerCase().split('x');
    if (parts.length != 2) return null;
    final w = int.tryParse(parts[0]);
    final h = int.tryParse(parts[1]);
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return (w, h);
  }

  static String? _subtitleFormatHint(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.vtt') || path.contains('.vtt')) return 'vtt';
    if (path.endsWith('.srt')) return 'srt';
    if (path.endsWith('.ass') || path.endsWith('.ssa')) return 'ass';
    return null;
  }

  /// HLS attribute list parser (`KEY=VALUE` / `KEY="VALUE"`).
  static Map<String, String> _parseAttrs(String raw) {
    final out = <String, String>{};
    final re = RegExp(r'([A-Z0-9-]+)=("([^"]*)"|[^,]*)', caseSensitive: false);
    for (final match in re.allMatches(raw)) {
      final key = match.group(1)?.toUpperCase();
      if (key == null) continue;
      final quoted = match.group(3);
      final plain = match.group(2);
      final value = (quoted ?? plain ?? '').trim();
      out[key] = value;
    }
    return out;
  }

  /// Merge catalog tracks with HLS `#EXT-X-MEDIA` tracks (catalog wins on URL).
  static List<ExternalAudio> mergeAudioTracks(
    List<ExternalAudio> existing,
    List<ExternalAudio> fromMaster,
  ) {
    if (fromMaster.isEmpty) return existing;
    if (existing.isEmpty) return fromMaster;
    final seen = <String>{
      for (final a in existing)
        if (a.url.isNotEmpty) a.url,
    };
    return [
      ...existing,
      ...fromMaster.where((a) => a.url.isNotEmpty && seen.add(a.url)),
    ];
  }

  static List<ExternalSubtitle> mergeSubtitleTracks(
    List<ExternalSubtitle> existing,
    List<ExternalSubtitle> fromMaster,
  ) {
    if (fromMaster.isEmpty) return existing;
    if (existing.isEmpty) return fromMaster;
    final seen = <String>{
      for (final s in existing)
        if (s.url.isNotEmpty) s.url,
    };
    return [
      ...existing,
      ...fromMaster.where((s) => s.url.isNotEmpty && seen.add(s.url)),
    ];
  }
}
