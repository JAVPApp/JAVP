import 'dart:async';
import 'dart:io';

import 'package:javp/models/proxy_settings.dart';
import 'package:javp/services/torrent/torrent_file_picker.dart';
import 'package:javp/services/torrent/torrent_stream_health.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rqbit_engine/rqbit_engine.dart';

List<String> _extraTrackers = [];
String? _pendingSocks;
final TorrentHealthCache _health = TorrentHealthCache();

RqbitClient get _client {
  final http = RqbitEngine.http;
  if (http == null) {
    throw StateError('rqbit engine is not started');
  }
  return http;
}

Future<void> initTorrent() async {
  final dir = await getTemporaryDirectory();
  final savePath = Directory('${dir.path}/javp_torrents');
  if (!await savePath.exists()) {
    await savePath.create(recursive: true);
  }
  await RqbitEngine.start(
    savePath: savePath.path,
    socksProxyUrl: _pendingSocks,
  );
  unawaited(_refreshTrackers());
}

Future<void> _refreshTrackers() async {
  final list = await fetchPublicTrackers();
  if (list.isNotEmpty) _extraTrackers = list;
}

String? _socksUrl(ProxySettings settings) {
  if (!settings.isActiveFor(ProxyTrafficScope.torrents)) return null;
  return rqbitSocksProxyUrl(
    enabled: true,
    type: settings.type.name,
    host: settings.host,
    port: settings.port,
    username: settings.username,
    password: settings.password,
  );
}

bool applyProxySettings(ProxySettings settings) {
  _pendingSocks = _socksUrl(settings);
  final engine = RqbitEngine.instance;
  if (engine == null) return false;
  // Always push the resolved SOCKS URL (null clears a previous SOCKS).
  // HTTP torrent proxies are not supported; still drop leftover SOCKS.
  final applied = engine.setSocksProxy(_pendingSocks);
  if (settings.isActiveFor(ProxyTrafficScope.torrents) &&
      settings.type == ProxyType.http) {
    return false;
  }
  return applied;
}

Future<TorrentPlayback> resolveToStream(
  String magnetOrTorrentPath, {
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
  Duration metadataTimeout = const Duration(seconds: 90),
  Duration readyTimeout = const Duration(seconds: 120),
}) async {
  _health.clear();
  final added = await _addSource(magnetOrTorrentPath);
  final id = added.id;

  try {
    final meta = await _waitForMetadata(id, timeout: metadataTimeout);
    if (meta.files.isEmpty) {
      throw StateError('Torrent has no files yet.');
    }

    final fileIndex =
        _pickFile(
          meta.files,
          episodeNumber: episodeNumber,
          seasonNumber: seasonNumber,
          preferredFileName: preferredFileName,
        ) ??
        _largestVideoIndex(meta.files);

    await _updateOnlyFiles(id, [fileIndex]);
    final url = _client.streamUrl(id, fileIndex);
    if (url.isEmpty) {
      throw StateError('Torrent stream URL was empty.');
    }
    await _waitUntilStreamResponds(url, timeout: readyTimeout);

    final file = meta.files.cast<RqbitFile?>().firstWhere(
      (f) => f?.index == fileIndex,
      orElse: () => null,
    );

    return TorrentPlayback(
      torrentId: id,
      streamId: fileIndex,
      httpUrl: url,
      title: meta.name.isEmpty ? 'Torrent' : meta.name,
      fileName: file?.name ?? 'video',
    );
  } catch (e) {
    try {
      await _client.delete(id, deleteFiles: false);
    } catch (_) {}
    rethrow;
  }
}

Future<int> startOfflineDownload({
  required String jobId,
  required String magnetOrPath,
  required Directory saveDir,
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
  void Function(double progress)? onProgress,
  void Function(String name, int bytes)? onFileSelected,
  required bool Function() isCancelled,
  Duration metadataTimeout = const Duration(minutes: 3),
  Duration downloadTimeout = const Duration(hours: 12),
}) async {
  if (!await saveDir.exists()) {
    await saveDir.create(recursive: true);
  }
  final added = await _addSource(magnetOrPath, outputFolder: saveDir.path);
  return added.id;
}

