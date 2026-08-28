import 'package:javp/models/iptv_source.dart';

/// Whether idle / restore sync should treat [type] as having no local content.
///
/// Profile / Drive copies [IptvSource.channelCount], [IptvSource.vodCount],
/// and sync stamps without the SQLite rows. Trust only on-device listings.
bool sourceShelfLooksEmpty({
  required IptvSourceType type,
  required int catalogCount,
  required bool hasLocalLiveRows,
  required bool hasLocalVodRows,
  DateTime? lastSyncedAt,
}) {
  if (type == IptvSourceType.xmltv) {
    return lastSyncedAt == null;
  }
  if (type.isLiveIptv) {
    // Live listings are independent of VOD SQLite. VOD alone must not skip
    // live soft-sync after Drive restore (Xtream/Stalker idle prefetch).
    return !hasLocalLiveRows && catalogCount == 0;
  }
  if (type.isMediaServer) {
    // Media servers may be VOD-only; treat either occupancy as warm so an
    // empty Live listing does not soft-sync forever.
    return !hasLocalLiveRows && !hasLocalVodRows && catalogCount == 0;
  }
  // Custom catalogs live in SQLite VOD and/or [catalog].
  return catalogCount == 0 && !hasLocalVodRows;
}

/// Empty M3U / custom dump that already failed/tried recently must not
/// soft-sync again.
///
/// A 404 playlist or a dump that never wrote SQLite stays "empty", so
/// idle/rebuild/SWR used to hammer the URL and freeze Windows.
bool skipRecentEmptyHeavySyncRetry({
  required IptvSourceType type,
  required bool looksEmpty,
  DateTime? lastSyncedAt,
  required DateTime now,
  required Duration staleAfter,
}) {
  if (!looksEmpty) return false;
  if (type != IptvSourceType.m3u && type != IptvSourceType.custom) {
    return false;
  }
  if (lastSyncedAt == null) return false;
  final age = now.difference(lastSyncedAt);
  if (age.isNegative) return true;
  return age < staleAfter;
}
