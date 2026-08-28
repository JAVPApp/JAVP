/// Preset playback rates in the player speed picker (tap cycles a subset).
const kPlaybackSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

bool playbackRatesEqual(double a, double b) => (a - b).abs() < 0.001;

int playbackRateIndex(List<double> speeds, double rate) =>
    speeds.indexWhere((s) => playbackRatesEqual(s, rate));

/// Keep known presets, in picker order. Missing/empty → every preset.
List<double> normalizeCyclePlaybackSpeeds(Iterable<double>? raw) {
  if (raw == null) return List<double>.from(kPlaybackSpeeds);
  final selected = <double>[
    for (final speed in kPlaybackSpeeds)
      if (raw.any((s) => playbackRatesEqual(s, speed))) speed,
  ];
  return selected.isEmpty ? List<double>.from(kPlaybackSpeeds) : selected;
}

List<double> cyclePlaybackSpeedsFromStorage(List<String>? raw) {
  if (raw == null) return List<double>.from(kPlaybackSpeeds);
  return normalizeCyclePlaybackSpeeds(
    raw.map(double.tryParse).whereType<double>(),
  );
}

List<String> cyclePlaybackSpeedsToStorage(List<double> speeds) => [
  for (final speed in normalizeCyclePlaybackSpeeds(speeds)) speed.toString(),
];

/// Next rate when tapping / stepping [direction] (`+1` or `-1`).
double stepPlaybackSpeed({
  required double current,
  required int direction,
  List<double>? cycle,
}) {
  final speeds = normalizeCyclePlaybackSpeeds(cycle);
  final idx = playbackRateIndex(speeds, current);
  if (idx >= 0) {
    final count = speeds.length;
    return speeds[(idx + direction + count) % count];
  }
  // Current rate is not in the cycle — jump to the next ticked speed.
  if (direction >= 0) {
    for (final speed in speeds) {
      if (speed > current + 0.001) return speed;
    }
    return speeds.first;
  }
  for (var i = speeds.length - 1; i >= 0; i--) {
    if (speeds[i] < current - 0.001) return speeds[i];
  }
  return speeds.last;
}

bool cycleContainsPlaybackSpeed(List<double> cycle, double speed) =>
    playbackRateIndex(normalizeCyclePlaybackSpeeds(cycle), speed) >= 0;

/// Toggle [speed] in [cycle]. Refuses to clear the last remaining rate.
List<double> toggleCyclePlaybackSpeed(List<double> cycle, double speed) {
  final current = normalizeCyclePlaybackSpeeds(cycle);
  if (cycleContainsPlaybackSpeed(current, speed)) {
    if (current.length <= 1) return current;
    return [
      for (final s in current)
        if (!playbackRatesEqual(s, speed)) s,
    ];
  }
  return normalizeCyclePlaybackSpeeds([...current, speed]);
}

String formatPlaybackRateLabel(double rate) {
  final text = rate == rate.roundToDouble()
      ? rate.toInt().toString()
      : rate.toString();
  return '${text}x';
}

/// CAF [setPlaybackRate] accepts 0.5–2.0. 3x stays phone-only.
const kCastPlaybackRateMin = 0.5;
const kCastPlaybackRateMax = 2.0;

bool isCastPlaybackRate(double rate) =>
    rate >= kCastPlaybackRateMin - 0.001 &&
    rate <= kCastPlaybackRateMax + 0.001;

List<double> castPlaybackSpeeds([List<double>? cycle]) {
  final filtered = [
    for (final speed in normalizeCyclePlaybackSpeeds(cycle))
      if (isCastPlaybackRate(speed)) speed,
  ];
  return filtered.isEmpty ? const [0.75, 1.0, 1.25, 1.5, 2.0] : filtered;
}
