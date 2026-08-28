import 'package:javp/models/media_item.dart';

/// Local wall-clock label for catchup air time (`yyyy-MM-dd HH:mm`).
String formatCatchupAirDate(DateTime dt) {
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi';
}

/// Wall-clock start encoded in `dvr-{streamId}-{ms}` / `dvr-dl-…-{ms}` ids.
DateTime? catchupStartOf(MediaItem item) {
  if (item.kind != MediaKind.catchup) return null;
  final match = RegExp(r'^dvr-.+-(\d+)$').firstMatch(item.id);
  if (match == null) return null;
  final ms = int.tryParse(match.group(1)!);
  if (ms == null) return null;
  // Epoch ms are absolute; keep local DateTime like the rest of DVR math.
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

/// Resume wall-clock from a catchup history row.
///
/// [progress] is program-relative (see PlaybackProvider DVR persist). Prefer
/// the EPG [programDuration] over any clamped timeshift clip duration so
/// `duration * progress` does not snap to the segment start / wrong offset.
DateTime? catchupResumeWallClock({
  required DateTime? programStart,
  required double progress,
  Duration? programDuration,
  Duration? fallbackDuration,
}) {
  if (programStart == null) return null;
  final duration = (programDuration != null &&
          programDuration.inMilliseconds > 0)
      ? programDuration
      : fallbackDuration;
  final p = progress.clamp(0.0, 1.0);
  if (duration == null || duration.inMilliseconds <= 0) return programStart;
  if (p <= 0.02) return programStart;
  if (p >= 0.95) return programStart.add(duration * 0.95);
  return programStart.add(duration * p);
}

/// Air-date label from [MediaItem.releaseDate] or the timestamp in a catchup id.
String? catchupAirDateLabelOf(MediaItem item) {
  final stamped = item.releaseDate?.trim();
  if (stamped != null && stamped.isNotEmpty) return stamped;
  final start = catchupStartOf(item);
  if (start == null) return null;
  return formatCatchupAirDate(start);
}
