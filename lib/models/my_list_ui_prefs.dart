/// Lightweight My List browse prefs (kind / source / sort). Not profile-synced.
enum MyListKindFilter { all, movies, series }

/// Source chips for My List. Legacy persisted `simkl` maps to [simklWatching].
enum MyListSourceFilter {
  all,
  local,
  simklWatching,
  simklPlan,
  trakt,
  plex,
  letterboxd,
  serializdWatching,
  serializdWatchlist,
  betaseriesWatching,
  betaseriesPlan,

  /// @Deprecated — kept for older prefs JSON; treated as [simklWatching].
  simkl,
}

enum MyListSort { recentlyAdded, titleAsc }

class MyListUiPrefs {
  const MyListUiPrefs({
    this.kind = MyListKindFilter.all,
    this.source = MyListSourceFilter.all,
    this.sort = MyListSort.recentlyAdded,
  });

  static const defaults = MyListUiPrefs();

  final MyListKindFilter kind;
  final MyListSourceFilter source;
  final MyListSort sort;

  /// Normalized source (legacy `simkl` → watching).
  MyListSourceFilter get effectiveSource {
    if (source == MyListSourceFilter.simkl) {
      return MyListSourceFilter.simklWatching;
    }
    return source;
  }

  MyListUiPrefs copyWith({
    MyListKindFilter? kind,
    MyListSourceFilter? source,
    MyListSort? sort,
  }) {
    return MyListUiPrefs(
      kind: kind ?? this.kind,
      source: source ?? this.source,
      sort: sort ?? this.sort,
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    // Persist normalized value so we stop writing the legacy alias.
    'source': effectiveSource.name,
    'sort': sort.name,
  };

  factory MyListUiPrefs.fromJson(Map<String, dynamic> json) {
    MyListKindFilter kind = MyListKindFilter.all;
    MyListSourceFilter source = MyListSourceFilter.all;
    MyListSort sort = MyListSort.recentlyAdded;
    final kindName = json['kind'] as String?;
    final sourceName = json['source'] as String?;
    final sortName = json['sort'] as String?;
    for (final v in MyListKindFilter.values) {
      if (v.name == kindName) kind = v;
    }
    for (final v in MyListSourceFilter.values) {
      if (v.name == sourceName) source = v;
    }
    for (final v in MyListSort.values) {
      if (v.name == sortName) sort = v;
    }
    final prefs = MyListUiPrefs(kind: kind, source: source, sort: sort);
    if (prefs.source == MyListSourceFilter.simkl) {
      return prefs.copyWith(source: MyListSourceFilter.simklWatching);
    }
    return prefs;
  }
}

/// Overlay a one-shot source chip (Home Watching → See all) onto saved prefs.
/// Kind/sort stay as stored; the override is not persisted until the user
/// changes a chip.
MyListUiPrefs applyMyListInitialSource(
  MyListUiPrefs prefs,
  MyListSourceFilter? initialSource,
) {
  if (initialSource == null) return prefs;
  return prefs.copyWith(source: initialSource);
}
