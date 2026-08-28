import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:javp/models/media_item.dart';
import 'package:javp/services/download/catchup_air_date.dart';
import 'package:javp/services/download/hls_downloader.dart';
import 'package:javp/services/network/transient_network_error.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:javp/services/storage/app_documents.dart';
import 'package:javp/services/torrent/torrent_stream_service.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

enum DownloadStatus { queued, downloading, paused, completed, failed }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.item,
    required this.remoteUrl,
    this.localPath,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.error,
    this.statusDetail,
  });

  final String id;
  final MediaItem item;
  final String remoteUrl;
  String? localPath;
  DownloadStatus status;
  double progress;
  String? error;

  /// Extra UI line (e.g. selected torrent file + size).
  String? statusDetail;

  bool get isTorrentSource =>
      item.origin == MediaOrigin.torrent || looksLikeTorrentPlayUrl(remoteUrl);

  MediaItem asLocalItem() {
    final airDate = catchupAirDateLabelOf(item);
    final subtitle = item.subtitle?.trim() ?? '';
    final subtitleWithDate =
        airDate == null || airDate.isEmpty || subtitle.contains(airDate)
        ? (subtitle.isEmpty ? null : subtitle)
        : (subtitle.isEmpty ? airDate : '$subtitle · $airDate');
    return MediaItem(
      id: 'dl-$id',
      title: item.title,
      playUrl: localPath ?? item.playUrl,
      kind: MediaKind.local,
      origin: MediaOrigin.download,
      subtitle: subtitleWithDate,
      thumbnailUrl: item.thumbnailUrl,
      posterUrl: item.posterUrl,
      backdropUrl: item.backdropUrl,
      group: 'Downloads',
      duration: item.duration,
      progress: item.progress,
      sourceId: item.sourceId,
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      plot: item.plot,
      genres: item.genres,
      rating: item.rating,
      year: item.year,
      seasonNumber: item.seasonNumber,
      episodeNumber: item.episodeNumber,
      seriesId: item.seriesId,
      detailsId: item.detailsId,
      releaseDate: airDate ?? item.releaseDate,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'item': item.toJson(),
    'remoteUrl': remoteUrl,
    'localPath': localPath,
    'status': status.name,
    'progress': progress,
    'error': error,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] as String,
      item: MediaItem.fromJson(json['item'] as Map<String, dynamic>),
      remoteUrl: json['remoteUrl'] as String,
      localPath: json['localPath'] as String?,
      status:
          DownloadStatus.values.asNameMap()[json['status'] as String?] ??
          DownloadStatus.queued,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      error: json['error'] as String?,
    );
  }
}

