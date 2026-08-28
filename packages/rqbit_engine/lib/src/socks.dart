/// SOCKS5 URL for librqbit `SessionOptions.socks_proxy_url`.
///
/// Returns `null` when the proxy should stay off (inactive, or HTTP — rqbit
/// only tunnels BitTorrent over SOCKS5).
String? rqbitSocksProxyUrl({
  required bool enabled,
  required String type,
  required String host,
  required int port,
  String username = '',
  String password = '',
}) {
  if (!enabled) return null;
  if (type.toLowerCase() != 'socks5') return null;
  final h = host.trim();
  if (h.isEmpty || port <= 0 || port > 65535) return null;
  final user = username.trim();
  final pass = password;
  final auth = user.isNotEmpty && pass.isNotEmpty
      ? '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@'
      : '';
  return 'socks5://$auth$h:$port';
}
