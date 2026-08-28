import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/iptv/epg_parser.dart';

void main() {
  test('parses XMLTV programmes and finds currently airing show', () {
    final now = DateTime.utc(2026, 8, 8, 15, 0, 0);
    final start = '20260808143000 +0000';
    final stop = '20260808160000 +0000';
    final xml =
        '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="news1">
    <display-name>News One</display-name>
  </channel>
  <programme start="$start" stop="$stop" channel="news1">
    <title>Evening Bulletin</title>
    <desc>Headlines</desc>
    <icon src="https://cdn.example/bulletin.jpg" />
  </programme>
</tv>
''';

    final parser = EpgParser();
    final doc = parser.parseDocument(xml);
    expect(doc.programs, hasLength(1));
    expect(doc.programs.first.title, 'Evening Bulletin');
    expect(doc.programs.first.imageUrl, 'https://cdn.example/bulletin.jpg');
    expect(doc.programs.first.isAiringAt(now), isTrue);
    expect(doc.channelNames['news1'], 'News One');

    final programs = parser.parse(xml);
    final current = parser.currentByChannel(programs, at: now);
    expect(current['news1']?.title, 'Evening Bulletin');
  });

  test('decodeEpgResponseBody does not gzip-decode already-plain XMLTV', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <programme start="20260808143000 +0000" stop="20260808160000 +0000" channel="news1">
    <title>Plain Show</title>
  </programme>
</tv>
''';
    final decoded = decodeEpgResponseBody(
      utf8.encode(xml),
      url: 'https://example.com/guide.xml',
      contentEncoding: 'gzip',
    );
    final doc = EpgParser().parseDocument(decoded);
    expect(doc.programs.single.title, 'Plain Show');
  });

  test('parses XMLTV with an external xmltv.dtd doctype', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv>
  <channel id="news1"><display-name>News One</display-name></channel>
  <programme start="20260808143000 +0000" stop="20260808160000 +0000" channel="news1">
    <title>Doctype Bulletin</title>
  </programme>
</tv>
''';
    final doc = EpgParser().parseDocument(xml);
    expect(doc.programs.single.title, 'Doctype Bulletin');
    expect(doc.channelNames['news1'], 'News One');
  });

  test('decodeEpgResponseBody inflates gzip XMLTV payloads', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <programme start="20260808143000 +0000" stop="20260808160000 +0000" channel="news1">
    <title>Gzipped Show</title>
  </programme>
</tv>
''';
    final gz = gzip.encode(utf8.encode(xml));
    final decoded = decodeEpgResponseBody(
      gz,
      url: 'https://example.com/guide.xml.gz',
    );
    final doc = EpgParser().parseDocument(decoded);
    expect(doc.programs.single.title, 'Gzipped Show');
  });

  test('splitEpgUrls handles comma-separated x-tvg-url lists', () {
    expect(splitEpgUrls(null), isEmpty);
    expect(splitEpgUrls(''), isEmpty);
    expect(
      splitEpgUrls(
        'https://a.example/guide.xml.gz, https://b.example/guide.xml.gz',
      ),
      ['https://a.example/guide.xml.gz', 'https://b.example/guide.xml.gz'],
    );
    expect(splitEpgUrls('https://only.example/epg.xml'), [
      'https://only.example/epg.xml',
    ]);
  });

  test('parseEpgResponseInIsolate rejects oversized decoded guides', () async {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <programme start="20260808143000 +0000" stop="20260808160000 +0000" channel="news1">
    <title>Too Big</title>
  </programme>
</tv>
''';
    final result = await parseEpgResponseInIsolate(
      bytes: utf8.encode(xml),
      url: 'https://example.com/huge.xml',
      maxDecodedChars: 32,
    );
    expect(result.programs, isEmpty);
    expect(result.channelNames, isEmpty);
  });

  test('default decoded EPG cap is above former 25MB cutoff', () {
    // JP IPTV guide.xml.gz expands to ~26.6M Dart chars / ~43MB UTF-8.
    expect(kMaxEpgDecodedChars, greaterThan(26 * 1024 * 1024));
    expect(kMaxEpgDownloadBytes, greaterThan(8 * 1024 * 1024));
  });

  test(
    'parseEpgResponseInIsolate returns programmes via packed transfer',
    () async {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="news1"><display-name>News One</display-name></channel>
  <programme start="20260808143000 +0000" stop="20260808160000 +0000" channel="news1">
    <title>Packed Bulletin</title>
    <desc>Headlines</desc>
  </programme>
</tv>
''';
      final result = await parseEpgResponseInIsolate(
        bytes: utf8.encode(xml),
        url: 'https://example.com/guide.xml',
      );
      expect(result.programs, hasLength(1));
      expect(result.programs.single.title, 'Packed Bulletin');
      expect(result.programs.single.description, 'Headlines');
      expect(result.channelNames['news1'], 'News One');
    },
  );

  test(
    'ingestEpgPackedInIsolate streams SQL maps without a programme list',
    () async {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="news1"><display-name>News One</display-name></channel>
  <programme start="20260808143000 +0000" stop="20260808160000 +0000" channel="news1">
    <title>Ingested Bulletin</title>
  </programme>
</tv>
''';
      final rows = <Map<String, Object?>>[];
      final ingested = await ingestEpgPackedInIsolate(
        bytes: utf8.encode(xml),
        url: 'https://example.com/guide.xml',
        onChunk: (chunk) async => rows.addAll(chunk),
      );
      expect(ingested.programCount, 1);
      expect(ingested.channelNames['news1'], 'News One');
      expect(rows, hasLength(1));
      expect(rows.single['channel_id'], 'news1');
      expect(rows.single['title'], 'Ingested Bulletin');
      expect(rows.single.containsKey('start_ms'), isTrue);
    },
  );

  test('ingestEpgPackedInIsolate throws instead of ingesting 0 on parse failure',
      () async {
    await expectLater(
      ingestEpgPackedInIsolate(
        bytes: utf8.encode('not xmltv at all'),
        url: 'https://example.com/broken.xml',
        onChunk: (_) async {},
      ),
      throwsA(isA<StateError>()),
    );
  });
}
