/// Clock label for player / cast chrome (`1:02:03` or `5:03` / `05:03`).
///
/// Phone and Cast omit the leading zero on minutes when the title is under an
/// hour. TV chrome pads minutes so the seek bar width stays stable.
String formatPlayerClock(Duration d, {bool padMinutes = true}) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:$m:$s';
  return padMinutes ? '$m:$s' : '${d.inMinutes}:$s';
}