Future<String> waitForOfflineDownload({
  required String jobId,
  required int torrentId,
  required Directory saveDir,
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
  void Function(double progress)? onProgress,
  required bool Function() isCancelled,
  Duration metadataTimeout = const Duration(minutes: 3),
  Duration downloadTimeout = const Duration(hours: 12),
}) async {
  final meta = await _waitForMetadata(torrentId, timeout: metadataTimeout);
  if (isCancelled()) {
    throw StateError('Download cancelled');
  }
  if (meta.files.isEmpty) {
    throw StateError('Torrent has no files.');
  }

  var fileIndex = _pickFile(
    meta.files,
    episodeNumber: episodeNumber,
    seasonNumber: seasonNumber,
    preferredFileName: preferredFileName,
  );
  fileIndex ??= _largestVideoIndex(meta.files);

  await _updateOnlyFiles(torrentId, [fileIndex]);

  final selected = meta.files.cast<RqbitFile?>().firstWhere(
    (f) => f?.index == fileIndex,
    orElse: () => null,
  );
  if (selected == null) {
    throw StateError('Could not resolve selected torrent file.');
  }

  final savePath = meta.outputFolder.isNotEmpty
      ? meta.outputFolder
      : saveDir.path;

  final done = await _waitUntilFileDone(
    torrentId,
    fileIndex: fileIndex,
    expectedBytes: selected.length,
    resolveFile: () => _locateDownloadedFile(
      saveDir: saveDir,
      savePath: savePath,
      file: selected,
    ),
    timeout: downloadTimeout,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
  if (isCancelled()) {
    throw StateError('Download cancelled');
  }
  if (!done) {
    throw TimeoutException(
      'Timed out waiting for torrent to finish.',
      downloadTimeout,
    );
  }

  final out = await _locateDownloadedFile(
    saveDir: saveDir,
    savePath: savePath,
    file: selected,
  );
  if (out == null) {
    throw StateError(
      'Downloaded torrent file is missing under $savePath '
      '(wanted ${selected.path}).',
    );
  }

  final ext = p.extension(out.path).isNotEmpty
      ? p.extension(out.path)
      : p.extension(selected.name);
  final flat = File(
    p.join(saveDir.path, '$jobId${ext.isEmpty ? '.mkv' : ext}'),
  );
  if (p.normalize(out.path) != p.normalize(flat.path)) {
    await flat.parent.create(recursive: true);
    await out.copy(flat.path);
  }

  try {
    await _client.delete(torrentId, deleteFiles: false);
  } catch (_) {}

  return flat.path;
}

void cancelOfflineDownload(int id) {
  unawaited(_safeDelete(id, deleteFiles: true));
}

void stopStream(int streamId) {
  // rqbit streams are HTTP GETs; closing the player drops the connection.
}

void stopTorrent(int torrentId, {bool deleteFiles = false}) {
  _health.clear(ifTorrentId: torrentId);
  unawaited(_safeDelete(torrentId, deleteFiles: deleteFiles));
}

void clearStreamHealth({int? torrentId}) {
  _health.clear(ifTorrentId: torrentId);
}

Future<void> _safeDelete(int id, {required bool deleteFiles}) async {
  try {
    await _client.delete(id, deleteFiles: deleteFiles);
  } catch (_) {}
}

TorrentStreamHealth? activeStreamHealth({int? torrentId, int? streamId}) {
  if (torrentId == null) return _health.snapshot(null);
  unawaited(_refreshHealth(torrentId));
  return _health.snapshot(torrentId);
}

Future<void> _refreshHealth(int torrentId) async {
  try {
    final st = await _client.stats(torrentId);
    final incomplete = !st.finished && st.progress < 0.995;
    _health.update(
      torrentId,
      TorrentStreamHealth(
        fileIncomplete: incomplete,
        streamBuffering: incomplete && st.state == 'live',
      ),
    );
  } catch (_) {}
}

Future<RqbitTorrent> _addSource(String magnetOrPath, {String? outputFolder}) {
  final source = magnetOrPath.trim();
  if (source.toLowerCase().startsWith('magnet:')) {
    return _client.addMagnet(
      injectTrackers(source, _extraTrackers),
      outputFolder: outputFolder,
    );
  }
  final bytes = File(source).readAsBytesSync();
  return _client.addTorrentBytes(bytes, outputFolder: outputFolder);
}

int? _pickFile(
  List<RqbitFile> files, {
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
}) {
  return pickTorrentFileIndex(
    files: files
        .map(
          (f) => TorrentFileCandidate(
            index: f.index,
            name: f.name,
            path: f.path,
            size: f.length,
            isStreamable:
                looksLikeVideoFile(f.name) || looksLikeVideoFile(f.path),
          ),
        )
        .toList(),
    episodeNumber: episodeNumber,
    seasonNumber: seasonNumber,
    preferredFileName: preferredFileName,
  );
}

int _largestVideoIndex(List<RqbitFile> files) {
  final pool = files
      .where((f) => looksLikeVideoFile(f.name) || looksLikeVideoFile(f.path))
      .toList();
  final pick = (pool.isNotEmpty ? pool : files)
    ..sort((a, b) => b.length.compareTo(a.length));
  return pick.first.index;
}

Future<RqbitTorrent> _waitForMetadata(
  int id, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  RqbitTorrent? last;
  var sawFiles = false;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final details = await _client.details(id);
      last = details;
      if (details.files.isNotEmpty) sawFiles = true;
      final st = await _client.stats(id);
      if (st.isError) {
        throw StateError(
          st.error?.isNotEmpty == true ? st.error! : 'Torrent error',
        );
      }
      // File list can land while state is still `initializing`;
      // update_only_files 500s until live/paused.
      if (details.files.isNotEmpty && st.acceptsOnlyFilesUpdate) {
        return details;
      }
    } on RqbitApiException catch (e) {
      if (e.statusCode == 404) {
        throw StateError('Torrent disappeared before metadata arrived.');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  if (sawFiles || (last != null && last.files.isNotEmpty)) {
    throw TimeoutException(
      'Torrent stayed initializing. Check the magnet, proxy, and network.',
      timeout,
    );
  }
  throw TimeoutException(
    'Timed out waiting for torrent metadata. Check the magnet and network.',
    timeout,
  );
}

Future<void> _updateOnlyFiles(int id, List<int> fileIndexes) async {
  const attempts = 20;
  Object? last;
  for (var i = 0; i < attempts; i++) {
    try {
      await _client.updateOnlyFiles(id, fileIndexes);
      return;
    } on RqbitApiException catch (e) {
      last = e;
      if (!e.isInitializingOnlyFiles) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  throw last ??
      TimeoutException(
        'Torrent stayed initializing while picking a file.',
        Duration(milliseconds: attempts * 400),
      );
}

Future<void> _waitUntilStreamResponds(
  String url, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  final client = HttpClient();
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = await client.openUrl('HEAD', Uri.parse(url));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
        final res = await req.close().timeout(const Duration(seconds: 4));
        await res.drain<void>();
        if (res.statusCode < 500) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    client.close(force: true);
  }
  // URL is still usable; media_kit will retry. Do not fail the resolve.
}

Future<bool> _waitUntilFileDone(
  int id, {
  required int fileIndex,
  required int expectedBytes,
  required Future<File?> Function() resolveFile,
  required Duration timeout,
  void Function(double progress)? onProgress,
  required bool Function() isCancelled,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (isCancelled()) return false;
    try {
      final st = await _client.stats(id);
      if (st.isError) return false;
      var frac = st.progress;
      if (fileIndex >= 0 &&
          fileIndex < st.fileProgress.length &&
          expectedBytes > 0) {
        frac = (st.fileProgress[fileIndex] / expectedBytes).clamp(0.0, 1.0);
      }
      onProgress?.call(frac);
      final wantedDone = st.totalBytes > 0 && st.progressBytes >= st.totalBytes;
      if (st.finished || frac >= 0.999 || wantedDone) {
        for (var attempt = 0; attempt < 10; attempt++) {
          if (isCancelled()) return false;
          final file = await resolveFile();
          if (file != null) {
            final len = await file.length();
            if (expectedBytes <= 0 || len >= (expectedBytes * 0.98).floor()) {
              onProgress?.call(1);
              return true;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

Future<File?> _locateDownloadedFile({
  required Directory saveDir,
  required String savePath,
  required RqbitFile file,
}) async {
  final names = <String>{file.name, p.basename(file.path)};
  final candidates = <String>[
    p.normalize(p.join(savePath, file.path)),
    p.normalize(p.join(saveDir.path, file.path)),
    p.normalize(p.join(savePath, file.name)),
    p.normalize(p.join(saveDir.path, file.name)),
    p.normalize(p.join(savePath, file.path.replaceAll('\\', '/'))),
    p.normalize(p.join(saveDir.path, file.path.replaceAll('\\', '/'))),
  ];

  for (final path in candidates) {
    final f = File(path);
    try {
      if (await f.exists() && await f.length() > 0) return f;
    } catch (_) {}
  }

  for (final rootPath in {savePath, saveDir.path}) {
    final root = Directory(rootPath);
    if (!await root.exists()) continue;
    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        if (!names.contains(base)) continue;
        try {
          if (await entity.length() > 0) return entity;
        } catch (_) {}
      }
    } catch (_) {}
  }
  return null;
}

class TorrentPlayback {
  const TorrentPlayback({
    required this.torrentId,
    required this.streamId,
    required this.httpUrl,
    required this.title,
    required this.fileName,
  });

  final int torrentId;
  final int streamId;
  final String httpUrl;
  final String title;
  final String fileName;
}
