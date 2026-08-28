import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/services/network/app_http_client.dart';
import 'package:javp/services/network/fallback_http_client.dart';

/// Tiny HTTPS fetch used to verify the proxy handshake after save.
///
/// Any HTTP response means the tunnel succeeded (the destination page itself
/// is irrelevant). Auth / SOCKS failures throw before a status is returned.
///
/// Do **not** use example.com here — diagnostics log the request host on
/// failure, and users mistook that for the configured proxy hostname.
const proxyProbeUri = 'https://connectivitycheck.gstatic.com/generate_204';

class ProxyProbeResult {
  const ProxyProbeResult._({this.error, this.isAuthFailure = false});

  const ProxyProbeResult.ok() : error = null, isAuthFailure = false;

  factory ProxyProbeResult.fail(Object error) {
    return ProxyProbeResult._(
      error: describeProxyError(error),
      isAuthFailure: isProxyAuthFailure(error),
    );
  }

  final String? error;
  final bool isAuthFailure;

  bool get ok => error == null;
}

/// Sends one request through [settings] (no direct fallback).
///
/// Pass [client] in tests. Production builds a one-off client and closes it.
Future<ProxyProbeResult> probeProxy(
  ProxySettings settings, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 12),
  Uri? uri,
}) async {
  if (!settings.isActive) return const ProxyProbeResult.ok();

  final owned = client == null;
  final httpClient = client ?? await createAppHttpClient(settings);
  try {
    final response = await httpClient
        .get(uri ?? Uri.parse(proxyProbeUri))
        .timeout(timeout);
    if (response.statusCode == 407) {
      return ProxyProbeResult.fail(
        Exception('Proxy authentication required (HTTP 407)'),
      );
    }
    return const ProxyProbeResult.ok();
  } on TimeoutException {
    return ProxyProbeResult.fail(Exception('Timed out waiting for the proxy'));
  } catch (error) {
    return ProxyProbeResult.fail(error);
  } finally {
    if (owned) {
      httpClient.close();
    }
  }
}
