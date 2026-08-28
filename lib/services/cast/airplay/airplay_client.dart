import 'package:http/http.dart' as http;
import 'package:javp/services/cast/airplay/airplay_models.dart';
import 'package:javp/services/cast/cast_protocol.dart';

/// AirPlay 1 HTTP playback (`/play`, `/stop`). AirPlay 2 TVs may ignore this.
class AirPlayClient {
  AirPlayClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const _headers = {
    'User-Agent': 'MediaControl/1.0',
    'Content-Type': 'text/parameters',
  };

  Future<void> load(AirPlayDevice device, CastMediaRequest media) async {
    var start = 0.0;
    final duration = media.duration;
    if (duration != null && duration > Duration.zero) {
      start = media.position.inMilliseconds / duration.inMilliseconds;
      if (start.isNaN || start.isInfinite) start = 0;
      start = start.clamp(0.0, 1.0);
    }
    final body =
        'Content-Location: ${media.url}\nStart-Position: ${start.toStringAsFixed(4)}\n';
    final response = await _http
        .post(
          device.baseUri.replace(path: '/play'),
          headers: _headers,
          body: body,
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('AirPlay play failed (${response.statusCode})');
    }
  }

  Future<void> stop(AirPlayDevice device) async {
    await _http
        .post(
          device.baseUri.replace(path: '/stop'),
          headers: const {'User-Agent': 'MediaControl/1.0'},
        )
        .timeout(const Duration(seconds: 5));
  }
}
