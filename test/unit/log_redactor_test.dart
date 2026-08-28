import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/diagnostics/log_redactor.dart';

void main() {
  late LogRedactor redactor;

  setUp(() => redactor = LogRedactor());

  group('Xtream', () {
    test('masks credentials in live/movie/series stream paths', () {
      for (final kind in ['live', 'movie', 'series']) {
        final scrubbed = redactor.scrub(
          'HLS master -> open http://panel.example:8080/$kind/joe/s3cr3tpass/1234.ts',
        );
        expect(scrubbed.contains('s3cr3tpass'), isFalse);
        expect(scrubbed.contains('joe'), isFalse);
        expect(scrubbed, contains('/$kind/***/***/1234.ts'));
      }
    });

    test('masks credentials in timeshift window paths', () {
      final scrubbed = redactor.scrub(
        'catchup http://panel.example:8080/timeshift/joe/s3cr3tpass/60/2026-08-10:12-00/1234.ts',
      );
      expect(scrubbed.contains('s3cr3tpass'), isFalse);
      expect(scrubbed, contains('/timeshift/***/***/60/2026-08-10:12-00/'));
    });

    test('masks player_api query credentials but keeps the action', () {
      final scrubbed = redactor.scrub(
        'GET http://panel.example:8080/player_api.php?username=joe&password=s3cr3tpass&action=get_live_streams',
      );
      expect(scrubbed.contains('s3cr3tpass'), isFalse);
      expect(scrubbed, contains('username=***'));
      expect(scrubbed, contains('password=***'));
      expect(scrubbed, contains('action=get_live_streams'));
    });

    test('masks percent-encoded passwords the exact-value pass cannot see', () {
      final scrubbed = redactor.scrub(
        'GET http://panel.example/player_api.php?username=joe&password=p%40ss%2Fword',
      );
      expect(scrubbed.contains('p%40ss%2Fword'), isFalse);
      expect(scrubbed, contains('password=***'));
    });
  });

  group('Jellyfin and Plex', () {
    test('masks the Jellyfin api_key query parameter', () {
      final scrubbed = redactor.scrub(
        'stream http://jelly.example/Videos/1/stream?static=true&api_key=abcdef1234567890',
      );
      expect(scrubbed.contains('abcdef1234567890'), isFalse);
      expect(scrubbed, contains('api_key=***'));
      expect(scrubbed, contains('static=true'));
    });

    test('masks X-Plex-Token as a query parameter and as a header', () {
      final query = redactor.scrub(
        'GET http://plex.local:32400/library/sections?X-Plex-Token=xyzt0ken123',
      );
      expect(query.contains('xyzt0ken123'), isFalse);
      expect(query, contains('X-Plex-Token=***'));

      final header = redactor.scrub(
        'headers {X-Plex-Token: xyzt0ken123, Accept: application/json}',
      );
      expect(header.contains('xyzt0ken123'), isFalse);
      expect(header, contains('Accept: application/json'));
    });

    test('masks bearer tokens with and without an Authorization header', () {
      final header = redactor.scrub(
        'headers {Authorization: Bearer eyJhbGciOi.payload.signature}',
      );
      expect(header.contains('eyJhbGciOi'), isFalse);
      expect(header.contains('signature'), isFalse);

      final bare = redactor.scrub('retry with Bearer eyJhbGciOi.payload.sig');
      expect(bare.contains('eyJhbGciOi'), isFalse);
      expect(bare, contains('Bearer ***'));
    });
  });

  group('playlists and proxies', () {
    test('masks userinfo embedded in an M3U or proxy URL', () {
      final scrubbed = redactor.scrub(
        'refresh http://joe:hunter2pass@iptv.example/list.m3u',
      );
      expect(scrubbed.contains('hunter2pass'), isFalse);
      expect(scrubbed, 'refresh http://***:***@iptv.example/list.m3u');
    });

    test('leaves an ordinary host:port URL untouched', () {
      const line = 'catalog failed for http://panel.example:8080/list.m3u8';
      expect(redactor.scrub(line), line);
    });
  });

  group('registered secrets', () {
    test('masks a registered secret in any shape', () {
      redactor.registerSecret('s3cr3tpass');
      final scrubbed = redactor.scrub(
        'auth failed (user joe, pass s3cr3tpass) via /custom/s3cr3tpass/path',
      );
      expect(scrubbed.contains('s3cr3tpass'), isFalse);
    });

    test('masks a registered secret inside a longer token', () {
      redactor.registerSecret('abcdef1234567890');
      redactor.registerSecret('abcdef12');
      final scrubbed = redactor.scrub('token abcdef1234567890 rejected');
      expect(scrubbed, 'token *** rejected');
    });

    test('ignores short values so the line stays readable', () {
      redactor.registerSecret('abc');
      expect(redactor.secretCount, 0);
      expect(redactor.scrub('abc is fine'), 'abc is fine');
    });

    test('deduplicates and forgets on request', () {
      redactor.registerSecret('s3cr3tpass');
      redactor.registerSecret('s3cr3tpass');
      expect(redactor.secretCount, 1);
      redactor.forgetSecrets();
      expect(redactor.scrub('pass s3cr3tpass'), 'pass s3cr3tpass');
    });
  });

  test('scrubs every credential in a multi-line stack trace', () {
    final scrubbed = redactor.scrub(
      'ClientException: http://panel.example/live/joe/s3cr3tpass/1.ts\n'
      '#0 XtreamClient.fetch (package:javp/services/iptv/xtream_client.dart:466)\n'
      '#1 retry api_key=abcdef1234567890',
    );
    expect(scrubbed.contains('s3cr3tpass'), isFalse);
    expect(scrubbed.contains('abcdef1234567890'), isFalse);
    expect(scrubbed, contains('xtream_client.dart:466'));
  });

  test('leaves an empty line alone', () {
    expect(redactor.scrub(''), '');
  });
}
