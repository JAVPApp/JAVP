import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/services/iptv/channel_quality.dart';

/// Resolves live channels to XMLTV programmes with conservative matching.
///
/// Order: exact `tvg-id` → normalized id → unique normalized display-name.
/// When unsure (ambiguous id or name), returns no match rather than a wrong
/// guide.
class EpgChannelMatcher {
  const EpgChannelMatcher._();

  /// Case-fold, strip common prefixes / quality suffixes, unify separators.
  static String normalizeId(String raw) {
    var id = raw.trim().toLowerCase();
    if (id.isEmpty) return '';

    id = id.replaceAll(RegExp(r'[\s_]+'), '.');
    id = id.replaceAll(RegExp(r'\.+'), '.');
    id = id.replaceAll(RegExp(r'^\.+|\.+$'), '');

    const prefixes = ['tvg.', 'tvg-', 'channel.', 'channel-', 'epg.', 'epg-'];
    for (final prefix in prefixes) {
      if (id.startsWith(prefix)) {
        id = id.substring(prefix.length);
        break;
      }
    }

    id = id.replaceAll(
      RegExp(
        r'[.\-]?(?:uhd|4k|fhd|full\.?hd|hd|sd|hevc|h\.?265)$',
        caseSensitive: false,
      ),
      '',
    );
    id = id.replaceAll(RegExp(r'\.+'), '.');
    id = id.replaceAll(RegExp(r'^\.+|\.+$'), '');
    return id;
  }

  /// Looser id used only when it uniquely identifies one EPG channel.
  ///
  /// Strips a trailing 2–3 letter country / locale segment (`news1.uk` → `news1`).
  static String looseId(String raw) {
    final id = normalizeId(raw);
    if (id.isEmpty) return '';
    final match = RegExp(r'^(.+)\.([a-z]{2,3})$').firstMatch(id);
    if (match == null) return id;
    final base = match.group(1)!;
    final suffix = match.group(2)!;
    // Keep numeric-only bases with country (e.g. provider stream keys).
    if (base.isEmpty) return id;
    // Avoid turning `a.b.c` style ids into over-loose keys when middle is short.
    if (suffix.length > 3) return id;
    return base;
  }

  /// Display-name key for fuzzy fallback (quality suffixes stripped).
  static String normalizeName(String raw) {
    final cleaned = ChannelQuality.baseTitle(raw);
    return ChannelQuality.normalizeKey(cleaned);
  }

  /// Merge programmes from multiple XMLTV feeds without inventing joins.
  ///
  /// Keeps original [EpgProgram.channelId] values; dedupes identical rows.
  static List<EpgProgram> mergeProgrammes(Iterable<EpgProgram> programs) {
    final seen = <String>{};
    final out = <EpgProgram>[];
    for (final p in programs) {
      _collectMergedProgramme(p, seen, out);
    }
    _sortMergedProgrammes(out);
    return out;
  }

  /// Same as [mergeProgrammes] but yields so a 100k+ guide cannot freeze
  /// the UI isolate after the worker parse finishes.
  static Future<List<EpgProgram>> mergeProgrammesYielding(
    Iterable<EpgProgram> programs,
  ) async {
    final seen = <String>{};
    final out = <EpgProgram>[];
    final slice = Stopwatch()..start();
    var i = 0;
    for (final p in programs) {
      _collectMergedProgramme(p, seen, out);
      await yieldUiSlice(slice, i: i++, label: 'epg-merge-programmes');
    }
    _sortMergedProgrammes(out);
    await yieldAfterIsolateChunk();
    return out;
  }

  static void _collectMergedProgramme(
    EpgProgram p,
    Set<String> seen,
    List<EpgProgram> out,
  ) {
    final id = p.channelId.trim();
    if (id.isEmpty) return;
    final key =
        '$id|${p.start.toUtc().millisecondsSinceEpoch}|${p.end.toUtc().millisecondsSinceEpoch}|${p.title}';
    if (!seen.add(key)) return;
    out.add(p);
  }

  static void _sortMergedProgrammes(List<EpgProgram> out) {
    out.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      return a.channelId.compareTo(b.channelId);
    });
  }

  static EpgLookupIndex buildIndex({
    required List<EpgProgram> programs,
    required Map<String, String> channelNames,
  }) {
    return EpgLookupIndex.build(programs: programs, channelNames: channelNames);
  }
}

/// Precomputed XMLTV lookup tables for [EpgChannelMatcher] resolution.
class EpgLookupIndex {
  EpgLookupIndex._({
    required this.byExactId,
    required this.byNormalizedId,
    required this.byLooseId,
    required this.byNormalizedName,
    required this.displayNames,
  });

  final Map<String, List<EpgProgram>> byExactId;

  /// Normalized id → programmes (merged across feeds that share the key).
  final Map<String, List<EpgProgram>> byNormalizedId;

  /// Loose id → programmes only when exactly one distinct normalized id maps.
  final Map<String, List<EpgProgram>> byLooseId;

  /// Normalized display-name → programmes only when unique among EPG channels.
  final Map<String, List<EpgProgram>> byNormalizedName;

