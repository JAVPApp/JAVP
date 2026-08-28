/// Guess a MIME type the receiver can put in DIDL / MediaInfo.
String guessCastContentType(String url) {
  final lower = url.toLowerCase();
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? lower;
  if (path.endsWith('.m3u8') ||
      path.contains('.m3u8') ||
      lower.contains('m3u8')) {
    // Styled Media Receiver samples use x-mpegURL; vnd.apple.mpegurl can
    // load metadata then sit on a grey screen on some Cast firmware.
    return 'application/x-mpegURL';
  }
  if (path.contains('.mpd')) return 'application/dash+xml';
  if (path.contains('.mp3')) return 'audio/mpeg';
  if (path.contains('.aac')) return 'audio/aac';
  if (path.contains('.webm')) return 'video/webm';
  if (path.contains('.mkv')) return 'video/x-matroska';
  if (path.contains('.mov')) return 'video/quicktime';
  if (path.contains('.avi')) return 'video/x-msvideo';
  if (looksLikeMpegTsUrl(url)) return 'video/mp2t';
  return 'video/mp4';
}

/// Progressive MPEG-TS (Xtream `output=ts`, `.m2ts`) — not an HLS playlist.
bool looksLikeMpegTsUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.endsWith('.ts') ||
      path.endsWith('.m2ts') ||
      path.endsWith('.mts');
}

/// HLS playlist URL (not a muxed `.ts` file).
bool looksLikeHlsUrl(String url) {
  if (looksLikeMpegTsUrl(url)) return false;
  final lower = url.toLowerCase();
  return lower.contains('.m3u8');
}

bool looksLikeLoopbackUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return true;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '0.0.0.0';
}

/// RFC1918 (and typical LAN) HTTP the Chromecast can fetch itself.
bool isPrivateLanHttpUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  if (host.startsWith('192.168.') || host.startsWith('10.')) return true;
  return RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(host);
}

/// HTTP(S) the phone can fetch (includes loopback torrent streams).
/// Magnets and `file:` stay local until resolved to HTTP.
bool isHttpCastableUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}

/// HTTP(S) URLs the TV can fetch itself, without the phone proxying.
bool isLanCastableUrl(String url) {
  if (!isHttpCastableUrl(url)) return false;
  return !looksLikeLoopbackUrl(url);
}

const kCastUnsupportedOnDevice =
    'This content cannot be cast to this device';

enum CastCodecRisk { none, video, audio }

/// Styled Media Receiver often plays AAC and drops the picture for these.
CastCodecRisk classifyCastCodecRisk(
  String? fileName,
  String url, [
  String? contentType,
]) {
  final blob = '${fileName ?? ''} $url ${contentType ?? ''}'.toLowerCase();
  if (blob.contains('audio/mpeg') ||
      blob.contains('audio/aac') ||
      blob.contains('.mp3') ||
      blob.contains('.aac')) {
    return CastCodecRisk.none;
  }
  const video = [
    'x265',
    'h265',
    'h.265',
    'hevc',
    'av1',
    'av01',
    'dovi',
    'dvhe',
    'dolby vision',
    'dolbyvision',
  ];
  if (video.any(blob.contains)) return CastCodecRisk.video;
  const audio = ['truehd', 'atmos', 'dts-hd', 'dtshd'];
  if (audio.any(blob.contains)) return CastCodecRisk.audio;
  return CastCodecRisk.none;
}

bool looksLikeDirectPlayRisk(
  String? fileName,
  String url, [
  String? contentType,
]) {
  return classifyCastCodecRisk(fileName, url, contentType) !=
      CastCodecRisk.none;
}

/// Idle / LOAD failures from CAF → the user-facing unsupported line.
/// Connection / Wi‑Fi errors stay as-is.
String friendlyCastReceiverError(String raw) {
  final l = raw.toLowerCase();
  if (l.contains('could not connect') ||
      l.contains('wi-fi') ||
      l.contains('wifi') ||
      l.contains('need an http') ||
      l.contains('only available on')) {
    return raw;
  }
  if (l.contains('idle') ||
      l.contains('load failed') ||
      l.contains('invalid request') ||
      l.contains('did not start') ||
      l.contains('playback failed') ||
      l.contains('statuscode') ||
      l.contains('status code') ||
      raw == kCastUnsupportedOnDevice) {
    return kCastUnsupportedOnDevice;
  }
  return raw;
}
