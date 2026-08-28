import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/deep_links/javp_source_link.dart';

void main() {
  group('buildJavpSourceAddLink', () {
    test('round-trips custom catalog deep link', () {
      final link = buildJavpSourceAddLink(
        type: IptvSourceType.custom,
        url: 'https://example.com/catalog.json',
        name: 'My Catalog',
      );
      final parsed = parseJavpSourceAddLink(link);
      expect(parsed, isNotNull);
      expect(parsed!.type, IptvSourceType.custom);
      expect(parsed.url, 'https://example.com/catalog.json');
      expect(parsed.name, 'My Catalog');
    });

    test('round-trips m3u deep link', () {
      final link = buildJavpSourceAddLink(
        type: IptvSourceType.m3u,
        url: 'https://example.com/list.m3u',
        name: 'My IPTV',
      );
      final parsed = parseJavpSourceAddLink(link);
      expect(parsed, isNotNull);
      expect(parsed!.type, IptvSourceType.m3u);
      expect(parsed.url, 'https://example.com/list.m3u');
      expect(parsed.name, 'My IPTV');
    });

    test('includes optional epg', () {
      final link = buildJavpSourceAddLink(
        type: IptvSourceType.m3u,
        url: 'https://example.com/list.m3u',
        name: 'Demo',
        epgUrl: 'https://example.com/epg.xml',
      );
      final parsed = parseJavpSourceAddLink(link)!;
      expect(parsed.epgUrl, 'https://example.com/epg.xml');
    });

    test('round-trips xtream deep link', () {
      final link = buildJavpSourceAddLink(
        type: IptvSourceType.xtream,
        url: 'http://example.com:8080',
        name: 'My XC',
        username: 'user',
        password: 'pass',
        alternateServerUrl: 'http://backup.example.com',
      );
      final parsed = parseJavpSourceAddLink(link)!;
      expect(parsed.type, IptvSourceType.xtream);
      expect(parsed.url, 'http://example.com:8080');
      expect(parsed.username, 'user');
      expect(parsed.password, 'pass');
      expect(parsed.alternateServerUrl, 'http://backup.example.com');
      expect(parsed.name, 'My XC');
    });
  });

  group('buildJavpSourceAddHttpsLink', () {
    test('builds https://javp.app/add and round-trips', () {
      final link = buildJavpSourceAddHttpsLink(
        type: IptvSourceType.custom,
        url: 'https://example.com/catalog.json',
        name: 'Demo',
      );
      expect(link.scheme, 'https');
      expect(link.host, 'javp.app');
      expect(link.path, '/add');
      final parsed = parseJavpSourceAddLink(link)!;
      expect(parsed.type, IptvSourceType.custom);
      expect(parsed.url, 'https://example.com/catalog.json');
      expect(parsed.name, 'Demo');
    });

    test('toHttpsLink matches builder', () {
      const req = JavpSourceAddRequest(
        type: IptvSourceType.m3u,
        url: 'https://example.com/list.m3u',
        name: 'IPTV',
        epgUrl: 'https://example.com/epg.xml',
      );
      expect(
        req.toHttpsLink().toString(),
        buildJavpSourceAddHttpsLink(
          type: IptvSourceType.m3u,
          url: 'https://example.com/list.m3u',
          name: 'IPTV',
          epgUrl: 'https://example.com/epg.xml',
        ).toString(),
      );
    });
  });

  group('parseJavpSourceAddLink', () {
    test('parses encoded custom catalog link from catalog.example', () {
      final uri = Uri.parse(
        'javp://add?type=custom&url=https%3A%2F%2Fcatalog.example%2Fcatalog%2Fcatalog'
        '&name=AniList%20%2B%20Catalog',
      );
      final req = parseJavpSourceAddLink(uri);
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.custom);
      expect(req.url, 'https://catalog.example/catalog/catalog');
      expect(req.name, 'AniList + Catalog');
    });

    test('parses javp://add/ with go_router-normalized path', () {
      final uri = Uri.parse(
        'javp://add/?type=custom&url=https://catalog.example/catalog/catalog&name=Test',
      );
      final req = parseJavpSourceAddLink(uri);
      expect(req, isNotNull);
      expect(req!.url, 'https://catalog.example/catalog/catalog');
      expect(req.name, 'Test');
    });

    test('parses path-style /add fallback', () {
      final uri = Uri.parse(
        '/add?type=m3u&url=https://example.com/list.m3u&name=IPTV&epg=https://example.com/epg.xml',
      );
      final req = parseJavpSourceAddLink(uri);
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.m3u);
      expect(req.url, 'https://example.com/list.m3u');
      expect(req.epgUrl, 'https://example.com/epg.xml');
    });

    test('parses https://javp.app/add App Link', () {
      final uri = Uri.parse(
        'https://javp.app/add?type=custom&url=https%3A%2F%2Fexample.com%2Fc.json&name=Demo',
      );
      final req = parseJavpSourceAddLink(uri);
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.custom);
      expect(req.url, 'https://example.com/c.json');
      expect(req.name, 'Demo');
    });

    test('accepts www.javp.app host', () {
      expect(
        isJavpAddSourceLink(
          Uri.parse(
            'https://www.javp.app/add?type=custom&url=https://example.com/c',
          ),
        ),
        isTrue,
      );
    });

    test('rejects https add on other hosts', () {
      expect(
        isJavpAddSourceLink(
          Uri.parse(
            'https://evil.example/add?type=custom&url=https://example.com/c',
          ),
        ),
        isFalse,
      );
      expect(
        parseJavpSourceAddLink(
          Uri.parse(
            'https://evil.example/add?type=custom&url=https://example.com/c',
          ),
        ),
        isNull,
      );
    });

    test('rejects missing url', () {
      expect(
        parseJavpSourceAddLink(Uri.parse('javp://add?type=custom')),
        isNull,
      );
    });

    test('rejects unknown hosts', () {
      expect(
        parseJavpSourceAddLink(
          Uri.parse('javp://play?type=custom&url=https://example.com/c'),
        ),
        isNull,
      );
    });

    test('parses xtream link with alt DNS', () {
      final uri = Uri.parse(
        'javp://add?type=xtream'
        '&url=http%3A%2F%2Fxc.example.com'
        '&username=demo_user'
        '&password=demo_pass'
        '&alt=http%3A%2F%2Fxc-alt.example.com'
        '&name=IPTV',
      );
      final req = parseJavpSourceAddLink(uri);
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.xtream);
      expect(req.url, 'http://xc.example.com');
      expect(req.username, 'demo_user');
      expect(req.password, 'demo_pass');
      expect(req.alternateServerUrl, 'http://xc-alt.example.com');
      expect(req.name, 'IPTV');
      expect(req.typeLabel, 'Xtream Codes');
      expect(req.confirmSummary, isNot(contains('demo_pass')));
      expect(req.confirmSummary, contains('demo_user'));
    });

    test('parses xtream aliases (xc, server, user, pass)', () {
      final uri = Uri.parse(
        'javp://add?type=xc&server=https://portal.example:8080'
        '&user=alice&pass=secret',
      );
      final req = parseJavpSourceAddLink(uri);
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.xtream);
      expect(req.url, 'https://portal.example:8080');
      expect(req.username, 'alice');
      expect(req.password, 'secret');
      expect(req.alternateServerUrl, isNull);
    });

    test('rejects xtream without credentials', () {
      expect(
        parseJavpSourceAddLink(
          Uri.parse('javp://add?type=xtream&url=http://example.com'),
        ),
        isNull,
      );
      expect(
        parseJavpSourceAddLink(
          Uri.parse(
            'javp://add?type=xtream&url=http://example.com&password=x',
          ),
        ),
        isNull,
      );
    });
  });

  group('parseJavpSourceAddLinkText', () {
    test('unwraps pasted https://javp.app/add catalog share link', () {
      final req = parseJavpSourceAddLinkText(
        '  https://javp.app/add?type=custom'
        '&url=https%3A%2F%2Fexample.com%2Fcatalog.json'
        '&name=Shared%20Catalog  ',
      );
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.custom);
      expect(req.url, 'https://example.com/catalog.json');
      expect(req.name, 'Shared Catalog');
    });

    test('unwraps pasted javp://add catalog share link', () {
      final req = parseJavpSourceAddLinkText(
        'javp://add?type=custom&url=https://cdn.example/c.json&name=Mine',
      );
      expect(req, isNotNull);
      expect(req!.type, IptvSourceType.custom);
      expect(req.url, 'https://cdn.example/c.json');
      expect(req.name, 'Mine');
    });

    test('leaves plain catalog URLs alone', () {
      expect(
        parseJavpSourceAddLinkText('https://example.com/catalog.json'),
        isNull,
      );
      expect(parseJavpSourceAddLinkText(''), isNull);
      expect(parseJavpSourceAddLinkText('   '), isNull);
    });
  });

  group('isExternalDeepLink', () {
    test('detects javp add links', () {
      expect(
        isExternalDeepLink(
          Uri.parse('javp://add?type=custom&url=https://example.com/c'),
        ),
        isTrue,
      );
      expect(
        isExternalDeepLink(
          Uri.parse('/add?type=custom&url=https://x.com/c'),
        ),
        isTrue,
      );
      expect(
        isExternalDeepLink(
          Uri.parse(
            'https://javp.app/add?type=custom&url=https://example.com/c',
          ),
        ),
        isTrue,
      );
      expect(isExternalDeepLink(Uri.parse('/home')), isFalse);
    });

    test('detects javp pair links including path-style', () {
      expect(
        isExternalDeepLink(
          Uri.parse('javp://pair?h=192.168.1.20&p=19287&t=tok'),
        ),
        isTrue,
      );
      expect(
        isExternalDeepLink(
          Uri.parse('/pair?h=192.168.1.20&p=19287&t=tok'),
        ),
        isTrue,
      );
    });

    test('https javp.app/add is not treated as media open', () {
      final uri = Uri.parse(
        'https://javp.app/add?type=custom&url=https://example.com/c',
      );
      expect(isExternalMediaScheme(uri), isFalse);
      expect(isJavpAddSourceLink(uri), isTrue);
    });
  });
}
