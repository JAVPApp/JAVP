/// Parse TMDB / IMDb ids from catalog JSON, IPTV names, and M3U attributes.
///
/// Used so language editions (FR|/US|/PT|) can share a [VodGrouping] family
/// when the panel or BYO catalog embeds the id instead of a `tmdbId` field.
class ExternalIds {
  ExternalIds._();

  static final RegExp _tmdbTagged = RegExp(
    r'(?:\{|\(|\[)?tmdb[-_:=/\s]+(\d{1,8})(?:\}|\)|\])?',
    caseSensitive: false,
  );
  static final RegExp _tmdbSite = RegExp(
    r'themoviedb\.org/(?:movie|tv)/(\d{1,8})',
    caseSensitive: false,
  );
  static final RegExp _imdbId = RegExp(r'(tt\d{7,8})', caseSensitive: false);

  /// Positive integer from JSON number / numeric string (`"550"`, `550.0`).
  static int? parsePositiveInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw > 0 ? raw : null;
    if (raw is num) {
      final n = raw.toInt();
      return n > 0 ? n : null;
    }
    if (raw is String) {
      final t = raw.trim();
      if (t.isEmpty || t == 'null') return null;
      final asInt = int.tryParse(t);
      if (asInt != null) return asInt > 0 ? asInt : null;
      final asDouble = double.tryParse(t);
      if (asDouble == null || !asDouble.isFinite) return null;
      final n = asDouble.toInt();
      return n > 0 ? n : null;
    }
    if (raw is Map) {
      return parsePositiveInt(
        raw['tmdb'] ?? raw['tmdbId'] ?? raw['tmdb_id'] ?? raw['id'],
      );
    }
    return null;
  }

  static String? parseImdb(Object? raw) {
    if (raw == null) return null;
    if (raw is Map) {
      return parseImdb(
        raw['imdb'] ?? raw['imdbId'] ?? raw['imdb_id'] ?? raw['id'],
      );
    }
    final text = '$raw'.trim();
    if (text.isEmpty || text == 'null') return null;
    final tagged = imdbFromText(text);
    if (tagged != null) return tagged;
    if (RegExp(r'^tt\d+$', caseSensitive: false).hasMatch(text)) {
      return text.toLowerCase();
    }
    return null;
  }

  /// TMDB id tagged in a title, catalog id, or themoviedb.org URL.
  ///
  /// Does **not** scrape bare numbers from Xtream play URLs (`/movie/u/p/123`).
  static int? tmdbFromText(String? text) {
    if (text == null || text.isEmpty) return null;
    final site = _tmdbSite.firstMatch(text);
    if (site != null) return int.tryParse(site.group(1)!);
    final tagged = _tmdbTagged.firstMatch(text);
    if (tagged != null) return int.tryParse(tagged.group(1)!);
    return null;
  }

  static String? imdbFromText(String? text) {
    if (text == null || text.isEmpty) return null;
    final match = _imdbId.firstMatch(text);
    if (match == null) return null;
    return match.group(1)!.toLowerCase();
  }

  static int? tmdbFromMap(
    Map<dynamic, dynamic> map, {
    String? id,
    List<String> tags = const [],
    String? title,
    String? playUrl,
    String? posterUrl,
  }) {
    for (final key in const ['tmdbId', 'tmdb_id', 'tmdb']) {
      final hit = parsePositiveInt(map[key]);
      if (hit != null) return hit;
    }
    for (final nestedKey in const ['ids', 'externalIds', 'external_ids']) {
      final nested = map[nestedKey];
      if (nested is Map) {
        final hit = parsePositiveInt(
          nested['tmdb'] ?? nested['tmdbId'] ?? nested['tmdb_id'],
        );
        if (hit != null) return hit;
      }
    }
    // Some Xtream panels put themoviedb.org links in kinopoisk_url / similar.
    for (final urlKey in const [
      'kinopoisk_url',
      'tmdb_url',
      'movie_url',
      'url',
    ]) {
      final raw = map[urlKey];
      if (raw is! String || !raw.contains('themoviedb.org')) continue;
      final hit = tmdbFromText(raw);
      if (hit != null) return hit;
    }
    return tmdbFromText(
      [
        id,
        title,
        ...tags,
        posterUrl,
        // Site URLs only — Xtream `/movie/…/streamId` must not look like TMDB.
        if (playUrl != null && playUrl.contains('themoviedb.org')) playUrl,
      ].whereType<String>().join(' '),
    );
  }

  static String? imdbFromMap(
    Map<dynamic, dynamic> map, {
    String? id,
    List<String> tags = const [],
    String? title,
  }) {
    for (final key in const ['imdbId', 'imdb_id', 'imdb']) {
      final hit = parseImdb(map[key]);
      if (hit != null) return hit;
    }
    for (final nestedKey in const ['ids', 'externalIds', 'external_ids']) {
      final nested = map[nestedKey];
      if (nested is Map) {
        final hit = parseImdb(
          nested['imdb'] ?? nested['imdbId'] ?? nested['imdb_id'],
        );
        if (hit != null) return hit;
      }
    }
    return imdbFromText([id, title, ...tags].whereType<String>().join(' '));
  }

  /// Prefer the row field, then ids embedded in title / catalog id / tags.
  static int? resolvedTmdbId({
    int? tmdbId,
    String? title,
    String? id,
    List<String> tags = const [],
    String? originalTitle,
  }) {
    if (tmdbId != null && tmdbId > 0) return tmdbId;
    return tmdbFromText(
      [title, originalTitle, id, ...tags].whereType<String>().join(' '),
    );
  }

  static String? resolvedImdbId({
    String? imdbId,
    String? title,
    String? id,
    List<String> tags = const [],
    String? originalTitle,
  }) {
    final direct = imdbId?.trim();
    if (direct != null && direct.isNotEmpty) {
      return imdbFromText(direct) ?? direct.toLowerCase();
    }
    return imdbFromText(
      [title, originalTitle, id, ...tags].whereType<String>().join(' '),
    );
  }
}
