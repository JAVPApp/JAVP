import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/services/network/dns_fallback_http_client.dart';
import 'package:javp/services/network/fallback_http_client.dart';
import 'package:socks5_proxy/socks_client.dart' as socks;

/// Builds an [http.Client] that honors [ProxySettings] for HTTP/HTTPS.
///
/// HTTP type uses Dart's CONNECT proxy. SOCKS5 uses [socks5_proxy] with
/// optional username/password auth (compatible with common VPN SOCKS5).
///
/// When no proxy is active, uses [createDnsFallbackHttpClient] so hosts like
/// `api.simkl.com` still resolve if Android Private DNS / VPN breaks app DNS.
///
/// SOCKS/CONNECT handshake failures become [ProxyErrorHttpClient] errors so
/// callers (Plex sign-in, catalogs) can tell the proxy failed. Direct retry
/// is opt-in via [ProxySettings.allowDirectFallback].
///
/// On web, SOCKS/CONNECT proxies are unavailable — returns the browser client
/// (same as an inactive proxy).
Future<http.Client> createAppHttpClient([
  ProxySettings proxy = ProxySettings.disabled,
]) async {
  if (kIsWeb || !proxy.isActive) return createDnsFallbackHttpClient();

  final host = proxy.host.trim();
  final port = proxy.port;
  final client = HttpClient();
  client.maxConnectionsPerHost = 10;

  if (proxy.type == ProxyType.socks5) {
    final address = await _resolveProxyHost(host);
    final auth = proxy.hasProxyUserPass;
    socks.SocksTCPClient.assignToHttpClient(client, [
      socks.ProxySettings(
        address,
        port,
        username: auth ? proxy.username.trim() : null,
        password: auth ? proxy.password : null,
      ),
    ]);
    return ProxyErrorHttpClient(IOClient(client));
  }

  client.findProxy = (_) => 'PROXY $host:$port';
  final user = proxy.username.trim();
  if (user.isNotEmpty) {
    client.addProxyCredentials(
      host,
      port,
      'JAVP',
      HttpClientBasicCredentials(user, proxy.password),
    );
  }
  return ProxyErrorHttpClient(IOClient(client));
}

Future<InternetAddress> _resolveProxyHost(String host) async {
  final asIp = InternetAddress.tryParse(host);
  if (asIp != null) return asIp;

  try {
    final results = await InternetAddress.lookup(host);
    if (results.isNotEmpty) return results.first;
  } on SocketException {
    // Prefer DoH when system DNS fails for the proxy hostname too.
  }
  return resolveHostIpv4(host);
}
