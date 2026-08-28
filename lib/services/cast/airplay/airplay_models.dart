class AirPlayDevice {
  const AirPlayDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });

  final String id;
  final String name;
  final String host;
  final int port;

  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);
}
