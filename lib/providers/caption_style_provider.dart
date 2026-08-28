import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/caption_style.dart';
import 'package:javp/models/custom_caption_font.dart';
import 'package:javp/models/profile.dart';
import 'package:javp/services/fonts/opentype_font_name.dart';
import 'package:javp/services/storage/library_store.dart';
import 'package:javp/services/ui/persist_after_frame.dart';
import 'package:path/path.dart' as p;

class CaptionStyleProvider extends ChangeNotifier {
  CaptionStyleProvider({
    LibraryStore? store,
    String profileId = Profile.defaultId,
    this.onSyncableChanged,
  }) : _store = store ?? LibraryStore(profileId: profileId) {
    _bootstrap();
  }

  LibraryStore _store;
  CaptionStyleSettings _style = CaptionStyleSettings.outline;
  List<CustomCaptionFont> _customFonts = const [];
  String? _fontsDirPath;
  final Set<String> _loadedFlutterFamilies = {};
  bool loading = true;

  /// Fired after caption style is written so profile sync can push it.
  void Function()? onSyncableChanged;

  CaptionStyleSettings get style => _style;
  List<CustomCaptionFont> get customFonts => _customFonts;

  /// Absolute path for mpv `fonts-dir` when imported fonts exist.
  String? get extraFontsDir {
    if (_fontsDirPath == null) return null;
    if (!_customFonts.any((f) => f.isFileBacked)) return null;
    return _fontsDirPath;
  }

