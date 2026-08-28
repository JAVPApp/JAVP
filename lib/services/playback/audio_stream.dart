import 'dart:typed_data';

/// Tag stored on [MediaItem.tags] for Icecast / radio / audio-only streams.
const String kAudioOnlyTag = 'audio-only';

/// True when [tags] mark the item as audio-only (no video plane expected).
bool mediaTagsIndicateAudioOnly(Iterable<String> tags) =>
    tags.any((t) => t.trim().toLowerCase() == kAudioOnlyTag);

/// Merge [kAudioOnlyTag] into [tags] without duplicates.
List<String> withAudioOnlyTag(List<String> tags) {
  if (mediaTagsIndicateAudioOnly(tags)) {
    return List<String>.unmodifiable(tags);
  }
  return List<String>.unmodifiable([...tags, kAudioOnlyTag]);
}

/// True when [url] looks like a progressive audio file / radio mount.
bool looksLikeAudioOnlyUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  final path = (uri?.path ?? url).toLowerCase();
  // Strip a trailing slash so `/stream.mp3/` still matches.
  final normalized =
      path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  const exts = [
    '.mp3',
    '.aac',
    '.m4a',
    '.ogg',
    '.oga',
    '.opus',
    '.flac',
    '.wav',
  ];
  for (final ext in exts) {
    if (normalized.endsWith(ext)) return true;
  }
  // Hostnames like `cdn.onlyhitsradio.net` / `stream.example-radio.com`.
  final host = uri?.host.toLowerCase() ?? '';
  if (host.contains('radio')) return true;
  return false;
}

/// True when an M3U `group-title` clearly means radio / music / audio.
bool looksLikeRadioGroup(String? group) {
  final g = (group ?? '').trim().toLowerCase();
  if (g.isEmpty) return false;
  if (g.contains('radio') || g.contains('audio only') || g.contains('audio-only')) {
    return true;
  }
  // Whole-word "music" / "audio" so "Musical" / "Audiophile TV" are less noisy.
  return RegExp(r'(^|[^a-z0-9])(music|audio)([^a-z0-9]|$)').hasMatch(g);
}

/// Classify an HTTP probe as an infinite audio (radio) stream vs a finite file.
bool looksLikeInfiniteAudioStream({
  String? contentType,
  Map<String, String>? headers,
  List<int>? bytes,
  int? contentLength,
}) {
  final headerMap = _normalizeHeaders(headers);
  final ct = (contentType ?? headerMap['content-type'] ?? '').split(';').first.trim();
  final hasIcy = headerMap.keys.any((k) => k.startsWith('icy-'));

  if (hasIcy) return true;

  final isAudioType = ct.startsWith('audio/');
  final binaryAudio = bytes != null && bytesLookLikeMpegAudio(bytes);

  if (!isAudioType && !binaryAudio) return false;

  // Known finite length → treat as a downloadable/progressive file, not radio.
  if (contentLength != null && contentLength > 0) return false;

  return true;
}

/// ICY station name from response headers, when present.
String? icyNameFromHeaders(Map<String, String>? headers) {
  final map = _normalizeHeaders(headers);
  final name = map['icy-name']?.trim();
  if (name == null || name.isEmpty) return null;
  return name;
}

/// Full resource length from Content-Range / Content-Length when known.
///
/// Returns null for chunked / Icecast streams (unknown or unbounded).
int? fullContentLength({
  required int statusCode,
  Map<String, String>? headers,
}) {
  final map = _normalizeHeaders(headers);
  final range = map['content-range'];
  if (range != null) {
    final match = RegExp(r'/(\d+)\s*$').firstMatch(range);
    if (match != null) {
      final n = int.tryParse(match.group(1)!);
      if (n != null && n > 0) return n;
    }
    // `bytes 0-4095/*` → unknown total.
    if (range.contains('/*')) return null;
  }
  // On 206, Content-Length is only the partial body size — ignore it.
  if (statusCode == 206) return null;
  final cl = int.tryParse(map['content-length'] ?? '');
  if (cl != null && cl > 0) return cl;
  return null;
}

/// ID3 tag or MPEG audio frame sync in the first few bytes.
bool bytesLookLikeMpegAudio(List<int> bytes) {
  if (bytes.isEmpty) return false;
  // ID3v2 header.
  if (bytes.length >= 3 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    return true;
  }
  // Scan a short window for an MP3/AAC sync word (Icecast often starts mid-frame).
  final limit = bytes.length < 64 ? bytes.length - 1 : 63;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] != 0xFF) continue;
    final b = bytes[i + 1];
    // MP3: 1111 101x / 1111 100x — AAC ADTS: 1111 0001 / 1111 1001 …
    if ((b & 0xE0) == 0xE0) return true;
  }
  return false;
}

Map<String, String> _normalizeHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return const {};
  return {
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
  };
}

/// Convenience wrapper used by unit tests / call sites with raw header maps.
bool probeIndicatesAudioOnlyStream({
  required int statusCode,
  Map<String, String>? headers,
  Uint8List? bytes,
}) {
  return looksLikeInfiniteAudioStream(
    headers: headers,
    bytes: bytes,
    contentLength: fullContentLength(statusCode: statusCode, headers: headers),
  );
}
