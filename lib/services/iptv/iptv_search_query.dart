import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/vod_grouping.dart';

/// Tokenize + rank IPTV titles the way a live list should: fold diacritics,
/// ignore `US|` / `HD` noise, prefer prefix hits, and build FTS5 MATCH strings.
class IptvSearchQuery {
  IptvSearchQuery._();

  /// Split leftover non-token chars. Hyphens must not stay in the query —
  /// FTS5 treats bare `-` as NOT (`al-jazeera*` → `al` excluding `jazeera*`).
  static final _tokenSplit = RegExp(r'[^a-z0-9]+');
  static final _ws = RegExp(r'\s+');
  static final _punct = RegExp(r'[|_\-()[\].,:/\\+!?#"*]+');
  static final _combining = RegExp(r'[\u0300-\u036F]');
  static final _digitsOnly = RegExp(r'^\d+$');

  /// Fold accents / punctuation so `Café`, `CAFE`, and `US| NewsNet HD` share tokens.
  static String normalize(String raw) {
    final folded = _foldLatin(raw.toLowerCase()).replaceAll(_combining, '');
    return folded.replaceAll(_punct, ' ').replaceAll(_ws, ' ').trim();
  }

  /// Alphanumeric tokens used for AND matching / FTS prefix queries.
  static List<String> tokens(String raw) {
    final n = normalize(raw);
    if (n.isEmpty) return const [];
    return n
        .split(_tokenSplit)
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }

  /// FTS5 MATCH: `newsnet*` / `sports* network*` so partial typing still hits.
  static String ftsMatchQuery(String raw) {
    final t = tokens(raw);
    if (t.isEmpty) return '';
    return t.map((token) => '$token*').join(' ');
  }

  /// Digits-only query for channel-number matching, or null.
  static String? digitsOnly(String raw) {
    final t = raw.trim();
    if (t.isEmpty || !_digitsOnly.hasMatch(t)) return null;
    return t;
  }

  static final _trailingYear = RegExp(r'[-–—]\s*((?:19|20)\d{2})\s*$');

  /// Year from [item.year] or a trailing ` - 2024` on the raw title.
  static String? yearToken(MediaItem item) {
    final fromField = item.year?.toString();
    if (fromField != null && fromField.isNotEmpty) return fromField;
    return _trailingYear.firstMatch(item.title.trim())?.group(1);
  }

  /// Precomputed hay for one catalog row (ingest + in-memory fallback).
  static String hay({
    String? title,
    String? group,
    String? subtitle,
    String? channelName,
    String? streamId,
    String? channelId,
    String? epgChannelId,
    String? year,
  }) {
    return normalize(
      [
        title,
        group,
        subtitle,
        channelName,
        streamId,
        channelId,
        epgChannelId,
        year,
      ].whereType<String>().join(' '),
    );
  }

  static String hayForItem(MediaItem item) {
    return hay(
      title: rankTitle(item),
      group: item.group,
      subtitle: item.subtitle,
      channelName: item.channelName,
      streamId: item.streamId,
      channelId: item.channelId,
      epgChannelId: item.epgChannelId,
      year: yearToken(item),
    );
  }

  /// Lowercased title with region/quality prefixes stripped, then normalized.
  ///
  /// Appends a year token when present so LIKE / in-memory search still hit
  /// `2021` after [VodGrouping.displayTitle] strips trailing ` - 2021`.
  static String rankTitle(MediaItem item) {
    if (item.isLive) {
      final cleaned = ChannelQuality.baseTitle(item.title);
      if (cleaned.isNotEmpty) return normalize(cleaned);
    }
    final display = VodGrouping.displayTitle(item);
    final base = display.isNotEmpty ? display : item.title;
    final year = yearToken(item);
    if (year != null && year.isNotEmpty && !base.contains(year)) {
      return normalize('$base $year');
    }
    return normalize(base);
  }

  /// Higher is better. 0 = no match. Prefix / earlier index outranks contains.
  static int scoreNorm(String hayNorm, List<String> tokens) {
    if (hayNorm.isEmpty || tokens.isEmpty) return 0;
    var score = 0;
    for (final token in tokens) {
      final idx = hayNorm.indexOf(token);
      if (idx < 0) return 0;
      score +=
          100 - (idx > 99 ? 99 : idx) + (hayNorm.startsWith(token) ? 25 : 0);
    }
    return score;
  }

  /// Score a catalog row. Channel-number exact/prefix outranks name matches.
  static int scoreItem(String query, MediaItem item) {
    final q = query.trim();
    if (q.isEmpty) return 0;
    final toks = tokens(q);
    var score = toks.isEmpty ? 0 : scoreNorm(hayForItem(item), toks);
    final digits = digitsOnly(q);
    if (digits != null) {
      final id = (item.streamId ?? '').trim();
      final ch = (item.channelId ?? '').trim();
      if (id == digits || ch == digits) {
        score = score < 1000 ? 1000 : score;
      } else if (id.startsWith(digits) ||
          (ch.isNotEmpty && ch.startsWith(digits))) {
        if (score < 500) score = 500;
      }
    }
    return score;
  }

  /// Lower is better. 0 = exact cleaned title. 99 = no / weak match.
  static int relevance(String query, MediaItem item) {
    final q = query.trim();
    if (q.isEmpty) return 99;
    final score = scoreItem(q, item);
    if (score <= 0) return 99;
    if (score >= 1000) return 0;
    if (score >= 500) return 1;
    final stripped = rankTitle(item);
    final nq = normalize(q);
    if (stripped == nq) return 0;
    if (stripped.startsWith(nq)) return 1;
    return score >= 125 ? 2 : (score >= 80 ? 3 : 4);
  }

  static bool matchesFields(String query, Iterable<String?> fields) {
    final toks = tokens(query);
    if (toks.isEmpty) return true;
    return scoreNorm(normalize(fields.whereType<String>().join(' ')), toks) > 0;
  }

  static String _foldLatin(String s) {
    return s
        .replaceAll(RegExp('[àáâãäåāăą]'), 'a')
        .replaceAll(RegExp('[èéêëēĕėęě]'), 'e')
        .replaceAll(RegExp('[ìíîïĩīĭįı]'), 'i')
        .replaceAll(RegExp('[òóôõöōŏőø]'), 'o')
        .replaceAll(RegExp('[ùúûüũūŭůűų]'), 'u')
        .replaceAll(RegExp('[ýÿŷ]'), 'y')
        .replaceAll(RegExp('[ñńņň]'), 'n')
        .replaceAll(RegExp('[çćĉċč]'), 'c')
        .replaceAll(RegExp('[šśŝş]'), 's')
        .replaceAll(RegExp('[žźż]'), 'z')
        .replaceAll(RegExp('[ďđ]'), 'd')
        .replaceAll(RegExp('[ğģ]'), 'g')
        .replaceAll(RegExp('[ľłļ]'), 'l')
        .replaceAll(RegExp('[řŕŗ]'), 'r')
        .replaceAll(RegExp('[ťţ]'), 't')
        .replaceAll('æ', 'ae')
        .replaceAll('œ', 'oe')
        .replaceAll('ß', 'ss');
  }
}