  Future<void> _bootstrap() async {
    try {
      _style = await _store.loadCaptionStyle();
      _customFonts = await _store.loadCustomCaptionFonts();
      final dir = await _store.captionFontsDirectory();
      _fontsDirPath = dir.path;
      await _registerFlutterFonts(_customFonts);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Swap the backing store when the active profile changes.
  Future<void> bindProfile(String profileId) async {
    if (_store.profileId == profileId && !loading) {
      return;
    }
    _store = LibraryStore(profileId: profileId);
    _style = CaptionStyleSettings.outline;
    _customFonts = const [];
    _fontsDirPath = null;
    _loadedFlutterFamilies.clear();
    loading = true;
    notifyListeners();
    await _bootstrap();
  }

  /// Re-read after Drive/WebDAV applied a remote captionStyle section.
  Future<void> reloadFromStore() async {
    loading = true;
    notifyListeners();
    await _bootstrap();
  }

  void _noteSyncableChange() {
    onSyncableChanged?.call();
  }

  Future<void> applyPreset(CaptionPreset preset) async {
    _style = CaptionStyleSettings.forPreset(
      preset,
    ).copyWith(preferAss: _style.preferAss);
    notifyListeners();
    await persistAfterFrame(() async {
      await _store.saveCaptionStyle(_style);
      _noteSyncableChange();
    });
  }

  Future<void> setPreferAss(bool value) {
    return update(_style.copyWith(preferAss: value));
  }

  Future<void> update(CaptionStyleSettings style) async {
    _style = style;
    notifyListeners();
    await persistAfterFrame(() async {
      await _store.saveCaptionStyle(_style);
      _noteSyncableChange();
    });
  }

  Future<void> tweak(CaptionStyleSettings Function(CaptionStyleSettings) fn) {
    final next = fn(_style).copyWith(preset: CaptionPreset.custom);
    return update(next);
  }

  /// Adds a system font by family name (must already be installed for playback).
  Future<bool> addCustomFontByName(String rawName) async {
    final family = rawName.trim();
    if (family.isEmpty) return false;
    for (final choice in CaptionStyleSettings.fontChoices) {
      final builtin = choice.family;
      if (builtin != null && _sameFamily(builtin, family)) {
        await tweak((s) => s.copyWith(fontFamily: builtin));
        return true;
      }
    }
    if (_customFonts.any((f) => _sameFamily(f.family, family))) {
      await tweak((s) => s.copyWith(fontFamily: _existingFamily(family)));
      return true;
    }
    final next = [..._customFonts, CustomCaptionFont(family: family)];
    await _persistCustomFonts(next);
    await tweak((s) => s.copyWith(fontFamily: family));
    return true;
  }

  /// Imports a `.ttf` / `.otf` file into the app fonts dir and selects it.
  ///
  /// Returns an error key: `notFound`, `badFormat`, or `noFamily`.
  Future<String?> importFontFile(String sourcePath) async {
    final ext = p.extension(sourcePath).toLowerCase();
    if (ext != '.ttf' && ext != '.otf' && ext != '.ttc' && ext != '.otc') {
      return 'badFormat';
    }

    final source = File(sourcePath);
    if (!await source.exists()) return 'notFound';

    final bytes = await source.readAsBytes();
    final family = readOpenTypeFamilyName(Uint8List.sublistView(bytes))?.trim();
    if (family == null || family.isEmpty) {
      return 'noFamily';
    }

    final dir = await _store.captionFontsDirectory();
    _fontsDirPath = dir.path;
    final safeBase = _safeFileStem(family);
    var fileName = '$safeBase$ext';
    var dest = File(p.join(dir.path, fileName));
    var n = 2;
    while (await dest.exists()) {
      fileName = '${safeBase}_$n$ext';
      dest = File(p.join(dir.path, fileName));
      n++;
    }
    await dest.writeAsBytes(bytes, flush: true);

    final entry = CustomCaptionFont(family: family, fileName: fileName);
    final withoutDupes = [
      for (final f in _customFonts)
        if (!_sameFamily(f.family, family)) f,
    ];
    // Drop a previous file for the same family.
    for (final old in _customFonts) {
      if (!_sameFamily(old.family, family) || !old.isFileBacked) continue;
      if (old.fileName == fileName) continue;
      try {
        await File(p.join(dir.path, old.fileName!)).delete();
      } catch (_) {}
    }
    await _persistCustomFonts([...withoutDupes, entry]);
    await _registerFlutterFonts([entry]);
    await tweak((s) => s.copyWith(fontFamily: family));
    return null;
  }

  Future<void> removeCustomFont(CustomCaptionFont font) async {
    final next = [
      for (final f in _customFonts)
        if (!_sameFamily(f.family, font.family)) f,
    ];
    if (font.isFileBacked && _fontsDirPath != null) {
      try {
        await File(p.join(_fontsDirPath!, font.fileName!)).delete();
      } catch (_) {}
    }
    await _persistCustomFonts(next);
    if (_sameFamily(_style.fontFamily ?? '', font.family)) {
      await tweak((s) => s.copyWith(clearFontFamily: true));
    }
  }

  Future<void> _persistCustomFonts(List<CustomCaptionFont> fonts) async {
    _customFonts = List.unmodifiable(fonts);
    notifyListeners();
    await _store.saveCustomCaptionFonts(_customFonts);
  }

  Future<void> _registerFlutterFonts(List<CustomCaptionFont> fonts) async {
    if (_fontsDirPath == null) return;
    for (final font in fonts) {
      if (!font.isFileBacked) continue;
      if (_loadedFlutterFamilies.contains(font.family)) continue;
      final file = File(p.join(_fontsDirPath!, font.fileName!));
      if (!await file.exists()) continue;
      try {
        final data = await file.readAsBytes();
        final loader = FontLoader(font.family);
        loader.addFont(Future.value(ByteData.sublistView(data)));
        await loader.load();
        _loadedFlutterFamilies.add(font.family);
      } catch (e) {
        debugPrint('Caption font preview load failed for ${font.family}: $e');
      }
    }
  }

  String _existingFamily(String family) {
    for (final f in _customFonts) {
      if (_sameFamily(f.family, family)) return f.family;
    }
    return family;
  }

  static bool _sameFamily(String a, String b) =>
      a.toLowerCase() == b.toLowerCase();

  static String _safeFileStem(String family) {
    final cleaned = family
        .replaceAll(RegExp(r'[^\w\s-]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'caption_font' : cleaned;
  }
}
