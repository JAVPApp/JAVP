import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/library/series_watchlist.dart';

void main() {
  group('SeriesWatchlistTitle.showTitleFromReleaseName', () {
    test('skips a house prefix before the show', () {
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          'StreamCo | Sample Show S01E07',
        ),
        'Sample Show',
      );
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          'SC | Sample Show',
        ),
        'Sample Show',
      );
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          'StreamCo - Sample Show',
        ),
        'Sample Show',
      );
    });

    test('skips language and quality pipe segments', () {
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          'EN | Sample Show S01E01',
        ),
        'Sample Show',
      );
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName('1080p | Sample Show'),
        'Sample Show',
      );
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          'Sample Show | 1080p | WEB',
        ),
        'Sample Show',
      );
    });

    test('still strips release groups and season tokens', () {
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          '[Subs] Sample Show - 07 (1080p)',
        ),
        'Sample Show - 07',
      );
      expect(
        SeriesWatchlistTitle.showTitleFromReleaseName(
          'Sample Show S01E07 1080p',
        ),
        'Sample Show',
      );
    });
  });

  test('isPlatformLabel matches short single-token shelf labels', () {
    expect(SeriesWatchlistTitle.isPlatformLabel('StreamCo'), isTrue);
    expect(SeriesWatchlistTitle.isPlatformLabel('SC'), isTrue);
    // Short tokens are shelf-like; language skip is separate in skippable path.
    expect(SeriesWatchlistTitle.isPlatformLabel('EN'), isTrue);
    expect(SeriesWatchlistTitle.isPlatformLabel('Sample Show'), isFalse);
  });
}
