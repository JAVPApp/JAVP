import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';

void main() {
  group('IptvSearchQuery', () {
    test('tokens strip punctuation and keep AND pieces', () {
      expect(IptvSearchQuery.tokens('  SPORTS network! '), ['sports', 'network']);
      expect(IptvSearchQuery.tokens('newsnet'), ['newsnet']);
      expect(IptvSearchQuery.tokens('***'), isEmpty);
      expect(IptvSearchQuery.tokens('al-jazeera'), ['al', 'jazeera']);
      expect(IptvSearchQuery.tokens('foo - bar'), ['foo', 'bar']);
    });

    test('ftsMatchQuery uses prefix wildcards', () {
      expect(IptvSearchQuery.ftsMatchQuery('newsnet'), 'newsnet*');
      expect(IptvSearchQuery.ftsMatchQuery('sports network'), 'sports* network*');
      expect(IptvSearchQuery.ftsMatchQuery('al-jazeera'), 'al* jazeera*');
      expect(IptvSearchQuery.ftsMatchQuery('foo - bar'), 'foo* bar*');
    });

    test('relevance prefers cleaned live titles over playlist prefixes', () {
      MediaItem live(String id, String title) {
        return MediaItem(
          id: id,
          title: title,
          playUrl: 'http://x/$id',
          kind: MediaKind.live,
          origin: MediaOrigin.iptvXtream,
          sourceId: 'src',
        );
      }

      final newsnet = live('newsnet', 'US | NewsNet HD');
      final extra = live('extra', 'ZZ Sports Extra NewsNet Newsroom');
      expect(
        IptvSearchQuery.relevance('newsnet', newsnet),
        lessThan(IptvSearchQuery.relevance('newsnet', extra)),
      );
      expect(IptvSearchQuery.rankTitle(newsnet), 'newsnet');
    });

    test('normalize folds diacritics and punctuation', () {
      expect(IptvSearchQuery.normalize('Café Network'), 'cafe network');
      expect(IptvSearchQuery.normalize('US| NewsNet HD'), 'us newsnet hd');
      expect(IptvSearchQuery.tokens('Café network!'), ['cafe', 'network']);
    });

    test('scoreNorm prefers prefix over later contains', () {
      expect(
        IptvSearchQuery.scoreNorm('newsnet international', ['newsnet']),
        greaterThan(
          IptvSearchQuery.scoreNorm('sports extra newsnet news', ['newsnet']),
        ),
      );
      expect(IptvSearchQuery.scoreNorm('sports network', ['zebra']), 0);
    });

    test('hay and rankTitle keep title years searchable', () {
      final withField = MediaItem(
        id: '1',
        title: 'Always a Catch',
        playUrl: 'https://example.com/1',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'iptv',
        year: 2021,
      );
      final fromTitle = MediaItem(
        id: '2',
        title: 'Always a Catch - 2021',
        playUrl: 'https://example.com/2',
        kind: MediaKind.vod,
        origin: MediaOrigin.iptvXtream,
        sourceId: 'iptv',
      );
      expect(IptvSearchQuery.yearToken(withField), '2021');
      expect(IptvSearchQuery.yearToken(fromTitle), '2021');
      expect(IptvSearchQuery.hayForItem(withField).contains('2021'), isTrue);
      expect(IptvSearchQuery.hayForItem(fromTitle).contains('2021'), isTrue);
      expect(IptvSearchQuery.rankTitle(fromTitle).contains('2021'), isTrue);
      expect(IptvSearchQuery.scoreItem('2021', fromTitle), greaterThan(0));
    });
  });
}
