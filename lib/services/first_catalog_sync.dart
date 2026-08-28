import 'package:javp/models/iptv_source.dart';

/// Sources that download a VOD / library catalog after the first playlist pass.
bool sourceExpectsOnDemandCatalog(IptvSource source) {
  if (!source.vodEnabled) return false;
  return switch (source.type) {
    IptvSourceType.xtream ||
    IptvSourceType.stalker ||
    IptvSourceType.custom ||
    IptvSourceType.jellyfin ||
    IptvSourceType.emby ||
    IptvSourceType.plex => true,
    IptvSourceType.m3u || IptvSourceType.xmltv => false,
  };
}

/// True until the first playlist (and VOD catalog, when this source has one)
/// has been stamped on [source].
///
/// VOD prefetch stamps [IptvSource.lastVodSyncedAt] before the long save, so
/// callers that need the banner through Saving VOD should also latch the id
/// while [isBusy] stays true.
bool sourceAwaitsFirstCatalog(IptvSource source) {
  if (!source.enabled) return false;
  if (source.type == IptvSourceType.xmltv) return false;
  if (source.lastSyncedAt == null) return true;
  if (sourceExpectsOnDemandCatalog(source) && source.lastVodSyncedAt == null) {
    return true;
  }
  return false;
}

/// First catalog download is still running — not a later 24h refresh.
bool isFirstCatalogSyncRunningFor({
  required Iterable<IptvSource> sources,
  required bool Function(String sourceId) isBusy,
  Set<String> latchedIds = const {},
}) {
  for (final id in latchedIds) {
    if (isBusy(id)) return true;
  }
  for (final source in sources) {
    if (!sourceAwaitsFirstCatalog(source)) continue;
    if (isBusy(source.id)) return true;
  }
  return false;
}
