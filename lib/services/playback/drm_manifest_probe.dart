import 'package:http/http.dart' as http;
import 'package:javp/services/playback/drm_detect.dart';

/// Fetch a DASH (or other) manifest and throw if it is DRM-protected.
///
/// HLS is probed inside [HlsMaster.resolvePlaybackPlan] so we do not GET twice.
class DrmManifestProbe {
  static Future<void> throwIfProtected(
    String url, {
    Map<String, String>? httpHeaders,
    http.Client? client,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (uri.scheme != 'http' && uri.scheme != 'https') return;
    if (!looksLikeDashUrl(url)) return;

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(uri, headers: httpHeaders ?? const {})
          .timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return;
      }
      final kind = detectDrmInManifest(response.body);
      if (kind != null) {
        throw UnsupportedDrmException(kind: kind, playUrl: url);
      }
    } on UnsupportedDrmException {
      rethrow;
    } catch (_) {
      // Network / parse failures fall through to the normal player error path.
    } finally {
      if (ownsClient) httpClient.close();
    }
  }
}
