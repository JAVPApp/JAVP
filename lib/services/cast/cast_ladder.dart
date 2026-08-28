import 'package:javp/services/cast/cast_mime.dart';

/// One transport attempt when sending media to Chromecast.
enum CastLoadMode {
  /// TV fetches the origin URL itself.
  direct,
  /// Phone re-exports the origin with CORS (and wraps MPEG-TS as HLS).
  proxy,
  /// Jellyfin / Emby / Plex H.264 transcode, then usually proxied.
  serverTranscode,
}

/// Build the Chromecast fallback list.
///
/// Progressive public HTTP: direct, then phone proxy.
/// HLS / live paths / MPEG-TS: proxy first (CAF CORS + no raw `video/mp2t`).
/// Loopback: proxy only (the TV cannot route to `127.0.0.1`).
/// Optional media-server transcode is last.
List<CastLoadMode> castLoadLadder({
  required String url,
  String? transcodeUrl,
}) {
  final modes = <CastLoadMode>[];
  final loopback = looksLikeLoopbackUrl(url);
  final mpegTs = looksLikeMpegTsUrl(url);
  final hls = looksLikeHlsUrl(url);
  final livePath =
      url.toLowerCase().contains('/live/') ||
      url.toLowerCase().contains('/timeshift/');
  final skipDirectFirst = loopback || mpegTs || hls || livePath;
  if (!skipDirectFirst) {
    modes.add(CastLoadMode.direct);
  }
  modes.add(CastLoadMode.proxy);
  if (transcodeUrl != null &&
      transcodeUrl.isNotEmpty &&
      transcodeUrl != url) {
    modes.add(CastLoadMode.serverTranscode);
  }
  // HLS / live: proxy first (CORS). If that still idles, let the TV try the
  // origin itself — some CDNs allow GET without OPTIONS.
  if (skipDirectFirst && !loopback && !mpegTs) {
    modes.add(CastLoadMode.direct);
  }
  return modes;
}

enum CastFailureKind {
  codecVideo,
  codecAudio,
  fetch,
  rejected,
  connect,
}

CastFailureKind classifyCastFailure({
  required CastCodecRisk codecRisk,
  required List<CastLoadMode> tried,
  String? rawError,
}) {
  final raw = (rawError ?? '').toLowerCase();
  if (raw.contains('could not connect') ||
      raw.contains('wi-fi') ||
      raw.contains('wifi')) {
    return CastFailureKind.connect;
  }
  if (codecRisk == CastCodecRisk.video) return CastFailureKind.codecVideo;
  if (codecRisk == CastCodecRisk.audio) return CastFailureKind.codecAudio;
  if (tried.contains(CastLoadMode.direct) &&
      tried.contains(CastLoadMode.proxy)) {
    return CastFailureKind.fetch;
  }
  return CastFailureKind.rejected;
}
