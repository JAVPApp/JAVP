import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// Thrown when a remote is unreachable or rejects a request.
class SyncRemoteException implements Exception {
  SyncRemoteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A file's contents plus a token identifying this exact version of it.
///
/// The token is what makes a compare-and-swap possible: hand it back on write
/// and the remote will refuse if anyone else got there first.
class RemoteRead {
  const RemoteRead({this.contents, this.revision});

  static const absent = RemoteRead();

  /// Null when the file doesn't exist.
  final String? contents;

  /// An ETag, a content fingerprint, or null when the file was absent.
  final String? revision;

  bool get exists => contents != null;
}

/// The only thing profile sync needs from a backend: read, write, and list
/// small text files under a root folder.
///
/// Deliberately dumb so a backend can be anything with a filesystem shape —
/// a synced folder, WebDAV, SFTP, or an FTP server.
abstract class SyncRemote {
  /// Human-readable target, shown in settings.
  String get label;

  /// Fails with [SyncRemoteException] when the target isn't usable.
  ///
  /// When [requireWrite] is false (restore / import), the remote only needs to
  /// be readable — Android scoped storage often blocks writing a probe file
  /// even when profile snapshots can still be listed and read.
  Future<void> probe({bool requireWrite = true});

  /// File names (not full paths) directly inside [dir], relative to the root.
  Future<List<String>> list(String dir);

  /// File contents, or null when the file doesn't exist.
  Future<String?> read(String path);

  /// Contents plus the revision token needed by [writeIfUnchanged].
  Future<RemoteRead> readWithRevision(String path);

  /// Unconditional write. Use [writeIfUnchanged] for anything another device
  /// might be writing at the same time.
  Future<void> write(String path, String contents);

  /// Writes only if the file is still at [expectedRevision], where null means
  /// "expect this file not to exist yet".
  ///
  /// Returns false when someone else wrote first, leaving their version alone.
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  });

  Future<void> delete(String path);

  void close();
}

/// Stable fingerprint of a file's contents, used where a backend has no ETag.
String fingerprint(String contents) {
  // BigInt keeps full 64-bit FNV-1a on web (JS number can't hold these consts).
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final unit in contents.codeUnits) {
    hash = (hash ^ BigInt.from(unit)) & mask;
    hash = (hash * prime) & mask;
  }
  return '${contents.length}-${hash.toRadixString(16)}';
}

/// A plain folder on this device.
///
/// This is the backend for anything that already syncs files for you —
/// Syncthing, a Google Drive / Dropbox / Nextcloud desktop folder, or a
/// mounted network share. Nothing has to stay awake but the file host.
class LocalFolderRemote implements SyncRemote {
  LocalFolderRemote(this.rootPath);

  final String rootPath;

  @override
  String get label => rootPath;

  String _resolve(String path) =>
      '$rootPath${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}';

  @override
  Future<void> probe({bool requireWrite = true}) async {
    final dir = Directory(rootPath);
    if (!await dir.exists()) {
      throw SyncRemoteException('Folder not found: $rootPath');
    }
    try {
      final probe = File('${dir.path}${Platform.pathSeparator}.javp-write-test');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return;
    } on FileSystemException catch (e) {
      if (requireWrite) {
        throw SyncRemoteException(
          'Folder is not writable: ${e.message}. '
          'On Android, pick a folder JAVP can write to (or use Google Drive).',
        );
      }
    }
    // Restore / import only needs to read existing snapshots.
    try {
      await dir.list(followLinks: false).take(1).drain<void>();
    } on FileSystemException catch (e) {
      throw SyncRemoteException('Folder is not readable: ${e.message}');
    }
  }

  @override
  Future<List<String>> list(String dir) async {
    final target = Directory(_resolve(dir));
    if (!await target.exists()) return const [];
    final names = <String>[];
    await for (final entity in target.list(followLinks: false)) {
      if (entity is File) names.add(entity.uri.pathSegments.last);
    }
    return names;
  }

  @override
  Future<String?> read(String path) async {
    final file = File(_resolve(path));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<RemoteRead> readWithRevision(String path) async {
    final contents = await read(path);
    if (contents == null) return RemoteRead.absent;
    return RemoteRead(contents: contents, revision: fingerprint(contents));
  }

  @override
  Future<void> write(String path, String contents) async {
    final file = File(_resolve(path));
    await file.parent.create(recursive: true);
    // Write beside the target first so a crash, or a sync client picking the
    // file up mid-write, can never see a half-written snapshot. The temp name
    // is unique so two writers in one folder can't trip over each other.
    final temp = File('${file.path}.${_tempSuffix()}.tmp');
    try {
      await temp.writeAsString(contents, flush: true);
      await _replace(temp, file.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  /// Replacing a file can fail transiently when something else holds it open —
  /// another writer mid-rename, a sync client, or a virus scanner on Windows.
  static Future<void> _replace(File temp, String target) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.rename(target);
        return;
      } on FileSystemException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
      }
    }
  }

  @override
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  }) async {
    // A plain folder has no atomic compare-and-swap, so re-check immediately
    // before writing. That shrinks the window to the rename itself rather than
    // spanning the whole read-merge-write cycle.
    final current = await readWithRevision(path);
    if (current.revision != expectedRevision) return false;
    await write(path, contents);
    return true;
  }

  @override
  Future<void> delete(String path) async {
    final file = File(_resolve(path));
    if (await file.exists()) await file.delete();
  }

  static int _counter = 0;

  static String _tempSuffix() {
    _counter = (_counter + 1) & 0xFFFF;
    final now = DateTime.now().microsecondsSinceEpoch;
    return '$now-${pid.toRadixString(16)}-$_counter';
  }

  @override
  void close() {}
}

