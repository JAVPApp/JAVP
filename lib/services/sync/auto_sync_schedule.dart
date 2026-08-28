/// Debounce after a syncable local write before Drive/WebDAV push.
const kLocalDirtyAutoSyncDebounce = Duration(seconds: 45);

/// Source add/remove/edit — short coalesce so other devices can pull soon.
const kUrgentAutoSyncDebounce = Duration(seconds: 8);

/// Floor between successful non-urgent auto-syncs so history soft-persist /
/// tracker merges cannot stack a full snapshot apply roughly every minute.
const kLocalDirtyAutoSyncMinInterval = Duration(minutes: 5);

/// Delay until the next local-dirty auto-sync may start.
///
/// [urgent] (source list changes) skips [minInterval] — the other device
/// cannot pull a source that this one has not pushed yet. History / lists
/// still wait out the floor so browsing Home does not fire Drive every minute.
Duration localDirtyAutoSyncDelay({
  required DateTime? lastSyncAt,
  required DateTime now,
  required bool urgent,
  Duration debounce = kLocalDirtyAutoSyncDebounce,
  Duration urgentDebounce = kUrgentAutoSyncDebounce,
  Duration minInterval = kLocalDirtyAutoSyncMinInterval,
}) {
  if (urgent) return urgentDebounce;
  if (lastSyncAt == null) return debounce;
  final untilEarliest = lastSyncAt.add(minInterval).difference(now);
  if (untilEarliest <= Duration.zero) return debounce;
  return untilEarliest > debounce ? untilEarliest : debounce;
}
