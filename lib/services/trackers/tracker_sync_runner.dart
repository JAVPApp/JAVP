import 'package:javp/models/media_item.dart';
import 'package:javp/services/simkl/simkl_match.dart';

/// Light stage labels for Integrations Sync Now / bootstrap tracker pulls.
///
/// Shared by SIMKL, Trakt, and future trackers (Serializd / BetaSeries) so the
/// UI can show the same progress vocabulary without per-provider strings.
enum TrackerSyncPhase {
  /// Network list / activities fetch.
  fetching,

  /// Building the local id/title match index over catalog + VOD.
  indexing,

  /// Matching remote rows onto local [MediaItem]s.
  matching,

  /// Applying playback progress / status merges.
  merging,
}

/// Pools used to resolve tracker shelves onto local playable rows.
class TrackerMatchPools {
  const TrackerMatchPools({
    required this.catalog,
    required this.history,
    required this.watchlist,
    this.extra = const [],
    this.extraCount,
  });

  final List<MediaItem> catalog;
  final List<MediaItem> history;
  final List<MediaItem> watchlist;
  final Iterable<MediaItem> extra;

  /// Optional size hint for [extra] (e.g. VOD cache count) — avoids walking it.
  final int? extraCount;

  /// Streams pools without allocating a giant concatenated list.
  Iterable<MediaItem> get chained sync* {
    yield* catalog;
    yield* history;
    yield* watchlist;
    yield* extra;
  }
}

/// Builds a reusable [SimklMatchIndex] with frame yields (not [Isolate.run] —
/// shipping ~200k [MediaItem]s through an isolate transfer crashes the Windows
/// embedder; same constraint as VOD group indexing).
Future<SimklMatchIndex> buildTrackerMatchIndex(
  TrackerMatchPools pools, {
  void Function(TrackerSyncPhase phase)? onPhase,
  int yieldEvery = 1024,
}) async {
  onPhase?.call(TrackerSyncPhase.indexing);
  return SimklMatchIndex.buildAsync(
    pools.chained,
    yieldEvery: yieldEvery,
  );
}
