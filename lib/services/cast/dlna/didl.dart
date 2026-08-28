import 'package:javp/services/cast/cast_mime.dart';
import 'package:javp/services/cast/cast_xml.dart';

String buildDidlLite({
  required String url,
  required String title,
  String? subtitle,
  bool live = false,
}) {
  final mime = guessCastContentType(url);
  final className = mime.startsWith('audio/')
      ? 'object.item.audioItem.musicTrack'
      : 'object.item.videoItem';
  final extra = subtitle == null || subtitle.trim().isEmpty
      ? ''
      : '<dc:description>${xmlEscape(subtitle.trim())}</dc:description>';
  final op = live
      ? 'DLNA.ORG_OP=00;DLNA.ORG_CI=0'
      : 'DLNA.ORG_OP=01;DLNA.ORG_CI=0';
  return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${xmlEscape(title)}</dc:title>'
      '$extra'
      '<upnp:class>$className</upnp:class>'
      '<res protocolInfo="http-get:*:$mime:$op">${xmlEscape(url)}</res>'
      '</item></DIDL-Lite>';
}

String soapEnvelope({
  required String serviceType,
  required String action,
  required String body,
}) {
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body>'
      '<u:$action xmlns:u="${xmlEscape(serviceType)}">'
      '$body'
      '</u:$action>'
      '</s:Body></s:Envelope>';
}
