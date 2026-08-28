import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';

/// Rank IPTV group titles against the device locale using common panel prefixes
/// (`EU | FRANCE…`, `[FR] …`, `JP | …`).
class IptvLocaleHints {
  IptvLocaleHints._();

  static Duration? _debugTimeZoneOffset;

  /// Test override for [DateTime.now] offset. Pass `null` to clear.
  @visibleForTesting
  static void debugTimeZoneOffset(Duration? offset) {
    _debugTimeZoneOffset = offset;
  }

  static Duration get _timeZoneOffset =>
      _debugTimeZoneOffset ?? DateTime.now().timeZoneOffset;

  /// Locale used for IPTV region matching / For you labels.
  ///
  /// Fire OS (and some AOSP builds) expose **Français** as `fr_CA`. That is
  /// Canadian French as a language tag, not “this device is in Canada” —
  /// unless the clock is in the Americas (Québec / Canada), in which case
  /// `CA |` is correct. Europe/Africa offsets remap to `fr_FR`.
  static Locale normalize(Locale locale) {
    final lang = locale.languageCode.toLowerCase();
    final country = (locale.countryCode ?? '').toUpperCase();
    if (lang == 'fr' && country == 'CA') {
      // Canada is UTC−3:30…−8; France / Fire-OS-in-Europe is UTC+0…+2.
      if (_timeZoneOffset.isNegative) {
        return const Locale('fr', 'CA');
      }
      return const Locale('fr', 'FR');
    }
    if (country.isEmpty) return Locale(lang);
    return Locale(lang, country);
  }

  /// Country or language code shown in “Matched to XX”.
  static String matchCode(Locale locale) {
    final resolved = normalize(locale);
    final country = resolved.countryCode;
    if (country != null && country.isNotEmpty) {
      return country.toUpperCase();
    }
    return resolved.languageCode.toUpperCase();
  }

  /// Device locale after Fire OS / timezone remap (Catalog + Live For you).
  static Locale get contentLocale =>
      normalize(PlatformDispatcher.instance.locale);

  /// Title / group prefixes that count as this locale’s region
  /// (`FR|` in Europe, `CA|` / `QC|` in Canada).
  static Set<String> regionTagsFor(Locale locale) {
    final resolved = normalize(locale);
    final lang = resolved.languageCode.toLowerCase();
    final country = (resolved.countryCode ?? '').toLowerCase();
    final out = <String>{lang};
    switch (lang) {
      case 'fr':
        if (country == 'ca') {
          out.addAll(['ca', 'qc']);
        } else {
          out.addAll(['fr', 'be']);
        }
      case 'en':
        if (country == 'ca') {
          out.addAll(['ca', 'qc']);
        } else if (country == 'gb' || country == 'uk') {
          out.addAll(['uk', 'gb']);
        } else if (country == 'us') {
          out.add('us');
        }
      default:
        if (country.isNotEmpty) out.add(country);
    }
    return out;
  }

