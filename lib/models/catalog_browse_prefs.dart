/// Catalog Movies/Series browse prefs (sort + hide watched + genre include/exclude).
///
/// Local to the device/profile (not Drive-synced), same idea as My List chips.
enum CatalogBrowseSort { popular, titleAsc, yearDesc, ratingDesc }

class CatalogBrowsePrefs {
  const CatalogBrowsePrefs({
    this.sort = CatalogBrowseSort.popular,
    this.hideWatched = true,
    this.includeGenres = const {},
    this.excludeGenres = const {},
  });

  /// Popular first, hide finished titles, no genre pins.
  static const defaults = CatalogBrowsePrefs();

  /// Legacy Catalog behavior: A–Z, watched titles stay visible.
  static const legacyTitle = CatalogBrowsePrefs(
    sort: CatalogBrowseSort.titleAsc,
    hideWatched: false,
  );

  final CatalogBrowseSort sort;
  final bool hideWatched;
  final Set<String> includeGenres;
  final Set<String> excludeGenres;

  bool get hasGenreFilters =>
      includeGenres.isNotEmpty || excludeGenres.isNotEmpty;

  /// True when the user changed something from [defaults].
  bool get isCustomized =>
      sort != CatalogBrowseSort.popular || !hideWatched || hasGenreFilters;

  int get stamp => Object.hash(
    sort.index,
    hideWatched,
    Object.hashAll(includeGenres.toList()..sort()),
    Object.hashAll(excludeGenres.toList()..sort()),
  );

  CatalogBrowsePrefs copyWith({
    CatalogBrowseSort? sort,
    bool? hideWatched,
    Set<String>? includeGenres,
    Set<String>? excludeGenres,
  }) {
    return CatalogBrowsePrefs(
      sort: sort ?? this.sort,
      hideWatched: hideWatched ?? this.hideWatched,
      includeGenres: includeGenres ?? this.includeGenres,
      excludeGenres: excludeGenres ?? this.excludeGenres,
    );
  }

  Map<String, dynamic> toJson() => {
    'sort': sort.name,
    'hideWatched': hideWatched,
    'includeGenres': includeGenres.toList()..sort(),
    'excludeGenres': excludeGenres.toList()..sort(),
  };

  factory CatalogBrowsePrefs.fromJson(Map<String, dynamic> json) {
    var sort = CatalogBrowseSort.popular;
    final sortName = json['sort'] as String?;
    for (final v in CatalogBrowseSort.values) {
      if (v.name == sortName) sort = v;
    }
    final include = _stringSet(json['includeGenres']);
    final exclude = _stringSet(json['excludeGenres']);
    return CatalogBrowsePrefs(
      sort: sort,
      hideWatched: json['hideWatched'] as bool? ?? true,
      includeGenres: include,
      excludeGenres: exclude,
    );
  }

  static Set<String> _stringSet(Object? raw) {
    if (raw is! List) return const {};
    return {
      for (final e in raw)
        if ('$e'.trim().isNotEmpty) '$e'.trim(),
    };
  }
}
