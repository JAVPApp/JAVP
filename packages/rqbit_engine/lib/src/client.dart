import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// HTTP client for a running rqbit loopback API.
class RqbitClient {
  RqbitClient({required this.baseUrl, HttpClient? http})
      : _http = http ?? HttpClient() {
    // POST /torrents waits for magnet metadata on the server.
    _http.idleTimeout = const Duration(minutes: 3);
    _http.connectionTimeout ??= const Duration(seconds: 15);
  }

  /// `http://127.0.0.1:<port>` with no trailing slash.
  String baseUrl;
  final HttpClient _http;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      path: path,
      queryParameters: query,
    );
  }

  Future<RqbitTorrent> addMagnet(
    String magnet, {
    String? outputFolder,
    bool overwrite = true,
  }) {
    return _add(
      utf8.encode(magnet),
      outputFolder: outputFolder,
      overwrite: overwrite,
      isUrl: true,
    );
  }

  Future<RqbitTorrent> addTorrentBytes(
    List<int> bytes, {
    String? outputFolder,
    bool overwrite = true,
  }) {
    return _add(bytes, outputFolder: outputFolder, overwrite: overwrite);
  }

  Future<RqbitTorrent> _add(
    List<int> body, {
    String? outputFolder,
    required bool overwrite,
    bool isUrl = false,
  }) async {
    final query = <String, String>{
      'overwrite': overwrite ? 'true' : 'false',
      if (outputFolder != null && outputFolder.isNotEmpty)
        'output_folder': outputFolder,
      if (isUrl) 'is_url': 'true',
    };
    final json = await _json('POST', '/torrents', query: query, body: body);
    return RqbitTorrent.fromAddJson(json);
  }

  Future<RqbitTorrent> details(int id) async {
    final json = await _json('GET', '/torrents/$id');
    return RqbitTorrent.fromDetailsJson(json);
  }

  Future<RqbitStats> stats(int id) async {
    final json = await _json('GET', '/torrents/$id/stats/v1');
    return RqbitStats.fromJson(json);
  }

  Future<void> updateOnlyFiles(int id, List<int> fileIndexes) async {
    await _json(
      'POST',
      '/torrents/$id/update_only_files',
      jsonBody: {'only_files': fileIndexes},
    );
  }

  Future<void> delete(int id, {required bool deleteFiles}) async {
    final action = deleteFiles ? 'delete' : 'forget';
    await _json('POST', '/torrents/$id/$action');
  }

  /// HTTP range stream for media_kit.
  String streamUrl(int id, int fileIndex) =>
      '$baseUrl/torrents/$id/stream/$fileIndex';

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? body,
    Map<String, dynamic>? jsonBody,
  }) async {
    final uri = _uri(path, query);
    final req = await _http.openUrl(method, uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (jsonBody != null) {
      final encoded = utf8.encode(jsonEncode(jsonBody));
      req.headers.contentType = ContentType.json;
      req.add(encoded);
    } else if (body != null) {
      req.add(Uint8List.fromList(body));
    }
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RqbitApiException(
        statusCode: res.statusCode,
        path: path,
        body: text,
      );
    }
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return const {};
  }

  void close() => _http.close(force: true);
}

class RqbitApiException implements Exception {
  RqbitApiException({
    required this.statusCode,
    required this.path,
    required this.body,
  });

  final int statusCode;
  final String path;
  final String body;

  @override
  String toString() {
    final snippet = body.length > 240 ? '${body.substring(0, 240)}…' : body;
    return 'Rqbit API $statusCode $path: $snippet';
  }

  /// librqbit rejects `update_only_files` until the torrent leaves initializing.
  bool get isInitializingOnlyFiles {
    if (statusCode != 500 && statusCode != 409) return false;
    return body.toLowerCase().contains('initializing');
  }
}
