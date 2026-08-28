import 'package:javp/models/iptv_category.dart';
import 'package:javp/models/media_item.dart';

/// Page a live category from local storage; only run [ensureIfCold] when empty.
///
/// Used by main Live TV and the player overlay browse so cold Xtream groups
/// demand-fetch instead of flashing an empty list.
Future<List<MediaItem>> pageLiveCategoryWithEnsure({
  required Future<List<MediaItem>> Function() page,
  required Future<void> Function() ensureIfCold,
}) async {
  final first = await page();
  if (first.isNotEmpty) return first;
  await ensureIfCold();
  return page();
}

/// Prefer a loaded scoped list. An empty scoped result must still fall back
/// to provider Xtream rows — category-first sync can land chips without a
/// liveDbRevision bump, and locking in empty made Direct look sourceless.
List<IptvCategory> tvLiveCategoriesForBrowse({
  required List<IptvCategory> scoped,
  required List<IptvCategory> fromProvider,
}) {
  if (scoped.isNotEmpty) return scoped;
  return fromProvider;
}

/// Scaffold freeze identity for Live TV.
///
/// Live category ids must be part of this: loading `iptv_categories` from disk
/// does not bump `liveDbRevision`, and freezing the first empty Categories
/// frame kept Direct blank after the rows arrived.
Object tvLiveScaffoldFreezeStamp({
  required Object listStamp,
  required int tabIndex,
  required String categorySearch,
  required Iterable<String> favoriteCategoryIds,
  required Iterable<String> liveCategoryIds,
  required int scopedCount,
  required bool scopedLoading,
}) {
  return Object.hash(
    listStamp,
    tabIndex,
    categorySearch,
    scopedCount,
    scopedLoading,
    Object.hashAll(favoriteCategoryIds),
    Object.hashAll(liveCategoryIds),
  );
}

/// First live groups to demand-fill when Direct is open and SQLite is empty.
///
/// [preferGroupNames] (locale-ranked) are filled first; remaining live groups
/// follow so we still warm *something* when no name scores for the locale.
List<IptvCategory> liveCategoriesToWarm(
  List<IptvCategory> liveCategories, {
  Iterable<String>? sourceIds,
  int limit = 3,
  Iterable<String> preferGroupNames = const [],
}) {
  if (limit <= 0) return const [];
  final want = sourceIds == null
      ? null
      : {
          for (final id in sourceIds)
            if (id.isNotEmpty) id,
        };
  bool matches(IptvCategory category) {
    if (category.kind != IptvCategoryKind.live) return false;
    if (want != null && want.isNotEmpty) {
      final sourceId = category.sourceId;
      if (sourceId == null || !want.contains(sourceId)) return false;
    }
    return true;
  }

  final seen = <String>{};
  final out = <IptvCategory>[];
  void add(IptvCategory category) {
    if (out.length >= limit) return;
    if (!matches(category)) return;
    if (!seen.add(category.id)) return;
    out.add(category);
  }

  if (preferGroupNames.isNotEmpty) {
    final byName = <String, IptvCategory>{
      for (final category in liveCategories)
        if (matches(category)) category.name: category,
    };
    for (final name in preferGroupNames) {
      final category = byName[name];
      if (category != null) add(category);
      if (out.length >= limit) return out;
    }
  }
  for (final category in liveCategories) {
    add(category);
    if (out.length >= limit) break;
  }
  return out;
}
