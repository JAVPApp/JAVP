import 'package:flutter/foundation.dart';

/// A discrete thing the user asked for with a controller.
///
/// Deliberately UI-level rather than button-level: the player and the browse
/// shell both consume these, and only the mapping table knows that "A" means
/// activate.
enum GamepadAction {
  up,
  down,
  left,
  right,

  /// A — activate the focused thing, or play/pause in the player.
  activate,

  /// B — back out.
  back,

  /// X — secondary (mute in the player).
  secondary,

  /// Y — tertiary (fullscreen in the player).
  tertiary,

  shoulderLeft,
  shoulderRight,
  triggerLeft,
  triggerRight,

  /// Start / menu.
  menu,

  /// View / back button (the small one, not B).
  view,
}

/// One XInput sample, normalised so the decoder never sees Win32 types.
@immutable
class GamepadSample {
  const GamepadSample({
    this.buttons = 0,
    this.leftTrigger = 0,
    this.rightTrigger = 0,
    this.thumbLX = 0,
    this.thumbLY = 0,
  });

  /// `XINPUT_GAMEPAD.wButtons` bitmask.
  final int buttons;

  /// 0–255, as reported by XInput.
  final int leftTrigger;
  final int rightTrigger;

  /// −32768…32767.
  final int thumbLX;
  final int thumbLY;

  bool pressed(int mask) => buttons & mask != 0;

  // XInput button masks (XINPUT_GAMEPAD_*).
  static const dpadUp = 0x0001;
  static const dpadDown = 0x0002;
  static const dpadLeft = 0x0004;
  static const dpadRight = 0x0008;
  static const start = 0x0010;
  static const back = 0x0020;
  static const shoulderLeft = 0x0100;
  static const shoulderRight = 0x0200;
  static const a = 0x1000;
  static const b = 0x2000;
  static const x = 0x4000;
  static const y = 0x8000;
}

/// Turns a stream of controller samples into discrete [GamepadAction]s.
///
/// Two jobs beyond plain edge detection: a held direction repeats the way a
/// keyboard does, and the analogue stick gets hysteresis so a thumb resting
/// near the threshold does not spray events.
class GamepadDecoder {
  GamepadDecoder({
    this.repeatDelay = const Duration(milliseconds: 380),
    this.repeatInterval = const Duration(milliseconds: 110),
  });

  /// Pushed past this the stick counts as a direction.
  static const engageThreshold = 16000;

  /// It stops counting only below this, so jitter cannot re-trigger.
  static const releaseThreshold = 9000;

  /// Analogue triggers are treated as buttons past this (0–255).
  static const triggerThreshold = 40;

  final Duration repeatDelay;
  final Duration repeatInterval;

  final Set<GamepadAction> _held = <GamepadAction>{};
  final Map<GamepadAction, Duration> _nextRepeat = <GamepadAction, Duration>{};

  /// Directions that are currently latched by the analogue stick.
  final Set<GamepadAction> _stickLatched = <GamepadAction>{};

  /// Feeds one sample taken at [now] and returns what the user just asked for.
  List<GamepadAction> decode(GamepadSample sample, Duration now) {
    final active = <GamepadAction>{};

    if (sample.pressed(GamepadSample.dpadUp)) active.add(GamepadAction.up);
    if (sample.pressed(GamepadSample.dpadDown)) active.add(GamepadAction.down);
    if (sample.pressed(GamepadSample.dpadLeft)) active.add(GamepadAction.left);
    if (sample.pressed(GamepadSample.dpadRight)) active.add(GamepadAction.right);
    if (sample.pressed(GamepadSample.a)) active.add(GamepadAction.activate);
    if (sample.pressed(GamepadSample.b)) active.add(GamepadAction.back);
    if (sample.pressed(GamepadSample.x)) active.add(GamepadAction.secondary);
    if (sample.pressed(GamepadSample.y)) active.add(GamepadAction.tertiary);
    if (sample.pressed(GamepadSample.shoulderLeft)) {
      active.add(GamepadAction.shoulderLeft);
    }
    if (sample.pressed(GamepadSample.shoulderRight)) {
      active.add(GamepadAction.shoulderRight);
    }
    if (sample.pressed(GamepadSample.start)) active.add(GamepadAction.menu);
    if (sample.pressed(GamepadSample.back)) active.add(GamepadAction.view);
    if (sample.leftTrigger >= triggerThreshold) {
      active.add(GamepadAction.triggerLeft);
    }
    if (sample.rightTrigger >= triggerThreshold) {
      active.add(GamepadAction.triggerRight);
    }

    active.addAll(_stickDirections(sample));

    final emitted = <GamepadAction>[];
    for (final action in active) {
      if (_held.add(action)) {
        emitted.add(action);
        _nextRepeat[action] = now + repeatDelay;
        continue;
      }
      // Only movement repeats; nobody wants play/pause to stutter on a hold.
      if (!_repeats(action)) continue;
      final due = _nextRepeat[action];
      if (due != null && now >= due) {
        emitted.add(action);
        _nextRepeat[action] = now + repeatInterval;
      }
    }

    _held.removeWhere((action) {
      if (active.contains(action)) return false;
      _nextRepeat.remove(action);
      return true;
    });

    return emitted;
  }

  static bool _repeats(GamepadAction action) {
    switch (action) {
      case GamepadAction.up:
      case GamepadAction.down:
      case GamepadAction.left:
      case GamepadAction.right:
      case GamepadAction.triggerLeft:
      case GamepadAction.triggerRight:
        return true;
      default:
        return false;
    }
  }

  Set<GamepadAction> _stickDirections(GamepadSample sample) {
    final directions = <GamepadAction>{};

    void axis(
      int value,
      GamepadAction positive,
      GamepadAction negative,
    ) {
      final magnitude = value.abs();
      final action = value > 0 ? positive : negative;
      final opposite = value > 0 ? negative : positive;
      _stickLatched.remove(opposite);
      if (magnitude >= engageThreshold) {
        _stickLatched.add(action);
      } else if (magnitude < releaseThreshold) {
        _stickLatched.remove(action);
      }
      if (_stickLatched.contains(action)) directions.add(action);
    }

    // Y is positive upward on XInput.
    axis(sample.thumbLY, GamepadAction.up, GamepadAction.down);
    axis(sample.thumbLX, GamepadAction.right, GamepadAction.left);
    return directions;
  }

  void reset() {
    _held.clear();
    _nextRepeat.clear();
    _stickLatched.clear();
  }
}