  final Map<String, String> displayNames;

  factory EpgLookupIndex.build({
    required List<EpgProgram> programs,
    required Map<String, String> channelNames,
  }) {
    return _finishBuild(
      byExact: _groupByExactId(programs),
      channelNames: channelNames,
    );
  }

  /// Same as [build] with frame yields — large XMLTV indexes used to stall
  /// the first Guide / now-playing lookup after a feed reload.
  static Future<EpgLookupIndex> buildYielding({
    required List<EpgProgram> programs,
    required Map<String, String> channelNames,
  }) async {
    final byExact = <String, List<EpgProgram>>{};
    final slice = Stopwatch()..start();
    for (var i = 0; i < programs.length; i++) {
      final id = programs[i].channelId.trim();
      if (id.isNotEmpty) {
        byExact.putIfAbsent(id, () => []).add(programs[i]);
      }
      await yieldUiSlice(slice, i: i, label: 'epg-index-build');
    }
    await yieldAfterIsolateChunk();
    return _finishBuild(byExact: byExact, channelNames: channelNames);
  }

  static Map<String, List<EpgProgram>> _groupByExactId(
    List<EpgProgram> programs,
  ) {
    final byExact = <String, List<EpgProgram>>{};
    for (final program in programs) {
      final id = program.channelId.trim();
      if (id.isEmpty) continue;
      byExact.putIfAbsent(id, () => []).add(program);
    }
    return byExact;
  }

  static EpgLookupIndex _finishBuild({
    required Map<String, List<EpgProgram>> byExact,
    required Map<String, String> channelNames,
  }) {
    final byNorm = <String, List<EpgProgram>>{};
    final normToExact = <String, Set<String>>{};
    for (final entry in byExact.entries) {
      final norm = EpgChannelMatcher.normalizeId(entry.key);
      if (norm.isEmpty) continue;
      byNorm.putIfAbsent(norm, () => []).addAll(entry.value);
      normToExact.putIfAbsent(norm, () => {}).add(entry.key);
    }

    final looseGroups = <String, Set<String>>{};
    for (final norm in byNorm.keys) {
      final loose = EpgChannelMatcher.looseId(norm);
      if (loose.isEmpty || loose == norm) continue;
      looseGroups.putIfAbsent(loose, () => {}).add(norm);
    }
    final byLoose = <String, List<EpgProgram>>{};
    for (final entry in looseGroups.entries) {
      if (entry.value.length != 1) continue;
      final rows = byNorm[entry.value.single];
      if (rows == null || rows.isEmpty) continue;
      byLoose[entry.key] = rows;
    }

    // Name → set of exact channel ids (from XMLTV display-name map).
    final nameToIds = <String, Set<String>>{};
    for (final entry in channelNames.entries) {
      final exactId = entry.key.trim();
      if (exactId.isEmpty) continue;
      final nameKey = EpgChannelMatcher.normalizeName(entry.value);
      if (nameKey.isEmpty) continue;
      nameToIds.putIfAbsent(nameKey, () => {}).add(exactId);
    }
    final byName = <String, List<EpgProgram>>{};
    for (final entry in nameToIds.entries) {
      if (entry.value.length != 1) continue;
      final rows = byExact[entry.value.single];
      if (rows == null || rows.isEmpty) continue;
      byName[entry.key] = rows;
    }

    return EpgLookupIndex._(
      byExactId: byExact,
      byNormalizedId: byNorm,
      byLooseId: byLoose,
      byNormalizedName: byName,
      displayNames: channelNames,
    );
  }

  /// Resolve guide rows for a live channel. Empty when no confident match.
  List<EpgProgram> programmesFor({
    String? epgChannelId,
    String? channelTitle,
    String? channelName,
  }) {
    final tvg = epgChannelId?.trim();
    if (tvg != null && tvg.isNotEmpty) {
      final exact = byExactId[tvg];
      if (exact != null && exact.isNotEmpty) return exact;

      final norm = EpgChannelMatcher.normalizeId(tvg);
      if (norm.isNotEmpty) {
        final byNorm = byNormalizedId[norm];
        if (byNorm != null && byNorm.isNotEmpty) return byNorm;

        // Playlist id may already be country-stripped (`newsnet` vs EPG `newsnet.us`).
        final looseHit = byLooseId[norm];
        if (looseHit != null && looseHit.isNotEmpty) return looseHit;

        final loose = EpgChannelMatcher.looseId(norm);
        if (loose.isNotEmpty && loose != norm) {
          final byLoose = byLooseId[loose];
          if (byLoose != null && byLoose.isNotEmpty) return byLoose;
        }
      }
    }

    for (final candidate in [channelName, channelTitle]) {
      final raw = candidate?.trim();
      if (raw == null || raw.isEmpty) continue;
      final key = EpgChannelMatcher.normalizeName(raw);
      if (key.isEmpty) continue;
      final byName = byNormalizedName[key];
      if (byName != null && byName.isNotEmpty) return byName;
    }
    return const [];
  }

