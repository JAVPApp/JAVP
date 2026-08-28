/// What a surface tap should do for ±10s skip.
///
/// Phone taps are delivered immediately. [GestureDetector.onDoubleTap] is not
/// used: it delays [onTap] and treats a follow-up pair as another double-tap,
/// which ate same-side skip chaining (double-tap, then single taps).
///
/// The first skip on a side is two taps within [kSeekDoubleTapWindow]. While
/// that burst is open (same window — the ±Ns badge stays up), same-side taps
/// add another step. Center / other-side taps end the burst and toggle chrome.
/// A lone side tap waits out the window in case a second tap is coming
/// ([PlayerSeekTapAction.scheduleChrome]).
enum PlayerSeekTapAction { seek, toggleChromeNow, scheduleChrome }

/// First skip on a side is two taps this close together. Follow-up same-side
/// taps and the skip badge use this same window after the last skip.
const kSeekDoubleTapWindow = Duration(milliseconds: 300);

PlayerSeekTapAction playerSeekTapAction({
  required int side,
  required int? burstSide,
  required int? pendingSide,
  required DateTime now,
  required DateTime? pendingAt,
  Duration window = kSeekDoubleTapWindow,
}) {
  final doubleTap =
      side != 0 &&
      pendingSide == side &&
      pendingAt != null &&
      now.difference(pendingAt) <= window;

  if (side != 0 && burstSide == side) {
    return PlayerSeekTapAction.seek;
  }
  if (burstSide != null) {
    return PlayerSeekTapAction.toggleChromeNow;
  }
  if (doubleTap) return PlayerSeekTapAction.seek;
  if (side == 0) return PlayerSeekTapAction.toggleChromeNow;
  return PlayerSeekTapAction.scheduleChrome;
}

/// Desktop picture click: pause/play immediately. A second click inside
/// [window] is treated as double-click-to-fullscreen and should revert that
/// play/pause so cinema does not also toggle transport.
const kDesktopPictureDoubleClickWindow = Duration(milliseconds: 320);

bool isDesktopPictureDoubleClick({
  required DateTime now,
  required DateTime? lastClickAt,
  Duration window = kDesktopPictureDoubleClickWindow,
}) {
  if (lastClickAt == null) return false;
  return now.difference(lastClickAt) <= window;
}

/// Drop a second play/pause within this window (one finger press must not
/// resume then immediately pause when the finger lifts).
const kPlayPauseToggleDebounce = Duration(milliseconds: 280);

bool shouldAcceptPlayPauseToggle({
  required DateTime now,
  required DateTime? lastToggleAt,
  Duration window = kPlayPauseToggleDebounce,
}) {
  if (lastToggleAt == null) return true;
  return now.difference(lastToggleAt) >= window;
}
