import 'dart:ui' show Locale;

import 'package:javp/models/iptv_category.dart';
import 'package:javp/services/iptv/iptv_locale_hints.dart';

/// Merge provider category rows with live-DB group names for TV / Live browse.
///
/// M3U and demo catalogs often only store `group-title` in the live DB — the
/// `iptv_categories` table stays empty. Without this union the TV categories
/// column looked empty aside from For you / Favorites / Recents / All.
List<IptvCategory> liveBrowseCategories({
  required List<IptvCategory> providerCategories,
  required List<String> liveGroupNames,
}) {
  if (liveGroupNames.isEmpty) return providerCategories;
  final byName = <String, IptvCategory>{
    for (final c in providerCategories) c.name: c,
  };
  final fromDb = <IptvCategory>[
    for (final name in liveGroupNames)
      byName[name] ??
          IptvCategory(id: name, name: name, kind: IptvCategoryKind.live),
  ];
  if (providerCategories.isEmpty) return fromDb;
  final seen = {for (final c in fromDb) c.name};
  return [
    ...fromDb,
    for (final c in providerCategories)
      if (seen.add(c.name)) c,
  ];
}

/// Favorited categories first (bookmark order), then the rest by locale
/// (`[FR]` / `FR |` ahead of `[CA]` in Europe).
///
/// Matches `LibraryProvider.favoriteCategoryIds` by category id, with a name
/// fallback for scoped/M3U rows that use the group name as id.
List<IptvCategory> iptvCategoriesWithFavoritesFirst(
  List<IptvCategory> categories,
  List<String> favoriteCategoryIds, {
  Locale? locale,
}) {
  if (categories.isEmpty) return categories;
  int compareRest(IptvCategory a, IptvCategory b) =>
      IptvLocaleHints.compareGroupNames(a.name, b.name, locale);

  if (favoriteCategoryIds.isEmpty) {
    return [...categories]..sort(compareRest);
  }
  final byId = <String, IptvCategory>{for (final c in categories) c.id: c};
  final byName = <String, IptvCategory>{for (final c in categories) c.name: c};
  final seen = <String>{};
  final favOrdered = <IptvCategory>[];
  for (final key in favoriteCategoryIds) {
    final cat = byId[key] ?? byName[key];
    if (cat == null || !seen.add(cat.id)) continue;
    favOrdered.add(cat);
  }
  final rest = [
    for (final c in categories)
      if (!seen.contains(c.id)) c,
  ]..sort(compareRest);
  if (favOrdered.isEmpty) return rest;
  return [...favOrdered, ...rest];
}

bool iptvCategoryIsFavorite(
  IptvCategory category,
  Set<String> favoriteCategoryIds,
) =>
    favoriteCategoryIds.contains(category.id) ||
    favoriteCategoryIds.contains(category.name);
