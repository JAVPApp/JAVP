/// Whether a playlist Synchroniser / soft-sync should skip re-downloading XMLTV.
///
/// Dedicated XMLTV sources still refresh on Sync (`*-sync:xmltv`). Live list
/// sync must not re-fetch a warm guide — that stalls the UI for seconds under
/// « Mise à jour du guide » even when parse is skipped (`fetchMs` ≫ `parseMs`).
bool shouldSkipWarmXmltvReloadAfterPlaylistSync({
  required String reason,
  required Set<String> urls,
  required Set<String> appliedFeedUrls,
  required bool hasPrograms,
}) {
  if (!_isPlaylistCatalogSyncReason(reason)) return false;
  if (urls.isEmpty || !hasPrograms) return false;
  // Exact match — every needed feed is already warm.
  if (urls.every(appliedFeedUrls.contains)) return true;
  // URL set only grew (or shrunk extras on disk). Keep the warm guide so
  // Synchroniser does not HTTP-fetch the new feed mid-Sync; idle/settings
  // refresh picks up additions.
  if (appliedFeedUrls.isNotEmpty && appliedFeedUrls.every(urls.contains)) {
    return true;
  }
  return false;
}

/// Skip download/parse of one feed during playlist follow-on when it is
/// already in SQLite. Adding a new catalog URL must not re-ingest the rest
/// of the merged guide (that is the 10s+ `epg-ingest` stall).
bool shouldReuseWarmXmltvFeed({
  required String reason,
  required String url,
  required Set<String> appliedFeedUrls,
}) {
  if (!_isPlaylistCatalogSyncReason(reason)) return false;
  return appliedFeedUrls.contains(url);
}

/// Xtream / M3U / custom catalog sync (manual or soft) — not a dedicated
/// XMLTV source Synchroniser, which must still hit the network.
bool _isPlaylistCatalogSyncReason(String reason) {
  if (reason == 'soft-sync:xmltv' || reason == 'manual-sync:xmltv') {
    return false;
  }
  return reason.startsWith('soft-sync:') || reason.startsWith('manual-sync:');
}