/// App-private offline downloads for progressive HTTP(S), HLS, and torrents.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    http.Client? httpClient,
    this.isUnmeteredNetwork,
    this.torrentOfflineDownload,
    this.cancelTorrentOffline,
    this.torrentService,
    HlsDownloader? hlsDownloader,
    Duration Function(int attempt)? retryDelayForAttempt,
  }) : _http = httpClient ?? http.Client(),
       _hls = hlsDownloader,
       _retryDelayForAttempt = retryDelayForAttempt;

  /// Transient network failures (e.g. "software caused connection abort").
  static const maxTransientRetries = 5;

  http.Client _http;
  HlsDownloader? _hls;
  // Initialized via [retryDelayForAttempt] named arg (public name for tests).
  // ignore: prefer_initializing_formals
  final Duration Function(int attempt)? _retryDelayForAttempt;
  final _uuid = const Uuid();
  final List<DownloadTask> tasks = [];
  final Map<String, int> _lastProgressBucket = {};
  final Map<String, int> _transientAttempts = {};
  final Set<String> _cellularOverrideIds = {};
  bool _busy = false;
  bool waitingForWifi = false;
  bool wifiOnly = true;

  /// Returns true when Wi‑Fi / ethernet (or unknown → allow).
  Future<bool> Function()? isUnmeteredNetwork;

  /// Swap the HTTP client used by progressive/HLS downloads, e.g. when the
  /// user enables a proxy or changes routing. Also drops the cached HLS
  /// downloader so it is rebuilt against the new client.
  void setHttpClient(http.Client client) {
    _http = client;
    _hls = null;
  }

  /// Preferred: direct service (survives hot reload better than a stale null callback).
  TorrentStreamService? torrentService;

  /// Full magnet/.torrent download → absolute file path.
  Future<String> Function({
    required String jobId,
    required String magnetOrPath,
    required Directory saveDir,
    required MediaItem item,
    required void Function(double progress) onProgress,
    void Function(String name, int bytes)? onFileSelected,
    required bool Function() isCancelled,
  })?
  torrentOfflineDownload;

  Future<void> Function(String jobId)? cancelTorrentOffline;

  bool get isBusy => _busy;

  static bool isEligible(MediaItem item, String playUrl) {
    if (item.isLive) return false;
    if (item.origin == MediaOrigin.torrent ||
        looksLikeTorrentPlayUrl(playUrl)) {
      return true;
    }
    if (headersIndicateDrm(item.httpHeaders)) return false;
    final uri = Uri.tryParse(playUrl);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host == '127.0.0.1' || uri.host == 'localhost') return false;
    final path = uri.path.toLowerCase();
    // DASH offline not supported yet.
    if (path.endsWith('.mpd')) return false;

    final hls = looksLikeHlsPlayUrl(playUrl);

    if (item.kind == MediaKind.catchup) {
      // VOD-style catchup HLS packages are saved as local playlists.
      if (hls) return true;
      final lower = playUrl.toLowerCase();
      if (lower.contains('timeshift.php') || lower.contains('/timeshift/')) {
        return true;
      }
      for (final ext in ['.ts', '.mp4', '.mkv', '.webm', '.avi', '.mov']) {
        if (path.endsWith(ext)) return true;
      }
      return false;
    }
    // Progressive HTTP(S) and HLS VOD (.m3u8 → local playlist package).
    return true;
  }

  /// True when [playUrl] looks like an HLS playlist (master or media).
  static bool looksLikeHlsPlayUrl(String playUrl) {
    final lower = playUrl.toLowerCase();
    final path = Uri.tryParse(playUrl)?.path.toLowerCase() ?? lower;
    return path.endsWith('.m3u8') ||
        lower.contains('.m3u8?') ||
        lower.contains('/m3u8');
  }

  DownloadTask? taskForItemId(String itemId) {
    DownloadTask? best;
    for (final t in tasks) {
      if (t.item.id == itemId || t.asLocalItem().id == itemId) {
        if (best == null || _statusRank(t.status) >= _statusRank(best.status)) {
          best = t;
        }
      }
    }
    return best;
  }

  /// Best queue entry for [item] (id, local id, URL, or series episode).
  DownloadTask? bestTaskFor(MediaItem item, {bool completedOnly = false}) {
    DownloadTask? best;
    for (final t in tasks) {
      if (completedOnly && t.status != DownloadStatus.completed) continue;
      if (!_taskMatchesItem(t, item)) continue;
      if (best == null || _statusRank(t.status) > _statusRank(best.status)) {
        best = t;
      } else if (best.status == t.status &&
          t.status == DownloadStatus.completed &&
          (t.progress >= best.progress)) {
        best = t;
      }
    }
    return best;
  }

  /// Absolute path to a completed offline file for [item], if still on disk.
  String? offlinePlayPathFor(MediaItem item) {
    if (item.origin == MediaOrigin.download || item.kind == MediaKind.local) {
      final path = item.playUrl.trim();
      if (path.isNotEmpty &&
          !path.startsWith('http://') &&
          !path.startsWith('https://') &&
          !looksLikeTorrentPlayUrl(path)) {
        final resolved = _existingLocalPath(path);
        if (resolved != null) return resolved;
      }
    }
    final task = bestTaskFor(item, completedOnly: true);
    final path = task?.localPath?.trim();
    if (path == null || path.isEmpty) return null;
    return _existingLocalPath(path);
  }

  static String? _existingLocalPath(String path) {
    if (File(path).existsSync()) return path;
    final relocated = AppDocuments.tryRelocateSync(path);
    if (relocated != path && File(relocated).existsSync()) return relocated;
    return null;
  }

  static bool _taskMatchesItem(DownloadTask t, MediaItem item) {
    if (t.item.id == item.id || t.asLocalItem().id == item.id) return true;
    if (item.id.startsWith('dl-') && item.id.substring(3) == t.id) {
      return true;
    }

    final sid = item.seriesId?.trim();
    final tsid = t.item.seriesId?.trim();
    final itemIsEp = item.seasonNumber != null && item.episodeNumber != null;
    final taskIsEp =
        t.item.seasonNumber != null && t.item.episodeNumber != null;
    if (sid != null &&
        sid.isNotEmpty &&
        tsid != null &&
        tsid.isNotEmpty &&
        sid == tsid &&
        itemIsEp &&
        taskIsEp) {
      if (t.item.seasonNumber == item.seasonNumber &&
          t.item.episodeNumber == item.episodeNumber) {
        final a = item.sourceId;
        final b = t.item.sourceId;
        if (a != null && b != null && a.isNotEmpty && b.isNotEmpty && a != b) {
          return false;
        }
        return true;
      }
      // Same series, different episode — do not fall through to shared
      // magnet / pack URL matching (that made every row share one progress).
      return false;
    }

    final play = item.playUrl.trim();
    if (play.isNotEmpty && (t.remoteUrl == play || t.item.playUrl == play)) {
      return true;
    }
    return false;
  }

  int _statusRank(DownloadStatus s) => switch (s) {
    DownloadStatus.completed => 4,
    DownloadStatus.downloading => 3,
    DownloadStatus.queued => 2,
    DownloadStatus.paused => 1,
    DownloadStatus.failed => 0,
  };

  Future<Directory> _dir() async {
    final root = await AppDocuments.directory();
    final dir = Directory(p.join(root.path, 'downloads'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<DownloadTask> enqueue({
    required MediaItem item,
    required String remoteUrl,
  }) async {
    if (!isEligible(item, remoteUrl)) {
      throw Exception('This stream cannot be downloaded offline');
    }
    final existing = tasks.cast<DownloadTask?>().firstWhere(
      (t) => t?.item.id == item.id && t?.status != DownloadStatus.failed,
      orElse: () => null,
    );
    if (existing != null) return existing;

    final task = DownloadTask(id: _uuid.v4(), item: item, remoteUrl: remoteUrl);
    tasks.insert(0, task);
    notifyListeners();
    unawaited(_pump());
    return task;
  }

  /// Start [taskId] even when [wifiOnly] would block (one-shot cellular override).
  Future<void> downloadAnyway(String taskId) async {
    _cellularOverrideIds.add(taskId);
    waitingForWifi = false;
    notifyListeners();
    unawaited(_pump());
  }

  /// Re-check network (e.g. after connectivity change).
  void onNetworkChanged() => unawaited(_pump());

  Future<bool> _networkAllows({required bool allowCellular}) async {
    if (!wifiOnly || allowCellular) return true;
    final check = isUnmeteredNetwork;
    if (check == null) return true;
    try {
      return await check();
    } catch (_) {
      return true;
    }
  }

  Future<void> _pump() async {
    if (_busy) return;
    final next = tasks.cast<DownloadTask?>().firstWhere(
      (t) => t?.status == DownloadStatus.queued,
      orElse: () => null,
    );
    if (next == null) {
      if (waitingForWifi) {
        waitingForWifi = false;
        notifyListeners();
      }
      return;
    }

    final allowCellular = _cellularOverrideIds.contains(next.id);
    final ok = await _networkAllows(allowCellular: allowCellular);
    if (!ok) {
      waitingForWifi = true;
      notifyListeners();
      return;
    }
    if (waitingForWifi) {
      waitingForWifi = false;
    }
    _cellularOverrideIds.remove(next.id);

    _busy = true;
    next.status = DownloadStatus.downloading;
    next.error = null;
    notifyListeners();
    var delayBeforeNextPump = Duration.zero;
    try {
      if (next.isTorrentSource) {
        await _downloadTorrent(next);
      } else if (looksLikeHlsPlayUrl(next.remoteUrl)) {
        await _downloadHls(next);
      } else {
        await _downloadHttp(next);
      }
      if (next.status == DownloadStatus.completed) {
        _transientAttempts.remove(next.id);
      }
    } catch (e) {
      if (next.status == DownloadStatus.paused) {
        // Interrupted by remove() — do not fail or retry.
      } else if (_shouldRetryTransient(next, e)) {
        final attempt = (_transientAttempts[next.id] ?? 0) + 1;
        _transientAttempts[next.id] = attempt;
        next.status = DownloadStatus.queued;
        next.error = null;
        next.statusDetail = 'Retrying ($attempt/$maxTransientRetries)…';
        delayBeforeNextPump = _retryDelay(attempt);
        debugPrint(
          'Download ${next.id} transient failure (attempt $attempt): $e',
        );
      } else {
        _transientAttempts.remove(next.id);
        next.status = DownloadStatus.failed;
        next.error = e.toString();
        next.statusDetail = null;
      }
    } finally {
      _busy = false;
      notifyListeners();
      if (delayBeforeNextPump > Duration.zero) {
        unawaited(_pumpAfter(delayBeforeNextPump));
      } else {
        unawaited(_pump());
      }
    }
  }

  Future<void> _pumpAfter(Duration delay) async {
    await Future<void>.delayed(delay);
    await _pump();
  }

  bool _shouldRetryTransient(DownloadTask task, Object e) {
    if (!isTransientNetworkError(e)) return false;
    final attempts = _transientAttempts[task.id] ?? 0;
    return attempts < maxTransientRetries;
  }

  Duration _retryDelay(int attempt) {
    final override = _retryDelayForAttempt;
    if (override != null) return override(attempt);
    // 1s, 2s, 4s, 8s, 16s (capped).
    final seconds = 1 << (attempt - 1).clamp(0, 4);
    return Duration(seconds: seconds);
  }

  Future<void> _downloadHls(DownloadTask next) async {
    final root = await _dir();
    final saveDir = Directory('${root.path}/hls-${next.id}');
    final downloader = _hls ?? HlsDownloader(httpClient: _http);
    _hls ??= downloader;
    try {
      final path = await downloader.download(
        remoteUrl: next.remoteUrl,
        saveDir: saveDir,
        httpHeaders: next.item.httpHeaders.isEmpty
            ? null
            : next.item.httpHeaders,
        onProgress: (p) => _setProgress(next, p),
        onDetail: (detail) {
          next.statusDetail = detail;
          notifyListeners();
        },
        isCancelled: () => next.status == DownloadStatus.paused,
      );
      if (next.status == DownloadStatus.paused) return;
      next.localPath = path;
      next.progress = 1;
      next.statusDetail = null;
      next.status = DownloadStatus.completed;
    } catch (e) {
      // Pause is not a failure — leave status as paused.
      if (next.status == DownloadStatus.paused) return;
      // Keep partial segments on transient errors so retries can resume.
      if (!isTransientNetworkError(e)) {
        try {
          if (await saveDir.exists()) {
            await saveDir.delete(recursive: true);
          }
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _downloadHttp(DownloadTask next) async {
    final dir = await _dir();
    final ext = _guessExt(next.remoteUrl);
    final file = File('${dir.path}/${next.id}$ext');
    var existingBytes = 0;
    if (await file.exists()) {
      existingBytes = await file.length();
      if (existingBytes < 0) existingBytes = 0;
    }

    final request = http.Request('GET', Uri.parse(next.remoteUrl));
    request.headers['User-Agent'] = 'JAVP';
    if (next.item.httpHeaders.isNotEmpty) {
      request.headers.addAll(next.item.httpHeaders);
    }
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
    }
    var response = await _http.send(request);
    var code = response.statusCode;
    // Stale / unsatisfiable Range — drop partial and restart once.
    if (code == 416 && existingBytes > 0) {
      try {
        await response.stream.drain<void>();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      existingBytes = 0;
      final retry = http.Request('GET', Uri.parse(next.remoteUrl));
      retry.headers['User-Agent'] = 'JAVP';
      if (next.item.httpHeaders.isNotEmpty) {
        retry.headers.addAll(next.item.httpHeaders);
      }
      response = await _http.send(retry);
      code = response.statusCode;
    }
    if (code >= 400) {
      throw Exception('Download failed ($code)');
    }

    final resume = code == 206 && existingBytes > 0;
    final sink = resume
        ? file.openWrite(mode: FileMode.append)
        : file.openWrite();
    var got = resume ? existingBytes : 0;
    final contentLen = response.contentLength ?? 0;
    final expectedBytes = resume
        ? (contentLen > 0
              ? existingBytes + contentLen
              : _estimatedCatchupBytes(next.item))
        : (contentLen > 0 ? contentLen : _estimatedCatchupBytes(next.item));
    try {
      await for (final chunk in response.stream) {
        if (next.status == DownloadStatus.paused) {
          return;
        }
        sink.add(chunk);
        got += chunk.length;
        next.statusDetail = _formatBytes(got);
        if (expectedBytes > 0) {
          // Cap below 1.0 until the stream closes so we don't mark done early.
          final ratio = (got / expectedBytes).clamp(0.0, 0.99);
          _setProgress(next, ratio);
        } else if (got > 0) {
          // Indeterminate: nudge the bar so the UI doesn't look stuck at 0%.
          _setProgress(next, 0.05);
        }
      }
    } finally {
      await sink.close();
    }
    if (next.status == DownloadStatus.paused) return;
    if (got <= 0) {
      throw Exception('Download produced an empty file');
    }
    next.localPath = file.path;
    next.progress = 1;
    next.statusDetail = _formatBytes(got);
    next.status = DownloadStatus.completed;
  }

  /// Rough byte budget for catchup when the server sends no Content-Length.
  /// ~4 Mbps ≈ 500 KB/s — enough for a progress bar, not a hard stop.
  int _estimatedCatchupBytes(MediaItem item) {
    if (item.kind != MediaKind.catchup) return 0;
    final seconds = item.duration?.inSeconds ?? 0;
    if (seconds <= 0) return 0;
    return seconds * 500 * 1024;
  }

  Future<void> _downloadTorrent(DownloadTask next) async {
    final dir = await _dir();
    final taskDir = Directory('${dir.path}/torrent-${next.id}');
    final downloader = torrentOfflineDownload;
    late final String path;
    if (downloader != null) {
      path = await downloader(
        jobId: next.id,
        magnetOrPath: next.remoteUrl,
        saveDir: taskDir,
        item: next.item,
        onProgress: (p) => _setProgress(next, p),
        onFileSelected: (name, bytes) {
          next.statusDetail =
              '$name · ${_formatBytes(bytes)} (selected file, not full pack)';
          notifyListeners();
        },
        isCancelled: () => next.status == DownloadStatus.paused,
      );
    } else {
      final service = torrentService;
      if (service == null) {
        throw Exception(
          'Torrent offline download is not available '
          '(restart the app to finish wiring)',
        );
      }
      path = await service.downloadOffline(
        jobId: next.id,
        magnetOrPath: next.remoteUrl,
        saveDir: taskDir,
        episodeNumber: next.item.episodeNumber,
        seasonNumber: next.item.seasonNumber,
        preferredFileName: next.item.torrentFile,
        onProgress: (p) => _setProgress(next, p),
        onFileSelected: (name, bytes) {
          next.statusDetail =
              '$name · ${_formatBytes(bytes)} (selected file, not full pack)';
          notifyListeners();
        },
        isCancelled: () => next.status == DownloadStatus.paused,
      );
    }
    if (next.status == DownloadStatus.paused) return;
    next.localPath = path;
    next.progress = 1;
    next.status = DownloadStatus.completed;
  }

  void _setProgress(DownloadTask next, double value) {
    next.progress = value.clamp(0.0, 1.0);
    final bucket = (next.progress * 40).floor();
    if (bucket != _lastProgressBucket[next.id]) {
      _lastProgressBucket[next.id] = bucket;
      notifyListeners();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String _guessExt(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final lower = url.toLowerCase();
    if (lower.contains('timeshift.php') || lower.contains('/timeshift/')) {
      return '.ts';
    }
    for (final ext in ['.mp4', '.mkv', '.webm', '.avi', '.mov', '.ts']) {
      if (path.endsWith(ext)) return ext;
    }
    return '.mp4';
  }

  Future<void> remove(String taskId, {bool deleteFile = true}) async {
    final idx = tasks.indexWhere((t) => t.id == taskId);
    if (idx < 0) return;
    final task = tasks.removeAt(idx);
    _cellularOverrideIds.remove(taskId);
    _lastProgressBucket.remove(taskId);
    _transientAttempts.remove(taskId);
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.paused;
      final cancel =
          cancelTorrentOffline ??
          (torrentService != null
              ? torrentService!.cancelOfflineDownload
              : null);
      if (cancel != null && task.isTorrentSource) {
        try {
          await cancel(taskId);
        } catch (_) {}
      }
    }
    if (deleteFile && task.localPath != null) {
      try {
        final f = File(task.localPath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      // Torrent offline jobs live under downloads/torrent-<id>/
      try {
        final dir = Directory('${(await _dir()).path}/torrent-$taskId');
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
      // HLS offline packages live under downloads/hls-<id>/
      try {
        final dir = Directory('${(await _dir()).path}/hls-$taskId');
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  List<MediaItem> get completedItems => tasks
      .where((t) => t.status == DownloadStatus.completed && t.localPath != null)
      .map((t) => t.asLocalItem())
      .toList();

  /// Keep download metadata aligned with watch progress (offline resume).
  ///
  /// [notify] defaults to true for structural updates. Playback progress ticks
  /// pass false so we never rebuild Library / rewrite downloads prefs every 5s.
  void syncItemProgress(
    MediaItem item, {
    required double progress,
    Duration? duration,
    bool notify = true,
  }) {
    var changed = false;
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      if (!_taskMatchesItem(task, item)) continue;
      final next = task.item.copyWith(
        progress: progress.clamp(0.0, 1.0),
        duration: duration ?? task.item.duration,
        lastWatchedAt: DateTime.now(),
      );
      if (next.progress == task.item.progress &&
          next.duration == task.item.duration) {
        continue;
      }
      tasks[i] = DownloadTask(
        id: task.id,
        item: next,
        remoteUrl: task.remoteUrl,
        localPath: task.localPath,
        status: task.status,
        progress: task.progress,
        error: task.error,
        statusDetail: task.statusDetail,
      );
      changed = true;
    }
    if (changed && notify) notifyListeners();
  }

  int get activeCount => tasks
      .where(
        (t) =>
            t.status == DownloadStatus.queued ||
            t.status == DownloadStatus.downloading,
      )
      .length;

  /// Rebuild completed tasks from persisted offline [MediaItem]s (Library).
  void restoreCompletedItems(List<MediaItem> items) {
    var added = false;
    for (final item in items) {
      if (item.origin != MediaOrigin.download) continue;
      final path = item.playUrl;
      if (path.isEmpty) continue;
      final taskId = item.id.startsWith('dl-') ? item.id.substring(3) : item.id;
      if (tasks.any((t) => t.id == taskId || t.asLocalItem().id == item.id)) {
        continue;
      }
      tasks.add(
        DownloadTask(
          id: taskId,
          item: item,
          remoteUrl: path,
          localPath: path,
          status: DownloadStatus.completed,
          progress: 1,
        ),
      );
      added = true;
    }
    if (added) notifyListeners();
  }

  void loadFromJson(List<dynamic> raw) {
    tasks
      ..clear()
      ..addAll(
        raw.whereType<Map>().map(
          (e) => DownloadTask.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
    notifyListeners();
  }

  List<Map<String, dynamic>> toJsonList() =>
      tasks.map((t) => t.toJson()).toList();
}
