import 'package:flutter/foundation.dart';
import 'package:javp/services/input/gamepad_events.dart';

import 'xinput_io.dart' if (dart.library.html) 'xinput_web.dart' as platform;

/// Reads Xbox-compatible controllers through XInput.
///
/// Flutter has no gamepad channel on Windows — the framework never sees these
/// devices — so the app talks to `xinput1_4.dll` itself. Everything here is a
/// no-op off Windows, where [open] simply fails and the service stays quiet.
class XInputReader {
  XInputReader._(this._handle);

  /// XInput supports four pads; JAVP only follows whichever one is talking.
  static const maxControllers = 4;

  final platform.XInputHandle _handle;
  bool _disposed = false;

  static XInputReader? open() {
    if (kIsWeb) return null;
    final handle = platform.openXInput();
    if (handle == null) return null;
    return XInputReader._(handle);
  }

  /// Returns the first connected pad's sample, or null when none is attached.
  GamepadSample? poll() {
    if (_disposed) return null;
    return platform.pollXInput(_handle);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    platform.disposeXInput(_handle);
  }
}
