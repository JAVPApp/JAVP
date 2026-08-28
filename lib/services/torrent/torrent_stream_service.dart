import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:javp/models/proxy_settings.dart';
import 'package:javp/services/torrent/torrent_stream_health.dart';

import 'torrent_stream_io.dart'
    if (dart.library.html) 'torrent_stream_web.dart'
    as platform;

export 'torrent_stream_health.dart';
export 'torrent_stream_io.dart'
    if (dart.library.html) 'torrent_stream_web.dart'
    show TorrentPlayback;

/// BYO magnet / .torrent → local HTTP URL for media_kit, or full offline file.
///
/// Uses embedded librqbit (Apache-2.0) via [rqbit_engine]. Only for content
/// you have the rights to download and stream.
class TorrentStreamService {
  TorrentStreamService();

  bool _ready = false;
  int? _activeTorrentId;
  int? _activeStreamId;
  ProxySettings _proxy = ProxySettings.disabled;
  bool _proxyApplied = false;

  /// Offline download jobs: task id → torrent id (separate from playback stream).
  final Map<String, int> _offlineJobs = {};
  final Set<String> _cancelOffline = {};

  bool get isReady => _ready;

  /// Last proxy push result (`true` when SOCKS5 was applied to rqbit).
  bool get proxyApplied => _proxyApplied;

  Future<void> ensureInitialized() async {
    if (kIsWeb) return;
    if (_ready) return;
    await platform.initTorrent();
    _ready = true;
    applyProxySettings(_proxy);
  }

  /// Push app [ProxySettings] into the rqbit session when available.
  bool applyProxySettings(ProxySettings settings) {
    _proxy = settings;
    if (kIsWeb || !_ready) {
      _proxyApplied = false;
      return false;
    }
    _proxyApplied = platform.applyProxySettings(settings);
    return _proxyApplied;
  }

  /// Live torrent HTTP stream: still downloading / stalled vs real EOF.
  TorrentStreamHealth? activeHealth() {
    if (kIsWeb || !_ready) return null;
    return platform.activeStreamHealth(
      torrentId: _activeTorrentId,
      streamId: _activeStreamId,
    );
  }

  /// True while a magnet / .torrent is the current playback source.
  bool get hasActivePlayback => _activeTorrentId != null;

  /// Resolves a `magnet:` URI or path to a `.torrent` file into a localhost
  /// HTTP stream URL (range-request capable).
  Future<platform.TorrentPlayback> resolveToStream(
    String magnetOrTorrentPath, {
    int? episodeNumber,
    int? seasonNumber,
    String? preferredFileName,
    Duration metadataTimeout = const Duration(seconds: 90),
    Duration readyTimeout = const Duration(seconds: 120),
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Torrent streaming not supported on web');
    }
    await ensureInitialized();
    applyProxySettings(_proxy);
    await stopActive(deleteFiles: false);

    final result = await platform.resolveToStream(
      magnetOrTorrentPath,
      episodeNumber: episodeNumber,
      seasonNumber: seasonNumber,
      preferredFileName: preferredFileName,
      metadataTimeout: metadataTimeout,
      readyTimeout: readyTimeout,
    );

    _activeTorrentId = result.torrentId;
    _activeStreamId = result.streamId;

    return result;
  }

  /// Fully download the chosen video file for offline playback.
  Future<String> downloadOffline({
    required String jobId,
    required String magnetOrPath,
    required dynamic saveDir, // Directory on io, ignored on web
    int? episodeNumber,
    int? seasonNumber,
    String? preferredFileName,
    void Function(double progress)? onProgress,
    void Function(String name, int bytes)? onFileSelected,
    bool Function()? isCancelled,
    Duration metadataTimeout = const Duration(minutes: 3),
    Duration downloadTimeout = const Duration(hours: 12),
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Torrent downloads not supported on web');
    }
    await ensureInitialized();
    applyProxySettings(_proxy);

    final torrentId = await platform.startOfflineDownload(
      jobId: jobId,
      magnetOrPath: magnetOrPath,
      saveDir: saveDir,
      episodeNumber: episodeNumber,
      seasonNumber: seasonNumber,
      preferredFileName: preferredFileName,
      onProgress: onProgress,
      onFileSelected: onFileSelected,
      isCancelled: () => _cancelled(jobId, isCancelled),
      metadataTimeout: metadataTimeout,
      downloadTimeout: downloadTimeout,
    );

    _offlineJobs[jobId] = torrentId;

    try {
      final path = await platform.waitForOfflineDownload(
        jobId: jobId,
        torrentId: torrentId,
        saveDir: saveDir,
        episodeNumber: episodeNumber,
        seasonNumber: seasonNumber,
        preferredFileName: preferredFileName,
        onProgress: onProgress,
        isCancelled: () => _cancelled(jobId, isCancelled),
        metadataTimeout: metadataTimeout,
        downloadTimeout: downloadTimeout,
      );
      return path;
    } finally {
      _offlineJobs.remove(jobId);
      _cancelOffline.remove(jobId);
    }
  }

  /// Cancel an in-flight [downloadOffline] job and delete partial data.
  Future<void> cancelOfflineDownload(String jobId) async {
    if (kIsWeb) return;
    _cancelOffline.add(jobId);
    final id = _offlineJobs.remove(jobId);
    if (id == null || !_ready) return;
    platform.cancelOfflineDownload(id);
  }

  bool _cancelled(String jobId, bool Function()? isCancelled) {
    if (_cancelOffline.contains(jobId)) return true;
    return isCancelled?.call() ?? false;
  }

  Future<void> stopActive({bool deleteFiles = false}) async {
    if (kIsWeb || !_ready) return;
    final streamId = _activeStreamId;
    final torrentId = _activeTorrentId;
    _activeStreamId = null;
    _activeTorrentId = null;
    platform.clearStreamHealth(torrentId: torrentId);

    if (streamId != null) {
      platform.stopStream(streamId);
    }
    if (torrentId != null) {
      // Never dispose an offline download handle.
      if (_offlineJobs.containsValue(torrentId)) return;
      platform.stopTorrent(torrentId, deleteFiles: deleteFiles);
    }
  }
}

bool isMagnetUri(String value) =>
    value.trim().toLowerCase().startsWith('magnet:');

bool isTorrentPath(String value) {
  final lower = value.trim().toLowerCase();
  return lower.endsWith('.torrent') && !lower.startsWith('http');
}

bool looksLikeTorrentPlayUrl(String value) =>
    isMagnetUri(value) || isTorrentPath(value);
