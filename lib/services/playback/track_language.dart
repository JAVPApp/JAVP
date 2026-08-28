import 'dart:ui' show PlatformDispatcher;

import 'package:javp/l10n/app_localizations.dart';

/// Match media_kit / catalog language tags to preferred codes.
abstract final class TrackLanguage {
  static const commonChoices = <({String code, String label})>[
    (code: 'auto', label: 'Preferred / device language (when audio differs)'),
    (code: 'en', label: 'English'),
    (code: 'fr', label: 'Français'),
    (code: 'es', label: 'Español'),
    (code: 'de', label: 'Deutsch'),
    (code: 'it', label: 'Italiano'),
    (code: 'pt', label: 'Português'),
    (code: 'ja', label: '日本語'),
    (code: 'ko', label: '한국어'),
    (code: 'zh', label: '中文'),
    (code: 'ar', label: 'العربية'),
    (code: 'ru', label: 'Русский'),
    (code: 'nl', label: 'Nederlands'),
    (code: 'pl', label: 'Polski'),
    (code: 'tr', label: 'Türkçe'),
    (code: 'hi', label: 'हिन्दी'),
    (code: 'sv', label: 'Svenska'),
    (code: 'da', label: 'Dansk'),
    (code: 'no', label: 'Norsk'),
    (code: 'fi', label: 'Suomi'),
  ];

