/// Interactive DVR timeshift window for Xtream catchup URLs.
library;

/// Smallest forward window we will request.
const Duration kDvrTimeshiftMinWindow = Duration(minutes: 30);

/// Panels often reject multi-hour catchup; stay inside the existing scrub cap.
const Duration kDvrTimeshiftMaxWindow = Duration(hours: 3);

/// Extra time past the live edge so the clip keeps covering newly aired video.
///
/// Live continues while we play. A duration of only "until live" ends the
/// segment at the old live edge; joining live then skips that gap.
const Duration kDvrTimeshiftBeyondLive = Duration(hours: 3);

/// How close to now counts as caught up (same as [seekLiveDvrTo] live snap).
const Duration kDvrTimeshiftCaughtUp = Duration(seconds: 2);

/// Forward duration to put on a DVR/timeshift URL.
///
/// Never "time until live": that stops the server at the live edge as it was
/// when the clip was requested. Request [untilLive] + [kDvrTimeshiftBeyondLive]
/// (capped) so playback can continue as the archive grows.
Duration continuousTimeshiftDuration({
  required DateTime start,
  required DateTime now,
}) {
  final untilLive = now.difference(start);
  if (untilLive <= Duration.zero) return kDvrTimeshiftMinWindow;
  var duration = untilLive + kDvrTimeshiftBeyondLive;
  if (duration < kDvrTimeshiftMinWindow) return kDvrTimeshiftMinWindow;
  if (duration > kDvrTimeshiftMaxWindow) return kDvrTimeshiftMaxWindow;
  return duration;
}

/// Join live after timeshift EOF only when the playhead has reached now.
///
/// At 1x the original delay never shrinks. Treating "within 12s of live" as
/// caught-up jumps to the new live edge and skips the gap that aired during
/// the clip. Instant-EOF extend loops are handled by the caller.
bool shouldJoinLiveAfterTimeshift({required Duration behindLive}) {
  return behindLive <= kDvrTimeshiftCaughtUp;
}
