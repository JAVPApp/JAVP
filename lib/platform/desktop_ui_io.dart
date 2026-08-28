import 'dart:io' show Platform;

/// Whether this is a desktop platform (Windows/Linux/macOS).
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;
