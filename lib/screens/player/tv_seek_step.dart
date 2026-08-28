/// Window in which repeated seek keys grow the step size.
const kTvSeekBurstWindow = Duration(milliseconds: 400);

/// Next skip size when the user hammers seek.
///
/// Outside [burstWindow] the step resets to [resetStep]. Inside the burst,
/// [doubleEachBurst] doubles (TV remote, cap 120s); otherwise the step grows
/// by [resetStep] (simple TV / `video_player`, cap 60s).
int nextTvSeekStepSeconds({
  required int currentStep,
  required DateTime now,
  DateTime? lastSeekAt,
  Duration burstWindow = kTvSeekBurstWindow,
  int resetStep = 10,
  int maxStep = 60,
  bool doubleEachBurst = false,
}) {
  final inBurst =
      lastSeekAt != null && now.difference(lastSeekAt) < burstWindow;
  if (!inBurst) return resetStep;
  final next = doubleEachBurst ? currentStep * 2 : currentStep + resetStep;
  return next.clamp(resetStep, maxStep);
}
