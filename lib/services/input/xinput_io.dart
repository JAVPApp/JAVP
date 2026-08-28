import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:javp/services/input/gamepad_events.dart';

/// Opaque handle for an opened XInput binding.
class XInputHandle {
  XInputHandle(this.getState, this.buffer);

  final int Function(int, Pointer<__XInputState>) getState;
  final Pointer<__XInputState> buffer;
}

final class __XInputGamepad extends Struct {
  @Uint16()
  external int buttons;
  @Uint8()
  external int leftTrigger;
  @Uint8()
  external int rightTrigger;
  @Int16()
  external int thumbLX;
  @Int16()
  external int thumbLY;
  @Int16()
  external int thumbRX;
  @Int16()
  external int thumbRY;
}

final class __XInputState extends Struct {
  @Uint32()
  external int packetNumber;
  external __XInputGamepad gamepad;
}

typedef _XInputGetStateNative = Uint32 Function(Uint32, Pointer<__XInputState>);
typedef _XInputGetState = int Function(int, Pointer<__XInputState>);

const _errorDeviceNotConnected = 1167;

XInputHandle? openXInput() {
  if (kIsWeb || !Platform.isWindows) return null;
  for (final name in const [
    'xinput1_4.dll',
    'xinput1_3.dll',
    'xinput9_1_0.dll',
  ]) {
    try {
      final library = DynamicLibrary.open(name);
      final getState = library.lookupFunction<_XInputGetStateNative, _XInputGetState>(
        'XInputGetState',
      );
      return XInputHandle(getState, calloc<__XInputState>());
    } catch (_) {
      continue;
    }
  }
  debugPrint('XInput unavailable — controller input disabled');
  return null;
}

GamepadSample? pollXInput(XInputHandle handle) {
  for (var index = 0; index < 4; index++) {
    final result = handle.getState(index, handle.buffer);
    if (result == _errorDeviceNotConnected) continue;
    if (result != 0) continue;
    final pad = handle.buffer.ref.gamepad;
    return GamepadSample(
      buttons: pad.buttons,
      leftTrigger: pad.leftTrigger,
      rightTrigger: pad.rightTrigger,
      thumbLX: pad.thumbLX,
      thumbLY: pad.thumbLY,
    );
  }
  return null;
}

void disposeXInput(XInputHandle handle) {
  calloc.free(handle.buffer);
}
