import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/letterboxd/letterboxd_csv.dart';

/// One film row from a Letterboxd export CSV (movies only by nature of LB).
class LetterboxdFilmRow {
  const LetterboxdFilmRow({
    required this.title,
    this.year,
    this.letterboxdUri,
    this.tmdbId,
    this.imdbId,
    this.listedAt,
    this.watchedAt,
    this.rating,
  });

  final String title;
  final int? year;
  final String? letterboxdUri;
  final int? tmdbId;
  final String? imdbId;
  final DateTime? listedAt;
  final DateTime? watchedAt;
  final double? rating;

  String get stableKey {
    final uri = letterboxdUri?.trim();
    if (uri != null && uri.isNotEmpty) return uri;
    if (tmdbId != null && tmdbId! > 0) return 'tmdb:$tmdbId';
    final imdb = imdbId?.trim();
    if (imdb != null && imdb.isNotEmpty) return imdb;
    final y = year ?? 0;
    return 'title:${title.toLowerCase().trim()}|$y';
  }
}

/// Parsed Letterboxd account export (ZIP or individual CSV).
class LetterboxdExportData {
  const LetterboxdExportData({
    this.watchlist = const [],
    this.watched = const [],
    this.diary = const [],
    this.ratings = const [],
  });

  final List<LetterboxdFilmRow> watchlist;
  final List<LetterboxdFilmRow> watched;
  final List<LetterboxdFilmRow> diary;
  final List<LetterboxdFilmRow> ratings;

  bool get isEmpty =>
      watchlist.isEmpty &&
      watched.isEmpty &&
      diary.isEmpty &&
      ratings.isEmpty;

  int get filmCount {
    final keys = <String>{};
    for (final list in [watchlist, watched, diary, ratings]) {
      for (final row in list) {
        keys.add(row.stableKey);
      }
    }
    return keys.length;
  }
}

/// Result of a user-driven Letterboxd export import.
class LetterboxdImportResult {
  const LetterboxdImportResult({
    this.watchlistCount = 0,
    this.completedCount = 0,
    this.cancelled = false,
    this.error,
  });

  final int watchlistCount;
  final int completedCount;
  final bool cancelled;
  final String? error;

  bool get ok => !cancelled && error == null;
}

/// Official Letterboxd path: user Settings → Data → Export (ZIP of CSVs).
/// Also accepts a single CSV (watchlist / watched / diary / ratings).
LetterboxdExportData parseLetterboxdExportBytes(
  Uint8List bytes, {
  String? fileNameHint,
}) {
  final name = (fileNameHint ?? '').toLowerCase();
  if (name.endsWith('.csv')) {
    return _parseNamedCsv(utf8.decode(bytes, allowMalformed: true), name);
  }
  // ZIP magic or unknown → try archive first, then plain CSV.
  if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
    return parseLetterboxdExportZip(bytes);
  }
  if (name.endsWith('.zip')) {
    return parseLetterboxdExportZip(bytes);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.contains(',') && text.toLowerCase().contains('name')) {
    return _inferCsvKind(text);
  }
  // Last resort: ZIP decode (some pickers omit extension).
  try {
    return parseLetterboxdExportZip(bytes);
  } catch (_) {
    return _inferCsvKind(text);
  }
}

LetterboxdExportData parseLetterboxdExportZip(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  var watchlist = <LetterboxdFilmRow>[];
  var watched = <LetterboxdFilmRow>[];
  var diary = <LetterboxdFilmRow>[];
  var ratings = <LetterboxdFilmRow>[];

  for (final file in archive) {
    if (!file.isFile) continue;
    final path = file.name.replaceAll('\\', '/').toLowerCase();
    // Skip deleted / orphaned mirrors — active lists live at the ZIP root.
    if (path.contains('/deleted/') || path.contains('/orphaned/')) {
      continue;
    }
    final base = path.split('/').last;
    if (!base.endsWith('.csv')) continue;
    final text = utf8.decode(file.content as List<int>, allowMalformed: true);
    if (base == 'watchlist.csv') {
      watchlist = _rowsFromCsv(text, preferWatchedDate: false);
    } else if (base == 'watched.csv') {
      watched = _rowsFromCsv(text, preferWatchedDate: true);
    } else if (base == 'diary.csv') {
      diary = _rowsFromCsv(text, preferWatchedDate: true);
    } else if (base == 'ratings.csv') {
      ratings = _rowsFromCsv(text, preferWatchedDate: false);
    }
  }

  return LetterboxdExportData(
    watchlist: watchlist,
    watched: watched,
    diary: diary,
    ratings: ratings,
  );
}

