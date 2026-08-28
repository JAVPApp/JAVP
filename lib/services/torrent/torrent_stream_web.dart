import 'dart:async';

import 'package:javp/models/proxy_settings.dart';
import 'package:javp/services/torrent/torrent_stream_health.dart';

Future<void> initTorrent() async {}

bool applyProxySettings(ProxySettings settings) => false;

Future<TorrentPlayback> resolveToStream(
  String magnetOrTorrentPath, {
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
  Duration metadataTimeout = const Duration(seconds: 90),
  Duration readyTimeout = const Duration(seconds: 120),
}) async {
  throw UnsupportedError('Torrent streaming not supported on web');
}

Future<int> startOfflineDownload({
  required String jobId,
  required String magnetOrPath,
  required dynamic saveDir,
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
  void Function(double progress)? onProgress,
  void Function(String name, int bytes)? onFileSelected,
  required bool Function() isCancelled,
  Duration metadataTimeout = const Duration(minutes: 3),
  Duration downloadTimeout = const Duration(hours: 12),
}) async {
  throw UnsupportedError('Torrent downloads not supported on web');
}

Future<String> waitForOfflineDownload({
  required String jobId,
  required int torrentId,
  required dynamic saveDir,
  int? episodeNumber,
  int? seasonNumber,
  String? preferredFileName,
  void Function(double progress)? onProgress,
  required bool Function() isCancelled,
  Duration metadataTimeout = const Duration(minutes: 3),
  Duration downloadTimeout = const Duration(hours: 12),
}) async {
  throw UnsupportedError('Torrent downloads not supported on web');
}

void cancelOfflineDownload(int id) {}

void stopStream(int streamId) {}

void stopTorrent(int torrentId, {bool deleteFiles = false}) {}

void clearStreamHealth({int? torrentId}) {}

TorrentStreamHealth? activeStreamHealth({int? torrentId, int? streamId}) =>
    null;

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
