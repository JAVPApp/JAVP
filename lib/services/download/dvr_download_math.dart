/// Clamp catchup/DVR download window with before/after padding.
class DvrDownloadWindow {
  const DvrDownloadWindow({
    required this.start,
    required this.duration,
    required this.clamped,
  });

  final DateTime start;
  final Duration duration;
  final bool clamped;
}

/// Max timeshift duration accepted by Xtream URL builders (4 hours).
const Duration kMaxTimeshiftDuration = Duration(hours: 4);

DvrDownloadWindow computeDvrDownloadWindow({
  required DateTime programStart,
  required Duration programDuration,
  required Duration padBefore,
  required Duration padAfter,
  required DateTime now,
  required Duration archiveWindow,
  Duration maxDuration = kMaxTimeshiftDuration,
}) {
  final earliest = now.subtract(archiveWindow);
  var start = programStart.subtract(padBefore);
  var clamped = false;
  if (start.isBefore(earliest)) {
    start = earliest;
    clamped = true;
  }
  if (start.isAfter(now)) {
    start = now;
    clamped = true;
  }

  var duration = programDuration + padBefore + padAfter;
  if (duration < const Duration(minutes: 1)) {
    duration = const Duration(minutes: 1);
    clamped = true;
  }
  final untilLive = now.difference(start);
  if (untilLive.inSeconds > 0 && duration > untilLive) {
    duration = untilLive;
    clamped = true;
  }
  if (duration > maxDuration) {
    duration = maxDuration;
    clamped = true;
  }
  if (duration.inSeconds <= 0) {
    duration = const Duration(minutes: 1);
    clamped = true;
  }
  return DvrDownloadWindow(start: start, duration: duration, clamped: clamped);
}

/// Duration chips offered by the no-guide catchup record dialog.
const List<int> kCatchupRecordDurationChoicesMin = [30, 60, 90, 120, 180, 240];

int snapCatchupRecordDurationMin(int rawMinutes) {
  final clamped = rawMinutes.clamp(30, 240);
  return kCatchupRecordDurationChoicesMin.reduce((a, b) {
    final da = (clamped - a).abs();
    final db = (clamped - b).abs();
    if (da != db) return da < db ? a : b;
    // Prefer the longer window on a tie so scrub depth is not truncated.
    return a > b ? a : b;
  });
}

/// Prefill for the end-anchored catchup record dialog (start = end − duration).
({DateTime end, int durationMin}) suggestCatchupRecordEndWindow({
  required DateTime now,
  required DateTime earliest,
  DateTime? initialStart,
  int? initialDurationMin,
}) {
  var durationMin = snapCatchupRecordDurationMin(initialDurationMin ?? 60);
  var end = now;
  if (initialStart != null) {
    final suggestedEnd = initialStart.add(Duration(minutes: durationMin));
    if (suggestedEnd.isAfter(now)) {
      end = now;
      final backMin = now.difference(initialStart).inMinutes;
      if (backMin >= 30) {
        durationMin = snapCatchupRecordDurationMin(backMin);
      }
    } else if (!suggestedEnd.isBefore(earliest)) {
      end = suggestedEnd;
    }
  }
  // Round down to the nearest 5 minutes for cleaner timeshift stamps.
  end = DateTime(end.year, end.month, end.day, end.hour, (end.minute ~/ 5) * 5);
  final minEnd = earliest.add(Duration(minutes: durationMin));
  if (end.isBefore(minEnd)) end = minEnd.isAfter(now) ? now : minEnd;
  if (end.isAfter(now)) end = now;
  return (end: end, durationMin: durationMin);
}