LetterboxdExportData _parseNamedCsv(String text, String name) {
  if (name.contains('watchlist')) {
    return LetterboxdExportData(
      watchlist: _rowsFromCsv(text, preferWatchedDate: false),
    );
  }
  if (name.contains('watched')) {
    return LetterboxdExportData(
      watched: _rowsFromCsv(text, preferWatchedDate: true),
    );
  }
  if (name.contains('diary')) {
    return LetterboxdExportData(
      diary: _rowsFromCsv(text, preferWatchedDate: true),
    );
  }
  if (name.contains('rating')) {
    return LetterboxdExportData(
      ratings: _rowsFromCsv(text, preferWatchedDate: false),
    );
  }
  return _inferCsvKind(text);
}

LetterboxdExportData _inferCsvKind(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('watched date') || lower.contains('watcheddate')) {
    return LetterboxdExportData(
      diary: _rowsFromCsv(text, preferWatchedDate: true),
    );
  }
  if (lower.contains('rating') && !lower.contains('letterboxd uri')) {
    return LetterboxdExportData(
      ratings: _rowsFromCsv(text, preferWatchedDate: false),
    );
  }
  // Default: treat as watchlist (Name/Year/URI).
  return LetterboxdExportData(
    watchlist: _rowsFromCsv(text, preferWatchedDate: false),
  );
}

List<LetterboxdFilmRow> _rowsFromCsv(
  String text, {
  required bool preferWatchedDate,
}) {
  final maps = parseLetterboxdCsv(text);
  final out = <LetterboxdFilmRow>[];
  for (final m in maps) {
    final title = (m['name'] ?? '').trim();
    if (title.isEmpty) continue;
    final year = int.tryParse(m['year'] ?? '');
    final uri = (m['letterboxdUri'] ?? '').trim();
    final tmdb = int.tryParse(m['tmdbId'] ?? '');
    var imdb = (m['imdbId'] ?? '').trim();
    if (imdb.isNotEmpty && !imdb.startsWith('tt')) {
      // Letterboxd sometimes exports bare numeric IMDb ids.
      if (RegExp(r'^\d+$').hasMatch(imdb)) {
        imdb = 'tt$imdb';
      }
    }
    final listedAt = DateTime.tryParse(m['date'] ?? '');
    final watchedAt = DateTime.tryParse(m['watchedDate'] ?? '') ??
        (preferWatchedDate ? listedAt : null);
    final rating = double.tryParse(m['rating'] ?? '');
    out.add(
      LetterboxdFilmRow(
        title: title,
        year: year,
        letterboxdUri: uri.isEmpty ? null : uri,
        tmdbId: tmdb != null && tmdb > 0 ? tmdb : null,
        imdbId: imdb.isEmpty ? null : imdb,
        listedAt: listedAt,
        watchedAt: watchedAt,
        rating: rating,
      ),
    );
  }
  return out;
}

/// Map export rows into agnostic statuses (movies only).
List<TrackerStatusEntry> letterboxdStatusesFromExport(LetterboxdExportData data) {
  final byKey = <String, TrackerStatusEntry>{};

  void put(LetterboxdFilmRow row, TrackerWatchStatus status) {
    final entry = TrackerStatusEntry(
      source: TrackerSources.letterboxd,
      key: row.stableKey,
      status: status,
      title: row.title,
      year: row.year,
      tmdbId: row.tmdbId,
      imdbId: row.imdbId,
      updatedAt: row.watchedAt ?? row.listedAt,
      progress: status == TrackerWatchStatus.completed ? 1.0 : null,
      rating: row.rating,
      moviesOnly: true,
    );
    final prev = byKey[entry.compositeKey];
    if (prev == null) {
      byKey[entry.compositeKey] = entry;
      return;
    }
    // Prefer completed over watchlist when both appear.
    final rank = _statusRank(status);
    final prevRank = _statusRank(prev.status);
    if (rank >= prevRank) {
      byKey[entry.compositeKey] = entry.copyWith(
        rating: entry.rating ?? prev.rating,
        updatedAt: entry.updatedAt ?? prev.updatedAt,
      );
    }
  }

  for (final row in data.watchlist) {
    put(row, TrackerStatusKind.watchlist);
  }
  for (final row in data.ratings) {
    put(row, TrackerStatusKind.completed);
  }
  for (final row in data.watched) {
    put(row, TrackerStatusKind.completed);
  }
  for (final row in data.diary) {
    put(row, TrackerStatusKind.completed);
  }
  return byKey.values.toList();
}

int _statusRank(TrackerStatusKind k) {
  switch (k) {
    case TrackerStatusKind.watchlist:
    case TrackerStatusKind.planToWatch:
      return 1;
    case TrackerStatusKind.watching:
    case TrackerStatusKind.hold:
      return 2;
    case TrackerStatusKind.dropped:
      return 3;
    case TrackerStatusKind.completed:
      return 4;
  }
}
