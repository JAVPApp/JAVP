import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/pairing/source_pairing_server.dart';

void main() {
  group('parsePairingPayload', () {
    test('parses m3u with optional epg', () {
      final parsed = parsePairingPayload({
        'type': 'm3u',
        'name': 'Sports',
        'url': 'https://example.com/list.m3u',
        'epgUrl': 'https://example.com/epg.xml',
      });
      expect(parsed.type, IptvSourceType.m3u);
      expect(parsed.name, 'Sports');
      expect(parsed.url, 'https://example.com/list.m3u');
      expect(parsed.epgUrl, 'https://example.com/epg.xml');
    });

    test('parses xtream credentials', () {
      final parsed = parsePairingPayload({
        'type': 'xtream',
        'serverUrl': 'http://host:8080',
        'username': 'u',
        'password': 'p',
      });
      expect(parsed.type, IptvSourceType.xtream);
      expect(parsed.name, 'Xtream Source');
      expect(parsed.serverUrl, 'http://host:8080');
      expect(parsed.username, 'u');
      expect(parsed.password, 'p');
    });

    test('parses plex manual token', () {
      final parsed = parsePairingPayload({
        'type': 'plex',
        'serverUrl': 'http://192.168.1.10:32400',
        'password': 'token',
      });
      expect(parsed.type, IptvSourceType.plex);
      expect(parsed.password, 'token');
    });

    test('rejects missing url', () {
      expect(
        () => parsePairingPayload({'type': 'custom', 'url': '  '}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects unknown type', () {
      expect(
        () => parsePairingPayload({'type': 'ftp'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('parses javp://add quicklink', () {
      final parsed = parsePairingPayload({
        'javpLink':
            'javp://add?type=custom&url=https%3A%2F%2Fcatalog.example%2Fcatalog%2Fcatalog&name=Custom catalog',
      });
      expect(parsed.type, IptvSourceType.custom);
      expect(parsed.url, 'https://catalog.example/catalog/catalog');
      expect(parsed.name, 'Custom catalog');
    });

    test('parses iptv-org m3u quicklink via link field', () {
      final parsed = parsePairingPayload({
        'link':
            'javp://add?type=m3u&url=https%3A%2F%2Fiptv-org.github.io%2Fiptv%2Findex.country.m3u&name=IPTV-org',
      });
      expect(parsed.type, IptvSourceType.m3u);
      expect(
        parsed.url,
        'https://iptv-org.github.io/iptv/index.country.m3u',
      );
      expect(parsed.name, 'IPTV-org');
    });

    test('rejects invalid javpLink', () {
      expect(
        () => parsePairingPayload({'javpLink': 'https://example.com'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
