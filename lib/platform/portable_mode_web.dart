/// Web: never portable-on-disk.
void registerPortablePathProviderIfNeeded() {}

bool get isPortableMode => false;

bool? debugPortableOverride;
Map<String, String>? debugPortableEnvOverride;
String? debugPortableExeDirectoryOverride;

void debugResetPortableMode() {
  debugPortableOverride = null;
  debugPortableEnvOverride = null;
  debugPortableExeDirectoryOverride = null;
}

bool looksLikeWindowsInstallDir(String exeDirectory, Map<String, String> env) =>
    false;

String portableDataRoot(String exeDirectory) => '$exeDirectory/data';

String portableMarkerPath(String exeDirectory) => '$exeDirectory/portable';

bool resolvePortableMode({
  required Map<String, String> env,
  required String exeDirectory,
  bool Function(String path)? fileExists,
}) => false;
