import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/proxy_preset.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/services/torrent/torrent_stream_service.dart';

void main() {
  group('ProxySettings', () {
    test('isActive requires enabled host and valid port', () {
      expect(ProxySettings.disabled.isActive, isFalse);
      expect(
        const ProxySettings(
          enabled: true,
          host: '127.0.0.1',
          port: 8080,
        ).isActive,
        isTrue,
      );
      expect(
        const ProxySettings(enabled: true, host: '', port: 8080).isActive,
        isFalse,
      );
    });

    test('round-trips json including socks5 type and scopes', () {
      const original = ProxySettings(
        enabled: true,
        type: ProxyType.socks5,
        host: 'socks.provider.test',
        port: 1080,
        username: 'u',
        password: 'p',
        routeIptv: true,
        routeCatalogs: false,
        routeMetadata: true,
        routeMediaServers: false,
        routeTorrents: true,
        routeDownloads: true,
        allowDirectFallback: true,
      );
      final parsed = ProxySettings.fromJson(original.toJson());
      expect(parsed.enabled, original.enabled);
      expect(parsed.type, ProxyType.socks5);
      expect(parsed.host, original.host);
      expect(parsed.port, original.port);
      expect(parsed.username, original.username);
      expect(parsed.password, original.password);
      expect(parsed.routeIptv, isTrue);
      expect(parsed.routeCatalogs, isFalse);
      expect(parsed.routeMetadata, isTrue);
      expect(parsed.routeMediaServers, isFalse);
      expect(parsed.routeTorrents, isTrue);
      expect(parsed.routeDownloads, isTrue);
      expect(parsed.allowDirectFallback, isTrue);
      expect(parsed.displayLabel, contains('SOCKS5'));
      expect(parsed.isActiveFor(ProxyTrafficScope.catalogs), isFalse);
      expect(parsed.isActiveFor(ProxyTrafficScope.torrents), isTrue);
      expect(parsed.isActiveFor(ProxyTrafficScope.downloads), isTrue);
    });

    test('defaults missing type and scopes for older saves', () {
      final parsed = ProxySettings.fromJson({
        'enabled': true,
        'host': 'proxy.example',
        'port': 3128,
        'username': 'u',
        'password': 'p',
      });
      expect(parsed.type, ProxyType.http);
      expect(parsed.displayLabel, contains('HTTP'));
      expect(parsed.routeIptv, isFalse);
      expect(parsed.routeCatalogs, isFalse);
      expect(parsed.routeMetadata, isFalse);
      expect(parsed.routeMediaServers, isFalse);
      expect(parsed.routeTorrents, isTrue);
      expect(parsed.routeDownloads, isFalse);
      expect(parsed.allowDirectFallback, isFalse);
      expect(parsed.isActiveFor(ProxyTrafficScope.iptv), isFalse);
      expect(parsed.isActiveFor(ProxyTrafficScope.torrents), isTrue);
      expect(parsed.isActiveFor(ProxyTrafficScope.downloads), isFalse);
    });

    test('constructor defaults route torrents only', () {
      const settings = ProxySettings(
        enabled: true,
        host: '127.0.0.1',
        port: 1080,
      );
      expect(settings.routeIptv, isFalse);
      expect(settings.routeCatalogs, isFalse);
      expect(settings.routeMetadata, isFalse);
      expect(settings.routeMediaServers, isFalse);
      expect(settings.routeTorrents, isTrue);
      expect(settings.routeDownloads, isFalse);
      expect(settings.isActiveFor(ProxyTrafficScope.catalogs), isFalse);
      expect(settings.isActiveFor(ProxyTrafficScope.torrents), isTrue);
      expect(settings.isActiveFor(ProxyTrafficScope.downloads), isFalse);
    });

    test('hasProxyUserPass requires both username and password', () {
      expect(
        const ProxySettings(
          enabled: true,
          type: ProxyType.socks5,
          host: '127.0.0.1',
          port: 1080,
          username: 'user',
        ).hasProxyUserPass,
        isFalse,
      );
      expect(
        const ProxySettings(
          enabled: true,
          type: ProxyType.socks5,
          host: '127.0.0.1',
          port: 1080,
          username: 'user',
          password: 'secret',
        ).hasProxyUserPass,
        isTrue,
      );
    });

    test('hasProxyUserPass requires both username and password', () {
      expect(
        const ProxySettings(
          enabled: true,
          type: ProxyType.socks5,
          host: '127.0.0.1',
          port: 1080,
          username: 'user',
        ).hasProxyUserPass,
        isFalse,
      );
      expect(
        const ProxySettings(
          enabled: true,
          type: ProxyType.socks5,
          host: '127.0.0.1',
          port: 1080,
          username: 'user',
          password: 'secret',
        ).hasProxyUserPass,
        isTrue,
      );
    });
  });

  group('ProxyPreset', () {
    test('matchHost recognizes provider hostnames', () {
      expect(
        ProxyPreset.matchHost('nl.socks.nordhold.net').id,
        ProxyPresetId.nordVpn,
      );
      expect(
        ProxyPreset.matchHost('proxy-nl.privateinternetaccess.com').id,
        ProxyPresetId.pia,
      );
      expect(
        ProxyPreset.matchHost('proxy.torguard.org').id,
        ProxyPresetId.torGuard,
      );
      expect(
        ProxyPreset.matchHost('se-sto.pvdata.host').id,
        ProxyPresetId.privateVpn,
      );
      expect(
        ProxyPreset.matchHost('nl1-wg.socks5.relays.mullvad.net').id,
        ProxyPresetId.custom,
      );
      expect(
        ProxyPreset.matchHost('socks.example.com').id,
        ProxyPresetId.custom,
      );
    });

    test('provider presets default to SOCKS5 on 1080', () {
      for (final preset in ProxyPreset.all) {
        if (preset.id == ProxyPresetId.custom) continue;
        expect(preset.type, ProxyType.socks5);
        expect(preset.port, 1080);
        expect(preset.hostExample, isNotEmpty);
        expect(
          ProxySettings.isPlaceholderHost(preset.hostExample),
          isFalse,
          reason: '${preset.label} must not use a placeholder host',
        );
      }
      expect(ProxyPreset.byId(ProxyPresetId.custom).hostExample, isEmpty);
      expect(
        ProxyPreset.byId(ProxyPresetId.nordVpn).hostExample,
        'nl.socks.nordhold.net',
      );
    });

    test('placeholder hosts are never active', () {
      expect(ProxySettings.isPlaceholderHost('example.com'), isTrue);
      expect(ProxySettings.isPlaceholderHost('socks.example.com'), isTrue);
      expect(
        ProxySettings.isPlaceholderHost('nl.socks.nordhold.net'),
        isFalse,
      );
      expect(
        const ProxySettings(
          enabled: true,
          type: ProxyType.socks5,
          host: 'proxy.example.com',
          port: 1080,
        ).isActive,
        isFalse,
      );
    });

    test('provider presets link to a credentials page', () {
      expect(ProxyPreset.byId(ProxyPresetId.custom).credentialsUrl, isNull);
      expect(
        ProxyPreset.byId(ProxyPresetId.nordVpn).credentialsUrl,
        contains('nordaccount.com'),
      );
      expect(
        ProxyPreset.byId(ProxyPresetId.pia).credentialsUrl,
        'https://www.privateinternetaccess.com/account/client-sign-in',
      );
      expect(
        ProxyPreset.byId(ProxyPresetId.torGuard).credentialsUrl,
        'https://torguard.net/managecredentials.php',
      );
      expect(
        ProxyPreset.byId(ProxyPresetId.privateVpn).credentialsUrl,
        'https://privatevpn.com/control-panel',
      );
    });
  });

  group('torrent helpers', () {
    test('detects magnet and torrent paths', () {
      expect(isMagnetUri('magnet:?xt=urn:btih:abc'), isTrue);
      expect(isMagnetUri('https://example.com'), isFalse);
      expect(isTorrentPath(r'C:\files\movie.torrent'), isTrue);
      expect(isTorrentPath('https://example.com/a.torrent'), isFalse);
      expect(looksLikeTorrentPlayUrl('magnet:?xt=urn:btih:abc'), isTrue);
    });

    test('maps ProxySettings into LtProxyConfig via apply before init', () {
      final service = TorrentStreamService();
      expect(
        service.applyProxySettings(
          const ProxySettings(
            enabled: true,
            type: ProxyType.socks5,
            host: 'socks.example',
            port: 1080,
            username: 'u',
            password: 'p',
          ),
        ),
        isFalse, // session not ready yet; settings are retained for init
      );
      expect(service.proxyApplied, isFalse);
    });

    test('retains settings when torrents scope is off before init', () {
      final service = TorrentStreamService();
      expect(
        service.applyProxySettings(
          const ProxySettings(
            enabled: true,
            type: ProxyType.socks5,
            host: 'socks.example',
            port: 1080,
            routeTorrents: false,
          ),
        ),
        isFalse,
      );
      expect(service.proxyApplied, isFalse);
    });
  });
}