  /// ISO 639-1 / 639-2 (B+T) / mkv+mpv tags + IPTV / scene tokens
  /// (`VF`, `VOSTFR`, `JP|`, …).
  static const _aliases = <String, String>{
    // English — ISO 639-2 is only `eng` (no B/T split).
    'eng': 'en',
    'enm': 'en',
    'english': 'en',
    'anglais': 'en',
    'british': 'en',
    'american': 'en',
    'vosten': 'en',
    'vosta': 'en',
    'vostang': 'en',
    'vosteng': 'en',
    'sten': 'en',
    'suben': 'en',
    'engsub': 'en',
    'subeng': 'en',
    'omeu': 'en', // German: Original mit englischen Untertiteln
    // French — 639-2/T `fra`, 639-2/B `fre`. IPTV: VF / VOSTFR / VFQ…
    'fre': 'fr',
    'fra': 'fr',
    'french': 'fr',
    'français': 'fr',
    'francais': 'fr',
    'vf': 'fr',
    'vff': 'fr',
    'vfi': 'fr',
    'vfq': 'fr',
    'vfb': 'fr',
    'vostfr': 'fr',
    'vostf': 'fr',
    'stfr': 'fr',
    'subfr': 'fr',
    'truefrench': 'fr',
    'québécois': 'fr',
    'quebecois': 'fr',
    'quebec': 'fr',
    // German — 639-2/T `deu`, 639-2/B `ger`. OmU / OmdU = original + German subs.
    'ger': 'de',
    'deu': 'de',
    'german': 'de',
    'deutsch': 'de',
    'allemand': 'de',
    'vostde': 'de',
    'vostger': 'de',
    'omu': 'de',
    'omdu': 'de',
    'subde': 'de',
    'subger': 'de',
    // Spanish — VOSE = Versión Original Subtitulada Español.
    'spa': 'es',
    'spanish': 'es',
    'español': 'es',
    'espanol': 'es',
    'castilian': 'es',
    'castellano': 'es',
    'latino': 'es',
    'latam': 'es',
    'vostes': 'es',
    'vostesp': 'es',
    'vose': 'es',
    'vosesp': 'es',
    'subes': 'es',
    'subesp': 'es',
    'subcast': 'es',
    // Italian — SUB ITA / SUBITA.
    'ita': 'it',
    'italian': 'it',
    'italiano': 'it',
    'italien': 'it',
    'vostit': 'it',
    'subita': 'it',
    'itasub': 'it',
    // Portuguese — LEGENDADO = original + Portuguese subs (BR). DUBLADO = PT dub.
    'por': 'pt',
    'portuguese': 'pt',
    'português': 'pt',
    'portugues': 'pt',
    'brazilian': 'pt',
    'brasileiro': 'pt',
    'ptbr': 'pt',
    'vostpt': 'pt',
    'legendado': 'pt',
    'legendada': 'pt',
    'legpt': 'pt',
    'subpt': 'pt',
    'dublado': 'pt',
    'dublada': 'pt',
    // Japanese — 639-2 `jpn`. IPTV prefixes `JP|` / `JA|`.
    'jpn': 'ja',
    'jp': 'ja',
    'jap': 'ja',
    'japanese': 'ja',
    'japonais': 'ja',
    'nihongo': 'ja',
    'vostjp': 'ja',
    'vostja': 'ja',
    'vostjpn': 'ja',
    // Korean
    'kor': 'ko',
    'korean': 'ko',
    'coréen': 'ko',
    'coreen': 'ko',
    'hangul': 'ko',
    'vostko': 'ko',
    'subko': 'ko',
    // Chinese — 639-2/T `zho`, 639-2/B `chi`.
    'chi': 'zh',
    'zho': 'zh',
    'cmn': 'zh',
    'chinese': 'zh',
    'mandarin': 'zh',
    'cantonese': 'zh',
    'yue': 'zh',
    'cht': 'zh',
    'chs': 'zh',
    'zhcn': 'zh',
    'zhtw': 'zh',
    'cn': 'zh',
    // Arabic
    'ara': 'ar',
    'arabic': 'ar',
    'arabe': 'ar',
    'vostar': 'ar',
    'subar': 'ar',
    // Russian
    'rus': 'ru',
    'russian': 'ru',
    'russe': 'ru',
    'vostru': 'ru',
    'subru': 'ru',
    'subrus': 'ru',
    // Dutch — 639-2/T `nld`, 639-2/B `dut`.
    'dut': 'nl',
    'nld': 'nl',
    'dutch': 'nl',
    'flemish': 'nl',
    'nederlands': 'nl',
    'néerlandais': 'nl',
    'neerlandais': 'nl',
    'vostnl': 'nl',
    'subnl': 'nl',
    'ondertiteld': 'nl',
    // Polish — NAPISY = subs.
    'pol': 'pl',
    'polish': 'pl',
    'polski': 'pl',
    'polonais': 'pl',
    'vostpl': 'pl',
    'subpl': 'pl',
    'napisy': 'pl',
    'nappl': 'pl',
    // Turkish
    'tur': 'tr',
    'turkish': 'tr',
    'turkce': 'tr',
    'türkçe': 'tr',
    'turc': 'tr',
    // Hindi
    'hin': 'hi',
    'hindi': 'hi',
    // Swedish / Danish / Norwegian / Finnish
    'swe': 'sv',
    'swedish': 'sv',
    'svenska': 'sv',
    'suédois': 'sv',
    'suedois': 'sv',
    'dan': 'da',
    'danish': 'da',
    'dansk': 'da',
    'danois': 'da',
    'nor': 'no',
    'nob': 'no',
    'nno': 'no',
    'norwegian': 'no',
    'norsk': 'no',
    'norvégien': 'no',
    'norvegien': 'no',
    'fin': 'fi',
    'finnish': 'fi',
    'suomi': 'fi',
    'finnois': 'fi',
    // Other mkv tracks that show up on IPTV / anime rips.
    'heb': 'he',
    'iw': 'he',
    'hebrew': 'he',
    'hébreu': 'he',
    'hebreu': 'he',
    'ell': 'el',
    'gre': 'el',
    'greek': 'el',
    'grec': 'el',
    'ces': 'cs',
    'cze': 'cs',
    'czech': 'cs',
    'tchèque': 'cs',
    'tcheque': 'cs',
    'ron': 'ro',
    'rum': 'ro',
    'romanian': 'ro',
    'roumain': 'ro',
    // Albanian — ISO 639-1 `sq`, 639-2/T `sqi`, 639-2/B `alb`.
    // IPTV panels often use `ALB|` / `[ALB]` (bibliographic code).
    'alb': 'sq',
    'sqi': 'sq',
    'albanian': 'sq',
    'albanais': 'sq',
    'shqip': 'sq',
    'hun': 'hu',
    'hungarian': 'hu',
    'hongrois': 'hu',
    'ukr': 'uk',
    'ukrainian': 'uk',
    'ukrainien': 'uk',
    'tha': 'th',
    'thai': 'th',
    'thaï': 'th',
    'thail': 'th',
    'vie': 'vi',
    'vietnamese': 'vi',
    'vietnamien': 'vi',
    'ind': 'id',
    'indonesian': 'id',
    'indonésien': 'id',
    'indonesien': 'id',
    'may': 'ms',
    'msa': 'ms',
    'malay': 'ms',
    'malais': 'ms',
    'bul': 'bg',
    'bulgarian': 'bg',
    'bulgare': 'bg',
    'hrv': 'hr',
    'croatian': 'hr',
    'croate': 'hr',
    'srp': 'sr',
    'serbian': 'sr',
    'serbe': 'sr',
    'slk': 'sk',
    'slo': 'sk',
    'slovak': 'sk',
    'slovaque': 'sk',
    'slv': 'sl',
    'slovenian': 'sl',
    'slovène': 'sl',
    'slovene': 'sl',
  };

