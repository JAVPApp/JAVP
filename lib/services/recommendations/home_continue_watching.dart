import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/vod_grouping.dart';

/// Home Continue watching vs Watching overlap + last-close snapshot fill.
///
/// Live CW is computed before catalog / Simkl relink finish, so a non-empty
/// leftover list (movies, live, catchup) used to replace the last-close rail.
/// Watching was also keyed only by [MediaItem.id] for episodes, so the same
/// show could sit on both shelves until a later rebuild.
class HomeContinueWatching {
  HomeContinueWatching._();

  /// Identities that mark two Continue watching / Watching rows as one title
  /// (episode vs series shell, AniList vs TMDB vs seriesId).
  ///
  /// TMDB movie and TV ids are separate sequences — movies use `tmdb:`,
  /// series/episodes use `tmdb-tv:`. Xtream `streamId` is only a title key
  /// for series/episodes (per-type counters, not global).
  static Set<String> identityKeys(MediaItem item) {
    final keys = <String>{'id:${item.id}'};
    final al = item.anilistId;
    if (al != null && al > 0) keys.add('al:$al');
    final simkl = item.simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) keys.add('simkl:$simkl');
    final tmdb = item.tmdbId;
    if (tmdb != null && tmdb > 0) {
      if (item.isSeries || item.isEpisode) {
        keys.add('tmdb-tv:$tmdb');
      } else {
        keys.add('tmdb:$tmdb');
      }
    }
    final sid = item.seriesId?.trim();
    if (sid != null && sid.isNotEmpty) {
      keys.add('series:$sid');
      keys.add('id:$sid');
    }
    final stream = item.streamId?.trim();
    if (stream != null &&
        stream.isNotEmpty &&
        (item.isSeries || item.isEpisode)) {
      keys.add('stream:$stream');
    }
    if (item.isSeries) {
      final title = VodGrouping.normalizeTitle(item.title);
      if (title.isNotEmpty) {
        keys.add('series-title:$title|${item.year ?? ''}');
      }
    } else if (!item.isLive &&
        item.kind != MediaKind.catchup &&
        !item.isEpisode) {
      // Quality / language encodes of one movie share Continue watching.
      // Year-qualified name aliases also link a TMDB-enriched row to a
      // name-only sibling. Yearless bare titles stay on `id:` only.
      final g = VodGrouping.groupKey(item);
      if (g != null) keys.add('vod:$g');
      for (final alias in VodGrouping.nameGroupAliases(item)) {
        if (alias.contains('|')) keys.add('vod:$alias');
      }
    }
    return keys;
  }

  static bool overlaps(MediaItem item, Set<String> otherKeys) {
    for (final key in identityKeys(item)) {
      if (otherKeys.contains(key)) return true;
    }
    return false;
  }

  static Set<String> keySet(Iterable<MediaItem> items) {
    return {for (final item in items) ...identityKeys(item)};
  }

  static List<MediaItem> _withoutWatching(
    List<MediaItem> items,
    Set<String> watchingKeys,
  ) {
    if (watchingKeys.isEmpty) return items;
    return [
      for (final item in items)
        if (!overlaps(item, watchingKeys)) item,
    ];
  }

  /// [live] from history. [snapshot] last-close. [watching] the Watching shelf
  /// that will actually paint (live Simkl list or last-close snapshot).
  ///
  /// [historyKeys] are identities still allowed on Continue watching — caller
  /// must apply the same tombstone / source / tracker gates as live CW so
  /// snapshot fill cannot resurrect intentionally hidden rows. Snapshot rows
  /// whose identity is gone (user removed) stay dropped.
  static List<MediaItem> resolve({
    required List<MediaItem> live,
    required List<MediaItem> snapshot,
    required List<MediaItem> watching,
    required bool loading,
    Set<String> historyKeys = const {},
  }) {
    final watchingKeys = keySet(watching);
    final liveFiltered = _withoutWatching(live, watchingKeys);
    final snapFiltered = _withoutWatching(snapshot, watchingKeys);

    if (liveFiltered.isNotEmpty) {
      if (snapFiltered.length > liveFiltered.length && historyKeys.isNotEmpty) {
        return _fillFromSnapshot(liveFiltered, snapFiltered, historyKeys);
      }
      return liveFiltered;
    }
    if (loading) return snapFiltered;
    if (snapFiltered.isEmpty || historyKeys.isEmpty) return const [];
    return [
      for (final item in snapFiltered)
        if (overlaps(item, historyKeys)) item,
    ];
  }

  /// Live rows first (current playheads); append last-close cards that history
  /// still supports but live CW dropped (catalog shell not ready yet).
  static List<MediaItem> _fillFromSnapshot(
    List<MediaItem> live,
    List<MediaItem> snapshot,
    Set<String> historyKeys,
  ) {
    final seen = keySet(live);
    final out = List<MediaItem>.from(live);
    for (final item in snapshot) {
      if (overlaps(item, seen)) continue;
      if (!overlaps(item, historyKeys)) continue;
      out.add(item);
      seen.addAll(identityKeys(item));
    }
    return out;
  }
}
