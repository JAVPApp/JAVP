import 'package:javp/services/iptv/vod_grouping.dart';

/// Show-title helpers for My List.
///
/// IPTV / torrent rows often prefix a streaming-house / IPTV-shelf label
/// (`House | Show S01E01`, `AB | Show`). Bookmark the show, not the shelf.
class SeriesWatchlistTitle {
  SeriesWatchlistTitle._();

  static final _qualityOrMeta = RegExp(
    r'^(?:4k|uhd|fhd|hd|sd|hdr|hdr10|dv|web|web-?dl|webrip|bluray|hdtv|'
    r'1080p|720p|2160p|480p|hevc|x264|x265|avc|aac|dts|multi|multi-?sub|'
    r'vostfr|vfq|vff|vf|vo|sub|subs|dub|proper|repack|internal)$',
    caseSensitive: false,
  );

  static final _seasonCut = RegExp(
    r'\s+S\d{1,2}(?:E\d{1,3})?\b|\s+Season\s*\d+',
    caseSensitive: false,
  );

  static final _leadingBrackets = RegExp(r'^(\[[^\]]+\]\s*)+');

  /// True when [title] looks like a short single-token IPTV shelf / house label
  /// (not a multi-word show title).
  static bool isPlatformLabel(String title) {
    final s = title.trim();
    if (s.isEmpty) return false;
    if (s.contains('|')) return false;
    if (s.contains(RegExp(r'\s'))) return false;
    if (s.length > 18 || s.length < 2) return false;
    if (_qualityOrMeta.hasMatch(s)) return false;
    if (_isBareEpisodeTitle(s)) return false;
    return true;
  }

  /// Whether two titles name the same show after IPTV cleanup.
  static bool titlesMatch(String a, String b) {
    final na = VodGrouping.normalizeTitle(a);
    final nb = VodGrouping.normalizeTitle(b);
    if (na.isEmpty || nb.isEmpty) return false;
    return na == nb;
  }

  /// Strip release-group / `Sxx` / codec noise. Skip house / lang prefixes.
  static String? showTitleFromReleaseName(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(_leadingBrackets, '');
    if (s.contains('|')) {
      final picked = _firstShowSegment(
        s.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
      if (picked == null) return null;
      s = picked;
    } else {
      s = _stripLeadingPlatformDash(s);
    }
    final seasonCut = _seasonCut.firstMatch(s);
    if (seasonCut != null) s = s.substring(0, seasonCut.start).trim();
    final paren = s.indexOf('(');
    if (paren > 0) s = s.substring(0, paren).trim();
    if (s.isEmpty || isPlatformLabel(s) || _isBareEpisodeTitle(s)) return null;
    return s;
  }

  static String? _firstShowSegment(Iterable<String> parts) {
    for (final part in parts) {
      if (_isSkippablePrefix(part)) continue;
      if (_isBareEpisodeTitle(part) || isPlatformLabel(part)) continue;
      return part;
    }
    return null;
  }

  static bool _isSkippablePrefix(String part) {
    if (isPlatformLabel(part)) return true;
    if (_qualityOrMeta.hasMatch(part.trim())) return true;
    final lang = VodGrouping.languageFromTitle('$part | x');
    if (lang != null && part.trim().length <= 3) return true;
    return false;
  }

  static String _stripLeadingPlatformDash(String raw) {
    final dash = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(raw);
    if (dash == null) return raw;
    final head = dash.group(1)!.trim();
    final tail = dash.group(2)!.trim();
    if (isPlatformLabel(head) && tail.isNotEmpty && !isPlatformLabel(tail)) {
      return tail;
    }
    return raw;
  }

  static bool _isBareEpisodeTitle(String title) => RegExp(
    r'^(episode|épisode|ep)\s*\d+$',
    caseSensitive: false,
  ).hasMatch(title.trim());
}
