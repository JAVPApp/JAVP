import 'package:javp/models/proxy_settings.dart';

/// Known VPN / proxy platforms that expose SOCKS5 (or HTTP) endpoints.
///
/// Presets only fill type / host / port examples — credentials stay blank for
/// the user to paste from their provider dashboard.
enum ProxyPresetId {
  custom,
  nordVpn,
  pia,
  torGuard,
  privateVpn,
}

class ProxyPreset {
  const ProxyPreset({
    required this.id,
    required this.label,
    required this.type,
    required this.hostExample,
    required this.port,
    required this.hostMatchers,
    this.credentialsUrl,
  });

  final ProxyPresetId id;
  final String label;
  final ProxyType type;

  /// Suggested hostname shown / applied when the preset is selected.
  final String hostExample;
  final int port;

  /// Substrings that identify this provider from a saved host.
  final List<String> hostMatchers;

  /// Provider dashboard / help page where the user copies proxy credentials.
  final String? credentialsUrl;

  static const List<ProxyPreset> all = [
    ProxyPreset(
      id: ProxyPresetId.custom,
      label: 'Custom',
      type: ProxyType.socks5,
      hostExample: '',
      port: 1080,
      hostMatchers: [],
    ),
    ProxyPreset(
      id: ProxyPresetId.nordVpn,
      label: 'NordVPN',
      type: ProxyType.socks5,
      hostExample: 'nl.socks.nordhold.net',
      port: 1080,
      hostMatchers: ['nordhold.net', 'nordcdn.com'],
      credentialsUrl:
          'https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/',
    ),
    ProxyPreset(
      id: ProxyPresetId.pia,
      label: 'PIA',
      type: ProxyType.socks5,
      hostExample: 'proxy-nl.privateinternetaccess.com',
      port: 1080,
      hostMatchers: ['privateinternetaccess.com'],
      credentialsUrl:
          'https://www.privateinternetaccess.com/account/client-sign-in',
    ),
    ProxyPreset(
      id: ProxyPresetId.torGuard,
      label: 'TorGuard',
      type: ProxyType.socks5,
      hostExample: 'proxy.torguard.org',
      port: 1080,
      hostMatchers: ['torguard.org', 'torguard.io', 'stealthtunnel.net'],
      credentialsUrl: 'https://torguard.net/managecredentials.php',
    ),
    ProxyPreset(
      id: ProxyPresetId.privateVpn,
      label: 'PrivateVPN',
      type: ProxyType.socks5,
      hostExample: 'se-sto.pvdata.host',
      port: 1080,
      hostMatchers: ['pvdata.host', 'privatevpn.com'],
      credentialsUrl: 'https://privatevpn.com/control-panel',
    ),
  ];

  static ProxyPreset byId(ProxyPresetId id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);

  /// Infer the active preset from the current host (falls back to Custom).
  static ProxyPreset matchHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return byId(ProxyPresetId.custom);
    for (final preset in all) {
      if (preset.id == ProxyPresetId.custom) continue;
      for (final m in preset.hostMatchers) {
        if (h.contains(m)) return preset;
      }
    }
    return byId(ProxyPresetId.custom);
  }

  bool matchesHost(String host) {
    if (id == ProxyPresetId.custom) {
      return matchHost(host).id == ProxyPresetId.custom;
    }
    final h = host.trim().toLowerCase();
    return hostMatchers.any(h.contains);
  }
}
