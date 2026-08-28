import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/services/ui/persist_after_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User override for app UI language (`null` = follow the device).
///
/// Also stores **preferred content locales** used to soft-rank Home shelves and
/// pick matching audio/subtitle editions. Playback track auto-select remains
/// under Playback → track language settings.
class LocaleController extends ChangeNotifier {
  LocaleController() {
    _load();
  }

  static const _prefsKey = 'ui_locale';
  static const _contentLocalesKey = 'content_preferred_locales';

  Locale? _override;
  List<String> _preferredContentLocales = const [];
  bool _ready = false;

  Locale? get overrideLocale => _override;
  bool get isReady => _ready;

  /// Explicit preferred content language codes (`fr`, `en`, …).
  ///
  /// Empty means “follow [effectiveLanguageCode]” (app override or device).
  List<String> get preferredContentLocalesOverride =>
      List.unmodifiable(_preferredContentLocales);

  /// App override when set, otherwise the device language (e.g. `fr`).
  ///
  /// Passed to custom catalog bridges as `?locale=` on progressive resolve
  /// and other v2 query calls.
  String get effectiveLanguageCode =>
      _override?.languageCode ??
      PlatformDispatcher.instance.locale.languageCode;

  /// Locales used for Home / version matching (never empty).
  List<String> get preferredContentLanguageCodes {
    if (_preferredContentLocales.isNotEmpty) {
      return List.unmodifiable(_preferredContentLocales);
    }
    return [effectiveLanguageCode];
  }

  /// Native-script labels for the language picker.
  static const nativeNames = <String, String>{
    'en': 'English',
    'fr': 'Français',
    'es': 'Español',
    'de': 'Deutsch',
    'it': 'Italiano',
    'pt': 'Português',
    'nl': 'Nederlands',
    'pl': 'Polski',
    'tr': 'Türkçe',
    'ru': 'Русский',
    'uk': 'Українська',
    'ja': '日本語',
    'zh': '中文',
    'ko': '한국어',
    'ar': 'العربية',
    'hi': 'हिन्दी',
    'sv': 'Svenska',
    'id': 'Bahasa Indonesia',
    'vi': 'Tiếng Việt',
  };

  static List<Locale> get supportedLocales =>
      AppLocalizations.supportedLocales;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefsKey)?.trim();
    if (code != null && code.isNotEmpty) {
      final match = _matchSupported(code);
      if (match != null) _override = match;
    }
    final stored = prefs.getStringList(_contentLocalesKey);
    if (stored != null) {
      _preferredContentLocales = _normalizeCodes(stored);
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> setLocale(Locale? locale) async {
    _override = locale == null ? null : _matchSupported(locale.languageCode);
    notifyListeners();
    await persistAfterFrame(() async {
      final prefs = await SharedPreferences.getInstance();
      if (_override == null) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, _override!.languageCode);
      }
    });
  }

  /// Replace preferred content locales. Pass an empty list to follow the
  /// device / app language.
  Future<void> setPreferredContentLocales(List<String> codes) async {
    _preferredContentLocales = _normalizeCodes(codes);
    notifyListeners();
    await persistAfterFrame(() async {
      final prefs = await SharedPreferences.getInstance();
      if (_preferredContentLocales.isEmpty) {
        await prefs.remove(_contentLocalesKey);
      } else {
        await prefs.setStringList(
          _contentLocalesKey,
          _preferredContentLocales,
        );
      }
    });
  }

  Future<void> togglePreferredContentLocale(String languageCode) async {
    final code = languageCode.trim().toLowerCase();
    if (code.isEmpty) return;
    final next = [..._preferredContentLocales];
    if (next.contains(code)) {
      next.remove(code);
    } else {
      next.add(code);
    }
    await setPreferredContentLocales(next);
  }

  static List<String> _normalizeCodes(Iterable<String> codes) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in codes) {
      final code = raw.trim().toLowerCase().split(RegExp(r'[_-]')).first;
      if (code.isEmpty || !seen.add(code)) continue;
      if (_matchSupported(code) == null && !nativeNames.containsKey(code)) {
        continue;
      }
      out.add(code);
    }
    return out;
  }

  static Locale? _matchSupported(String languageCode) {
    for (final locale in supportedLocales) {
      if (locale.languageCode == languageCode) return locale;
    }
    return null;
  }

  static String nativeName(Locale locale) =>
      nativeNames[locale.languageCode] ?? locale.languageCode;

  static String nativeNameForCode(String languageCode) =>
      nativeNames[languageCode] ?? languageCode;
}

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
