import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:javp/services/cast/dlna/dlna_models.dart';
import 'package:javp/services/cast/dlna/ssdp.dart';
import 'package:xml/xml.dart';

/// SSDP + device-description scan for UPnP MediaRenderer (DLNA DMR).
class DlnaDiscovery {
  DlnaDiscovery({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static final _ssdpGroup = InternetAddress('239.255.255.250');
  static const _ssdpPort = 1900;

  final http.Client _http;
  final Map<String, DlnaRenderer> _byUsn = {};
  RawDatagramSocket? _socket;
  Timer? _searchTimer;
  bool _started = false;

  List<DlnaRenderer> get renderers =>
      _byUsn.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<void> start({void Function()? onChanged}) async {
    if (_started) return;
    _started = true;
    _onChanged = onChanged;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.multicastHops = 4;
      socket.readEventsEnabled = true;
      try {
        socket.joinMulticast(_ssdpGroup);
      } catch (_) {}
      _socket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        unawaited(
          _handlePacket(utf8.decode(datagram.data, allowMalformed: true)),
        );
      });
      _search();
      _searchTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _search(),
      );
    } catch (_) {
      _started = false;
      _socket?.close();
      _socket = null;
    }
  }

  void Function()? _onChanged;

  void stop() {
    _started = false;
    _searchTimer?.cancel();
    _searchTimer = null;
    try {
      _socket?.leaveMulticast(_ssdpGroup);
    } catch (_) {}
    _socket?.close();
    _socket = null;
  }

  void _search() {
    final socket = _socket;
    if (socket == null) return;
    const targets = [
      'urn:schemas-upnp-org:device:MediaRenderer:1',
      'urn:schemas-upnp-org:service:AVTransport:1',
    ];
    for (final st in targets) {
      final payload =
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $st\r\n'
          '\r\n';
      socket.send(utf8.encode(payload), _ssdpGroup, _ssdpPort);
    }
  }

  Future<void> _handlePacket(String packet) async {
    final headers = parseSsdpHeaders(packet);
    final location = headers['location'];
    if (location == null || location.isEmpty) return;
    if (!ssdpLooksLikeMediaRenderer(headers) &&
        !(headers['st'] ?? '').toLowerCase().contains('rootdevice') &&
        !(headers['nt'] ?? '').toLowerCase().contains('rootdevice')) {
      // Still try location — some TVs omit MediaRenderer in ST.
    }
    final usn = headers['usn'] ?? location;
    if (_byUsn.containsKey(usn)) return;
    try {
      final renderer = await _fetchRenderer(location: location, usn: usn);
      if (renderer == null) return;
      _byUsn[renderer.usn] = renderer;
      _onChanged?.call();
    } catch (_) {}
  }

  Future<DlnaRenderer?> _fetchRenderer({
    required String location,
    required String usn,
  }) async {
    final loc = Uri.tryParse(location);
    if (loc == null) return null;
    final response = await _http.get(loc).timeout(const Duration(seconds: 4));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final doc = XmlDocument.parse(response.body);
    final device = doc.findAllElements('device').firstOrNull;
    if (device == null) return null;
    final type = device.getElement('deviceType')?.innerText ?? '';
    if (!type.toLowerCase().contains('mediarenderer')) {
      // Embedded devices (Samsung often nests the renderer).
      final nested = device.findAllElements('device').where((el) {
        final t = el.getElement('deviceType')?.innerText.toLowerCase() ?? '';
        return t.contains('mediarenderer');
      }).firstOrNull;
      if (nested == null) return null;
      return _rendererFromDevice(nested, loc, usn);
    }
    return _rendererFromDevice(device, loc, usn);
  }

  DlnaRenderer? _rendererFromDevice(XmlElement device, Uri loc, String usn) {
    final name = (device.getElement('friendlyName')?.innerText ?? '').trim();
    if (name.isEmpty) return null;
    XmlElement? av;
    for (final service in device.findAllElements('service')) {
      final st = service.getElement('serviceType')?.innerText ?? '';
      if (st.toLowerCase().contains('avtransport')) {
        av = service;
        break;
      }
    }
    if (av == null) return null;
    final control = av.getElement('controlURL')?.innerText;
    final serviceType =
        av.getElement('serviceType')?.innerText ??
        'urn:schemas-upnp-org:service:AVTransport:1';
    final controlUrl = resolveUpnpUrl(loc, control ?? '');
    if (controlUrl == null) return null;
    final udn = device.getElement('UDN')?.innerText.trim();
    return DlnaRenderer(
      usn: (udn != null && udn.isNotEmpty) ? udn : usn,
      name: name,
      controlUrl: controlUrl,
      serviceType: serviceType,
    );
  }
}
