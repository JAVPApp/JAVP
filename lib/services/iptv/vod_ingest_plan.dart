import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/vod_variant_index.dart';
import 'package:javp/services/storage/vod_catalog_db.dart';

/// Packed VOD ingest: SQL rows + Versions id lists.
///
/// This is the **only** write contract for Catalog VOD. Fetch/parse stays
/// source-shaped (M3U text, custom JSON, Xtream lists, Stalker portal pages,
/// media-server browse). Do not fold those into one parser. After a plan
/// exists, [LibraryProvider] persists it with `_applyVodPlan`.
///
/// Persist policy (do not "unify" these — they are real product rules):
///
/// * **Replace** — M3U, custom dump, Xtream/Stalker prefetch, media-server
///   first page. Empty plan **clears** that source (live-only playlist must
///   not leave yesterday's movies).
/// * **Upsert** — custom query-API browse seed and deep-sync pages. Empty
///   plan is a no-op (a failed page must not wipe the library).
/// * **Empty fetch keeps cache** — Xtream/Stalker prefetch only. The client
///   still returns an empty plan; the library skips `_applyVodPlan` when a
///   warm cache exists. Not the same as M3U empty-clear.
///
/// Built off the UI isolate so [VodCatalogDb] can insert maps and the
/// library can store family ids without hydrating [MediaItem] graphs.
class VodIngestPlan {
  const VodIngestPlan({
    required this.rows,
    required this.families,
    required this.canonical,
  });

  /// `vod_items` insert maps (SQL column names).
  final List<Map<String, Object?>> rows;

  /// Versions family key → member ids (same shape as [VodVariantIndex]).
  final Map<String, List<String>> families;

  /// Primary / alias key → canonical family key.
  final Map<String, String> canonical;

  int get vodCount => rows.length;
}

/// Pack VOD/series items and build the Versions id index in one pass.
VodIngestPlan buildVodIngestPlan(
  List<MediaItem> items, {
  String? fallbackSourceId,
}) {
  final rows = <Map<String, Object?>>[];
  final variantRows = <Map<String, Object?>>[];
  for (final item in items) {
    if (item.kind != MediaKind.vod && item.kind != MediaKind.series) continue;
    rows.add(VodCatalogDb.packItem(item, fallbackSourceId: fallbackSourceId));
    if (item.isEpisode || item.isLive) continue;
    variantRows.add(VodVariantIndex.packRow(item));
  }
  if (variantRows.isEmpty) {
    return VodIngestPlan(rows: rows, families: const {}, canonical: const {});
  }
  final packed = VodVariantIndex.buildPacked(variantRows);
  final rawFamilies = packed['families'] as Map? ?? const {};
  final rawCanonical = packed['canonical'] as Map? ?? const {};
  return VodIngestPlan(
    rows: rows,
    families: {
      for (final e in rawFamilies.entries)
        '${e.key}': [for (final id in (e.value as List)) '$id'],
    },
    canonical: {for (final e in rawCanonical.entries) '${e.key}': '${e.value}'},
  );
}

/// Same as [buildVodIngestPlan] but yields the UI isolate while packing.
Future<VodIngestPlan> buildVodIngestPlanYielding(
  List<MediaItem> items, {
  String? fallbackSourceId,
}) async {
  if (items.isEmpty) {
    return const VodIngestPlan(rows: [], families: {}, canonical: {});
  }
  final rows = <Map<String, Object?>>[];
  final variantRows = <Map<String, Object?>>[];
  final slice = Stopwatch()..start();
  var i = 0;
  for (final item in items) {
    if (item.kind != MediaKind.vod && item.kind != MediaKind.series) continue;
    rows.add(VodCatalogDb.packItem(item, fallbackSourceId: fallbackSourceId));
    if (!item.isEpisode && !item.isLive) {
      variantRows.add(VodVariantIndex.packRow(item));
    }
    await yieldUiSlice(slice, i: i++, label: 'vod-plan-pack');
  }
  return vodIngestPlanFromVariantRowChunksInIsolate(
    rows: rows,
    variantRowChunks: [variantRows],
  );
}

/// Assemble a plan from already-packed SQL + Versions rows.
VodIngestPlan vodIngestPlanFromVariantRows({
  required List<Map<String, Object?>> rows,
  required List<Map<String, Object?>> variantRows,
}) {
  if (variantRows.isEmpty) {
    return VodIngestPlan(rows: rows, families: const {}, canonical: const {});
  }
  final packed = VodVariantIndex.buildPacked(variantRows);
  final rawFamilies = packed['families'] as Map? ?? const {};
  final rawCanonical = packed['canonical'] as Map? ?? const {};
  return VodIngestPlan(
    rows: rows,
    families: {
      for (final e in rawFamilies.entries)
        '${e.key}': [for (final id in (e.value as List)) '$id'],
    },
    canonical: {for (final e in rawCanonical.entries) '${e.key}': '${e.value}'},
  );
}

/// Assemble a plan while constructing the Versions index on a worker isolate.
///
/// Callers that already have separate batches should pass them separately so
/// a large combined variant-row list is never allocated on the UI isolate.
Future<VodIngestPlan> vodIngestPlanFromVariantRowChunksInIsolate({
  required List<Map<String, Object?>> rows,
  required List<List<Map<String, Object?>>> variantRowChunks,
}) async {
  final packed = await VodVariantIndex.buildChunksInIsolate(variantRowChunks);
  return VodIngestPlan(
    rows: rows,
    families:
        packed['families'] as Map<String, List<String>>? ??
        const <String, List<String>>{},
    canonical:
        packed['canonical'] as Map<String, String>? ?? const <String, String>{},
  );
}

/// Split live/other leftovers from VOD/series and pack the VOD set.
({List<MediaItem> leftovers, VodIngestPlan vod}) splitAndPackVodItems(
  List<MediaItem> items, {
  String? fallbackSourceId,
}) {
  final leftovers = <MediaItem>[];
  final vodItems = <MediaItem>[];
  for (final item in items) {
    if (item.kind == MediaKind.vod || item.kind == MediaKind.series) {
      vodItems.add(item);
    } else {
      leftovers.add(item);
    }
  }
  return (
    leftovers: leftovers,
    vod: buildVodIngestPlan(vodItems, fallbackSourceId: fallbackSourceId),
  );
}

/// Stamp [fallbackGroup] onto packed VOD rows that have no `group` / category.
///
/// Catalog shelves are keyed by non-empty group names. Custom JSON dumps often
/// omit `group`, so without this they land in SQLite and Home but never in
/// the Catalog tab.
void stampEmptyVodGroupNames(
  List<Map<String, Object?>> rows, {
  required String fallbackGroup,
}) {
  final group = fallbackGroup.trim();
  if (group.isEmpty || rows.isEmpty) return;
  for (final row in rows) {
    final current = '${row['group_name'] ?? ''}'.trim();
    if (current.isEmpty) row['group_name'] = group;
  }
}
