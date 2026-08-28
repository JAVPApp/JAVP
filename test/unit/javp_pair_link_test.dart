import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';

void main() {
  group('javp pair link', () {
    test('round-trips host port token and pin', () {
      final uri = buildJavpPairLink(
        host: '192.168.1.20',
        port: 19287,
        token: 'abcTOKEN',
        pin: 'AB12CD',
      );
      expect(uri.scheme, 'javp');
      expect(uri.host, 'pair');
      final parsed = parseJavpPairLink(uri);
      expect(parsed, isNotNull);
      expect(parsed!.host, '192.168.1.20');
      expect(parsed.port, 19287);
      expect(parsed.token, 'abcTOKEN');
      expect(parsed.pin, 'AB12CD');
      expect(parsed.authSecret, 'abcTOKEN');
      expect(parsed.httpOrigin.toString(), 'http://192.168.1.20:19287');
    });

    test('accepts pin-only auth for manual entry', () {
      final parsed = parseJavpPairLink(
        Uri.parse('javp://pair?h=10.0.0.5&p=19290&c=XY9K2M'),
      );
      expect(parsed, isNotNull);
      expect(parsed!.token, isEmpty);
      expect(parsed.pin, 'XY9K2M');
      expect(parsed.authSecret, 'XY9K2M');
    });

    test('rejects incomplete links', () {
      expect(parseJavpPairLink(Uri.parse('javp://pair?h=1.2.3.4')), isNull);
      expect(
        parseJavpPairLink(Uri.parse('javp://pair?h=1.2.3.4&p=abc&t=x')),
        isNull,
      );
      expect(isJavpPairLink(Uri.parse('javp://add?type=m3u')), isFalse);
      expect(isJavpPairLink(Uri.parse('javp://pair?h=1.2.3.4&p=1&t=x')), isTrue);
    });

    test('parses path-style /pair fallback', () {
      final parsed = parseJavpPairLink(
        Uri.parse('/pair?h=192.168.1.20&p=19287&t=abcTOKEN&c=AB12CD'),
      );
      expect(isJavpPairLink(Uri.parse('/pair?h=1.2.3.4&p=1&t=x')), isTrue);
      expect(parsed, isNotNull);
      expect(parsed!.host, '192.168.1.20');
      expect(parsed.port, 19287);
      expect(parsed.token, 'abcTOKEN');
      expect(parsed.pin, 'AB12CD');
    });

    test('parses https://javp.app/pair App Link', () {
      final https = buildJavpPairHttpsLink(
        host: '192.168.1.20',
        port: 19287,
        token: 'tok',
        pin: 'AB12',
      );
      expect(https.toString(), startsWith('https://javp.app/pair?'));
      final parsed = parseJavpPairLink(https);
      expect(parsed, isNotNull);
      expect(parsed!.host, '192.168.1.20');
      expect(parsed.toLanBrowserLink().toString(),
          'http://192.168.1.20:19287/pair?t=tok');
      expect(
        isJavpPairLink(Uri.parse('https://evil.example/pair?h=1&p=1&t=x')),
        isFalse,
      );
    });
  });
}
