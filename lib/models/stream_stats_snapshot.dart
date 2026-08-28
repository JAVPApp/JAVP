import 'package:javp/compat/media_kit.dart';

/// Instantaneous playback stats for the in-player overlay.
class StreamStatsSnapshot {
  const StreamStatsSnapshot({
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
    this.fps,
    this.videoBitrate,
    this.audioBitrate,
    this.bufferAhead,
  });

  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;
  final double? fps;
  final int? videoBitrate;
  final double? audioBitrate;
  final Duration? bufferAhead;

  bool get isEmpty =>
      width == null &&
      height == null &&
      (videoCodec == null || videoCodec!.isEmpty) &&
      (audioCodec == null || audioCodec!.isEmpty) &&
      fps == null &&
      videoBitrate == null &&
      audioBitrate == null &&
      bufferAhead == null;

  List<String> get lines {
    final out = <String>[];
    if (width != null && height != null && width! > 0 && height! > 0) {
      out.add('$width×$height');
    }
    final vcodec = videoCodec?.trim();
    if (vcodec != null && vcodec.isNotEmpty && vcodec != 'no') {
      out.add(vcodec);
    }
    if (fps != null && fps! > 0) {
      final n = fps!;
      out.add(
        '${n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(1)} fps',
      );
    }
    if (videoBitrate != null && videoBitrate! > 0) {
      out.add('${(videoBitrate! / 1000).round()} kbps');
    }
    final acodec = audioCodec?.trim();
    if (acodec != null && acodec.isNotEmpty) {
      out.add(acodec);
    }
    if (audioBitrate != null && audioBitrate! > 0) {
      out.add('${(audioBitrate! / 1000).round()} kbps audio');
    }
    final buf = bufferAhead;
    if (buf != null && buf > Duration.zero) {
      final secs = buf.inMilliseconds / 1000.0;
      out.add('${secs.toStringAsFixed(1)}s buffer');
    }
    return out;
  }

  factory StreamStatsSnapshot.fromPlayer(Player player) {
    final state = player.state;
    final video = state.track.video;
    final w = state.width ?? video.w;
    final h = state.height ?? video.h;
    final fps = video.fps;
    final vBitrate = video.bitrate;
    final audioFmt = state.audioParams.format;
    final audioBr = state.audioBitrate;
    Duration? ahead;
    final buffer = state.buffer;
    final position = state.position;
    if (buffer > position) {
      ahead = buffer - position;
    }
    return StreamStatsSnapshot(
      width: (w != null && w > 0) ? w : null,
      height: (h != null && h > 0) ? h : null,
      videoCodec: video.codec,
      audioCodec: (audioFmt ?? '').isEmpty ? null : audioFmt,
      fps: (fps != null && fps > 0) ? fps : null,
      videoBitrate: (vBitrate != null && vBitrate > 0) ? vBitrate : null,
      audioBitrate: ((audioBr ?? 0) > 0) ? audioBr : null,
      bufferAhead: ahead,
    );
  }
}
