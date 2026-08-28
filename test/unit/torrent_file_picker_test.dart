import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/torrent/torrent_file_picker.dart';

void main() {
  List<TorrentFileCandidate> pack() => const [
        TorrentFileCandidate(
          index: 0,
          name: '[Group] Sample Anime - 01 (1080p) [ABC].mkv',
          path: '[Group] Sample Anime - 01 (1080p) [ABC].mkv',
          size: 100,
        ),
        TorrentFileCandidate(
          index: 1,
          name: '[Group] Sample Anime - 02 (1080p) [DEF].mkv',
          path: '[Group] Sample Anime - 02 (1080p) [DEF].mkv',
          size: 110,
        ),
        TorrentFileCandidate(
          index: 2,
          name: '[Group] Sample Anime - 10 (1080p) [GHI].mkv',
          path: '[Group] Sample Anime - 10 (1080p) [GHI].mkv',
          size: 120,
        ),
      ];

  test('picks episode by anime-style dash number', () {
    expect(
      pickTorrentFileIndex(files: pack(), episodeNumber: 2),
      1,
    );
    expect(
      pickTorrentFileIndex(files: pack(), episodeNumber: 10),
      2,
    );
  });

  test('prefers SxxExx over bare numbers', () {
    final files = const [
      TorrentFileCandidate(
        index: 0,
        name: 'Show.S01E02.1080p.mkv',
        path: 'Show.S01E02.1080p.mkv',
        size: 50,
      ),
      TorrentFileCandidate(
        index: 1,
        name: 'Show - 02 (1080p).mkv',
        path: 'Show - 02 (1080p).mkv',
        size: 50,
      ),
    ];
    expect(
      pickTorrentFileIndex(
        files: files,
        episodeNumber: 2,
        seasonNumber: 1,
      ),
      0,
    );
  });

  test('honours preferredFileName', () {
    expect(
      pickTorrentFileIndex(
        files: pack(),
        episodeNumber: 1,
        preferredFileName: 'Sample Anime - 10',
      ),
      2,
    );
  });

  test('returns null when no episode hint', () {
    expect(pickTorrentFileIndex(files: pack()), isNull);
  });
}