  /// Tokens that look like a 2–3 letter lang tag but are quality / meta.
  static const _notALanguage = {
    'und',
    'unknown',
    'null',
    'mul',
    'mis',
    'zxx',
    'off',
    'auto',
    'sub',
    'subs',
    'dub',
    'cc',
    'sdh',
    'hd',
    'fhd',
    'uhd',
    'hdr',
    'raw',
    'none',
    'na',
  };

  /// True for tags we treat as a real language in catalog UI (`fr`, `jpn`,
  /// `vostfr`) — not leftover 2–3 letter tokens (`lol`, `csi`, `hbo`).
  static bool isCatalogLanguageTag(String? raw) {
    if (raw == null) return false;
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) return false;
    if (t == 'multi' || t == 'multilang' || t == 'msub' || t == 'multisub') {
      return true;
    }
    final compact = t.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (compact.isEmpty || _notALanguage.contains(compact)) return false;
    if (_aliases.containsKey(t) || _aliases.containsKey(compact)) return true;
    final n = normalize(t);
    if (n == null) return false;
    if (commonChoices.any((c) => c.code == n)) return true;
    if (_extraNames.containsKey(n)) return true;
    if (_aliases.containsValue(n)) return true;
    return false;
  }

  static String? normalize(String? raw) {
    if (raw == null) return null;
    var t = raw.trim().toLowerCase();
    if (t.isEmpty) return null;
    t = t.replaceAll('_', '-');
    final compact = t.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (compact.isEmpty || _notALanguage.contains(compact)) return null;
    final aliased = _aliases[t] ?? _aliases[compact];
    if (aliased != null) return aliased;
    final primary = t.split(RegExp(r'[-/]')).first.trim();
    if (primary.isEmpty || _notALanguage.contains(primary)) return null;
    return _aliases[primary] ??
        (primary.length <= 3 ? primary : null);
  }

  static String deviceLanguageCode() {
    // Prefer the full system preference list — `.locale` alone can lag or
    // disagree with the ordered locales Android/iOS expose.
    for (final locale in PlatformDispatcher.instance.locales) {
      final code = normalize(locale.languageCode) ??
          normalize(locale.toLanguageTag());
      if (code != null) return code;
    }
    final locale = PlatformDispatcher.instance.locale;
    return normalize(locale.languageCode) ??
        normalize(locale.toLanguageTag()) ??
        'en';
  }

  static String labelFor(String code) {
    if (code == 'off') return 'Off';
    if (code == 'auto') return 'Device language (when audio differs)';
    for (final c in commonChoices) {
      if (c.code == code) return c.label;
    }
    return _extraNames[code] ?? code.toUpperCase();
  }

  static String labelForL10n(AppLocalizations l10n, String code) {
    if (code == 'off') return l10n.off;
    if (code == 'auto') return l10n.deviceLanguageWhenAudioDiffers;
    for (final c in commonChoices) {
      if (c.code == code) return c.label;
    }
    return _extraNames[code] ?? code.toUpperCase();
  }

  static const _extraNames = <String, String>{
    'he': 'עברית',
    'el': 'Ελληνικά',
    'cs': 'Čeština',
    'ro': 'Română',
    'sq': 'Shqip',
    'hu': 'Magyar',
    'uk': 'Українська',
    'th': 'ไทย',
    'vi': 'Tiếng Việt',
    'id': 'Bahasa Indonesia',
    'ms': 'Bahasa Melayu',
    'bg': 'Български',
    'hr': 'Hrvatski',
    'sr': 'Српски',
    'sk': 'Slovenčina',
    'sl': 'Slovenščina',
  };

  /// Preference list to try in order (`auto` expands to device + en).
  ///
  /// Use for **picking** a subtitle/audio track. For “does the listener
  /// already understand this audio?” gating, use [spokenPreferenceCodes]
  /// so the English fallback does not suppress captions.
  ///
  /// When [preference] is `auto`, pass [contentLocales] / [uiLocale] so
  /// Preferred content languages and the app UI locale win over raw device
  /// (e.g. UI/content = French on an English OS still picks FR captions).
  static List<String> preferenceCodes(
    String preference, {
    List<String> contentLocales = const [],
    String? uiLocale,
  }) {
    final p = preference.trim().toLowerCase();
    if (p.isEmpty || p == 'off') return const [];
    if (p == 'auto') {
      return autoPreferenceCodes(
        contentLocales: contentLocales,
        uiLocale: uiLocale,
      );
    }
    final n = normalize(p);
    return n == null ? const [] : [n];
  }

  /// Ordered codes for `auto` subtitle/audio prefs.
  ///
  /// Content locales → UI locale → device → English track fallback.
  static List<String> autoPreferenceCodes({
    List<String> contentLocales = const [],
    String? uiLocale,
    String? deviceLocale,
  }) {
    final codes = <String>[];
    void add(String? raw) {
      final n = normalize(raw);
      if (n != null && !codes.contains(n)) codes.add(n);
    }

    for (final raw in contentLocales) {
      add(raw);
    }
    add(uiLocale);
    add(deviceLocale ?? deviceLanguageCode());
    if (!codes.contains('en')) codes.add('en');
    return codes;
  }

  /// Languages the listener is assumed to understand for auto-caption gating.
  ///
  /// Unlike [preferenceCodes], this is **only** the primary language — never
  /// the English track fallback. Otherwise dual-audio anime that defaults to EN
  /// would skip French (etc.) captions on a non-English system.
  ///
  /// Do **not** gate on preferred *audio* language: wanting JP original audio
  /// must not suppress FR captions.
  static List<String> spokenPreferenceCodes(
    String preference, {
    List<String> contentLocales = const [],
    String? uiLocale,
  }) {
    final codes = preferenceCodes(
      preference,
      contentLocales: contentLocales,
      uiLocale: uiLocale,
    );
    if (codes.isEmpty) return const [];
    return [codes.first];
  }

  /// True when demuxer [language]/[title] show dialogue the listener
  /// already understands — never catalog `audioLanguages` alone (VOSTFR rows
  /// are often mis-tagged as `fr` while the stream is Japanese).
  static bool demuxerAudioMatchesSpoken({
    required String? language,
    required String? title,
    required List<String> spokenPreferred,
    String? trackId,
  }) {
    if (spokenPreferred.isEmpty) return false;
    final id = (trackId ?? '').trim().toLowerCase();
    if (id == 'auto' || id == 'no') return false;
    return score(
          language: language,
          title: title,
          preferred: spokenPreferred,
        ) >=
        10;
  }

  /// True when [title] mentions [token] as its own word/tag (not a substring).
  ///
  /// Avoids `en` matching inside `french` / `japanese`.
  static bool titleMentions(String title, String token) {
    final t = token.trim().toLowerCase();
    if (t.isEmpty) return false;
    final hay = title.toLowerCase();
    if (t.length <= 3) {
      return RegExp(
        '(^|[^a-z0-9])${RegExp.escape(t)}([^a-z0-9]|\$)',
      ).hasMatch(hay);
    }
    if (hay.contains(t)) return true;
    final compactHay = hay.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final compactToken = t.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return compactToken.length > 3 && compactHay.contains(compactToken);
  }

  static bool matches(String? trackLanguage, String? trackTitle, String want) {
    final wantN = normalize(want);
    if (wantN == null) return false;
    final lang = normalize(trackLanguage);
    // Explicit language tags win — titles are only a fallback when unset.
    if (lang != null) return lang == wantN;
    final title = (trackTitle ?? '').toLowerCase();
    if (title.isEmpty) return false;
    if (titleMentions(title, wantN)) return true;
    for (final e in _aliases.entries) {
      if (e.value == wantN && titleMentions(title, e.key)) return true;
    }
    return false;
  }

  /// Index in [preferred] that matched, or -1.
  static int matchIndex({
    required String? language,
    required String? title,
    required List<String> preferred,
  }) {
    for (var i = 0; i < preferred.length; i++) {
      if (matches(language, title, preferred[i])) return i;
    }
    return -1;
  }

  static int score({
    required String? language,
    required String? title,
    required List<String> preferred,
    bool isDefault = false,
  }) {
    if (preferred.isEmpty) return isDefault ? 1 : 0;
    final i = matchIndex(
      language: language,
      title: title,
      preferred: preferred,
    );
    if (i < 0) return isDefault ? 1 : 0;
    return 1000 - i * 10 + (isDefault ? 1 : 0);
  }

  /// libmpv / media_kit meta rows — not real streams.
  static bool isMetaTrackId(String? id) {
    final t = (id ?? '').trim().toLowerCase();
    return t.isEmpty || t == 'auto' || t == 'no';
  }

  /// Inner token for `[jpn]` / `(vostfr)` style mpv / IPTV titles.
  static String _unwrapLangToken(String raw) {
    final t = raw.trim().toLowerCase();
    final wrapped =
        RegExp(r'^[\[\(\{<]*([a-z]{2,12})[\]\)\}>]*$').firstMatch(t);
    return wrapped?.group(1) ?? t;
  }

  /// True when [raw] is only a code/tag (`jpn`, `vf`, `[eng]`, `vost-fr`).
  ///
  /// Spoken names (`Japanese`, `Français`) stay as the row title.
  static bool isBareLangCode(String? raw) {
    final t = (raw ?? '').trim().toLowerCase();
    if (t.isEmpty) return true;
    final compact = t.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (compact.isEmpty || _notALanguage.contains(compact)) return true;
    if (compact.length <= 3 && normalize(compact) != null) return true;
    if (_aliases.containsKey(compact) && compact.length <= 8) {
      // IPTV tags (`vostfr`, `truefrench`) vs English names (`japanese`).
      return compact.length <= 4 ||
          compact.startsWith('vost') ||
          compact.startsWith('sub') ||
          compact.startsWith('st') ||
          compact.startsWith('leg') ||
          compact == 'truefrench' ||
          compact == 'ptbr' ||
          compact == 'latam' ||
          compact == 'zhcn' ||
          compact == 'zhtw' ||
          compact == 'vose' ||
          compact == 'omu' ||
          compact == 'omdu' ||
          compact == 'omeu' ||
          compact == 'napisy' ||
          compact == 'nappl' ||
          compact == 'dublado' ||
          compact == 'dublada';
    }
    return false;
  }

  /// Human label for an audio/subtitle row (one language name, not `jpn · jpn`).
  ///
  /// Keeps a readable stream title (`Japanese`, `Commentary`). Bare codes
  /// (`jpn`, `eng`) become the language name.
  static String pickerLabel({
    required AppLocalizations l10n,
    required String id,
    String? title,
    String? language,
  }) {
    if (id == 'no') return l10n.off;
    if (id == 'auto') return l10n.auto;
    final titleTrim = title?.trim() ?? '';
    final langCode = normalize(
          language == null || language.trim().isEmpty
              ? language
              : _unwrapLangToken(language),
        ) ??
        (isBareLangCode(titleTrim) ? normalize(_unwrapLangToken(titleTrim)) : null);
    final langLabel = langCode == null ? null : labelForL10n(l10n, langCode);
    if (titleTrim.isNotEmpty && !isBareLangCode(titleTrim)) {
      if (langLabel == null ||
          _titleNamesLanguage(titleTrim, langCode, langLabel)) {
        return titleTrim;
      }
      return '$titleTrim · $langLabel';
    }
    if (langLabel != null) return langLabel;
    if (titleTrim.isNotEmpty && !isBareLangCode(titleTrim)) return titleTrim;
    return l10n.trackNumber(id);
  }

  static bool _titleNamesLanguage(
    String title,
    String? langCode,
    String langLabel,
  ) {
    final t = title.trim().toLowerCase();
    if (t == langLabel.toLowerCase()) return true;
    if (langCode != null && normalize(title) == langCode) return true;
    return false;
  }

  static SessionTrackPick sessionPickFromTrack({
    required String id,
    String? language,
    String? title,
    bool uri = false,
  }) {
    if (id == 'no') return const SessionTrackPick(off: true);
    if (isMetaTrackId(id)) return const SessionTrackPick();
    return SessionTrackPick(
      uri: uri ? id : null,
      demuxerId: uri ? null : id,
      language: language,
      title: title,
    );
  }

  static bool trackMatchesSession({
    required SessionTrackPick pick,
    required String id,
    String? language,
    String? title,
  }) {
    if (pick.off) return id == 'no';
    if (!pick.hasIdentity) return false;
    if (pick.uri != null && pick.uri!.isNotEmpty && id == pick.uri) {
      return true;
    }
    if (isMetaTrackId(id)) return false;
    final wantLang = pick.language?.trim();
    if (wantLang != null && wantLang.isNotEmpty) {
      return matches(language, title, wantLang);
    }
    final wantTitle = pick.title?.trim();
    if (wantTitle != null && wantTitle.isNotEmpty) {
      return (title ?? '').trim().toLowerCase() == wantTitle.toLowerCase();
    }
    return pick.demuxerId != null && id == pick.demuxerId;
  }

  /// Best rematch after a quality/version reload (`sid` is not stable).
  static String? bestSessionTrackId({
    required SessionTrackPick pick,
    required List<SessionTrackCandidate> tracks,
  }) {
    if (pick.off) return 'no';
    SessionTrackCandidate? best;
    var bestScore = 0;
    for (final track in tracks) {
      final score = sessionMatchScore(pick: pick, track: track);
      if (score > bestScore) {
        bestScore = score;
        best = track;
      }
    }
    if (best != null && bestScore >= 50) return best.id;
    final demuxerId = pick.demuxerId;
    if (demuxerId != null && demuxerId.isNotEmpty) {
      for (final track in tracks) {
        if (track.id == demuxerId) return track.id;
      }
    }
    return null;
  }

  static int sessionMatchScore({
    required SessionTrackPick pick,
    required SessionTrackCandidate track,
  }) {
    if (pick.off) return track.id == 'no' ? 1000 : 0;
    if (pick.uri != null &&
        pick.uri!.isNotEmpty &&
        track.id == pick.uri) {
      return 1000;
    }
    var score = 0;
    final wantLang = pick.language?.trim();
    if (wantLang != null &&
        wantLang.isNotEmpty &&
        matches(track.language, track.title, wantLang)) {
      score += 50;
    }
    final wantTitle = pick.title?.trim();
    if (wantTitle != null && wantTitle.isNotEmpty) {
      final title = (track.title ?? '').trim();
      if (title.toLowerCase() == wantTitle.toLowerCase()) score += 40;
    }
    return score;
  }
}

/// User-picked audio/subtitle identity that survives a stream reload.
class SessionTrackPick {
  const SessionTrackPick({
    this.off = false,
    this.uri,
    this.demuxerId,
    this.language,
    this.title,
  });

  final bool off;
  final String? uri;
  final String? demuxerId;
  final String? language;
  final String? title;

  bool get hasIdentity =>
      off ||
      (uri != null && uri!.trim().isNotEmpty) ||
      (demuxerId != null && demuxerId!.trim().isNotEmpty) ||
      (language != null && language!.trim().isNotEmpty) ||
      (title != null && title!.trim().isNotEmpty);
}

class SessionTrackCandidate {
  const SessionTrackCandidate({
    required this.id,
    this.language,
    this.title,
  });

  final String id;
  final String? language;
  final String? title;
}
