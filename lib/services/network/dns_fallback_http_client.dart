import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// [http.Client] that still works when Android/system DNS fails for the app
/// process (common with broken Private DNS / some VPNs).
///
/// Lookup order: system DNS → DNS-over-HTTPS via 8.8.8.8 / 1.1.1.1 (by IP).
/// TLS uses the original hostname for SNI + certificate checks.
///
/// On web, [dart:io] sockets are unavailable — returns the browser [http.Client].
http.Client createDnsFallbackHttpClient() {
  if (kIsWeb) return http.Client();

  final httpClient = HttpClient();
  // Room for a browse GET beside in-flight catalog dumps (per host).
  httpClient.maxConnectionsPerHost = 10;
  // This client is only used without an HTTP proxy (see createAppHttpClient).
  httpClient.connectionFactory = (uri, proxyHost, proxyPort) {
    return Future<ConnectionTask<Socket>>.value(
      ConnectionTask.fromSocket(_connect(uri), () {}),
    );
  };
  return IOClient(httpClient);
}

Future<Socket> _connect(Uri uri) async {
  final port = uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80);
  final address = await resolveHostIpv4(uri.host);
  final raw = await Socket.connect(
    address,
    port,
    timeout: const Duration(seconds: 20),
  );
  if (uri.isScheme('https')) {
    return SecureSocket.secure(raw, host: uri.host);
  }
  return raw;
}

/// Resolves [host] to an IPv4 address, with DoH fallback.
Future<InternetAddress> resolveHostIpv4(String host) async {
  final asIp = InternetAddress.tryParse(host);
  if (asIp != null) return asIp;

  try {
    final results = await InternetAddress.lookup(host);
    if (results.isNotEmpty) {
      return results.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => results.first,
      );
    }
  } on SocketException {
    // Fall through to DoH.
  }

  final ip = await lookupIpv4ViaDoh(host);
  return InternetAddress(ip);
}

Future<String> lookupIpv4ViaDoh(String host) async {
  final attempts = <({InternetAddress ip, String sni, String path})>[
    (
      ip: InternetAddress('8.8.8.8'),
      sni: 'dns.google',
      path: '/resolve?name=${Uri.encodeQueryComponent(host)}&type=A',
    ),
    (
      ip: InternetAddress('1.1.1.1'),
      sni: 'cloudflare-dns.com',
      path: '/dns-query?name=${Uri.encodeQueryComponent(host)}&type=A',
    ),
  ];

  Object? lastError;
  for (final attempt in attempts) {
    SecureSocket? socket;
    try {
      final raw = await Socket.connect(
        attempt.ip,
        443,
        timeout: const Duration(seconds: 10),
      );
      socket = await SecureSocket.secure(raw, host: attempt.sni);
      final request = StringBuffer()
        ..write('GET ${attempt.path} HTTP/1.1\r\n')
        ..write('Host: ${attempt.sni}\r\n')
        ..write('Accept: application/dns-json\r\n')
        ..write('User-Agent: javp/0.1.0\r\n')
        ..write('Connection: close\r\n')
        ..write('\r\n');
      socket.add(utf8.encode(request.toString()));
      await socket.flush();

      final response = await utf8.decoder
          .bind(socket)
          .timeout(const Duration(seconds: 10))
          .join();
      final bodyStart = response.indexOf('\r\n\r\n');
      if (bodyStart < 0) {
        throw const SocketException('DoH response missing body');
      }
      final statusLine = response.split('\r\n').first;
      if (!statusLine.contains('200')) {
        throw SocketException('DoH HTTP error: $statusLine');
      }
      final body = response.substring(bodyStart + 4);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const SocketException('DoH returned unexpected JSON');
      }
      final answers = decoded['Answer'];
      if (answers is! List) {
        throw SocketException('DoH has no Answer for $host');
      }
      for (final answer in answers) {
        if (answer is Map && answer['type'] == 1 && answer['data'] is String) {
          final data = (answer['data'] as String).trim();
          if (InternetAddress.tryParse(data) != null) {
            return data;
          }
        }
      }
      throw SocketException('DoH has no A record for $host');
    } catch (e) {
      lastError = e;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  throw SocketException(
    "Failed host lookup: '$host'${lastError == null ? '' : ' ($lastError)'}",
  );
}
