/// Whether plex.tv hosted VOD metadata is something JAVP can list as playable.
///
/// `vod.provider.plex.tv` / Discover mix in the global movie/TV catalog
/// (posters and "where to watch") next to titles Plex actually hosts. Catalog
/// rows without [Media] or Plex AVOD [Availability] have no video for us.
bool plexCloudMetadataIsListed(Map<String, dynamic> meta) {
  final type = '${meta['type'] ?? ''}'.trim().toLowerCase();
  if (type == 'show') {
    // Episode files live on children; keep the series unless Availability
    // clearly points only at other services.
    return plexCloudAvailabilityIsPlexHosted(meta) != false;
  }
  if (plexCloudHasPlayableMedia(meta)) return true;
  return plexCloudAvailabilityIsPlexHosted(meta) == true;
}

/// True when [meta] includes at least one real video stream (not a trailer).
bool plexCloudHasPlayableMedia(Map<String, dynamic> meta) {
  for (final media in _asMapList(meta['Media'])) {
    if (_mediaLooksLikeTrailer(media)) continue;
    if (_mediaLooksLikeVideo(media)) return true;
  }
  return false;
}

/// `true` = Plex hosts this title, `false` = only other services, `null` = unknown.
bool? plexCloudAvailabilityIsPlexHosted(Map<String, dynamic> meta) {
  final rows = _asMapList(meta['Availability'] ?? meta['availability']);
  if (rows.isEmpty) return null;
  var sawPlexPlayable = false;
  for (final row in rows) {
    if (_availabilityIsPlexPlayable(row)) sawPlexPlayable = true;
  }
  return sawPlexPlayable;
}

bool _availabilityIsPlexPlayable(Map<String, dynamic> row) {
  final platform =
      '${row['platform'] ?? row['platformInfo'] ?? row['title'] ?? ''}'
          .trim()
          .toLowerCase();
  final offer = '${row['offerType'] ?? row['offer'] ?? ''}'
      .trim()
      .toLowerCase();
  if (_offerIsPaid(offer)) return false;
  if (platform.contains('plex')) return true;
  if (platform.isEmpty && (offer == 'avod' || offer == 'free')) return true;
  return false;
}

bool _offerIsPaid(String offer) {
  return offer.contains('buy') ||
      offer.contains('rent') ||
      offer.contains('purchase') ||
      offer == 'tvod';
}

bool _mediaLooksLikeTrailer(Map<String, dynamic> raw) {
  final extra = raw['extraType'];
  if (extra == null) return false;
  final value = '$extra'.trim().toLowerCase();
  return value.isNotEmpty && value != '0' && value != 'false';
}

bool _mediaLooksLikeVideo(Map<String, dynamic> media) {
  final protocol = '${media['protocol'] ?? ''}'.trim().toLowerCase();
  final codec = '${media['videoCodec'] ?? ''}'.trim().toLowerCase();
  final container = '${media['container'] ?? ''}'.trim().toLowerCase();
  if (protocol.isNotEmpty || codec.isNotEmpty || container.isNotEmpty) {
    return true;
  }
  final durationMs = (media['duration'] as num?)?.toInt() ?? 0;
  // Feature-length-ish; metadata-only titles often have no Media duration.
  return durationMs >= 60 * 1000;
}

List<Map<String, dynamic>> _asMapList(dynamic raw) {
  if (raw is List) {
    return [
      for (final row in raw)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }
  if (raw is Map) return [Map<String, dynamic>.from(raw)];
  return const [];
}