  /// Higher locale score first, then A–Z. Used by Catalog, Live categories,
  /// and the fullscreen player category column.
  static int compareGroupNames(String a, String b, [Locale? locale]) {
    final loc = locale ?? contentLocale;
    final byScore = scoreGroup(b, loc).compareTo(scoreGroup(a, loc));
    if (byScore != 0) return byScore;
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  static List<String> tokensFor(Locale locale) {
    final resolved = normalize(locale);
    final lang = resolved.languageCode.toLowerCase();
    final country = (resolved.countryCode ?? '').toLowerCase();
    final out = <String>{lang};

    switch (lang) {
      case 'fr':
        out.addAll([
          'france',
          'french',
          'francais',
          'français',
          'belg',
          'suisse',
          'eu | fr',
          'eu | france',
          'be |',
        ]);
      case 'en':
        out.addAll([
          'english',
          'british',
          'america',
          'uk |',
          'us |',
          'eu | uk',
          'eu | en',
          'au |',
          'nz |',
        ]);
      case 'de':
        out.addAll([
          'deutsch',
          'german',
          'allemagne',
          'austria',
          'österreich',
          'eu | de',
          'de |',
          'at |',
        ]);
      case 'es':
        out.addAll([
          'spain',
          'espanol',
          'español',
          'latino',
          'eu | es',
          'es |',
          'mx |',
          'ar | argentina',
        ]);
      case 'it':
        out.addAll(['ital', 'eu | it', 'it |']);
      case 'pt':
        out.addAll([
          'portugal',
          'brazil',
          'brasil',
          'brasile',
          'pt |',
          'br |',
          'eu | pt',
        ]);
      case 'nl':
        out.addAll(['dutch', 'neder', 'belg', 'nl |', 'eu | nl', 'be |']);
      case 'ar':
        out.addAll(['arab', 'arabic', 'ar |', 'mena']);
      case 'ja':
        out.addAll(['japan', 'japon', 'jp |', 'ja |']);
      case 'tr':
        out.addAll(['turk', 'tr |', 'eu | tr']);
      case 'pl':
        out.addAll(['polsk', 'poland', 'pl |', 'eu | pl']);
      case 'ru':
        out.addAll(['russ', 'ru |']);
      default:
        break;
    }

    if (country.isNotEmpty) {
      // Prefix form only — a raw 2-letter `contains` matches inside other
      // words (`ca` ⊂ `france`).
      out.add('$country |');
      switch (country) {
        case 'fr':
          out.addAll(['france', 'eu | france', 'eu | fr']);
        case 'be':
          out.addAll(['belg', 'eu | belg', 'be |']);
        case 'ch':
          out.addAll(['suisse', 'swiss', 'ch |']);
        case 'ca':
          out.addAll(['canada', 'quebec', 'québec', 'ca |', 'qc |']);
        case 'gb':
        case 'uk':
          out.addAll(['british', 'uk |', 'eu | uk']);
        case 'us':
          out.addAll(['america', 'us |']);
        case 'jp':
          out.addAll(['japan', 'jp |']);
        default:
          break;
      }
    }

    return out.toList();
  }

  /// Higher = better match for [locale]. `0` = no signal.
  static int scoreGroup(String group, Locale locale) {
    final raw = group.trim();
    if (raw.isEmpty) return 0;
    final g = raw.toLowerCase();
    var score = 0;

    final resolved = normalize(locale);
    final lang = resolved.languageCode.toLowerCase();
    final country = (resolved.countryCode ?? '').toLowerCase();
    final bracket = RegExp(r'\[([a-z]{2,5})\]', caseSensitive: false);
    for (final match in bracket.allMatches(raw)) {
      final tag = match.group(1)!.toLowerCase();
      if (tag == lang || (country.isNotEmpty && tag == country)) {
        score += 16;
      } else if (tag == 'multi' || tag.startsWith('multi')) {
        score += 1;
      }
    }

    final regionPrefix = RegExp(r'^([a-z]{2,3})\s*\|', caseSensitive: false);
    final prefix = regionPrefix.firstMatch(g);
    if (prefix != null) {
      final code = prefix.group(1)!;
      // Country prefix outranks language-only (`CA |` vs `FR |` for Québec).
      if (country.isNotEmpty &&
          (code == country || (country == 'ca' && code == 'qc'))) {
        score += 10;
      } else if (code == lang) {
        score += 6;
      }
      // Common panel region buckets for Western Europe FR users.
      if (lang == 'fr' && (code == 'eu' || code == 'fr' || code == 'be')) {
        score += 2;
      }
      if (country == 'ca' && (code == 'ca' || code == 'qc')) {
        score += 4;
      }
      if (lang == 'en' &&
          (code == 'uk' || code == 'us' || code == 'en' || code == 'eu')) {
        score += 2;
      }
      if (lang == 'ja' && (code == 'jp' || code == 'as')) {
        score += 4;
      }
    }

    for (final token in tokensFor(locale)) {
      if (token.isEmpty) continue;
      if (g.contains(token)) {
        score += token.length >= 5 ? 4 : 2;
      }
    }

    if (g.contains('multi-lang') || g.contains('multi lang')) {
      score += 1;
    }

    return score;
  }

  /// Best-matching group names first; drops zero-score groups.
  static List<String> rankGroups(Iterable<String> groups, Locale locale) {
    final scored = <({String name, int score})>[
      for (final name in groups)
        if (name.trim().isNotEmpty) (name: name, score: scoreGroup(name, locale)),
    ]..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return [
      for (final row in scored)
        if (row.score > 0) row.name,
    ];
  }
}
