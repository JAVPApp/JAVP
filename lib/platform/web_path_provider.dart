import 'package:flutter/foundation.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// `path_provider` 2.1+ dropped the web implementation. Register a stub so
/// callers get stable virtual paths instead of [MissingPluginException].
///
/// Dart `File` / `Directory` I/O still fails softly on web — LibraryStore and
/// friends already fall back to SharedPreferences when disk writes throw.
void registerWebPathProviderIfNeeded() {
  if (!kIsWeb) return;
  PathProviderPlatform.instance = _WebPathProvider();
}

class _WebPathProvider extends PathProviderPlatform {
  static const _root = '/javp_web';

  @override
  Future<String?> getTemporaryPath() async => '$_root/tmp';

  @override
  Future<String?> getApplicationSupportPath() async => '$_root/support';

  @override
  Future<String?> getApplicationDocumentsPath() async => '$_root/documents';

  @override
  Future<String?> getApplicationCachePath() async => '$_root/cache';

  @override
  Future<String?> getLibraryPath() async => '$_root/library';

  @override
  Future<String?> getExternalStoragePath() async => null;

  @override
  Future<List<String>?> getExternalCachePaths() async => null;

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => null;

  @override
  Future<String?> getDownloadsPath() async => '$_root/downloads';
}
