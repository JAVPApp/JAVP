import 'package:javp/models/iptv_source.dart';

/// Whether a source currently contributes live channels to the TV tab.
bool iptvSourceHasLive(IptvSource source) => source.channelCount > 0;

/// Enabled non-EPG sources for the TV source picker, optionally live-only.
///
/// When [liveOnly] is true, sources without live channels are hidden unless
/// they are in [selectedIds] (so the picker can still clear/change them).
List<IptvSource> tvPickerSources({
  required Iterable<IptvSource> sources,
  required bool liveOnly,
  Set<String> selectedIds = const {},
}) {
  final keep = {...selectedIds};
  final enabled = <IptvSource>[
    for (final source in sources)
      if (source.enabled && !source.type.isEpgOnly) source,
  ];
  if (!liveOnly) return enabled;
  return [
    for (final source in enabled)
      if (iptvSourceHasLive(source) || keep.contains(source.id)) source,
  ];
}

/// True when the picker should offer a Live / All filter (mixed catalogs).
bool tvPickerNeedsLiveFilter(Iterable<IptvSource> sources) {
  var hasLive = false;
  var hasNonLive = false;
  for (final source in sources) {
    if (!source.enabled || source.type.isEpgOnly) continue;
    if (iptvSourceHasLive(source)) {
      hasLive = true;
    } else {
      hasNonLive = true;
    }
    if (hasLive && hasNonLive) return true;
  }
  return false;
}
