import 'dart:async';

/// Web stub: never a desktop platform.
bool get isDesktopPlatform => false;

/// Web stub: never Windows desktop.
bool get isWindowsDesktop => false;

/// No-op on web.
Future<void> bootstrapDesktop() async {}
