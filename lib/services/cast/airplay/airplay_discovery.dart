import 'dart:async';
import 'dart:io';

import 'package:javp/services/cast/airplay/airplay_models.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// Bonjour `_airplay._tcp` scan (AirPlay 1 video receivers).
class AirPlayDiscovery {
  MDnsClient? _client;
  StreamSubscription<PtrResourceRecord>? _ptrSub;
  final Map<String, AirPlayDevice> _byId = {};
  bool _started = false;
  void Function()? _onChanged;

  List<AirPlayDevice> get devices =>
      _byId.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<void> start({void Function()? onChanged}) async {
    if (_started) return;
    _started = true;
    _onChanged = onChanged;
    final client = MDnsClient();
    try {
      await client.start(
        interfacesFactory: (type) =>
            NetworkInterface.list(includeLinkLocal: false, type: type),
      );
    } catch (_) {
      try {
        await client.start();
      } catch (_) {
        _started = false;
        return;
      }
    }
    _client = client;
    _ptrSub = client
        .lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('_airplay._tcp.local'),
        )
        .listen(_onPtr);
  }

  Future<void> _onPtr(PtrResourceRecord ptr) async {
    final client = _client;
    if (client == null) return;
    await for (final srv in client.lookup<SrvResourceRecord>(
      ResourceRecordQuery.service(ptr.domainName),
    )) {
      String? ip;
      await for (final addr in client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(srv.target),
      )) {
        ip = addr.address.address;
        break;
      }
      if (ip == null) continue;
      final name = _prettyName(ptr.domainName);
      final id = '$ip:${srv.port}';
      final existing = _byId[id];
      if (existing != null && existing.name == name) continue;
      _byId[id] = AirPlayDevice(id: id, name: name, host: ip, port: srv.port);
      _onChanged?.call();
    }
  }

  static String _prettyName(String domain) {
    var name = domain;
    const suffix = '._airplay._tcp.local';
    if (name.endsWith(suffix)) {
      name = name.substring(0, name.length - suffix.length);
    }
    if (name.endsWith('.local')) {
      name = name.substring(0, name.length - 6);
    }
    return name.replaceAll(r'\032', ' ').replaceAll('\\', '').trim();
  }

  void stop() {
    _started = false;
    unawaited(_ptrSub?.cancel());
    _ptrSub = null;
    _client?.stop();
    _client = null;
  }
}
