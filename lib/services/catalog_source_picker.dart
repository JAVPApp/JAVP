import 'package:javp/models/iptv_source.dart';

/// Whether [source] can contribute movies/series to Catalog.
///
/// Mirrors [LibraryProvider] VOD participation: enabled, not EPG-only, and
/// Xtream must have [IptvSource.vodEnabled].
bool iptvSourceContributesCatalog(IptvSource source) {
  if (!source.enabled || source.type.isEpgOnly) return false;
  if (source.type == IptvSourceType.xtream) return source.vodEnabled;
  return source.type == IptvSourceType.m3u ||
      source.type == IptvSourceType.stalker ||
      source.type == IptvSourceType.custom ||
      source.type.isMediaServer;
}

/// Enabled VOD-capable sources for the Catalog source picker.
///
/// When [vodOnly] is true (default), sources that do not contribute Catalog
/// VOD are hidden unless they are in [selectedIds] (so the picker can still
/// clear/change a stale selection).
List<IptvSource> catalogPickerSources({
  required Iterable<IptvSource> sources,
  bool vodOnly = true,
  Set<String> selectedIds = const {},
}) {
  final keep = {...selectedIds};
  final enabled = <IptvSource>[
    for (final source in sources)
      if (source.enabled && !source.type.isEpgOnly) source,
  ];
  if (!vodOnly) return enabled;
  return [
    for (final source in enabled)
      if (iptvSourceContributesCatalog(source) || keep.contains(source.id))
        source,
  ];
}
