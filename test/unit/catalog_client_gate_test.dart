import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/catalog/catalog_client_gate.dart';

void main() {
  const androidPhone = CatalogClientProfile(
    appVersion: '0.4.3+57',
    platform: 'android',
    device: 'mobile',
    capabilities: ['torrents', 'downloads'],
  );
  const androidTv = CatalogClientProfile(
    appVersion: '0.4.3+57',
    platform: 'android',
    device: 'tv',
    capabilities: ['torrents'],
  );
  const linuxDesktop = CatalogClientProfile(
    appVersion: '0.4.3+57',
    platform: 'linux',
    device: 'desktop',
  );
  const tizenTv = CatalogClientProfile(
    appVersion: '0.4.3',
    platform: 'tizen',
    device: 'tv',
  );

  test('empty gate allows any client', () {
    expect(
      catalogClientAllows(const CatalogClientGate(), androidPhone),
      isTrue,
    );
    expect(catalogClientAllows(const CatalogClientGate(), null), isTrue);
  });

  test('null profile skips platform and capability checks', () {
    const gate = CatalogClientGate(
      platforms: ['android'],
      requires: ['torrents'],
      minVersion: '9.0.0',
    );
    expect(catalogClientAllows(gate, null), isTrue);
  });

  test('platforms allow-list matches OS and form-factor tokens', () {
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['android']),
        androidTv,
      ),
      isTrue,
    );
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['tv']),
        androidTv,
      ),
      isTrue,
    );
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['android_tv']),
        androidTv,
      ),
      isTrue,
    );
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['android_tv']),
        androidPhone,
      ),
      isFalse,
    );
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['desktop']),
        linuxDesktop,
      ),
      isTrue,
    );
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['android']),
        linuxDesktop,
      ),
      isFalse,
    );
    expect(
      catalogClientAllows(
        const CatalogClientGate(platforms: ['tizen', 'webos']),
        tizenTv,
      ),
      isTrue,
    );
  });

  test('platform aliases normalize', () {
    expect(normalizeCatalogPlatform('WIN'), 'windows');
    expect(normalizeCatalogPlatform('mac'), 'macos');
    expect(normalizeCatalogPlatform('samsung'), 'tizen');
    expect(normalizeCatalogPlatform('lg'), 'webos');
    expect(normalizeCatalogPlatform('androidtv'), 'android_tv');
  });

  test('requires torrents rejects clients without the engine', () {
    const gate = CatalogClientGate(requires: ['torrents']);
    expect(catalogClientAllows(gate, androidPhone), isTrue);
    expect(catalogClientAllows(gate, linuxDesktop), isFalse);
    expect(catalogClientAllows(gate, tizenTv), isFalse);
    expect(
      catalogClientAllows(
        const CatalogClientGate(requires: ['p2p']),
        androidPhone,
      ),
      isTrue,
    );
  });

  test('unknown requires are ignored', () {
    expect(
      catalogClientAllows(
        const CatalogClientGate(requires: ['future-feature']),
        androidPhone,
      ),
      isTrue,
    );
  });

  test('item min_version skips rather than matching older apps', () {
    const gate = CatalogClientGate(minVersion: '0.5.0');
    expect(
      catalogClientMismatch(gate, androidPhone),
      CatalogClientMismatch.version,
    );
    expect(
      catalogClientAllows(gate, androidPhone.copyWithVersion('0.5.0')),
      isTrue,
    );
  });

  test('playUrlRequiresTorrents detects magnets', () {
    expect(playUrlRequiresTorrents('magnet:?xt=urn:btih:abc'), isTrue);
    expect(playUrlRequiresTorrents('https://cdn.example.com/a.mp4'), isFalse);
    expect(playUrlRequiresTorrents('/tmp/file.torrent'), isTrue);
    expect(
      playUrlRequiresTorrents('https://cdn.example.com/a.torrent?token=a+b/c'),
      isTrue,
    );
    expect(
      playUrlRequiresTorrents('https://cdn.example.com/a.torrent'),
      isTrue,
    );
  });

  test('CatalogUnsupportedException mentions torrents when required', () {
    const error = CatalogUnsupportedException(
      requires: ['torrents'],
      reason: CatalogClientMismatch.capability,
    );
    expect(error.toString(), contains('torrent playback'));
  });

  test('fromJson reads aliases', () {
    final gate = CatalogClientGate.fromJson({
      'minVersion': '0.4.3',
      'platform': 'android,tv',
      'needs': 'torrents',
    });
    expect(gate.minVersion, '0.4.3');
    expect(gate.platforms, ['android', 'tv']);
    expect(gate.requires, ['torrents']);
  });

  test('named sources parse id and gate', () {
    final sources = catalogNamedSourcesFromJson([
      {'id': 'http', 'name': 'CDN'},
      {
        'id': 'p2p',
        'requires': ['torrents'],
      },
    ]);
    expect(sources, hasLength(2));
    expect(sources.first.id, 'http');
    expect(sources.last.gate.requires, ['torrents']);
  });

  test('profile query params are prefixed', () {
    expect(androidTv.queryParameters, {
      'javp_version': '0.4.3+57',
      'javp_platform': 'android',
      'javp_device': 'tv',
      'javp_capabilities': 'torrents',
    });
    expect(androidTv.httpHeaders['X-JAVP-Platform'], 'android');
    expect(androidTv.httpHeaders['X-JAVP-Capabilities'], contains('torrents'));
  });

  test('android-only torrent source stays available on desktop', () {
    const gate = CatalogClientGate(
      platforms: ['android'],
      requires: ['torrents'],
    );
    const windowsDesktop = CatalogClientProfile(
      appVersion: '0.5.1+64',
      platform: 'windows',
      device: 'desktop',
      capabilities: ['torrents'],
    );
    expect(catalogClientAllows(gate, windowsDesktop), isTrue);
    expect(catalogClientAllows(gate, linuxDesktop), isFalse);
    expect(catalogClientAllows(gate, androidPhone), isTrue);
  });
}

extension on CatalogClientProfile {
  CatalogClientProfile copyWithVersion(String version) {
    return CatalogClientProfile(
      appVersion: version,
      platform: platform,
      device: device,
      capabilities: capabilities,
    );
  }
}
