import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Desktop scroll behavior: wheel, trackpad, and click-hold-drag all pan.
///
/// Flutter's default [MaterialScrollBehavior] omits [PointerDeviceKind.mouse]
/// from [dragDevices] so text selection wins; media shelves and lists need the
/// opposite — click-drag should scroll the way touch already does.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}
