import 'package:http/http.dart' as http;
import 'package:javp/services/cast/cast_protocol.dart';
import 'package:javp/services/cast/cast_xml.dart';
import 'package:javp/services/cast/dlna/didl.dart';
import 'package:javp/services/cast/dlna/dlna_models.dart';

class DlnaAvTransport {
  DlnaAvTransport({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<void> load(DlnaRenderer renderer, CastMediaRequest media) async {
    final didl = buildDidlLite(
      url: media.url,
      title: media.title,
      subtitle: media.subtitle,
      live: media.live,
    );
    await _action(
      renderer,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>${xmlEscape(media.url)}</CurrentURI>'
          '<CurrentURIMetaData>${xmlEscape(didl)}</CurrentURIMetaData>',
    );
    await _action(
      renderer,
      'Play',
      '<InstanceID>0</InstanceID><Speed>1</Speed>',
    );
    if (!media.live && media.position > Duration.zero) {
      try {
        await seek(renderer, media.position);
      } catch (_) {}
    }
  }

  Future<void> play(DlnaRenderer renderer) {
    return _action(
      renderer,
      'Play',
      '<InstanceID>0</InstanceID><Speed>1</Speed>',
    );
  }

  Future<void> pause(DlnaRenderer renderer) {
    return _action(renderer, 'Pause', '<InstanceID>0</InstanceID>');
  }

  Future<void> stop(DlnaRenderer renderer) {
    return _action(renderer, 'Stop', '<InstanceID>0</InstanceID>');
  }

  Future<void> seek(DlnaRenderer renderer, Duration position) {
    return _action(
      renderer,
      'Seek',
      '<InstanceID>0</InstanceID>'
          '<Unit>REL_TIME</Unit>'
          '<Target>${formatRelTime(position)}</Target>',
    );
  }

  Future<void> _action(
    DlnaRenderer renderer,
    String action,
    String body,
  ) async {
    final envelope = soapEnvelope(
      serviceType: renderer.serviceType,
      action: action,
      body: body,
    );
    final response = await _http
        .post(
          renderer.controlUrl,
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPAction': '"${renderer.serviceType}#$action"',
          },
          body: envelope,
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('DLNA $action failed (${response.statusCode})');
    }
  }
}
