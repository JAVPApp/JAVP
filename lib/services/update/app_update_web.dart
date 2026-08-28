/// Web stub for AppUpdateService platform helpers.
library;

import 'package:http/http.dart' as http;
import 'package:javp/models/app_update_info.dart';

enum UpdateInstallTarget {
  androidApk,
  windowsZip,
  linuxZip,
  macosZip,
  unsupported,
}

String get platformLabel => 'web';

UpdateInstallTarget detectInstallTarget() => UpdateInstallTarget.unsupported;

List<String> detectPreferredPackages() => const [];

List<String> detectPreferredAbis() => const [];

Exception httpException(String message, Uri uri) =>
    Exception('$message ($uri)');

String getFilePath(dynamic file) => '$file';

Future<dynamic> getCachedFile(String path) async => null;

Future<bool> checkAppliedStamp({
  required String stampPath,
  required String expectedSha256,
}) async => false;

Future<dynamic> downloadUpdate({
  required AppUpdateInfo update,
  required UpdateInstallTarget installTarget,
  required List<String> preferredAbis,
  required List<String> preferredPackages,
  required String userAgent,
  required http.Client client,
  void Function(int received, int? total)? onProgress,
}) async {
  throw UnsupportedError('Updates are not available in the web app');
}

Future<void> installUpdate({
  required dynamic downloaded,
  required UpdateInstallTarget installTarget,
}) async {
  throw UnsupportedError('Updates are not available in the web app');
}
