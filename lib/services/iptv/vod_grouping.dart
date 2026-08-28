import 'dart:ui' show Locale;

import 'package:javp/models/media_item.dart';
import 'package:javp/models/series_info.dart';
import 'package:javp/services/catalog/catalog_play_headers.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';
import 'package:javp/services/metadata/external_ids.dart';
import 'package:javp/services/playback/track_language.dart';

/// VOD family keys for collapsing language / source editions into one card.
///
/// ## Policy: if unsure, don't group
///
/// Default is **separate cards**. Merge only on positive evidence:
///
/// 1. **Shared external id** — same TMDB / IMDb / AniList id (typed for TMDB).
/// 2. **Title + year** — same normalized title and same year
///    (`name:{title}|{year}`). Confident enough across sources.
/// 3. **Same-source yearless editions** — multi-word title, no year/id, but
///    same `sourceId` (`srcname:{sourceId}:{title}`). Covers `EN|` / `FR|`
///    IPTV siblings on one panel without gluing unrelated catalogs.
///
/// Do **not** group when:
/// - title-only match with no year (especially short/common titles)
/// - conflicting external ids
/// - year missing on both sides and sources differ (no shared id)
/// - several identity families claim the same bare title alias (e.g. Belle)
///
/// Library merge may still attach a yearless orphan to an identity family
/// when **exactly one** TMDB/IMDb/AniList family claims that title alias.
class VodGrouping {
  const VodGrouping._();

  /// Stable family key for prefs + collapsing.
  ///
  /// Prefers external identity (`tmdb:movie:{id}`, `imdb:…`, `anilist:…`) when
  /// known, else a confident name key (see [nameGroupKey]). Returns null when
  /// there is no positive evidence to group this row with anything.
  static String? groupKey(MediaItem item) {
    final tmdb = ExternalIds.resolvedTmdbId(
      tmdbId: item.tmdbId,
      title: item.title,
      id: item.id,
      tags: item.tags,
      originalTitle: item.originalTitle,
    );
    if (tmdb != null && tmdb > 0) {
      // TMDB movie and TV ids are separate namespaces.
      if (item.isSeries) return 'tmdb:tv:$tmdb';
      return 'tmdb:movie:$tmdb';
    }
    final imdb = ExternalIds.resolvedImdbId(
      imdbId: item.imdbId,
      title: item.title,
      id: item.id,
      tags: item.tags,
      originalTitle: item.originalTitle,
    );
    if (imdb != null && imdb.isNotEmpty) {
      return 'imdb:$imdb';
    }
    final anilist = item.anilistId;
    if (anilist != null && anilist > 0) return 'anilist:$anilist';
    return nameGroupKey(item);
  }

  /// True when a normalized title is unsafe to group without year or id.
  ///
  /// Single-token titles collide constantly across years/countries ("Belle",
  /// "Her", "Up", "Drive"). Even multi-word titles are not grouped globally
  /// without a year — only same-source yearless editions may share a key.
  static bool isAmbiguousBareTitle(String normalized) {
    final parts = normalized
        .split(' ')
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return true;
    if (parts.length == 1) return true;
    return false;
  }

  /// Title(+year) / same-source key when external ids are missing.
  ///
  /// - With year → `name:{normalized}|{year}` (movies) or
  ///   `name:tv:{normalized}|{year}` (series). Cross-source OK.
  /// - Yearless multi-word with [MediaItem.sourceId] →
  ///   `srcname:{sourceId}:{normalized}` (panel-local EN|/FR| only).
  /// - Yearless bare/single-word, or no source → null (stay separate).
  ///
  /// Series keys are prefixed so a movie and a show that share a cleaned
  /// title+year never land in the same family.
  static String? nameGroupKey(MediaItem item) {
    return nameGroupKeyFor(
      title: item.title,
      year: item.year ?? yearFromTitle(item.title),
      sourceId: item.sourceId,
      isSeries: item.isSeries,
    );
  }

  /// Isolate-safe [nameGroupKey].
  static String? nameGroupKeyFor({
    required String title,
    int? year,
    String? sourceId,
    bool isSeries = false,
  }) {
    final base = normalizeTitle(title);
    if (base.length < 2) return null;
    final prefix = isSeries ? 'tv:' : '';
    if (year != null) return 'name:$prefix$base|$year';
    // No year and no external id: never collapse globally by title alone.
    if (isAmbiguousBareTitle(base)) return null;
    final source = sourceId?.trim();
    if (source == null || source.isEmpty) return null;
    return 'srcname:$source:$prefix$base';
  }

  /// Name aliases for linking identity-keyed rows to name-only siblings.
  ///
  /// Always includes the year-qualified form when known. The yearless
  /// `name:title` form is included so IPTV rows without a year can join a
  /// unique identity family — the variant index must only honor that alias
  /// when a single identity family claims it (see library merge).
  static List<String> nameGroupAliases(MediaItem item) {
    return nameGroupAliasesFor(
      title: item.title,
      originalTitle: item.originalTitle,
      year: item.year ?? yearFromTitle(item.title),
      isSeries: item.isSeries,
    );
  }

  /// Isolate-safe aliases for [nameGroupAliases].
  static List<String> nameGroupAliasesFor({
    required String title,
    String? originalTitle,
    int? year,
    bool isSeries = false,
  }) {
    final out = <String>{};
    final prefix = isSeries ? 'tv:' : '';
    void add(String raw) {
      final base = normalizeTitle(raw);
      if (base.length < 2) return;
      out.add('name:$prefix$base');
      if (year != null) out.add('name:$prefix$base|$year');
    }

    add(title);
    final original = originalTitle?.trim();
    if (original != null && original.isNotEmpty) add(original);
    return out.toList(growable: false);
  }

  /// True when [key] is an external-id family (not title/year/source-local).
  static bool isIdentityGroupKey(String key) {
    return key.startsWith('tmdb:') ||
        key.startsWith('imdb:') ||
        key.startsWith('anilist:');
  }

  /// True when [key] is a same-source yearless title family.
  static bool isSourceLocalGroupKey(String key) => key.startsWith('srcname:');

  static String preferenceKey(MediaItem item) {
    final key = groupKey(item);
    if (key == null) return item.id;
    return key;
  }

  // Hot path for ~100k+ Xtream rows (Versions index / Catalog shelves).
  // Allocate once — constructing RegExp per title dominated multi-second jank.
  static final RegExp _leadingLangSep = RegExp(r'^[a-z]{2,3}\s*[|:：\-–—]\s*');
  static final RegExp _bracketOrParenTags = RegExp(r'\[[^\]]*\]|\([^\)]*\)');
  static final RegExp _iptvQualityNoise = RegExp(
    r'\b(4k|uhd|1080p|720p|2160p|hdr|hevc|x264|x265|bluray|web-?dl|webrip|'
    r'multi-?sub|multi|vostfr|vfq|vff|vf|vo|fhd|hd|nf|sub)\b',
  );
  static final RegExp _yearToken = RegExp(r'\b(19|20)\d{2}\b');
  static final RegExp _yearCapture = RegExp(r'\b((?:19|20)\d{2})\b');
  static final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');
  static final RegExp _whitespaceRuns = RegExp(r'\s+');
  static final RegExp _leadingLangSepDisplay = RegExp(
    r'^[A-Za-z]{2,3}\s*[|:：\-–—]\s*',
  );
  static final RegExp _displayTagNoise = RegExp(
    r'\s*[\[\(][^\]\)]*(?:MULTI-?SUB|VOSTFR|SUB|VF|VO|NF)[^\]\)]*[\]\)]\s*',
    caseSensitive: false,
  );
  static final RegExp _trailingYearDash = RegExp(
    r'\s*[-–—]\s*(19|20)\d{2}\s*$',
  );
  static final RegExp _resUhd = RegExp(r'\b(4k|uhd|2160p)\b');
  static final RegExp _res1080 = RegExp(r'\b(1080p|fhd)\b');
  static final RegExp _res720 = RegExp(r'\b720p\b');
  static final RegExp _resSd = RegExp(r'\b(480p|360p|\bsd\b)\b');
  static final RegExp _hdrTag = RegExp(
    r'\b(hdr10\+?|hdr|dolby\s*vision|\bdv\b)\b',
  );

