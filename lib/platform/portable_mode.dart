import 'portable_mode_io.dart'
    if (dart.library.html) 'portable_mode_web.dart' as platform;

export 'portable_mode_io.dart'
    if (dart.library.html) 'portable_mode_web.dart'
    show
        debugPortableEnvOverride,
        debugPortableExeDirectoryOverride,
        debugPortableOverride,
        debugResetPortableMode,
        looksLikeWindowsInstallDir,
        portableDataRoot,
        portableMarkerPath,
        resolvePortableMode;

/// Redirects [path_provider] (and Windows SharedPreferences) into `data/` next
/// to the exe when this build is a portable zip.
void registerPortablePathProviderIfNeeded() =>
    platform.registerPortablePathProviderIfNeeded();

/// Whether this process is using the portable `data/` folder.
bool get isPortableMode => platform.isPortableMode;