/// WebDAV backend — Nextcloud, ownCloud, and most NAS boxes speak this.
class WebDavRemote implements SyncRemote {
  WebDavRemote({
    required this.baseUrl,
    this.username,
    this.password,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String? username;
  final String? password;
  final http.Client _client;

  @override
  String get label => baseUrl.toString();

  Uri _uri(String path) {
    final segments = [
      ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ];
    return baseUrl.replace(pathSegments: segments);
  }

  Map<String, String> get _headers {
    final user = username;
    if (user == null || user.isEmpty) return const {};
    final token = base64Encode(utf8.encode('$user:${password ?? ''}'));
    return {'authorization': 'Basic $token'};
  }

  @override
  Future<void> probe({bool requireWrite = true}) async {
    final response = await _send('PROPFIND', _uri(''), depth: '0');
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SyncRemoteException('WebDAV rejected these credentials.');
    }
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'WebDAV returned ${response.statusCode} for $baseUrl',
      );
    }
  }

  @override
  Future<List<String>> list(String dir) async {
    final response = await _send('PROPFIND', _uri(dir), depth: '1');
    if (response.statusCode == 404) return const [];
    if (response.statusCode >= 400) {
      throw SyncRemoteException('WebDAV list failed (${response.statusCode})');
    }
    return _parseHrefNames(response.body, dir);
  }

  @override
  Future<String?> read(String path) async => (await readWithRevision(path)).contents;

  @override
  Future<RemoteRead> readWithRevision(String path) async {
    final response = await _client.get(_uri(path), headers: _headers);
    if (response.statusCode == 404) return RemoteRead.absent;
    if (response.statusCode >= 400) {
      throw SyncRemoteException('WebDAV read failed (${response.statusCode})');
    }
    final contents = utf8.decode(response.bodyBytes);
    // Servers that don't send an ETag still get a usable revision, it just
    // can't be enforced server-side.
    return RemoteRead(
      contents: contents,
      revision: _etag(response) ?? fingerprint(contents),
    );
  }

  @override
  Future<void> write(String path, String contents) =>
      _put(path, contents, conditional: null);

  @override
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  }) async {
    // If-Match pins the write to the version we merged from; If-None-Match: *
    // means "only if nobody has created this yet".
    final conditional = expectedRevision == null
        ? {'if-none-match': '*'}
        : {'if-match': _quote(expectedRevision)};
    return _put(path, contents, conditional: conditional);
  }

  Future<bool> _put(
    String path,
    String contents, {
    required Map<String, String>? conditional,
  }) async {
    await _ensureCollections(path);
    final response = await _client.put(
      _uri(path),
      headers: {
        ..._headers,
        'content-type': 'application/json; charset=utf-8',
        ...?conditional,
      },
      body: utf8.encode(contents),
    );
    // 412 is the server telling us another device got there first.
    if (response.statusCode == 412 || response.statusCode == 409) return false;
    if (response.statusCode >= 400) {
      throw SyncRemoteException('WebDAV write failed (${response.statusCode})');
    }
    return true;
  }

  static String? _etag(http.Response response) {
    final raw = response.headers['etag']?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  static String _quote(String revision) {
    if (revision.startsWith('"') ||
        revision.startsWith('W/') ||
        revision == '*') {
      return revision;
    }
    return '"$revision"';
  }

  @override
  Future<void> delete(String path) async {
    final response = await _client.delete(_uri(path), headers: _headers);
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw SyncRemoteException('WebDAV delete failed (${response.statusCode})');
    }
  }

  /// MKCOL every parent folder; servers won't PUT into a missing collection.
  Future<void> _ensureCollections(String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return;
    var prefix = '';
    for (final part in parts.take(parts.length - 1)) {
      prefix = prefix.isEmpty ? part : '$prefix/$part';
      final response = await _send('MKCOL', _uri(prefix));
      // 405 / 301 mean it already exists, which is the common case.
      if (response.statusCode >= 400 &&
          response.statusCode != 405 &&
          response.statusCode != 301) {
        throw SyncRemoteException(
          'WebDAV could not create $prefix (${response.statusCode})',
        );
      }
    }
  }

  Future<http.Response> _send(String method, Uri uri, {String? depth}) async {
    final request = http.Request(method, uri)
      ..headers.addAll({
        ..._headers,
        'depth': ?depth,
      });
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  static List<String> _parseHrefNames(String body, String dir) {
    final names = <String>[];
    try {
      final document = XmlDocument.parse(body);
      for (final href in document.findAllElements(
        'href',
        namespace: '*',
      )) {
        final value = href.innerText.trim();
        if (value.isEmpty || value.endsWith('/')) continue;
        final decoded = Uri.decodeFull(value);
        final segments = decoded.split('/').where((s) => s.isNotEmpty);
        if (segments.isNotEmpty) names.add(segments.last);
      }
    } catch (_) {
      throw SyncRemoteException('WebDAV returned an unreadable listing.');
    }
    return names;
  }

  @override
  void close() => _client.close();
}