  /// Strip language / quality / subtitle tags for matching.
  static String normalizeTitle(String title) {
    var t = title.toLowerCase().trim();
    if (languageFromTitle(t) != null) {
      t = t.replaceFirst(_leadingLangSep, '');
    }
    // Bracket / paren tags
    t = t.replaceAll(_bracketOrParenTags, ' ');
    // Common IPTV noise
    t = t.replaceAll(_iptvQualityNoise, ' ');
    // Trailing / embedded year kept separately
    t = t.replaceAll(_yearToken, ' ');
    t = t.replaceAll(_nonAlnum, ' ');
    t = t.replaceAll(_whitespaceRuns, ' ').trim();
    return t;
  }

  static int? yearFromTitle(String title) {
    final match = _yearCapture.firstMatch(title);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Clean poster title without EN|/FR| noise.
  static String displayTitle(MediaItem item) => displayTitleFor(item.title);

  /// Isolate-safe [displayTitle] from a raw title string.
  static String displayTitleFor(String title) {
    var t = title.trim();
    if (languageFromTitle(t) != null) {
      t = t.replaceFirst(_leadingLangSepDisplay, '');
    }
    t = t.replaceAll(_displayTagNoise, ' ');
    // " - 2026" trailing year — keep year via item.year, strip from display if noisy
    t = t.replaceFirst(_trailingYearDash, '');
    t = t.replaceAll(_whitespaceRuns, ' ').trim();
    return t.isEmpty ? title : t;
  }

  /// Haystack used to infer audio / caption tags from IPTV naming.
  static String _tagHaystack(MediaItem item) {
    return tagHaystackFor(
      title: item.title,
      group: item.group,
      subtitle: item.subtitle,
      subtitleLanguages: item.subtitleLanguages,
      audioLanguages: item.audioLanguages,
    );
  }

  /// Isolate-safe haystack (same fields as [_tagHaystack]).
  static String tagHaystackFor({
    required String title,
    String? group,
    String? subtitle,
    List<String> subtitleLanguages = const [],
    List<String> audioLanguages = const [],
  }) {
    return [
      title,
      group ?? '',
      subtitle ?? '',
      ...subtitleLanguages,
      ...audioLanguages,
    ].join(' ');
  }

  /// Caption languages when known (catalog fields or title/category tags).
  static List<String> inferredSubtitleLanguages(MediaItem item) {
    final fromTracks = item.subtitles
        .map((s) => s.language?.trim())
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .map((e) => e.toLowerCase())
        .toList();
    return inferredSubtitleLanguagesFor(
      title: item.title,
      group: item.group,
      subtitle: item.subtitle,
      subtitleLanguages: item.subtitleLanguages,
      audioLanguages: item.audioLanguages,
      trackSubtitleLanguages: fromTracks,
    );
  }

  /// Isolate-safe caption inference (Versions index worker).
  static List<String> inferredSubtitleLanguagesFor({
    required String title,
    String? group,
    String? subtitle,
    List<String> subtitleLanguages = const [],
    List<String> audioLanguages = const [],
    List<String> trackSubtitleLanguages = const [],
  }) {
    if (subtitleLanguages.isNotEmpty) {
      return [
        for (final e in subtitleLanguages)
          if (_knownLangCode(e) != null) _knownLangCode(e)!,
      ];
    }
    if (trackSubtitleLanguages.isNotEmpty) {
      return trackSubtitleLanguages.toSet().toList();
    }

    final upper = tagHaystackFor(
      title: title,
      group: group,
      subtitle: subtitle,
      subtitleLanguages: subtitleLanguages,
      audioLanguages: audioLanguages,
    ).toUpperCase();
    if (RegExp(r'MULTI[-\s]?SUB|MULTI[-\s]?SUBS|\bMSUBS?\b').hasMatch(upper)) {
      return const ['multi'];
    }
    // Locale-specific “original + subs” tags (VOSTFR, VOSE, OmU, SUBITA, …).
    final captionLangs = <String>[];
    void addCaption(String code, bool hit) {
      if (hit && !captionLangs.contains(code)) captionLangs.add(code);
    }

    addCaption(
      'fr',
      upper.contains('VOSTFR') ||
          upper.contains('VOST-FR') ||
          upper.contains('STFR'),
    );
    addCaption(
      'en',
      RegExp(r'VOST-?EN|VOSTANG|\bOMEU\b|ENG-?SUB|SUB-?ENG').hasMatch(upper),
    );
    addCaption(
      'es',
      RegExp(r'\bVOSE\b|VOS-?ESP|SUB-?ESP|SUB-?CAST').hasMatch(upper),
    );
    addCaption(
      'de',
      RegExp(r'\bOMU\b|\bOMDU\b|VOST-?DE|SUB-?GER|SUB-?DEU').hasMatch(upper),
    );
    addCaption(
      'it',
      RegExp(r'SUB-?ITA|\bSUBITA\b|ITA-?SUB|VOST-?IT').hasMatch(upper),
    );
    addCaption(
      'pt',
      RegExp(r'LEGENDAD[OA]|VOST-?PT|SUB-?PT').hasMatch(upper),
    );
    addCaption('nl', RegExp(r'VOST-?NL|SUB-?NL|ONDERTITELD').hasMatch(upper));
    addCaption('pl', RegExp(r'\bNAPISY\b|VOST-?PL|SUB-?PL').hasMatch(upper));
    addCaption('ru', RegExp(r'VOST-?RU|SUB-?RUS?').hasMatch(upper));
    addCaption('ja', RegExp(r'VOST-?JP|VOST-?JA|SUB-?JPN?').hasMatch(upper));
    if (captionLangs.isNotEmpty) return captionLangs;
    if (RegExp(r'\bHARD\s*SUB|\bHARDSUB\b').hasMatch(upper)) {
      return const ['hardsub'];
    }
    if (RegExp(r'\bSOFT\s*SUB|\bSOFTSUB\b').hasMatch(upper)) {
      return const ['softsub'];
    }
    if (RegExp(
      r'\[SUB\]|\(SUB\)|\bSUBBED\b|\bWITH\s+SUBS?\b',
    ).hasMatch(upper)) {
      return const ['sub'];
    }
    if (RegExp(r'\bCC\b|\bSDH\b|\bCLOSED\s*CAPTION').hasMatch(upper)) {
      return const ['cc'];
    }
    return const [];
  }

  /// True when naming explicitly advertises no captions.
  static bool explicitlyNoCaptions(MediaItem item) {
    final upper = _tagHaystack(item).toUpperCase();
    return RegExp(
      r'\bNO[-\s]?SUBS?\b|\bNOSUBS?\b|\bRAW\b|\bUNCENSORED\s*RAW\b|\[RAW\]',
    ).hasMatch(upper);
  }

  /// Human caption chip: `Subs EN/FR`, `Multi-sub`, `No captions`, …
  static String? captionLabel(MediaItem item) {
    final langs = inferredSubtitleLanguages(item);
    if (langs.isNotEmpty) {
      if (langs.any((e) => e == 'multi' || e == 'multisub' || e == 'msub')) {
        return 'Multi-sub';
      }
      if (langs.every((e) => e == 'hardsub')) return 'Hardsub';
      if (langs.every((e) => e == 'softsub')) return 'Softsub';
      if (langs.every((e) => e == 'cc' || e == 'sdh')) return 'CC';
      if (langs.every((e) => e == 'sub' || e == 'subbed')) return 'Subbed';
      final codes = langs
          .where((e) => e.length <= 3 && e != 'sub')
          .take(4)
          .map((e) => e.toUpperCase())
          .toList();
      if (codes.isNotEmpty) return 'Subs ${codes.join('/')}';
      return 'Subbed';
    }
    if (explicitlyNoCaptions(item)) return 'No captions';
    return null;
  }

  /// Language / edition chip for a variant row.
  ///
  /// Pass [sourceLabel] when variants span multiple sources so the chip
  /// distinguishes Jellyfin vs Xtream editions of the same title.
  static String variantLabel(MediaItem item, {String? sourceLabel}) {
    final parts = <String>[];
    if (item.audioLanguages.length > 1) {
      parts.add(
        'Audio ${item.audioLanguages.take(4).map((e) => e.trim().toUpperCase()).where((e) => e.isNotEmpty).join('/')}',
      );
    } else {
      final lang = languageCode(item);
      if (lang != null) {
        parts.add(
          lang == 'multi' ? 'Multi audio' : 'Audio ${lang.toUpperCase()}',
        );
      }
    }

    final captions = captionLabel(item);
    if (captions != null) {
      parts.add(captions);
    }

    final res = item.resolution?.trim();
    if (res != null && res.isNotEmpty) parts.add(res.toUpperCase());
    final hdr = item.hdr?.trim();
    if (hdr != null && hdr.isNotEmpty) parts.add(hdr.toUpperCase());

    final source = sourceLabel?.trim();
    if (source != null && source.isNotEmpty) {
      parts.add(source);
    }

    // Fall back to category when we still have nothing distinctive.
    final group = item.group?.trim();
    if (parts.isEmpty && group != null && group.isNotEmpty) {
      parts.add(group);
    }
    if (parts.isEmpty) return 'Version';
    return parts.join(' · ');
  }

  /// Distinct `sourceId`s in family order (first seen wins).
  static List<String> uniqueSourceIds(Iterable<MediaItem> items) {
    final out = <String>[];
    final seen = <String>{};
    for (final item in items) {
      final sid = item.sourceId?.trim();
      if (sid == null || sid.isEmpty) continue;
      if (seen.add(sid)) out.add(sid);
    }
    return out;
  }

  /// Search subtitle: never both "N versions" and "N sources".
  ///
  /// Multi-source families leave this empty so the row can show compact
  /// source-color dots instead. Same-source language editions keep
  /// [versionsLabel]. A single hit keeps the catalog name.
  static String? searchHitSubtitle({
    required int variantCount,
    required int sourceCount,
    required String versionsLabel,
    required String sourceLabel,
  }) {
    if (sourceCount > 1) return null;
    if (variantCount > 1) {
      final label = versionsLabel.trim();
      return label.isEmpty ? null : label;
    }
    final source = sourceLabel.trim();
    return source.isEmpty ? null : source;
  }

  /// A–Z on the cleaned poster title, then sourceId / id for stability.
  static int compareDisplayTitle(MediaItem a, MediaItem b) {
    final byTitle = displayTitle(
      a,
    ).toLowerCase().compareTo(displayTitle(b).toLowerCase());
    if (byTitle != 0) return byTitle;
    final as = a.sourceId ?? '';
    final bs = b.sourceId ?? '';
    final bySource = as.compareTo(bs);
    if (bySource != 0) return bySource;
    return a.id.compareTo(b.id);
  }

  /// Short explanation for the Versions section header.
  static String versionsSectionHint(List<MediaItem> variants) {
    final hasAudioDiff =
        variants.map(languageCode).whereType<String>().toSet().length > 1;
    final captions = variants.map(captionLabel).toSet();
    final hasCaptionDiff =
        captions.length > 1 ||
        captions.any((c) => c != null && c != 'No captions');
    if (hasAudioDiff && hasCaptionDiff) {
      return 'Different audio and caption editions';
    }
    if (hasAudioDiff) return 'Different audio editions';
    if (hasCaptionDiff) return 'Different caption editions';
    return 'Alternate encodes / sources';
  }

  static String? languageCode(MediaItem item) {
    if (item.audioLanguages.isNotEmpty) {
      for (final raw in item.audioLanguages) {
        final n = _knownLangCode(raw);
        if (n != null) return n;
      }
    }
    final fromTitle = languageFromTitle(item.title);
    if (fromTitle != null) return fromTitle;
    return languageFromCategory(item.group ?? item.subtitle ?? '');
  }

  /// IPTV `EN| Title` / `FR: Title` prefixes — not show names (`LOL: …`).
  static String? languageFromTitle(String title) {
    final m = RegExp(
      r'^([A-Za-z]{2,3})\s*([|:：\-–—])\s*',
    ).firstMatch(title.trim());
    if (m == null) return null;
    final raw = m.group(1)!;
    final sep = m.group(2)!;
    final n = _knownLangCode(raw);
    if (n == null) return null;
    // `IT:` / `IT-` is usually a title (`IT: Chapter Two`), not Italian.
    // Pipe / fullwidth colon is the IPTV catalog form (`IT | Gomorra`).
    if ((sep == ':' || sep == '-' || sep == '–' || sep == '—') && n == 'it') {
      return null;
    }
    return n;
  }

  static String? _knownLangCode(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (t == 'multi' || t == 'mul' || t.startsWith('multi')) return 'multi';
    if (TrackLanguage.isCatalogLanguageTag(t)) {
      return TrackLanguage.normalize(t) ?? t;
    }
    // IPTV region prefixes (`CA|`, `US|`, `UK|`, `BR|`) — not 3-letter
    // title acronyms (`LOL:`, `CSI:`).
    if (t.length == 2 && RegExp(r'^[a-z]{2}$').hasMatch(t)) {
      return TrackLanguage.normalize(t) ?? t;
    }
    return null;
  }

  static String? languageFromCategory(String category) {
    final m = RegExp(
      r'^\[\s*([A-Za-z]{2,3}|MULTI-?LANG)\s*\]',
      caseSensitive: false,
    ).firstMatch(category.trim());
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase();
    if (raw.startsWith('MULTI')) return 'multi';
    return _knownLangCode(raw);
  }

  /// Normalize preferred language codes (`fr`, `FR-CA` → `fr`).
  static List<String> normalizePreferredLangs(Iterable<String> langs) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in langs) {
      final code = raw.trim().toLowerCase().split(RegExp(r'[_-]')).first;
      if (code.isEmpty || !seen.add(code)) continue;
      out.add(code);
    }
    return out;
  }

  /// How well [item] matches preferred content locales (audio > captions > tags).
  ///
  /// Used for Home soft-ranking and version picking. Catalog rows expose
  /// `audioLanguages` and `subtitleLanguages` separately; a single preferred
  /// list matches either so watchable editions surface without inventing a
  /// second Settings control (playback track prefs stay in Playback).
  static int localeAffinity(
    MediaItem item, {
    List<String> preferredLangs = const [],
    Locale? locale,
  }) {
    final prefs = normalizePreferredLangs(preferredLangs);
    if (prefs.isEmpty) return 0;
    return languagesAffinity(
      audioLanguages: [
        ...item.audioLanguages,
        if (item.audioTracks.isNotEmpty)
          for (final t in item.audioTracks)
            if ((t.language ?? '').trim().isNotEmpty) t.language!,
      ],
      subtitleLanguages: [
        ...item.subtitleLanguages,
        ...inferredSubtitleLanguages(item),
        if (item.subtitles.isNotEmpty)
          for (final s in item.subtitles)
            if ((s.language ?? '').trim().isNotEmpty) s.language!,
      ],
      title: item.title,
      group: item.group ?? item.subtitle,
      preferredLangs: prefs,
      locale: locale,
    );
  }

  /// Score language lists / IPTV tags against preferred codes.
  ///
  /// Audio match ranks above subtitle-only match so dubbed/original editions
  /// win over foreign-audio+subs when both exist.
  static int languagesAffinity({
    List<String> audioLanguages = const [],
    List<String> subtitleLanguages = const [],
    String? title,
    String? group,
    List<String> preferredLangs = const [],
    Locale? locale,
  }) {
    final prefs = normalizePreferredLangs(preferredLangs);
    if (prefs.isEmpty) return 0;
    final loc = locale ?? IptvLocaleHints.contentLocale;
    final resolved = IptvLocaleHints.normalize(loc);
    final lang = resolved.languageCode.toLowerCase();
    final country = (resolved.countryCode ?? '').toLowerCase();
    final regions = IptvLocaleHints.regionTagsFor(resolved);

    int bestAudio = 0;
    int bestSub = 0;
    for (var i = 0; i < prefs.length; i++) {
      final pref = prefs[i];
      final weight = 100 - i * 8;
      for (final raw in audioLanguages) {
        final code = raw.trim().toLowerCase().split(RegExp(r'[_-]')).first;
        if (code == pref || code == 'multi') {
          bestAudio = bestAudio < weight + (code == 'multi' ? -15 : 0)
              ? weight + (code == 'multi' ? -15 : 0)
              : bestAudio;
        }
      }
      for (final raw in subtitleLanguages) {
        final code = raw.trim().toLowerCase().split(RegExp(r'[_-]')).first;
        if (code == pref || code == 'multi') {
          final score = (weight * 0.55).round() + (code == 'multi' ? -5 : 0);
          if (score > bestSub) bestSub = score;
        }
      }
    }

    var tag = 0;
    var wrongLocaleTag = false;
    final inferred =
        languageFromTitle(title ?? '') ?? languageFromCategory(group ?? '');
    if (inferred != null) {
      for (var i = 0; i < prefs.length; i++) {
        final pref = prefs[i];
        final matchesPref = inferred == pref || inferred == 'multi';
        final matchesRegion =
            regions.contains(inferred) &&
            (pref == lang || (country.isNotEmpty && pref == country));
        if (!matchesPref && !matchesRegion) continue;
        var score = 70 - i * 6 - (inferred == 'multi' ? 20 : 0);
        if (country.isNotEmpty && inferred == country) score += 20;
        if (score > tag) tag = score;
        break;
      }
      // Clear IPTV locale tag (`ALB|`, `[DE]`, …) that does not match prefs:
      // hard-demote below unknown/untagged (0). Leave `multi` and untagged
      // alone — soft-rank must not hide editions with no language signal.
      if (tag == 0 && inferred != 'multi') {
        wrongLocaleTag = true;
      }
    }

    final audioBoost = bestAudio > 0 ? 1000 + bestAudio : 0;
    final subBoost = bestSub > 0 ? 400 + bestSub : 0;
    final tagBoost = tag > 0 ? 250 + tag : 0;
    final best = audioBoost > subBoost
        ? (audioBoost > tagBoost ? audioBoost : tagBoost)
        : (subBoost > tagBoost ? subBoost : tagBoost);
    if (best > 0) return best;
    // No audio/sub/preferred-tag signal: demote wrong-locale below untagged.
    if (wrongLocaleTag) return -500;
    return 0;
  }

  /// Prefer: user language(s) → EN → MULTI → others; media servers over IPTV;
  /// then quality / metadata tags.
  static int rankFor(
    MediaItem item, {
    String? preferredLang,
    List<String>? preferredLangs,
    Locale? locale,
  }) {
    final prefs = normalizePreferredLangs([
      ...?preferredLangs,
      if (preferredLang != null) preferredLang,
    ]);
    final lang = languageCode(item);
    var score = localeAffinity(item, preferredLangs: prefs, locale: locale);
    if (score == 0 &&
        prefs.isNotEmpty &&
        lang != null &&
        prefs.contains(lang)) {
      score += 1000;
    }
    score += switch (lang) {
      'en' => 80,
      'multi' => 60,
      'fr' => 50,
      null => 40,
      _ => 30,
    };
    // Prefer library servers over IPTV panels when language ranks tie.
    score += switch (item.origin) {
      MediaOrigin.jellyfin || MediaOrigin.emby || MediaOrigin.plex => 25,
      MediaOrigin.customCatalog => 15,
      MediaOrigin.localFile || MediaOrigin.download => 10,
      _ => 0,
    };
    final upper = item.title.toUpperCase();
    if (upper.contains('MULTI-SUB')) score -= 5;
    if (RegExp(r'\b4K\b|\bUHD\b').hasMatch(upper)) score += 10;
    if (item.tmdbId != null) score += 5;
    if (item.audioLanguages.length > 1) score += 8;
    if (item.hasExternalSubtitles ||
        item.subtitleLanguages.isNotEmpty ||
        inferredSubtitleLanguages(item).isNotEmpty) {
      score += 4;
    }
    return score;
  }

  static int compareVariants(
    MediaItem a,
    MediaItem b, {
    String? preferredLang,
    List<String>? preferredLangs,
    Locale? locale,
  }) {
    final rank =
        rankFor(
          b,
          preferredLang: preferredLang,
          preferredLangs: preferredLangs,
          locale: locale,
        ).compareTo(
          rankFor(
            a,
            preferredLang: preferredLang,
            preferredLangs: preferredLangs,
            locale: locale,
          ),
        );
    if (rank != 0) return rank;
    return compareDisplayTitle(a, b);
  }

  /// Home shelf order: matching locales first, then A–Z.
  static int compareForHome(
    MediaItem a,
    MediaItem b, {
    List<String> preferredLangs = const [],
    Locale? locale,
  }) {
    final byLocale =
        localeAffinity(
          b,
          preferredLangs: preferredLangs,
          locale: locale,
        ).compareTo(
          localeAffinity(a, preferredLangs: preferredLangs, locale: locale),
        );
    if (byLocale != 0) return byLocale;
    return compareDisplayTitle(a, b);
  }

  /// Soft score for a catalog `group` shelf (name tags + item match density).
  static int groupHomeScore(
    String group,
    List<MediaItem> items, {
    List<String> preferredLangs = const [],
    Locale? locale,
  }) {
    final prefs = normalizePreferredLangs(preferredLangs);
    if (prefs.isEmpty) return 0;
    final loc = locale ?? IptvLocaleHints.contentLocale;
    var score = 0;
    for (final code in prefs) {
      final hintLocale = code == loc.languageCode.toLowerCase()
          ? loc
          : Locale(code);
      final hint = IptvLocaleHints.scoreGroup(group, hintLocale);
      if (hint > score) score = hint;
    }
    if (items.isEmpty) return score * 10;
    var matched = 0;
    var sample = 0;
    for (final item in items) {
      if (++sample > 24) break;
      if (localeAffinity(item, preferredLangs: prefs, locale: loc) > 0) {
        matched++;
      }
    }
    final density = matched / sample;
    score = score * 10 + (density * 40).round();
    // Mild boost when most sampled rows match — never a hard filter.
    if (density >= 0.5) score += 25;
    if (density >= 0.8) score += 25;
    return score;
  }

  /// Significant tokens from a cleaned title (length ≥ 5, stopwords dropped).
  ///
  /// Used to find Xtream language editions with localized names (e.g. PT
  /// `SampleTitle - The Maze`) after one sibling gets a panel `tmdb_id`.
  static List<String> significantTitleTokens(String title) {
    const stop = {
      'the',
      'a',
      'an',
      'and',
      'or',
      'of',
      'le',
      'la',
      'les',
      'el',
      'los',
      'der',
      'die',
      'das',
      'um',
      'de',
      'du',
      'des',
      'une',
      'un',
      'para',
      'por',
      'com',
    };
    final out = <String>[];
    final seen = <String>{};
    for (final part in normalizeTitle(title).split(' ')) {
      if (part.length < 5 || stop.contains(part)) continue;
      if (!seen.add(part)) continue;
      out.add(part);
    }
    return out;
  }

  /// Same-source Xtream VODs missing a TMDB id that likely share [seed]'s film.
  ///
  /// Heuristic only — callers must confirm via `get_vod_info` before trusting
  /// a match. Requires a shared year and every significant seed token as a
  /// whole word in the candidate title (keeps OtherTitle out when
  /// the seed is SampleTitle 2026).
  static List<MediaItem> likelyMissingTmdbSiblings({
    required MediaItem seed,
    required Iterable<MediaItem> pool,
    int limit = 24,
  }) {
    if (seed.origin != MediaOrigin.iptvXtream) return const [];
    final source = seed.sourceId?.trim();
    if (source == null || source.isEmpty) return const [];
    final year = seed.year ?? yearFromTitle(seed.title);
    if (year == null) return const [];
    final tokens = significantTitleTokens(displayTitleFor(seed.title));
    if (tokens.isEmpty) return const [];
    // Short single tokens collide ("house", "night"); require ≥6 when alone.
    if (tokens.length == 1 && tokens.first.length < 6) return const [];

    final out = <MediaItem>[];
    for (final item in pool) {
      if (identical(item, seed) || item.id == seed.id) continue;
      if (item.origin != MediaOrigin.iptvXtream) continue;
      if (item.sourceId?.trim() != source) continue;
      if (item.isSeries || item.isEpisode || item.isLive) continue;
      if (item.kind != MediaKind.vod) continue;
      if (item.streamId == null || item.streamId!.isEmpty) continue;
      final existing = ExternalIds.resolvedTmdbId(
        tmdbId: item.tmdbId,
        title: item.title,
        id: item.id,
        tags: item.tags,
        originalTitle: item.originalTitle,
      );
      if (existing != null && existing > 0) continue;
      final itemYear = item.year ?? yearFromTitle(item.title);
      if (itemYear != year) continue;
      final hay = ' ${normalizeTitle(item.title)} ';
      var allHit = true;
      for (final token in tokens) {
        if (!hay.contains(' $token ')) {
          allHit = false;
          break;
        }
      }
      if (!allHit) continue;
      out.add(item);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Apply list-row heuristics (year, poster, cleaned subtitle) without network.
  static MediaItem decorate(MediaItem item) {
    if (item.kind != MediaKind.vod && item.kind != MediaKind.series) {
      return item;
    }
    final year = item.year ?? yearFromTitle(item.title);
    final tmdb = ExternalIds.resolvedTmdbId(
      tmdbId: item.tmdbId,
      title: item.title,
      id: item.id,
      tags: item.tags,
      originalTitle: item.originalTitle,
    );
    final imdb = ExternalIds.resolvedImdbId(
      imdbId: item.imdbId,
      title: item.title,
      id: item.id,
      tags: item.tags,
      originalTitle: item.originalTitle,
    );
    final art = item.posterUrl ?? item.thumbnailUrl;
    final lang = languageCode(item);
    final audio = [
      for (final e
          in item.audioLanguages.isNotEmpty
              ? item.audioLanguages
              : [if (lang != null && lang != 'multi') lang])
        if (_knownLangCode(e) != null) _knownLangCode(e)!,
    ];
    final subs = item.subtitleLanguages.isNotEmpty
        ? item.subtitleLanguages
        : inferredSubtitleLanguages(item)
              .where(
                (e) =>
                    e != 'sub' &&
                    e != 'subbed' &&
                    e != 'hardsub' &&
                    e != 'softsub' &&
                    e != 'cc',
              )
              .map((e) => e == 'multi' ? 'multi' : e)
              .toList();
    final caption = captionLabel(item);
    return item.copyWith(
      year: year,
      tmdbId: tmdb,
      imdbId: imdb,
      posterUrl: art,
      thumbnailUrl: item.thumbnailUrl ?? art,
      audioLanguages: audio,
      subtitleLanguages: subs,
      subtitle: [
        if (lang != null) lang.toUpperCase(),
        if (caption != null) caption,
        if (year != null) '$year',
        if (item.group != null && item.group!.isNotEmpty) item.group!,
      ].join(' · '),
    );
  }

  /// Resolution + HDR bucket used to keep **distinct files** (4K vs 1080 URLs)
  /// as separate encodes. HLS/DASH rungs on the **same** `playUrl` are not
  /// versions — [collapseSameStreamEditions] folds them first.
  static VodQualityKey qualityKey(MediaItem item) {
    return qualityKeyFor(
      title: item.title,
      group: item.group,
      subtitle: item.subtitle,
      resolution: item.resolution,
      hdr: item.hdr,
      extra: item.torrentFile,
    );
  }

  static VodQualityKey qualityKeyFor({
    String? title,
    String? group,
    String? subtitle,
    String? resolution,
    String? hdr,
    String? extra,
  }) {
    final hay = [
      title ?? '',
      group ?? '',
      subtitle ?? '',
      resolution ?? '',
      hdr ?? '',
      extra ?? '',
    ].join(' ').toLowerCase();
    final bucket = () {
      if (_resUhd.hasMatch(hay)) return VodQualityBucket.uhd;
      if (_res1080.hasMatch(hay)) return VodQualityBucket.hd1080;
      if (_res720.hasMatch(hay)) return VodQualityBucket.hd720;
      if (_resSd.hasMatch(hay)) return VodQualityBucket.sd;
      return VodQualityBucket.unknown;
    }();
    final hasHdr = (hdr ?? '').trim().isNotEmpty || _hdrTag.hasMatch(hay);
    return VodQualityKey(bucket: bucket, hdr: hasHdr);
  }

  /// Normalized audio codes used to tell language editions apart.
  static List<String> inferredAudioLanguages(MediaItem item) {
    Iterable<String> raw = const [];
    if (item.audioLanguages.isNotEmpty) {
      raw = item.audioLanguages;
    } else if (item.audioTracks.isNotEmpty) {
      raw = [
        for (final t in item.audioTracks)
          if ((t.language ?? '').trim().isNotEmpty) t.language!.trim(),
      ];
    } else {
      final lang = languageCode(item);
      if (lang != null && lang.isNotEmpty) raw = [lang];
    }
    final out = <String>[];
    for (final e in raw) {
      final n = _knownLangCode(e);
      if (n != null) out.add(n);
    }
    if (out.isNotEmpty) return out;
    final upper = _tagHaystack(item).toUpperCase();
    if (RegExp(
      r'MULTI[-\s]?AUDIO|MULTI[-\s]?LANG|\bDUAL[-\s]?AUDIO\b',
    ).hasMatch(upper)) {
      return const ['multi'];
    }
    return const [];
  }

  /// Fingerprint: same source + quality + inferred audio/subs collapse together.
  static String languageFingerprint(MediaItem item) {
    final audio = inferredAudioLanguages(item).toSet().toList()..sort();
    final subs = <String>{
      for (final e in inferredSubtitleLanguages(item))
        if (e.trim().isNotEmpty) e.trim().toLowerCase(),
    };
    if (explicitlyNoCaptions(item)) subs.add('none');
    final subList = subs.toList()..sort();
    return '${audio.join(',')}|${subList.join(',')}';
  }

  /// Identity for a playable stream: source + URL + torrent file hint.
  ///
  /// Empty `playUrl` (series shells) is not an identity — those stay separate.
  /// Same HLS master listed as 1080 and 4K shares this key; a batch magnet
  /// with different `torrentFile` values does not.
  static String? streamIdentity(MediaItem item) {
    final url = item.playUrl.trim();
    if (url.isEmpty) return null;
    final file = (item.torrentFile ?? '').trim();
    final source = item.sourceId?.trim() ?? '';
    return '$source\t$url\t$file';
  }

  /// Fold rows that are the same file/stream (catalog HLS master tagged as
  /// several qualities, duplicate `playVariants` URLs).
  static List<MediaItem> collapseSameStreamEditions(
    List<MediaItem> items, {
    List<String> preferredLangs = const [],
  }) {
    if (items.length <= 1) return items;
    final buckets = <String, MediaItem>{};
    final order = <String>[];
    final noUrl = <MediaItem>[];
    for (final item in items) {
      final key = streamIdentity(item);
      if (key == null) {
        noUrl.add(item);
        continue;
      }
      final existing = buckets[key];
      if (existing == null) {
        order.add(key);
        buckets[key] = item;
        continue;
      }
      buckets[key] = mergeSameStreamEditions(
        existing,
        item,
        preferredLangs: preferredLangs,
      );
    }
    return [...order.map((k) => buckets[k]!), ...noUrl];
  }

  /// Keep the preferred row, union language lists, stamp the higher resolution
  /// tag (cosmetic — adaptive rungs still live in the player).
  static MediaItem mergeSameStreamEditions(
    MediaItem a,
    MediaItem b, {
    List<String> preferredLangs = const [],
  }) {
    final keepA = compareVariants(a, b, preferredLangs: preferredLangs) <= 0;
    final keep = keepA ? a : b;
    final other = keepA ? b : a;
    final betterRes =
        qualityKey(other).compareTo(qualityKey(keep)) > 0 ? other : keep;
    return keep.copyWith(
      audioLanguages: _unionLangCodes(
        keep.audioLanguages,
        other.audioLanguages,
      ),
      subtitleLanguages: _unionLangCodes(
        keep.subtitleLanguages,
        other.subtitleLanguages,
      ),
      subtitles: _unionSubtitles(keep.subtitles, other.subtitles),
      audioTracks: _unionAudioTracks(keep.audioTracks, other.audioTracks),
      resolution: betterRes.resolution ?? keep.resolution ?? other.resolution,
      hdr: betterRes.hdr ?? keep.hdr ?? other.hdr,
      videoCodec: betterRes.videoCodec ?? keep.videoCodec ?? other.videoCodec,
      audioCodec: keep.audioCodec ?? other.audioCodec,
      httpHeaders: mergePlaybackHeaders(other.httpHeaders, keep.httpHeaders),
    );
  }

  /// Same HLS / file URL on episode `playVariants` → one version.
  static List<EpisodePlayVariant> collapseEpisodeVariantsByStream(
    List<EpisodePlayVariant> variants,
  ) {
    if (variants.length <= 1) return variants;
    final buckets = <String, EpisodePlayVariant>{};
    final order = <String>[];
    for (final v in variants) {
      final url = v.playUrl.trim();
      if (url.isEmpty) continue;
      final key = '$url\t${(v.torrentFile ?? '').trim()}';
      final existing = buckets[key];
      if (existing == null) {
        order.add(key);
        buckets[key] = v;
        continue;
      }
      buckets[key] = _mergeEpisodeVariant(existing, v);
    }
    return [for (final k in order) buckets[k]!];
  }

  static EpisodePlayVariant _mergeEpisodeVariant(
    EpisodePlayVariant a,
    EpisodePlayVariant b,
  ) {
    final qa = qualityKeyFor(
      title: a.label,
      subtitle: a.subtitle,
      resolution: a.resolution,
      hdr: a.hdr,
      extra: a.torrentFile,
    );
    final qb = qualityKeyFor(
      title: b.label,
      subtitle: b.subtitle,
      resolution: b.resolution,
      hdr: b.hdr,
      extra: b.torrentFile,
    );
    final keepA = qa.compareTo(qb) >= 0;
    final keep = keepA ? a : b;
    final other = keepA ? b : a;
    return EpisodePlayVariant(
      id: keep.id,
      label: keep.label,
      playUrl: keep.playUrl,
      subtitle: keep.subtitle ?? other.subtitle,
      resolution: keep.resolution ?? other.resolution,
      videoCodec: keep.videoCodec ?? other.videoCodec,
      audioCodec: keep.audioCodec ?? other.audioCodec,
      hdr: keep.hdr ?? other.hdr,
      torrentFile: keep.torrentFile ?? other.torrentFile,
      audioLanguages: _unionLangCodes(keep.audioLanguages, other.audioLanguages),
      subtitleLanguages: _unionLangCodes(
        keep.subtitleLanguages,
        other.subtitleLanguages,
      ),
      httpHeaders: mergePlaybackHeaders(other.httpHeaders, keep.httpHeaders),
    );
  }

  static List<String> _unionLangCodes(List<String> a, List<String> b) {
    final out = <String>[];
    final seen = <String>{};
    for (final e in [...a, ...b]) {
      final t = e.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  static List<ExternalSubtitle> _unionSubtitles(
    List<ExternalSubtitle> a,
    List<ExternalSubtitle> b,
  ) {
    final out = <ExternalSubtitle>[];
    final seen = <String>{};
    for (final s in [...a, ...b]) {
      final u = s.url.trim();
      if (u.isEmpty || !seen.add(u)) continue;
      out.add(s);
    }
    return out;
  }

  static List<ExternalAudio> _unionAudioTracks(
    List<ExternalAudio> a,
    List<ExternalAudio> b,
  ) {
    final out = <ExternalAudio>[];
    final seen = <String>{};
    for (final t in [...a, ...b]) {
      final u = t.url.trim();
      if (u.isEmpty || !seen.add(u)) continue;
      out.add(t);
    }
    return out;
  }

  /// Drop indistinguishable same-source encodes (two unlabeled MULTI rows).
  static List<MediaItem> collapseIndistinguishableEditions(
    List<MediaItem> items, {
    List<String> preferredLangs = const [],
  }) {
    if (items.length <= 1) return items;
    final folded = collapseSameStreamEditions(
      items,
      preferredLangs: preferredLangs,
    );
    if (folded.length <= 1) return folded;
    final buckets = <String, MediaItem>{};
    for (final item in folded) {
      final source = item.sourceId?.trim() ?? '';
      final file = (item.torrentFile ?? '').trim();
      final key =
          '$source\t${qualityKey(item).id}\t${languageFingerprint(item)}\t$file';
      final existing = buckets[key];
      if (existing == null) {
        buckets[key] = item;
        continue;
      }
      final cmp = compareVariants(
        item,
        existing,
        preferredLangs: preferredLangs,
      );
      if (cmp < 0) buckets[key] = item;
    }
    final out = buckets.values.toList();
    out.sort((a, b) => compareVariants(a, b, preferredLangs: preferredLangs));
    return out;
  }

  /// Source → quality → remaining language editions for a title family.
  static VodFamilyLayout familyLayout(
    List<MediaItem> variants, {
    List<String> preferredLangs = const [],
    String Function(MediaItem item)? sourceLabelFor,
  }) {
    final collapsed = collapseIndistinguishableEditions(
      variants,
      preferredLangs: preferredLangs,
    );
    if (collapsed.isEmpty) return const VodFamilyLayout(sources: []);

    final bySource = <String, List<MediaItem>>{};
    final sourceOrder = <String>[];
    for (final item in collapsed) {
      final sid = item.sourceId?.trim() ?? '';
      if (!bySource.containsKey(sid)) {
        sourceOrder.add(sid);
        bySource[sid] = [];
      }
      bySource[sid]!.add(item);
    }

    final sources = <VodSourceGroup>[];
    for (final sid in sourceOrder) {
      final members = bySource[sid]!;
      final byQuality = <String, List<MediaItem>>{};
      final qualityOrder = <String>[];
      for (final item in members) {
        final q = qualityKey(item);
        if (!byQuality.containsKey(q.id)) {
          qualityOrder.add(q.id);
          byQuality[q.id] = [];
        }
        byQuality[q.id]!.add(item);
      }
      qualityOrder.sort((a, b) {
        final qa = byQuality[a]!.first;
        final qb = byQuality[b]!.first;
        return qualityKey(qb).compareTo(qualityKey(qa));
      });
      final label = sourceLabelFor != null
          ? sourceLabelFor(members.first)
          : (sid.isEmpty ? '' : sid);
      sources.add(
        VodSourceGroup(
          sourceId: sid,
          sourceLabel: label,
          qualities: [
            for (final qid in qualityOrder)
              VodQualityCluster(
                sourceId: sid,
                sourceLabel: label,
                quality: qualityKey(byQuality[qid]!.first),
                editions: byQuality[qid]!,
              ),
          ],
        ),
      );
    }
    return VodFamilyLayout(sources: sources);
  }

  /// Other series shells to try when [current] has no playable episode URL.
  ///
  /// Other catalogs first, then same-source alternate encodes.
  static List<MediaItem> siblingSeriesShells({
    required MediaItem current,
    required List<MediaItem> editions,
  }) {
    final otherSource = <MediaItem>[];
    final sameSource = <MediaItem>[];
    final currentSource = current.sourceId ?? '';
    for (final e in editions) {
      if (e.id == current.id) continue;
      if (!e.isSeries) continue;
      if ((e.sourceId ?? '') != currentSource) {
        otherSource.add(e);
      } else {
        sameSource.add(e);
      }
    }
    return [...otherSource, ...sameSource];
  }

  static bool _isMultiLangToken(String t) =>
      t == 'multi' || t == 'multisub' || t == 'msub';

  static bool _isNonLanguageTrackToken(String t) =>
      t == 'hardsub' ||
      t == 'softsub' ||
      t == 'cc' ||
      t == 'sdh' ||
      t == 'sub' ||
      t == 'subbed';

  /// Unique ISO codes; `jpn`/`ja` collapse. [hasMulti] when only a MULTI tag.
  static ({List<String> codes, bool hasMulti}) _catalogLangSet(
    Iterable<String> langs,
  ) {
    final codes = <String>[];
    final seen = <String>{};
    var hasMulti = false;
    for (final raw in langs) {
      final t = raw.trim().toLowerCase();
      if (t.isEmpty) continue;
      if (_isMultiLangToken(t)) {
        hasMulti = true;
        continue;
      }
      if (_isNonLanguageTrackToken(t)) continue;
      final n = TrackLanguage.normalize(t);
      if (n == null) continue;
      if (!TrackLanguage.isCatalogLanguageTag(t) && n.length != 2) continue;
      if (!seen.add(n)) continue;
      codes.add(n);
    }
    return (codes: codes, hasMulti: hasMulti);
  }

  static List<String> _orderLangCodes(List<String> codes, List<String> prefs) {
    if (codes.isEmpty) return const [];
    final remaining = codes.toSet();
    final out = <String>[];
    for (final p in prefs) {
      if (remaining.remove(p)) out.add(p);
    }
    for (final c in codes) {
      if (remaining.remove(c)) out.add(c);
    }
    return out;
  }

  /// Availability line (`Audio JA/FR · Subs FR/EN`).
  ///
  /// Lists every known audio/caption language. [preferredLangs] only
  /// controls order (preferred codes first). `multi` is shown when there
  /// are no concrete codes.
  static String localeAvailabilityLabel({
    required Iterable<String> audioLangs,
    required Iterable<String> subtitleLangs,
    List<String> preferredLangs = const [],
  }) {
    final prefs = [
      for (final p in normalizePreferredLangs(preferredLangs))
        TrackLanguage.normalize(p) ?? p,
    ];
    final audio = _catalogLangSet(audioLangs);
    final subs = _catalogLangSet(subtitleLangs);
    final parts = <String>[];
    final audioHits = _orderLangCodes(audio.codes, prefs);
    if (audioHits.isNotEmpty) {
      parts.add(
        'Audio ${audioHits.map((e) => e.toUpperCase()).join('/')}',
      );
    } else if (audio.hasMulti) {
      parts.add('Multi audio');
    }
    final subHits = _orderLangCodes(subs.codes, prefs);
    if (subHits.isNotEmpty) {
      parts.add('Subs ${subHits.map((e) => e.toUpperCase()).join('/')}');
    } else if (subs.hasMulti) {
      parts.add('Multi-sub');
    }
    return parts.join(' · ');
  }

  static String editionDownloadLabel(
    MediaItem item, {
    String? sourceLabel,
    List<String> preferredLangs = const [],
  }) {
    final parts = <String>[
      if ((sourceLabel ?? '').trim().isNotEmpty) sourceLabel!.trim(),
      qualityKey(item).label,
      localeAvailabilityLabel(
        audioLangs: inferredAudioLanguages(item),
        subtitleLangs: inferredSubtitleLanguages(item),
        preferredLangs: preferredLangs,
      ),
    ].where((e) => e.trim().isNotEmpty).toList();
    if (parts.isEmpty) return variantLabel(item, sourceLabel: sourceLabel);
    return parts.join(' · ');
  }
}

enum VodQualityBucket { uhd, hd1080, hd720, sd, unknown }

class VodQualityKey implements Comparable<VodQualityKey> {
  const VodQualityKey({required this.bucket, required this.hdr});

  final VodQualityBucket bucket;
  final bool hdr;

  String get id => '${bucket.name}${hdr ? '+hdr' : ''}';

  String get label {
    final base = switch (bucket) {
      VodQualityBucket.uhd => '4K',
      VodQualityBucket.hd1080 => '1080p',
      VodQualityBucket.hd720 => '720p',
      VodQualityBucket.sd => 'SD',
      VodQualityBucket.unknown => '',
    };
    if (base.isEmpty) return hdr ? 'HDR' : '';
    return hdr ? '$base HDR' : base;
  }

  @override
  int compareTo(VodQualityKey other) {
    final byBucket = other.bucket.index.compareTo(bucket.index);
    if (byBucket != 0) return byBucket;
    if (hdr == other.hdr) return 0;
    return hdr ? -1 : 1;
  }

  @override
  bool operator ==(Object other) =>
      other is VodQualityKey && other.bucket == bucket && other.hdr == hdr;

  @override
  int get hashCode => Object.hash(bucket, hdr);
}

class VodQualityCluster {
  const VodQualityCluster({
    required this.sourceId,
    required this.sourceLabel,
    required this.quality,
    required this.editions,
  });

  final String sourceId;
  final String sourceLabel;
  final VodQualityKey quality;
  final List<MediaItem> editions;

  List<String> get audioLanguages => [
    for (final e in editions) ...VodGrouping.inferredAudioLanguages(e),
  ];

  List<String> get subtitleLanguages => [
    for (final e in editions) ...VodGrouping.inferredSubtitleLanguages(e),
  ];

  MediaItem representative({List<String> preferredLangs = const []}) {
    if (editions.length <= 1) return editions.first;
    var best = editions.first;
    for (var i = 1; i < editions.length; i++) {
      if (VodGrouping.compareVariants(
            editions[i],
            best,
            preferredLangs: preferredLangs,
          ) <
          0) {
        best = editions[i];
      }
    }
    return best;
  }

  bool contains(MediaItem item) => editions.any((e) => e.id == item.id);

  MediaItem? editionForAudio(String lang) {
    final code = lang.trim().toLowerCase();
    if (code.isEmpty) return null;
    MediaItem? multi;
    for (final e in editions) {
      final audio = VodGrouping.inferredAudioLanguages(e);
      if (audio.contains(code)) return e;
      if (multi == null && audio.contains('multi')) multi = e;
    }
    return multi;
  }

  MediaItem? editionForSubtitle(String lang) {
    final code = lang.trim().toLowerCase();
    if (code.isEmpty) return null;
    MediaItem? multi;
    for (final e in editions) {
      final subs = VodGrouping.inferredSubtitleLanguages(e);
      if (subs.contains(code)) return e;
      if (multi == null &&
          (subs.contains('multi') ||
              subs.contains('multisub') ||
              subs.contains('msub'))) {
        multi = e;
      }
    }
    return multi;
  }
}

class VodSourceGroup {
  const VodSourceGroup({
    required this.sourceId,
    required this.sourceLabel,
    required this.qualities,
  });

  final String sourceId;
  final String sourceLabel;
  final List<VodQualityCluster> qualities;

  MediaItem representative({List<String> preferredLangs = const []}) {
    if (qualities.isEmpty) {
      throw StateError('empty source group');
    }
    if (qualities.length == 1) {
      return qualities.first.representative(preferredLangs: preferredLangs);
    }
    var best = qualities.first.representative(preferredLangs: preferredLangs);
    for (var i = 1; i < qualities.length; i++) {
      final candidate = qualities[i].representative(
        preferredLangs: preferredLangs,
      );
      if (VodGrouping.compareVariants(
            candidate,
            best,
            preferredLangs: preferredLangs,
          ) <
          0) {
        best = candidate;
      }
    }
    return best;
  }
}

class VodFamilyLayout {
  const VodFamilyLayout({required this.sources});

  final List<VodSourceGroup> sources;

  bool get isEmpty => sources.isEmpty;
  bool get hasMultipleSources => sources.length > 1;
  bool get hasMultipleQualities =>
      sources.any((s) => s.qualities.length > 1) ||
      sources.fold<int>(0, (n, s) => n + s.qualities.length) > 1;

  List<MediaItem> get editions => [
    for (final s in sources)
      for (final q in s.qualities) ...q.editions,
  ];

  int get distinctEncodeCount => editions.length;

  /// Audio / captions / ceiling quality for the title page (`Audio JA/FR · Subs FR · Up to 4K`).
  ///
  /// Sources stay off this line — Play auto-picks, the player switches.
  String availabilityLabel({List<String> preferredLangs = const []}) {
    final locale = VodGrouping.localeAvailabilityLabel(
      audioLangs: [
        for (final e in editions) ...VodGrouping.inferredAudioLanguages(e),
      ],
      subtitleLangs: [
        for (final e in editions) ...VodGrouping.inferredSubtitleLanguages(e),
      ],
      preferredLangs: preferredLangs,
    );
    VodQualityKey? best;
    final buckets = <String>{};
    for (final e in editions) {
      final q = VodGrouping.qualityKey(e);
      buckets.add(q.id);
      if (q.bucket == VodQualityBucket.unknown && !q.hdr) continue;
      if (best == null || q.compareTo(best) > 0) best = q;
    }
    final quality = best?.label ?? '';
    final qualityBit = quality.isEmpty
        ? ''
        : (buckets.length > 1 ? 'Up to $quality' : quality);
    return [
      locale,
      qualityBit,
    ].where((e) => e.trim().isNotEmpty).join(' · ');
  }

  /// Audio/sub encode anywhere in the family (not only the current source).
  MediaItem? editionForAudio(
    String lang, {
    MediaItem? preferNear,
    List<String> preferredLangs = const [],
  }) {
    return _editionForLang(
      lang,
      audio: true,
      preferNear: preferNear,
      preferredLangs: preferredLangs,
    );
  }

  MediaItem? editionForSubtitle(
    String lang, {
    MediaItem? preferNear,
    List<String> preferredLangs = const [],
  }) {
    return _editionForLang(
      lang,
      audio: false,
      preferNear: preferNear,
      preferredLangs: preferredLangs,
    );
  }

  MediaItem? _editionForLang(
    String lang, {
    required bool audio,
    MediaItem? preferNear,
    List<String> preferredLangs = const [],
  }) {
    final hits = <MediaItem>[];
    for (final s in sources) {
      for (final q in s.qualities) {
        final hit = audio
            ? q.editionForAudio(lang)
            : q.editionForSubtitle(lang);
        if (hit != null) hits.add(hit);
      }
    }
    if (hits.isEmpty) return null;
    if (preferNear != null) {
      final qid = VodGrouping.qualityKey(preferNear).id;
      final sid = preferNear.sourceId?.trim() ?? '';
      MediaItem? pick(Iterable<MediaItem> pool) {
        final list = pool.toList();
        if (list.isEmpty) return null;
        list.sort(
          (a, b) => VodGrouping.compareVariants(
            a,
            b,
            preferredLangs: preferredLangs,
          ),
        );
        return list.first;
      }

      final sameSourceQ = pick(
        hits.where(
          (e) =>
              (e.sourceId?.trim() ?? '') == sid &&
              VodGrouping.qualityKey(e).id == qid,
        ),
      );
      if (sameSourceQ != null) return sameSourceQ;
      final sameQ = pick(
        hits.where((e) => VodGrouping.qualityKey(e).id == qid),
      );
      if (sameQ != null) return sameQ;
    }
    hits.sort(
      (a, b) =>
          VodGrouping.compareVariants(a, b, preferredLangs: preferredLangs),
    );
    return hits.first;
  }

  /// One encode per quality bucket across sources, matching [matchLangOf]
  /// when that language exists at that quality.
  List<MediaItem> qualityChoices({
    List<String> preferredLangs = const [],
    MediaItem? matchLangOf,
  }) {
    final byId = <String, List<MediaItem>>{};
    final order = <String>[];
    for (final e in editions) {
      final id = VodGrouping.qualityKey(e).id;
      if (!byId.containsKey(id)) {
        order.add(id);
        byId[id] = [];
      }
      byId[id]!.add(e);
    }
    if (order.length <= 1) return const [];
    order.sort((a, b) {
      final qa = VodGrouping.qualityKey(byId[a]!.first);
      final qb = VodGrouping.qualityKey(byId[b]!.first);
      return qb.compareTo(qa);
    });
    final want = matchLangOf == null
        ? const <String>[]
        : VodGrouping.inferredAudioLanguages(matchLangOf);
    return [
      for (final id in order)
        _qualityRepresentative(
          byId[id]!,
          preferredLangs: preferredLangs,
          wantAudio: want,
        ),
    ];
  }

  static MediaItem _qualityRepresentative(
    List<MediaItem> items, {
    required List<String> preferredLangs,
    required List<String> wantAudio,
  }) {
    if (wantAudio.isNotEmpty) {
      for (final code in wantAudio) {
        for (final e in items) {
          if (VodGrouping.inferredAudioLanguages(e).contains(code)) {
            return e;
          }
        }
      }
    }
    var best = items.first;
    for (final e in items.skip(1)) {
      if (VodGrouping.compareVariants(
            e,
            best,
            preferredLangs: preferredLangs,
          ) <
          0) {
        best = e;
      }
    }
    return best;
  }

  VodQualityCluster? clusterFor(MediaItem item) {
    for (final s in sources) {
      for (final q in s.qualities) {
        if (q.contains(item)) return q;
      }
    }
    return null;
  }

  VodQualityCluster? clusterMatching(MediaItem item) {
    final hit = clusterFor(item);
    if (hit != null) return hit;
    final sid = item.sourceId?.trim() ?? '';
    final qid = VodGrouping.qualityKey(item).id;
    for (final s in sources) {
      if (s.sourceId != sid) continue;
      for (final q in s.qualities) {
        if (q.quality.id == qid) return q;
      }
    }
    return null;
  }
}
