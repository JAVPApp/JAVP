import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_bootstrap_io.dart' if (dart.library.html) 'desktop_bootstrap_web.dart'
    as platform;

export 'desktop_bootstrap_io.dart' if (dart.library.html) 'desktop_bootstrap_web.dart'
    show isDesktopPlatform, isWindowsDesktop;

/// True for Windows / Linux / macOS desktop shells.
bool get isDesktopPlatform => platform.isDesktopPlatform;

/// True when this build is the Windows desktop app.
bool get isWindowsDesktop => platform.isWindowsDesktop;

/// Initializes desktop-only plumbing before [runApp].
Future<void> bootstrapDesktop() => platform.bootstrapDesktop();
