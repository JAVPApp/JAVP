import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:javp/services/pairing/tv_remote_page_html.dart';
import 'package:javp/services/pairing/tv_remote_ui_strings.dart';

/// Kind of input a phone remote session can send to the TV.
enum TvRemoteCommandKind { search, channel, pasteUrl }

/// Payload posted from the phone browser → TV.
class TvRemoteCommand {
  const TvRemoteCommand({required this.kind, required this.value});

  final TvRemoteCommandKind kind;
  final String value;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'value': value};
}

/// LAN HTTP server: phone browser types search / channel / URL → TV.
///
/// Mirrors [SourcePairingServer] (tokenized QR URL, emulator adb forward).
class TvRemoteServer {
  TvRemoteServer({this.port = 19288, TvRemoteUiStrings? uiStrings})
    : uiStrings = uiStrings ?? TvRemoteUiStrings.english;

  final int port;

  /// Localized copy for the phone HTML page and API error messages.
  TvRemoteUiStrings uiStrings;

  HttpServer? _server;
  String? _token;
  DateTime? _tokenExpiresAt;
  String? _lanIp;
  int _boundPort = 19288;
  final _commandController = StreamController<TvRemoteCommand>.broadcast();

  Stream<TvRemoteCommand> get onCommand => _commandController.stream;

  bool get isRunning => _server != null;
  String? get token => _token;
  String? get lanIp => _lanIp;
  int get boundPort => _boundPort;

  /// Emulator / AVD private IP — not reachable from a phone on Wi‑Fi.
  bool get isEmulatorNetwork => looksLikeEmulatorIpv4(_lanIp);

  /// Optional host override for QR / URL (e.g. PC LAN IP via dart-define).
  String? hostOverride;

  Uri? get remoteUri {
    final host = effectiveHost;
    if (_server == null || _token == null || host == null) return null;
    return Uri(
      scheme: 'http',
      host: host,
      port: _boundPort,
      path: '/remote',
      queryParameters: {'t': _token},
    );
  }

  String? get effectiveHost {
    final override = hostOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    if (isEmulatorNetwork) return '127.0.0.1';
    return _lanIp;
  }

  String? get adbForwardCommand {
    if (!isEmulatorNetwork && hostOverride == null) return null;
    return 'adb forward tcp:$_boundPort tcp:$_boundPort';
  }

  static bool looksLikeEmulatorIpv4(String? ip) {
    if (ip == null || ip.isEmpty) return false;
    return ip.startsWith('10.0.2.') || ip.startsWith('10.0.3.');
  }

  Future<void> start() async {
    await stop();
    _lanIp = await _resolveLanIpv4();
    _rotateToken();
    HttpServer? server;
    Object? lastError;
    for (var p = port; p < port + 20; p++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _boundPort = p;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (server == null) {
      throw StateError('Could not bind remote port: $lastError');
    }
    _server = server;
    server.listen(_handleRequest, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    _tokenExpiresAt = null;
    await server?.close(force: true);
  }

  void rotateToken() => _rotateToken();

  void _rotateToken() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    _token = base64UrlEncode(bytes).replaceAll('=', '');
    _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 15));
  }

  bool _tokenValid(String? candidate) {
    if (candidate == null || candidate.isEmpty || _token == null) return false;
    if (_tokenExpiresAt != null && DateTime.now().isAfter(_tokenExpiresAt!)) {
      return false;
    }
    return candidate == _token;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && (path == '/' || path == '/remote')) {
        final t = request.uri.queryParameters['t'];
        if (!_tokenValid(t)) {
          await _write(
            request,
            HttpStatus.unauthorized,
            buildTvRemoteExpiredHtml(uiStrings),
            contentType: ContentType.html,
          );
          return;
        }
        await _write(
          request,
          HttpStatus.ok,
          buildTvRemoteFormHtml(uiStrings),
          contentType: ContentType.html,
        );
        return;
      }

      if (request.method == 'POST' && path == '/api/remote') {
        final body = await utf8.decoder.bind(request).join();
        Map<String, dynamic> json;
        try {
          json = jsonDecode(body) as Map<String, dynamic>;
        } catch (_) {
          await _writeJson(request, HttpStatus.badRequest, {
            'ok': false,
            'code': 'invalid_json',
            'error': uiStrings.errorInvalidJson,
          });
          return;
        }
        final t =
            json['token'] as String? ??
            request.uri.queryParameters['t'] ??
            request.headers.value('x-javp-token');
        if (!_tokenValid(t)) {
          await _writeJson(request, HttpStatus.unauthorized, {
            'ok': false,
            'code': 'bad_token',
            'error': uiStrings.errorBadToken,
          });
          return;
        }
        try {
          final command = parseTvRemoteCommand(json);
          _commandController.add(command);
          await _writeJson(request, HttpStatus.ok, {
            'ok': true,
            'kind': command.kind.name,
            'value': command.value,
          });
        } on TvRemoteParseException catch (e) {
          await _writeJson(request, HttpStatus.badRequest, {
            'ok': false,
            'code': e.code,
            'error': uiStrings.errorForCode(e.code),
          });
        } catch (e) {
          await _writeJson(request, HttpStatus.badRequest, {
            'ok': false,
            'error': e.toString(),
          });
        }
        return;
      }

      await _write(request, HttpStatus.notFound, 'Not found');
    } catch (_) {
      try {
        await _write(request, HttpStatus.internalServerError, 'Error');
      } catch (_) {}
    }
  }

  Future<void> _write(
    HttpRequest request,
    int status,
    String body, {
    ContentType? contentType,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = contentType ?? ContentType.text;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  static Future<String?> _resolveLanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('virtual') ||
            name.contains('vethernet') ||
            name.contains('docker') ||
            name.contains('vbox')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          return ip;
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    unawaited(stop());
    unawaited(_commandController.close());
  }
}

/// Pure validation for remote form JSON (unit-tested).
TvRemoteCommand parseTvRemoteCommand(Map<String, dynamic> json) {
  final kindRaw = (json['kind'] as String?)?.trim().toLowerCase() ?? '';
  final value =
      (json['value'] as String?)?.trim() ??
      (json['text'] as String?)?.trim() ??
      (json['query'] as String?)?.trim() ??
      '';

  switch (kindRaw) {
    case 'search':
    case 'text':
    case 'query':
      if (value.isEmpty) {
        throw const TvRemoteParseException('search_required');
      }
      return TvRemoteCommand(kind: TvRemoteCommandKind.search, value: value);
    case 'channel':
    case 'ch':
    case 'number':
      if (value.isEmpty) {
        throw const TvRemoteParseException('channel_required');
      }
      final n = int.tryParse(value);
      if (n == null || n < 1) {
        throw const TvRemoteParseException('channel_invalid');
      }
      return TvRemoteCommand(
        kind: TvRemoteCommandKind.channel,
        value: n.toString(),
      );
    case 'paste':
    case 'url':
    case 'pasteurl':
    case 'paste_url':
      if (value.isEmpty) {
        throw const TvRemoteParseException('url_required');
      }
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !(uri.scheme == 'http' ||
              uri.scheme == 'https' ||
              uri.scheme == 'magnet')) {
        throw const TvRemoteParseException('url_invalid');
      }
      return TvRemoteCommand(kind: TvRemoteCommandKind.pasteUrl, value: value);
    default:
      throw ArgumentError('Unknown remote kind: $kindRaw');
  }
}
