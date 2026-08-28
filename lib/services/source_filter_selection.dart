// Multi-select source filter helpers shared by TV and Catalog.
//
// Convention: an **empty** set means “All sources” (no filter). A non-empty
// set means include only those source ids (`sourceId ∈ selected`).

/// Drop ids that are no longer available; empty → still “All”.
Set<String> normalizeSourceSelection(
  Iterable<String> selected, {
  required Iterable<String> availableIds,
}) {
  final available = availableIds.toSet();
  return {
    for (final id in selected)
      if (id.isNotEmpty && available.contains(id)) id,
  };
}

/// Whether [sourceId] passes the current multi-select filter.
///
/// Empty [selected] = all sources. Null/empty [sourceId] only matches “All”.
bool sourceMatchesFilter(String? sourceId, Set<String> selected) {
  if (selected.isEmpty) return true;
  final id = sourceId?.trim() ?? '';
  if (id.isEmpty) return false;
  return selected.contains(id);
}

/// Toggle [id] in a copy of [selected]. Empty result = All.
Set<String> toggleSourceInSelection(Set<String> selected, String id) {
  if (id.isEmpty) return Set<String>.from(selected);
  final next = Set<String>.from(selected);
  if (!next.add(id)) next.remove(id);
  return next;
}

/// Clear selection → All sources.
Set<String> clearSourceSelection() => const <String>{};

/// Encode for SharedPreferences (sorted for stable equality).
String encodeSourceSelection(Set<String> selected) {
  final ids = selected.where((id) => id.isNotEmpty).toList()..sort();
  return ids.join('\u001f');
}

/// Decode prefs payload; empty / blank → All.
Set<String> decodeSourceSelection(String? raw) {
  if (raw == null || raw.isEmpty) return const <String>{};
  return {
    for (final part in raw.split('\u001f'))
      if (part.isNotEmpty) part,
  };
}

/// Chip label: All / single source name / “N sources”.
String sourceFilterChipLabel({
  required Set<String> selected,
  required String Function(String id) nameForId,
  required String allLabel,
  required String Function(int count) nSourcesLabel,
}) {
  if (selected.isEmpty) return allLabel;
  if (selected.length == 1) {
    final id = selected.single;
    final name = nameForId(id).trim();
    return name.isEmpty ? allLabel : name;
  }
  return nSourcesLabel(selected.length);
}

/// Stable stamp for list invalidation (order-independent).
Object sourceSelectionStamp(Set<String> selected) {
  if (selected.isEmpty) return 0;
  final ids = selected.toList()..sort();
  return Object.hashAll(ids);
}
