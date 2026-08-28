import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/iptv/epg_parser.dart';
import 'package:javp/services/local_source_path.dart';
import 'package:javp/services/storage/epg_program_db.dart';

/// Download + SQLite ingest for one XMLTV URL (SyncEngine / tests).
class EpgFeedIngest {
  EpgFeedIngest({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  static const _connectTimeout = Duration(seconds: 30);
  static const _idleTimeout = Duration(seconds: 60);

  void close() => _http.close();

  Future<({List<int> bytes, String? contentEncoding})?> loadBytes(
    String epgUrl,
  ) async {
    final localPath = LocalSourcePath.tryLocalFilePath(epgUrl);
    if (localPath != null) {
      final file = File(localPath);
      if (!await file.exists()) return null;
      final bytes = await collectBytesYielding(
        file.openRead(),
        maxBytes: kMaxEpgDownloadBytes,
        tooLargeMessage: 'Guide file is too large',
      );
      if (bytes.isEmpty) return null;
      return (bytes: bytes, contentEncoding: null);
    }
    if (!LocalSourcePath.isRemoteUrl(epgUrl)) return null;

    final request = http.Request('GET', Uri.parse(epgUrl));
    request.headers.addAll({
      'Accept': 'application/xml, text/xml, */*',
      'Accept-Encoding': 'gzip',
    });
    late final http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request).timeout(
            _connectTimeout,
            onTimeout: () => throw TimeoutException('Guide download timed out'),
          );
    } on TimeoutException {
      return null;
    } catch (e) {
      JavpLog.w('epg', 'download failed url=$epgUrl ($e)');
      return null;
    }
    if (streamed.statusCode >= 400) {
      unawaited(
        streamed.stream.drain<void>().then<void>((_) {}, onError: (_) {}),
      );
      return null;
    }
    try {
      final bytes = await collectBytesYielding(
        streamed.stream.timeout(
          _idleTimeout,
          onTimeout: (sink) {
            sink.addError(TimeoutException('Guide download stalled'));
          },
        ),
        maxBytes: kMaxEpgDownloadBytes,
        tooLargeMessage: 'Guide is too large',
      );
      if (bytes.isEmpty) return null;
      return (
        bytes: bytes,
        contentEncoding: streamed.headers['content-encoding'],
      );
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  /// Replace one feed in [db]. Returns programme count written (0 = empty).
  Future<int> ingestFeed({
    required EpgProgramDb db,
    required String url,
    required List<int> bytes,
    String? contentEncoding,
  }) async {
    await db.clearFeed(url);
    final ingested = await ingestEpgPackedInIsolate(
      bytes: bytes,
      url: url,
      contentEncoding: contentEncoding,
      onChunk: (rows) => db.insertPrograms(url, rows),
    );
    if (ingested.programCount == 0 && ingested.channelNames.isEmpty) {
      return 0;
    }
    await db.insertChannels(url, ingested.channelNames);
    await db.touchFeed(url, ingested.programCount);
    return ingested.programCount;
  }
}
