import 'package:javp/models/media_item.dart';

/// 0-based index after [delta] steps from [currentIndex].
///
/// When [currentIndex] is negative (channel not in the list), counting starts
/// at 0 — same as [PlaybackProvider.zapLiveRelative].
int liveZapRelativeIndex({
  required int length,
  required int currentIndex,
  required int delta,
}) {
  if (length <= 0) return 0;
  final start = currentIndex < 0 ? 0 : currentIndex % length;
  if (delta == 0) return start;
  var next = (start + delta) % length;
  if (next < 0) next += length;
  return next;
}

/// Like [liveZapRelativeIndex], but skips indexes where [skip] is true.
///
/// Returns null when [delta] is 0, the list is empty, or every channel is
/// skipped (e.g. multi-view would land on the other pane).
int? liveZapRelativeIndexSkipping({
  required int length,
  required int currentIndex,
  required int delta,
  required bool Function(int index) skip,
}) {
  if (length <= 0 || delta == 0) return null;
  final start = currentIndex < 0 ? 0 : currentIndex % length;
  for (var step = 1; step <= length; step++) {
    var next = (start + delta * step) % length;
    if (next < 0) next += length;
    if (!skip(next)) return next;
  }
  return null;
}

/// Resolve digit entry against a zap list: match [channelId]/[streamId], else
/// fall back to 1-based list index.
MediaItem? resolveLiveZapNumber(List<MediaItem> list, int number) {
  if (number < 1 || list.isEmpty) return null;
  final asString = '$number';
  final byMeta = list.indexWhere((c) {
    if (c.channelId == asString || c.streamId == asString) return true;
    final ch = int.tryParse(c.channelId ?? '');
    if (ch == number) return true;
    final sid = int.tryParse(c.streamId ?? '');
    return sid == number;
  });
  if (byMeta >= 0) return list[byMeta];
  if (number <= list.length) return list[number - 1];
  return null;
}
