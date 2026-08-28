/// Picks a file index inside a multi-file torrent (batch anime packs, etc.).
///
/// Returns `null` when the caller should keep the engine default
/// (largest streamable file).
int? pickTorrentFileIndex({
  required List<TorrentFileCandidate> files,
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
}) {
  if (files.isEmpty) return null;

  final candidates = files
      .where((f) => f.isStreamable || looksLikeVideoFile(f.name) || looksLikeVideoFile(f.path))
      .toList();
  final pool = candidates.isNotEmpty ? candidates : files;

  final hint = preferredFileName?.trim();
  if (hint != null && hint.isNotEmpty) {
    final lower = hint.toLowerCase();
    final exact = pool.where((f) {
      final name = f.name.toLowerCase();
      final path = f.path.toLowerCase();
      return name == lower ||
          path == lower ||
          path.endsWith('/$lower') ||
          path.endsWith('\\$lower') ||
          name.contains(lower) ||
          path.contains(lower);
    }).toList();
    if (exact.isNotEmpty) {
      exact.sort((a, b) => b.size.compareTo(a.size));
      return exact.first.index;
    }
  }

  final ep = episodeNumber;
  if (ep == null || ep <= 0) return null;

  var bestScore = 0;
  TorrentFileCandidate? best;
  for (final f in pool) {
    final score = episodeMatchScore(
      name: f.name,
      path: f.path,
      episodeNumber: ep,
      seasonNumber: seasonNumber,
    );
    if (score <= 0) continue;
    if (best == null ||
        score > bestScore ||
        (score == bestScore && f.size > best.size)) {
      bestScore = score;
      best = f;
    }
  }
  return best?.index;
}

class TorrentFileCandidate {
  const TorrentFileCandidate({
    required this.index,
    required this.name,
    required this.path,
    required this.size,
    this.isStreamable = true,
  });

  final int index;
  final String name;
  final String path;
  final int size;
  final bool isStreamable;
}

bool looksLikeVideoFile(String value) {
  final lower = value.toLowerCase();
  return lower.endsWith('.mkv') ||
      lower.endsWith('.mp4') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.m4v') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.m2ts');
}

/// Higher is better. `0` means no match.
int episodeMatchScore({
  required String name,
  required String path,
  required int episodeNumber,
  int? seasonNumber,
}) {
  final text = '$path/$name';
  final ep = episodeNumber;
  final ep2 = ep.toString().padLeft(2, '0');
  final ep3 = ep.toString().padLeft(3, '0');
  final season = seasonNumber != null && seasonNumber > 0 ? seasonNumber : null;
  final s2 = season?.toString().padLeft(2, '0');

  var score = 0;

  if (season != null && s2 != null) {
    final patterns = <RegExp>[
      RegExp('s${s2}e$ep2', caseSensitive: false),
      RegExp('s${season}e$ep\\b', caseSensitive: false),
      RegExp('${season}x$ep2', caseSensitive: false),
      RegExp('${season}x$ep\\b', caseSensitive: false),
    ];
    for (final p in patterns) {
      if (p.hasMatch(text)) score = score < 100 ? 100 : score;
    }
  }

  final epPatterns = <(RegExp, int)>[
    (RegExp('[^\\d]E0*$ep(?!\\d)', caseSensitive: false), 80),
    (RegExp('EP(?:ISODE)?[\\s._-]*0*$ep(?!\\d)', caseSensitive: false), 75),
    // Anime pack style: "Title - 01 (1080p)" / "Title - 01 ["
    (RegExp('[\\s._-]0*$ep(?=\\s*[(\\[_.-]|\$)'), 70),
    (RegExp('\\[0*$ep\\]'), 65),
    (RegExp('(?<!\\d)0*$ep2(?!\\d)'), 40),
    if (ep3 != ep2) (RegExp('(?<!\\d)$ep3(?!\\d)'), 35),
  ];

  for (final entry in epPatterns) {
    if (!entry.$1.hasMatch(text)) continue;
    if (entry.$2 > score) score = entry.$2;
  }

  // Reject filenames whose only numeric hit is a known non-episode token.
  if (score > 0 && score <= 40) {
    final bare = RegExp('(?<!\\d)0*$ep(?!\\d)');
    final matches = bare.allMatches(text).toList();
    if (matches.isEmpty) return score;
    var onlyNoise = true;
    for (final m in matches) {
      final around = text.substring(
        (m.start - 4).clamp(0, text.length),
        (m.end + 4).clamp(0, text.length),
      );
      if (!RegExp(r'(?:480|720|1080|1440|2160|19\d{2}|20\d{2})').hasMatch(around)) {
        onlyNoise = false;
        break;
      }
    }
    if (onlyNoise) return 0;
  }

  return score;
}

bool _hasStrongEpisodeToken(String text, int ep, String ep2) {
  return RegExp('E0*$ep(?!\\d)', caseSensitive: false).hasMatch(text) ||
      RegExp('[\\s._-]0*$ep2(?=\\s*[(\\[_.-]|\$)').hasMatch(text);
}
