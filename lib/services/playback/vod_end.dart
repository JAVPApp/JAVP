/// Decide whether an engine EOF / near-end tick is a real VOD finish.
///
/// Torrent HTTP and truncated demuxer windows often set `eof-reached` (or
/// report a short duration) while the file is still downloading. Auto-advance
/// must not treat that as the next episode.
///
/// Catalog runtimes are often longer than the real file (generic 45m slots,
/// extras in metadata). Once the torrent is complete — or this is not a
/// torrent — trust the demuxer duration so the next episode can start.
({bool finished, String reason}) decideVodEnd({
  required Duration position,
  required Duration engineDuration,
  Duration? catalogDuration,
  bool buffering = false,
  bool torrentIncomplete = false,
  bool torrentStreamBuffering = false,
  int torrentReadHead = 0,
  int torrentFileSize = 0,
  bool eofReached = false,
}) {
  if (buffering) return (finished: false, reason: 'buffering');
  if (torrentStreamBuffering) {
    return (finished: false, reason: 'torrent-buffering');
  }

  if (torrentFileSize > 0 &&
      torrentReadHead >= 0 &&
      torrentReadHead + (2 * 1024 * 1024) < torrentFileSize) {
    return (finished: false, reason: 'torrent-bytes');
  }

  if (position < const Duration(seconds: 2)) {
    return (finished: false, reason: 'too-early');
  }

  if (torrentIncomplete &&
      catalogDuration != null &&
      catalogDuration.inSeconds >= 20 &&
      engineDuration.inMilliseconds > 0 &&
      engineDuration.inMilliseconds <
          (catalogDuration.inMilliseconds * 0.85).round() &&
      position + const Duration(seconds: 2) < catalogDuration) {
    return (finished: false, reason: 'short-demuxer');
  }

  if (torrentIncomplete &&
      catalogDuration != null &&
      catalogDuration.inSeconds >= 20 &&
      position + const Duration(seconds: 3) < catalogDuration) {
    return (finished: false, reason: 'torrent-incomplete');
  }

  if (torrentIncomplete && catalogDuration == null) {
    return (finished: false, reason: 'torrent-incomplete');
  }

  final Duration known;
  if (torrentIncomplete) {
    known = knownVodRuntime(engineDuration, catalogDuration);
  } else if (engineDuration.inMilliseconds > 0) {
    known = engineDuration;
  } else if (eofReached) {
    return (finished: true, reason: 'eof');
  } else {
    known = catalogDuration ?? Duration.zero;
  }

  if (known.inMilliseconds <= 0) {
    if (torrentIncomplete) {
      return (finished: false, reason: 'torrent-incomplete');
    }
    return (finished: true, reason: 'eof');
  }

  final progress = position.inMilliseconds / known.inMilliseconds;
  final remaining = known - position;
  if (progress < 0.97) {
    return (finished: false, reason: 'progress');
  }
  if (!eofReached && remaining > const Duration(milliseconds: 1500)) {
    return (finished: false, reason: 'remaining');
  }
  return (finished: true, reason: eofReached ? 'eof' : 'end');
}

/// Prefer the longer of engine vs catalog so a truncated demuxer window cannot
/// look like 100% progress.
Duration knownVodRuntime(Duration engineDuration, Duration? catalogDuration) {
  final engineMs = engineDuration.inMilliseconds;
  final catalogMs = catalogDuration?.inMilliseconds ?? 0;
  if (catalogMs > engineMs) return catalogDuration!;
  if (engineMs > 0) return engineDuration;
  if (catalogMs > 0) return catalogDuration!;
  return Duration.zero;
}
