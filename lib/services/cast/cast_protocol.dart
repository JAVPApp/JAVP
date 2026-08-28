/// How JAVP is sending the current title to another screen.
///
/// Only one protocol is active at a time. Picking a device of a different
/// type stops the previous session first so Google Cast / DLNA / AirPlay
/// never fight over the same TV.
enum CastProtocol { chromecast, dlna, airplay }

class CastTarget {
  const CastTarget({
    required this.protocol,
    required this.id,
    required this.name,
  });

  final CastProtocol protocol;
  final String id;
  final String name;

  String get protocolLabel => switch (protocol) {
    CastProtocol.chromecast => 'Google Cast',
    CastProtocol.dlna => 'DLNA',
    CastProtocol.airplay => 'AirPlay',
  };

  @override
  bool operator ==(Object other) =>
      other is CastTarget && other.protocol == protocol && other.id == id;

  @override
  int get hashCode => Object.hash(protocol, id);
}

class CastMediaRequest {
  const CastMediaRequest({
    required this.url,
    required this.title,
    this.subtitle,
    this.posterUrl,
    this.position = Duration.zero,
    this.duration,
    this.live = false,
    this.fileName,
    this.transcodeUrl,
    this.codecHint,
  });

  final String url;
  final String title;
  final String? subtitle;
  final String? posterUrl;
  final Duration position;
  final Duration? duration;
  final bool live;
  /// Torrent / download filename (extension) when [url] has none.
  final String? fileName;
  /// Optional Jellyfin/Emby/Plex transcode URL to try after direct/proxy.
  final String? transcodeUrl;
  /// Filename / server codec labels used only to explain Cast failures.
  final String? codecHint;
}
