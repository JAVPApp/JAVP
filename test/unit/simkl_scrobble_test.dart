import 'package:flutter_test/flutter_test.dart';
import 'package:javp/models/simkl_models.dart';

void main() {
  test('movie history payload includes external ids under movies', () {
    final event = SimklScrobbleEvent(
      title: 'Sample Film',
      progress: 1,
      status: SimklWatchStatus.completed,
      year: 2010,
      tmdbId: 27205,
      imdbId: 'tt1375666',
      tvdbId: 12345,
      simklId: '472214',
    );

    expect(event.toHistoryPayload(), {
      'movies': [
        {
          'ids': {
            'simkl': 472214,
            'tmdb': 27205,
            'imdb': 'tt1375666',
            'tvdb': 12345,
          },
          'title': 'Sample Film',
          'year': 2010,
          'status': 'completed',
        },
      ],
    });
  });

  test('show watching status omits episode so history does not mark watched', () {
    final event = SimklScrobbleEvent(
      title: 'Sample Series',
      progress: 0.1,
      status: SimklWatchStatus.watching,
      year: 2008,
      tmdbId: 1396,
      seasonNumber: 1,
      episodeNumber: 1,
      isShow: true,
    );

    expect(event.toHistoryPayload(), {
      'shows': [
        {
          'ids': {'tmdb': 1396},
          'title': 'Sample Series',
          'year': 2008,
          'status': 'watching',
        },
      ],
    });
  });

  test('show episode payload nests season/episode and stays watching', () {
    final event = SimklScrobbleEvent(
      title: 'Sample Series',
      progress: 0.95,
      status: SimklWatchStatus.completed,
      year: 2008,
      tmdbId: 1396,
      seasonNumber: 1,
      episodeNumber: 1,
      isShow: true,
    );

    expect(event.toHistoryPayload(), {
      'shows': [
        {
          'ids': {'tmdb': 1396},
          'title': 'Sample Series',
          'year': 2008,
          // Episode watched ≠ series completed on Simkl.
          'status': 'watching',
          'seasons': [
            {
              'number': 1,
              'episodes': [
                {'number': 1},
              ],
            },
          ],
        },
      ],
    });
  });

  test('anime episode without season uses top-level episodes shorthand', () {
    final event = SimklScrobbleEvent(
      title: 'Sample Anime',
      progress: 1,
      status: SimklWatchStatus.completed,
      year: 2023,
      tmdbId: 209867,
      episodeNumber: 1,
      isShow: true,
    );

    expect(event.toHistoryPayload(), {
      'shows': [
        {
          'ids': {'tmdb': 209867},
          'title': 'Sample Anime',
          'year': 2023,
          'status': 'watching',
          'episodes': [
            {'number': 1},
          ],
        },
      ],
    });
  });

  test('show without episode numbers never sends completed', () {
    final event = SimklScrobbleEvent(
      title: 'Some Anime',
      progress: 1,
      status: SimklWatchStatus.completed,
      tmdbId: 42,
      isShow: true,
    );

    expect(event.toHistoryPayload(), {
      'shows': [
        {
          'ids': {'tmdb': 42},
          'title': 'Some Anime',
          'status': 'watching',
        },
      ],
    });
  });

  test('omits empty ids object when nothing known', () {
    final event = SimklScrobbleEvent(
      title: 'Unknown Local File',
      progress: 0.5,
      status: SimklWatchStatus.watching,
    );

    expect(event.toHistoryPayload(), {
      'movies': [
        {
          'title': 'Unknown Local File',
          'status': 'watching',
        },
      ],
    });
  });

  test('SimklPinSession parses verification_uri and defaults', () {
    final session = SimklPinSession.fromJson({
      'result': 'OK',
      'user_code': 'ABCDE',
      'verification_uri': 'https://simkl.com/pin',
      'expires_in': 900,
      'interval': 5,
    });

    expect(session.userCode, 'ABCDE');
    expect(session.verificationUri.toString(), 'https://simkl.com/pin');
    expect(session.expiresIn, 900);
    expect(session.interval, 5);
  });

  test('SimklPinSession falls back to verification_url', () {
    final session = SimklPinSession.fromJson({
      'user_code': 'ZZZZZ',
      'verification_url': 'https://simkl.com/pin/',
    });

    expect(session.userCode, 'ZZZZZ');
    expect(session.verificationUri.toString(), 'https://simkl.com/pin/');
    expect(session.expiresIn, 900);
    expect(session.interval, 5);
  });
}
