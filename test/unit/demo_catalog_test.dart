import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/services/catalog/custom_catalog_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled demo catalog parses as open movies + series', () {
    final file = File('assets/demo/catalog.json');
    expect(file.existsSync(), isTrue);
    final body = file.readAsStringSync();
    final parsed = CustomCatalogClient().parse(
      body,
      sourceId: LibraryProvider.demoSourceId,
    );

    expect(parsed.name, contains('Demo'));
    expect(parsed.version, 1);
    final titles = parsed.items.map((i) => i.title).toSet();
    expect(titles, contains('Big Buck Bunny'));
    expect(titles, contains('Sintel'));
    expect(titles, contains('Sample Shorts'));
    expect(
      parsed.items.any((i) => i.kind.name == 'series'),
      isTrue,
    );
    expect(
      parsed.items.where((i) => i.kind.name == 'live').length,
      greaterThanOrEqualTo(2),
    );
    // Streams must be HTTPS open samples — never magnets / private hosts.
    for (final item in parsed.items) {
      final url = item.playUrl;
      if (url == null || url.isEmpty) continue;
      expect(url.startsWith('https://'), isTrue, reason: item.title);
      expect(url.contains('magnet:'), isFalse);
    }
    expect(jsonDecode(body), isA<Map>());
  });

  test('asset:// demo URL maps to bundled asset path helpers', () {
    expect(
      LibraryProvider.isAssetCatalogUrl(LibraryProvider.demoCatalogUrl),
      isTrue,
    );
    expect(LibraryProvider.isAssetCatalogUrl('https://javp.app/demo/catalog.json'),
        isFalse);
    expect(LibraryProvider.demoCatalogAsset, 'assets/demo/catalog.json');
  });

  test('demo asset is registered for rootBundle', () async {
    final body =
        await rootBundle.loadString(LibraryProvider.demoCatalogAsset);
    final parsed = CustomCatalogClient().parse(
      body,
      sourceId: LibraryProvider.demoSourceId,
    );
    expect(parsed.items, isNotEmpty);
  });
}
