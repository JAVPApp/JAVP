import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// True for remote Back / Escape / browser-back.
bool isTvBackKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.browserBack;
}

/// True for remote OK / Select / Enter / A.
bool isTvSelectKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA;
}

/// False when a sheet/dialog is above [context]'s route — Back belongs there.
bool tvRouteIsCurrent(BuildContext context) {
  final route = ModalRoute.of(context);
  return route == null || route.isCurrent;
}

/// Android TV Back arrives as both a key event and a Navigator pop.
///
/// Without coalescing, chrome closes the menu on the key and the PopScope
/// then leaves the player — Back appears to skip “close menu” and jump to
/// Home. The two events can land in consecutive frames, so this is a short
/// time window rather than a single-frame lock.
class TvBackGate {
  /// How long key + twin [popRoute] from one Back press are treated as one.
  static const coalesceWindow = Duration(milliseconds: 120);

  /// Key-only leave fallback: must exceed [coalesceWindow] so we never pop
  /// the player while the twin Android popRoute can still arrive.
  static const leaveFallbackDelay = Duration(milliseconds: 180);

  /// After Back hides chrome, the twin popRoute can land past
  /// [coalesceWindow]. Absorb one leave so we stay fullscreen.
  static const dismissAbsorbWindow = Duration(milliseconds: 400);

  DateTime? _claimedAt;
  DateTime? _absorbLeaveUntil;

  /// First caller in the window wins; later callers get false.
  bool claim() {
    final now = DateTime.now();
    final previous = _claimedAt;
    if (previous != null && now.difference(previous) < coalesceWindow) {
      return false;
    }
    _claimedAt = now;
    return true;
  }

  /// Call when Back dismissed chrome / an overlay instead of leaving.
  void armAbsorbLeave() {
    _absorbLeaveUntil = DateTime.now().add(dismissAbsorbWindow);
  }

  /// True once for a leave that is the twin of a chrome-dismiss Back.
  bool takeAbsorbLeave() {
    final until = _absorbLeaveUntil;
    if (until == null) return false;
    _absorbLeaveUntil = null;
    return DateTime.now().isBefore(until);
  }

  /// Test hook: expire the coalesce claim without dropping a pending absorb.
  void expireClaim() {
    _claimedAt = null;
  }

  /// Test hook: expire claim and absorb without waiting.
  void reset() {
    _claimedAt = null;
    _absorbLeaveUntil = null;
  }
}

/// Lets TV player chrome consume Back before the route exits.
class TvBackDispatcher {
  final TvBackGate gate = TvBackGate();
  bool Function()? _consume;
  bool _leavePending = false;

  void attach(bool Function() consume) {
    _consume = consume;
  }

  void detach() {
    _consume = null;
    _leavePending = false;
  }

  /// Returns true when the press was a duplicate or chrome handled it
  /// (menu closed, overlay dismissed). False means the route should leave.
  ///
  /// Use from [PopScope] / route pop — that path owns leaving the player.
  bool handle() {
    if (_leavePending) {
      // Key already decided leave; this twin popRoute performs it.
      _leavePending = false;
      return false;
    }
    if (!gate.claim()) return true;
    if (gate.takeAbsorbLeave()) return true;
    final consumed = _consume?.call() ?? false;
    if (consumed) gate.armAbsorbLeave();
    return consumed;
  }

  /// Key-event path for the same Back press that also delivers [PopScope].
  ///
  /// Android TV / Fire TV send both a key event and a Navigator pop. If the
  /// key handler pops `/player`, the twin pop finishes the Activity (app
  /// exits). Chrome may still consume here; leaving is always deferred to
  /// [handle] so only one route pop runs.
  ///
  /// Returns true when Back is fully handled (chrome or duplicate). False
  /// means leave is pending for [PopScope] — do not call onClose/pop.
  bool handleKey() {
    if (!gate.claim()) return true;
    if (gate.takeAbsorbLeave()) return true;
    if (_consume?.call() ?? false) {
      gate.armAbsorbLeave();
      return true;
    }
    _leavePending = true;
    return false;
  }

  /// True when [handleKey] deferred leave and [handle] has not run yet.
  bool get leavePending => _leavePending;

  /// Fallback when the platform only delivered a key (no twin popRoute).
  /// Returns true once; clears the pending flag.
  bool takeLeavePending() {
    if (!_leavePending) return false;
    _leavePending = false;
    return true;
  }
}
