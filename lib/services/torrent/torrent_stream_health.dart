/// Snapshot of the in-flight torrent HTTP stream (playback stall vs real EOF).
class TorrentStreamHealth {
  const TorrentStreamHealth({
    this.fileIncomplete = false,
    this.streamBuffering = false,
    this.readHead = 0,
    this.fileSize = 0,
  });

  final bool fileIncomplete;
  final bool streamBuffering;
  final int readHead;
  final int fileSize;
}

/// Last health sample, keyed by torrent id so a switch/stop cannot leak
/// the previous magnet's incomplete / buffering flags into VOD end checks.
class TorrentHealthCache {
  int? _torrentId;
  TorrentStreamHealth? _health;

  int? get torrentId => _torrentId;

  /// Current snapshot for [torrentId], or `null` when none / id mismatch.
  ///
  /// Passing a new id drops the previous sample immediately. Passing `null`
  /// clears the cache.
  TorrentStreamHealth? snapshot(int? torrentId) {
    if (torrentId == null) {
      clear();
      return null;
    }
    if (_torrentId != torrentId) {
      _torrentId = torrentId;
      _health = null;
    }
    return _health;
  }

  void update(int torrentId, TorrentStreamHealth health) {
    if (_torrentId != torrentId) return;
    _health = health;
  }

  void clear({int? ifTorrentId}) {
    if (ifTorrentId != null && _torrentId != ifTorrentId) return;
    _torrentId = null;
    _health = null;
  }
}
