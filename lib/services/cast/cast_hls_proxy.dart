import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:javp/services/cast/cast_mime.dart';

/// Chromecast / DLNA fetch media themselves. This binds a LAN HTTP server on
/// the phone and re-exports origin URLs with CORS + Range.
///
/// Used for:
/// - HLS / progressive HTTP whose CDN 403s OPTIONS preflight
/// - Loopback torrent (and other) HTTP the TV cannot route to (`127.0.0.1`)
/// - Progressive MPEG-TS, wrapped as a one-segment HLS playlist
class CastHlsProxy {
  HttpServer? _server;
  HttpClient? _client;
  String? _lanIp;
  int _port = 0;

  /// Last HLS container peeked from the origin playlist (`ts` or `fmp4`).
  String? lastHlsSegmentFormat;

  bool get isRunning => _server != null && _lanIp != null && _port > 0;

  /// Start (or reuse) the proxy and return a TV-fetchable URL.
  ///
  /// Public HTTP, loopback, HLS, and MPEG-TS are rewritten to
  /// `http://<wifi-ip>:<port>/…`. LAN RFC1918 progressive HTTP is left on the
  /// origin. Returns null if a proxy is required but the phone has no Wi‑Fi
  /// address.
  Future<String?> startFor(
    String originUrl, {
    String? fileName,
    bool live = false,
    bool force = false,
  }) async {
    final origin = Uri.tryParse(originUrl);
    if (origin == null ||
        (origin.scheme != 'http' && origin.scheme != 'https')) {
      return null;
    }
    if (!force && !needsLanProxy(originUrl)) {
      lastHlsSegmentFormat = null;
      return originUrl;
    }

    _lanIp ??= await resolveLanIpv4();
    if (_lanIp == null) return null;

    if (_server != null &&
        origin.host == _lanIp &&
        origin.port == _port) {
      return originUrl;
    }

    if (_server == null) {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = server.port;
      _server = server;
      _client = HttpClient()
        // Fetch origin as a normal browser. Chromecast UA on the *upstream*
        // request 403s some IPTV panels; CORS is added on our response.
        ..userAgent =
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36'
        ..idleTimeout = const Duration(minutes: 30)
        ..connectionTimeout = const Duration(seconds: 15);
      server.listen(_handle, onError: (_) {});
    }
    lastHlsSegmentFormat = null;
    if (looksLikeMpegTsUrl(originUrl)) {
      lastHlsSegmentFormat = 'ts';
      return mpegTsHlsPlaylistUrl(
        origin: origin,
        lanHost: _lanIp!,
        port: _port,
        live: live,
      ).toString();
    }
    final proxied =
        proxify(origin, lanHost: _lanIp!, port: _port, fileName: fileName)
            .toString();
    if (looksLikeHlsUrl(originUrl)) {
      lastHlsSegmentFormat = await _peekHlsFormat(origin);
    }
    return proxied;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    _lanIp = null;
    _client?.close(force: true);
    _client = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    _applyCors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (request.uri.pathSegments.isNotEmpty &&
        request.uri.pathSegments.first == 'ts') {
      await _serveTsWrapper(request);
      return;
    }
    final origin = decodeProxied(request.uri);
    if (origin == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    try {
      await _pipe(request, origin);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _pipe(HttpRequest request, Uri origin) async {
    final client = _client;
    if (client == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final up = await client.openUrl(request.method, origin);
    up.followRedirects = true;
    final range = request.headers.value('range');
    if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
    final upResp = await up.close();
    request.response.statusCode = upResp.statusCode;
    final ctype = upResp.headers.contentType?.toString() ??
        upResp.headers.value('content-type');
    if (ctype != null) {
      request.response.headers.set(HttpHeaders.contentTypeHeader, ctype);
    }
    final contentRange = upResp.headers.value('content-range');
    if (contentRange != null) {
      request.response.headers.set('content-range', contentRange);
    }
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (request.method == 'HEAD') {
      final cl = upResp.contentLength;
      if (cl >= 0) request.response.contentLength = cl;
      await request.response.close();
      await upResp.drain<void>();
      return;
    }

    // Playlists are small and must be rewritten. MPEG-TS (live `.ts`) is an
    // endless byte stream — never fold it into a list.
    if (looksLikeMpegTsUrl(origin.toString())) {
      final cl = upResp.contentLength;
      if (cl >= 0) request.response.contentLength = cl;
      final lowerCtype = (ctype ?? '').toLowerCase();
      if (ctype == null ||
          lowerCtype.contains('octet-stream') ||
          lowerCtype.contains('mpegurl')) {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'video/mp2t',
        );
      }
      request.response.bufferOutput = false;
      await request.response.addStream(upResp);
      await request.response.close();
      return;
    }
    if (_maybeHlsPlaylist(origin.toString(), ctype)) {
      final rewritten = await _rewriteIfHlsPlaylist(
        request: request,
        origin: origin,
        upResp: upResp,
        ctype: ctype,
      );
      if (rewritten) return;
    }

    final cl = upResp.contentLength;
    if (cl >= 0) request.response.contentLength = cl;
    request.response.bufferOutput = false;
    await request.response.addStream(upResp);
    await request.response.close();
  }

  /// Buffer a playlist (or peek a live path) and rewrite it. Returns false
  /// when the body is not HLS so the caller should stream [upResp] as-is.
  ///
  /// For extensionless `/live/` URLs we peek the first bytes: `#EXTM3U` →
  /// playlist, otherwise MPEG-TS (0x47 sync) is streamed without waiting for
  /// EOF (live TS never ends).
  Future<bool> _rewriteIfHlsPlaylist({
    required HttpRequest request,
    required Uri origin,
    required HttpClientResponse upResp,
    required String? ctype,
  }) async {
    if (looksLikeHlsUrl(origin.toString())) {
      final bytes = await upResp.fold<List<int>>(<int>[], (p, c) {
        p.addAll(c);
        return p;
      });
      if (!_isHlsBody(bytes, ctype, origin)) {
        request.response.add(bytes);
        await request.response.close();
        return true;
      }
      await _writeRewrittenPlaylist(request, origin, bytes);
      return true;
    }

    final iterator = StreamIterator(upResp);
    final peek = <int>[];
    while (peek.length < 16 && await iterator.moveNext()) {
      peek.addAll(iterator.current);
    }
    final head = utf8.decode(peek.take(16).toList(), allowMalformed: true);
    if (!head.startsWith('#EXTM3U')) {
      final cl = upResp.contentLength;
      if (cl >= 0) request.response.contentLength = cl;
      request.response.bufferOutput = false;
      if (peek.isNotEmpty) request.response.add(peek);
      while (await iterator.moveNext()) {
        request.response.add(iterator.current);
      }
      await request.response.close();
      await iterator.cancel();
      return true;
    }
    const maxPlaylist = 512 * 1024;
    while (peek.length < maxPlaylist && await iterator.moveNext()) {
      peek.addAll(iterator.current);
    }
    await iterator.cancel();
    await _writeRewrittenPlaylist(request, origin, peek);
    return true;
  }

  Future<void> _writeRewrittenPlaylist(
    HttpRequest request,
    Uri origin,
    List<int> bytes,
  ) async {
    final text = utf8.decode(bytes, allowMalformed: true);
    final rewritten = rewriteHlsPlaylist(
      text,
      playlistUrl: origin,
      proxify: (abs) => proxify(abs, lanHost: _lanIp!, port: _port),
    );
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    request.response.write(rewritten);
    await request.response.close();
  }

  /// Chromecast cannot LOAD progressive MPEG-TS. Serve a one-segment HLS
  /// playlist that points at the proxied `.ts` byte stream.
  Future<void> _serveTsWrapper(HttpRequest request) async {
    final parts = request.uri.pathSegments;
    if (parts.length < 2) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    try {
      final origin = Uri.parse(utf8.decode(base64Url.decode(parts[1])));
      if (origin.scheme != 'http' && origin.scheme != 'https') {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final live = request.uri.queryParameters['live'] == '1';
      final segment = proxify(origin, lanHost: _lanIp!, port: _port);
      final body = wrapMpegTsAsHlsPlaylist(segmentUrl: segment, live: live);
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      if (request.method == 'HEAD') {
        request.response.contentLength = utf8.encode(body).length;
        await request.response.close();
        return;
      }
      request.response.write(body);
      await request.response.close();
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    }
  }

  static bool _isHlsBody(List<int> bytes, String? ctype, Uri origin) {
    final lowerCtype = (ctype ?? '').toLowerCase();
    if (lowerCtype.contains('mpegurl') || lowerCtype.contains('m3u8')) {
      return true;
    }
    if (looksLikeHlsUrl(origin.toString())) {
      final peek = utf8.decode(
        bytes.take(16).toList(),
        allowMalformed: true,
      );
      return peek.startsWith('#EXTM3U');
    }
    return false;
  }

  /// Playlists (`.m3u8` or extensionless `/live/`) may need rewrite. Muxed
  /// `.ts` never does — that path is handled before this is called.
  static bool _maybeHlsPlaylist(String url, String? ctype) {
    if (looksLikeMpegTsUrl(url)) return false;
    if (looksLikeHlsUrl(url)) return true;
    final lowerCtype = (ctype ?? '').toLowerCase();
    if (lowerCtype.contains('mpegurl') || lowerCtype.contains('m3u8')) {
      return true;
    }
    final lower = url.toLowerCase();
    return lower.contains('/live/') || lower.contains('/timeshift/');
  }

  static void _applyCors(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      ..set('Access-Control-Allow-Headers', '*')
      ..set(
        'Access-Control-Expose-Headers',
        'Content-Length, Content-Range, Content-Type, Accept-Ranges, Date',
      )
      ..set('Access-Control-Max-Age', '86400');
  }

  Future<String?> _peekHlsFormat(Uri origin) async {
    final client = _client;
    if (client == null) return inspectHlsPlaylist('');
    try {
      final req = await client.getUrl(origin);
      final resp = await req.close();
      final bytes = await resp.fold<List<int>>(<int>[], (p, c) {
        if (p.length > 64 * 1024) return p;
        p.addAll(c);
        return p;
      });
      return inspectHlsPlaylist(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return 'ts';
    }
  }
}

/// True when the TV cannot fetch [url] as-is (loopback) or CAF needs CORS
/// (HLS and most public CDNs). LAN RFC1918 progressive HTTP is left on the
/// origin.
bool needsLanProxy(String url) {
  if (looksLikeLoopbackUrl(url)) return true;
  if (looksLikeHlsUrl(url) || looksLikeMpegTsUrl(url)) return true;
  final lower = url.toLowerCase();
  // Xtream / Stalker live is often HLS or TS without a suffix.
  if (lower.contains('/live/') || lower.contains('/timeshift/')) return true;
  return isHttpCastableUrl(url) && !isPrivateLanHttpUrl(url);
}

/// One-segment HLS playlist so Chromecast will demux MPEG-TS.
String wrapMpegTsAsHlsPlaylist({
  required Uri segmentUrl,
  required bool live,
  int targetDurationSec = 10800,
}) {
  final dur = targetDurationSec < 1 ? 1 : targetDurationSec;
  final buf = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-TARGETDURATION:$dur')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
  if (!live) buf.writeln('#EXT-X-PLAYLIST-TYPE:VOD');
  buf
    ..writeln('#EXTINF:$dur.0,')
    ..writeln(segmentUrl.toString());
  if (!live) buf.writeln('#EXT-X-ENDLIST');
  return buf.toString();
}

Uri mpegTsHlsPlaylistUrl({
  required Uri origin,
  required String lanHost,
  required int port,
  bool live = false,
}) {
  final token = base64Url.encode(utf8.encode(origin.toString()));
  return Uri(
    scheme: 'http',
    host: lanHost,
    port: port,
    path: '/ts/$token/playlist.m3u8',
    queryParameters: live ? const {'live': '1'} : null,
  );
}

/// `ts` (MPEG-TS) or `fmp4` (CMAF). CAF must be told; defaulting everything
/// to TS makes fMP4 HLS load then show a blank receiver.
String inspectHlsPlaylist(String body) {
  final lower = body.toLowerCase();
  if (lower.contains('#ext-x-map')) return 'fmp4';
  for (final line in lower.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    if (t.contains('.m4s') ||
        t.contains('.cmfv') ||
        t.contains('.mp4')) {
      return 'fmp4';
    }
  }
  return 'ts';
}

Future<String?> probeHttpContentType(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..userAgent =
        'Mozilla/5.0 (CrKey armv7l) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.214 Safari/537.36';
  try {
    final req = await client.openUrl('HEAD', uri);
    final resp = await req.close();
    final raw = resp.headers.contentType?.mimeType ??
        resp.headers.value('content-type');
    await resp.drain<void>();
    if (raw == null || raw.isEmpty) return null;
    return raw.split(';').first.trim();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Rewrite playlist URI lines and `URI="…"` tags through [proxify].
String rewriteHlsPlaylist(
  String body, {
  required Uri playlistUrl,
  required Uri Function(Uri absolute) proxify,
}) {
  final lines = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      out.add(line);
      continue;
    }
    if (trimmed.startsWith('#')) {
      out.add(_rewriteTagUris(trimmed, playlistUrl, proxify));
      continue;
    }
    out.add(proxify(playlistUrl.resolve(trimmed)).toString());
  }
  return out.join('\n');
}

String _rewriteTagUris(
  String line,
  Uri playlistUrl,
  Uri Function(Uri absolute) proxify,
) {
  return line.replaceAllMapped(RegExp(r'URI="([^"]*)"', caseSensitive: false), (
    match,
  ) {
    final raw = match.group(1) ?? '';
    if (raw.isEmpty) return match.group(0)!;
    final abs = playlistUrl.resolve(raw);
    return 'URI="${proxify(abs)}"';
  });
}

Uri proxify(
  Uri absolute, {
  required String lanHost,
  required int port,
  String? fileName,
}) {
  final token = base64Url.encode(utf8.encode(absolute.toString()));
  return Uri(
    scheme: 'http',
    host: lanHost,
    port: port,
    // Keep a real media extension so Cast MIME sniffing still sees HLS/TS.
    path: '/u/$token/${proxyFilename(absolute, fileName: fileName)}',
  );
}

String proxyFilename(Uri absolute, {String? fileName}) {
  final hint = (fileName ?? '').toLowerCase();
  final path = absolute.path.toLowerCase();
  bool has(String ext) =>
      hint.endsWith(ext) || path.endsWith(ext) || path.contains(ext);
  if (has('.m3u8')) return 'playlist.m3u8';
  if (has('.m2ts')) return 'seg.m2ts';
  if (has('.mts')) return 'seg.mts';
  if (path.endsWith('.ts') || hint.endsWith('.ts')) return 'seg.ts';
  if (has('.webm')) return 'v.webm';
  if (has('.mkv')) return 'v.mkv';
  if (has('.mp4')) return 'v.mp4';
  // Torrent HTTP is `/stream/<hash>/<index>` with no extension. Default to
  // mp4 so Cast MIME sniffing matches [guessCastContentType].
  return 'v.mp4';
}

Uri? decodeProxied(Uri requestUri) {
  final parts = requestUri.pathSegments;
  if (parts.length < 2 || parts.first != 'u') return null;
  try {
    final raw = utf8.decode(base64Url.decode(parts[1]));
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  } catch (_) {
    return null;
  }
}

/// Pick a Wi‑Fi RFC1918 address. Android CLAT uses `192.0.0.4`, which
/// Chromecast on the LAN cannot route to.
String? pickLanIpv4(Iterable<({String name, String ip})> addrs) {
  String? rfc1918;
  String? wifi;
  for (final a in addrs) {
    final ip = a.ip;
    final name = a.name.toLowerCase();
    if (ip.startsWith('127.') ||
        ip.startsWith('169.254.') ||
        ip.startsWith('192.0.0.')) {
      continue;
    }
    if (name.contains('virtual') ||
        name.contains('vethernet') ||
        name.contains('docker') ||
        name.contains('vbox') ||
        name.contains('dummy') ||
        name.contains('clat')) {
      continue;
    }
    final private = ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip);
    if (!private) continue;
    rfc1918 ??= ip;
    if (name.contains('wlan') ||
        name.contains('wifi') ||
        name.contains('ap0') ||
        name.contains('swlan')) {
      wifi = ip;
      if (ip.startsWith('192.168.')) return ip;
    }
  }
  return wifi ?? rfc1918;
}

Future<String?> resolveLanIpv4() async {
  try {
    final addrs = <({String name, String ip})>[];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;
        addrs.add((name: iface.name, ip: addr.address));
      }
    }
    return pickLanIpv4(addrs);
  } catch (_) {}
  return null;
}
