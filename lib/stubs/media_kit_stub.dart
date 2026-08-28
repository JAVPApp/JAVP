/// Web stub for media_kit — enough surface for compile; playback uses video_player.
library media_kit_stub;

import 'dart:async';

class Player {
  Player({PlayerConfiguration? configuration})
    : platform = NativePlayer(configuration: configuration);

  final NativePlayer platform;

  PlayerStream get stream => platform.stream;
  PlayerStream get streams => stream;
  PlayerState get state => platform.state;
  Future<int> get handle async => 0;

  Future<void> open(Media media, {bool play = true}) async {}
  Future<void> play() async {}
  Future<void> pause() async {}
  Future<void> playOrPause() async {}
  Future<void> stop() async {}
  Future<void> seek(Duration position) async {}
  Future<void> setVolume(double volume) async {}
  Future<void> setRate(double rate) async {}
  Future<void> setAudioTrack(AudioTrack track) async {}
  Future<void> setVideoTrack(VideoTrack track) async {}
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  Future<void> dispose() async {}
}

class NativePlayer {
  NativePlayer({PlayerConfiguration? configuration});

  final PlayerStream stream = PlayerStream();
  final PlayerState state = PlayerState();

  Future<void> setProperty(
    String key,
    String value, {
    bool waitForInitialization = true,
  }) async {}
  Future<void> pause({bool synchronized = true}) async {}
  Future<void> play({bool synchronized = true}) async {}
  Future<String?> getProperty(String key) async => null;
}

class PlayerConfiguration {
  const PlayerConfiguration({
    this.title,
    this.ready,
    this.bufferSize,
    this.logLevel,
    this.libass,
    this.protocolWhitelist,
    this.osc,
    this.vid,
    this.vo,
  });

  final String? title;
  final void Function()? ready;
  final int? bufferSize;
  final MPVLogLevel? logLevel;
  final bool? libass;
  final List<String>? protocolWhitelist;
  final bool? osc;
  final String? vid;
  final String? vo;
}

enum MPVLogLevel { none, fatal, error, warn, info, v, debug, trace }

class PlayerState {
  Duration get position => Duration.zero;
  Duration get duration => Duration.zero;
  Duration get buffer => Duration.zero;
  bool get playing => false;
  bool get buffering => false;
  bool get completed => false;
  double get volume => 1.0;
  double get rate => 1.0;
  Playlist get playlist => const Playlist([]);
  int? get width => null;
  int? get height => null;
  Tracks get tracks => const Tracks();
  Track get track => const Track();
  AudioParams get audioParams => AudioParams();
  double? get audioBitrate => null;
}

class PlayerStream {
  Stream<Duration> get position => const Stream.empty();
  Stream<Duration> get duration => const Stream.empty();
  Stream<Duration> get buffer => const Stream.empty();
  Stream<bool> get playing => const Stream.empty();
  Stream<bool> get completed => const Stream.empty();
  Stream<bool> get buffering => const Stream.empty();
  Stream<double> get volume => const Stream.empty();
  Stream<double> get rate => const Stream.empty();
  Stream<Playlist> get playlist => const Stream.empty();
  Stream<int?> get width => const Stream.empty();
  Stream<int?> get height => const Stream.empty();
  Stream<Tracks> get tracks => const Stream.empty();
  Stream<Track> get track => const Stream.empty();
  Stream<String> get error => const Stream.empty();
  Stream<AudioParams> get audioParams => const Stream.empty();
  Stream<double> get audioBitrate => const Stream.empty();
}

class Media {
  const Media(this.uri, {this.httpHeaders, this.extras, this.start});

  final String uri;
  final Map<String, String>? httpHeaders;
  final Map<String, dynamic>? extras;
  final Duration? start;
}

class Playlist {
  const Playlist(this.medias, {this.index = 0});
  final List<Media> medias;
  final int index;
}

class Tracks {
  const Tracks();
  List<VideoTrack> get video => const [];
  List<AudioTrack> get audio => const [];
  List<SubtitleTrack> get subtitle => const [];
}

class Track {
  const Track();
  VideoTrack get video => VideoTrack.no();
  AudioTrack get audio => AudioTrack.no();
  SubtitleTrack get subtitle => SubtitleTrack.no();
}

class VideoTrack {
  const VideoTrack(
    this.id,
    this.title,
    this.language, {
    this.w,
    this.h,
    this.bitrate,
    this.codec,
    this.fps,
  });

  factory VideoTrack.no() => const VideoTrack('no', null, null);
  factory VideoTrack.auto() => const VideoTrack('auto', null, null);

  final String id;
  final String? title;
  final String? language;
  final int? w;
  final int? h;
  final int? bitrate;
  final String? codec;
  final double? fps;
}

class AudioTrack {
  const AudioTrack(
    this.id,
    this.title,
    this.language, {
    this.uri = false,
    this.channels,
  });

  factory AudioTrack.no() => const AudioTrack('no', null, null);
  factory AudioTrack.auto() => const AudioTrack('auto', null, null);
  factory AudioTrack.uri(String uri, {String? title, String? language}) =>
      AudioTrack(uri, title, language, uri: true);

  final String id;
  final String? title;
  final String? language;
  final bool uri;
  final int? channels;
}

class SubtitleTrack {
  const SubtitleTrack(
    this.id,
    this.title,
    this.language, {
    this.uri = false,
    this.codec,
  });

  factory SubtitleTrack.no() => const SubtitleTrack('no', null, null);
  factory SubtitleTrack.auto() => const SubtitleTrack('auto', null, null);
  factory SubtitleTrack.uri(String uri, {String? title, String? language}) =>
      SubtitleTrack(uri, title, language, uri: true);

  final String id;
  final String? title;
  final String? language;
  final bool uri;
  final String? codec;
}

class AudioParams {
  String? get format => null;
  int? get sampleRate => null;
  int? get channels => null;
  String? get channelLayout => null;
}

class MediaKit {
  static void ensureInitialized({String? libmpv}) {}
}
