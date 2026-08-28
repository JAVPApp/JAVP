/// Minimal RFC4180-ish CSV reader for Letterboxd export files.
List<Map<String, String>> parseLetterboxdCsv(String raw) {
  final text = raw.replaceFirst(RegExp(r'^\uFEFF'), '');
  if (text.trim().isEmpty) return const [];

  final rows = <List<String>>[];
  var field = StringBuffer();
  var row = <String>[];
  var inQuotes = false;

  void endField() {
    row.add(field.toString());
    field = StringBuffer();
  }

  void endRow() {
    endField();
    // Skip blank trailing lines.
    if (row.any((c) => c.trim().isNotEmpty)) {
      rows.add(row);
    }
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      inQuotes = true;
      continue;
    }
    if (ch == ',') {
      endField();
      continue;
    }
    if (ch == '\n') {
      endRow();
      continue;
    }
    if (ch == '\r') {
      if (i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
      continue;
    }
    field.write(ch);
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    endRow();
  }
  if (rows.isEmpty) return const [];

  final headers = [
    for (final h in rows.first) _normalizeHeader(h),
  ];
  final out = <Map<String, String>>[];
  for (var r = 1; r < rows.length; r++) {
    final cells = rows[r];
    final map = <String, String>{};
    for (var c = 0; c < headers.length; c++) {
      final key = headers[c];
      if (key.isEmpty) continue;
      map[key] = c < cells.length ? cells[c].trim() : '';
    }
    if (map.values.any((v) => v.isNotEmpty)) {
      out.add(map);
    }
  }
  return out;
}

String _normalizeHeader(String raw) {
  final s = raw.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
  switch (s) {
    case 'name':
    case 'title':
    case 'film':
      return 'name';
    case 'year':
      return 'year';
    case 'date':
      return 'date';
    case 'watcheddate':
      return 'watchedDate';
    case 'letterboxduri':
    case 'uri':
    case 'url':
      return 'letterboxdUri';
    case 'rating':
      return 'rating';
    case 'rewatch':
      return 'rewatch';
    case 'tags':
      return 'tags';
    case 'tmdbid':
    case 'tmdb':
      return 'tmdbId';
    case 'imdbid':
    case 'imdb':
      return 'imdbId';
    default:
      return s;
  }
}
