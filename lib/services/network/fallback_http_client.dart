import 'package:http/http.dart' as http;
import 'package:javp/services/diagnostics/javp_log.dart';

/// Remaps SOCKS5 / CONNECT authentication failures to [ProxyHandshakeException].
///
/// [socks5_proxy] throws a generic "Authentication failed" that UIs were
/// showing as a Plex / API-key failure. Does not retry without the proxy.
class ProxyErrorHttpClient extends http.BaseClient {
  ProxyErrorHttpClient(this.inner, {this.ownsInner = true});

  final http.Client inner;
  final bool ownsInner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      return await inner.send(request);
    } catch (error, stack) {
      if (isProxyHandshakeFailure(error)) {
        JavpLog.w(
          'net',
          'proxy handshake failed reaching ${request.url.host}',
          error: error,
        );
      }
      Error.throwWithStackTrace(explainProxyHandshakeError(error), stack);
    }
  }

  @override
  void close() {
    if (ownsInner) inner.close();
  }
}

/// Proxied [http.Client] that reports handshake failures, with an optional
/// direct retry when Settings → Network enables “retry without proxy”.
///
/// Inner clients are owned by [LibraryProvider]; do not close them here.
class FallbackHttpClient extends http.BaseClient {
  FallbackHttpClient({
    required this.primary,
    this.fallback,
    this.onProxyFailure,
  });

  final http.Client primary;
  final http.Client? fallback;
  final void Function(String host, Object error)? onProxyFailure;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final retry = fallback == null ? null : copyRequest(request);
    try {
      return await primary.send(request);
    } catch (error, stack) {
      if (!isProxyHandshakeFailure(error)) {
        Error.throwWithStackTrace(error, stack);
      }
      onProxyFailure?.call(request.url.host, error);
      if (retry == null ||
          fallback == null ||
          identical(primary, fallback)) {
        JavpLog.w(
          'net',
          'proxy failed for ${request.url.host}',
          error: error,
        );
        Error.throwWithStackTrace(explainProxyHandshakeError(error), stack);
      }
      JavpLog.w(
        'net',
        'proxy failed for ${request.url.host}, retrying direct',
        error: error,
      );
      try {
        return await fallback!.send(retry);
      } catch (fallbackError, fallbackStack) {
        Error.throwWithStackTrace(
          explainProxyHandshakeError(error, fallbackError: fallbackError),
          fallbackStack,
        );
      }
    }
  }

  @override
  void close() {}
}

/// Copy used for a single retry. Streamed bodies cannot be replayed.
http.Request? copyRequest(http.BaseRequest request) {
  if (request is! http.Request) return null;
  return http.Request(request.method, request.url)
    ..followRedirects = request.followRedirects
    ..maxRedirects = request.maxRedirects
    ..persistentConnection = request.persistentConnection
    ..headers.addAll(request.headers)
    ..bodyBytes = request.bodyBytes;
}

/// True for proxy username/password (or auth-negotiation) failures only.
///
/// Matches [socks5_proxy]'s bare `Authentication failed` / auth-version
/// errors and Dart CONNECT `407 Proxy Authentication Required`. Does not
/// match generic `SocksClient*` failures or other `Proxy failed to
/// establish tunnel` statuses — those are not credential rejections and
/// must not use the password copy or trigger
/// [ProxySettings.allowDirectFallback].
bool isProxyHandshakeFailure(Object error) {
  if (error is ProxyHandshakeException) return true;
  final text = error.toString().toLowerCase();
  if (text.contains('authentication failed') ||
      text.contains('authentication version') ||
      text.contains('proxy authentication required')) {
    return true;
  }
  // Dart IOClient: "Proxy failed to establish tunnel (407 ...)"
  return text.contains('proxy failed to establish tunnel') &&
      RegExp(r'\b407\b').hasMatch(text);
}

bool isProxyAuthFailure(Object error) {
  if (error is ProxyHandshakeException) return true;
  final text = error.toString().toLowerCase();
  return text.contains('authentication failed') ||
      text.contains('proxy authentication required') ||
      text.contains('http 407') ||
      RegExp(r'\b407\b').hasMatch(text);
}

/// Maps a proxy authentication error to [ProxyHandshakeException].
///
/// Other errors are returned unchanged so callers can still `rethrow`.
Object explainProxyHandshakeError(Object error, {Object? fallbackError}) {
  if (!isProxyHandshakeFailure(error)) return error;
  if (error is ProxyHandshakeException && fallbackError == null) {
    return error;
  }
  return ProxyHandshakeException(error, fallbackCause: fallbackError);
}

/// User-facing message when SOCKS5 / HTTP CONNECT auth fails.
class ProxyHandshakeException implements Exception {
  ProxyHandshakeException(this.cause, {this.fallbackCause});

  /// Original auth failure (`Exception: Authentication failed.`).
  final Object cause;

  /// Error from the direct retry, when one was attempted.
  final Object? fallbackCause;

  static const userMessage =
      'Proxy authentication failed. Check the username/password in '
      'Settings → Network, or turn the proxy off for this traffic.';

  @override
  String toString() {
    if (fallbackCause == null) return userMessage;
    return '$userMessage Direct connection also failed.';
  }
}

/// Formats a caught error for snackbars / form banners.
String describeCaughtError(Object error, {String? proxyHandshakeMessage}) {
  if (isProxyHandshakeFailure(error)) {
    return proxyHandshakeMessage ?? ProxyHandshakeException.userMessage;
  }
  final text = error.toString();
  const prefix = 'Exception: ';
  if (text.startsWith(prefix)) return text.substring(prefix.length);
  return text;
}

/// Short, UI-safe detail from a proxy [error] (strips Dart exception prefixes).
String describeProxyError(Object error) {
  if (error is ProxyHandshakeException) {
    return error.toString();
  }
  var text = error.toString().trim();
  const prefixes = [
    'Exception: ',
    'HttpException: ',
    'SocketException: ',
    'TimeoutException: ',
    'HandshakeException: ',
    'OS Error: ',
  ];
  var changed = true;
  while (changed) {
    changed = false;
    for (final prefix in prefixes) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        changed = true;
      }
    }
  }
  return text.isEmpty ? error.toString() : text;
}