  /// Display-name for a channel when a confident EPG match exists.
  String? displayNameFor({
    String? epgChannelId,
    String? channelTitle,
    String? channelName,
  }) {
    final programs = programmesFor(
      epgChannelId: epgChannelId,
      channelTitle: channelTitle,
      channelName: channelName,
    );
    if (programs.isEmpty) return null;
    final id = programs.first.channelId.trim();
    final name = displayNames[id]?.trim();
    if (name != null && name.isNotEmpty) return name;
    // Normalized merge may use a different exact id spelling.
    final tvg = epgChannelId?.trim();
    if (tvg != null && tvg.isNotEmpty) {
      final direct = displayNames[tvg]?.trim();
      if (direct != null && direct.isNotEmpty) return direct;
    }
    return null;
  }
}

/// Compact XMLTV id/name aliases — no programme lists.
///
/// Used when programmes live in [EpgProgramDb]. The old [EpgLookupIndex]
/// held every row per channel and froze the first Guide lookup.
class EpgChannelAliasIndex {
  EpgChannelAliasIndex._({
    required this.displayNames,
    required Map<String, String> byNormalizedId,
    required Map<String, String> byLooseId,
    required Map<String, String> byNormalizedName,
  }) : _byNormalizedId = byNormalizedId,
       _byLooseId = byLooseId,
       _byNormalizedName = byNormalizedName;

  final Map<String, String> displayNames;
  final Map<String, String> _byNormalizedId;
  final Map<String, String> _byLooseId;
  final Map<String, String> _byNormalizedName;

  static EpgChannelAliasIndex fromChannelNames(Map<String, String> names) {
    final byNorm = <String, String>{};
    final normAmbiguous = <String>{};
    for (final id in names.keys) {
      final exact = id.trim();
      if (exact.isEmpty) continue;
      final norm = EpgChannelMatcher.normalizeId(exact);
      if (norm.isEmpty) continue;
      if (normAmbiguous.contains(norm)) continue;
      final existing = byNorm[norm];
      if (existing == null) {
        byNorm[norm] = exact;
      } else if (existing != exact) {
        byNorm.remove(norm);
        normAmbiguous.add(norm);
      }
    }

    final looseGroups = <String, Set<String>>{};
    for (final norm in byNorm.keys) {
      final loose = EpgChannelMatcher.looseId(norm);
      if (loose.isEmpty || loose == norm) continue;
      looseGroups.putIfAbsent(loose, () => {}).add(norm);
    }
    final byLoose = <String, String>{};
    for (final entry in looseGroups.entries) {
      if (entry.value.length != 1) continue;
      final exact = byNorm[entry.value.single];
      if (exact == null) continue;
      byLoose[entry.key] = exact;
    }

    final nameToIds = <String, Set<String>>{};
    for (final entry in names.entries) {
      final exactId = entry.key.trim();
      if (exactId.isEmpty) continue;
      final nameKey = EpgChannelMatcher.normalizeName(entry.value);
      if (nameKey.isEmpty) continue;
      nameToIds.putIfAbsent(nameKey, () => {}).add(exactId);
    }
    final byName = <String, String>{};
    for (final entry in nameToIds.entries) {
      if (entry.value.length != 1) continue;
      byName[entry.key] = entry.value.single;
    }

    return EpgChannelAliasIndex._(
      displayNames: names,
      byNormalizedId: byNorm,
      byLooseId: byLoose,
      byNormalizedName: byName,
    );
  }

  /// Resolve to the XMLTV exact channel id, or null when unsure.
  String? resolve({
    String? epgChannelId,
    String? channelTitle,
    String? channelName,
  }) {
    final tvg = epgChannelId?.trim();
    if (tvg != null && tvg.isNotEmpty) {
      if (displayNames.containsKey(tvg)) return tvg;
      final norm = EpgChannelMatcher.normalizeId(tvg);
      if (norm.isNotEmpty) {
        final byNorm = _byNormalizedId[norm];
        if (byNorm != null) return byNorm;
        final looseHit = _byLooseId[norm];
        if (looseHit != null) return looseHit;
        final loose = EpgChannelMatcher.looseId(norm);
        if (loose.isNotEmpty && loose != norm) {
          final byLoose = _byLooseId[loose];
          if (byLoose != null) return byLoose;
        }
      }
    }
    for (final candidate in [channelName, channelTitle]) {
      final raw = candidate?.trim();
      if (raw == null || raw.isEmpty) continue;
      final key = EpgChannelMatcher.normalizeName(raw);
      if (key.isEmpty) continue;
      final byName = _byNormalizedName[key];
      if (byName != null) return byName;
    }
    return null;
  }

  String? displayNameFor({
    String? epgChannelId,
    String? channelTitle,
    String? channelName,
  }) {
    final id = resolve(
      epgChannelId: epgChannelId,
      channelTitle: channelTitle,
      channelName: channelName,
    );
    if (id == null) return null;
    final name = displayNames[id]?.trim();
    if (name != null && name.isNotEmpty) return name;
    final tvg = epgChannelId?.trim();
    if (tvg != null && tvg.isNotEmpty) {
      final direct = displayNames[tvg]?.trim();
      if (direct != null && direct.isNotEmpty) return direct;
    }
    return null;
  }
}
