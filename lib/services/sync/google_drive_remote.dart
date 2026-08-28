import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/services/sync/google_drive_auth.dart';
import 'package:javp/services/sync/sync_remote.dart';

/// Google Drive backend using [drive.file] scope.
///
/// Snapshots live under a normal Drive folder tree (`javp/profiles/…`) that
/// this app creates. Visible in the user's Drive, shared across devices that
/// sign in with the same Google account and OAuth client.
class GoogleDriveRemote implements SyncRemote {
  GoogleDriveRemote({
    required this.accessToken,
    required this.refreshToken,
    required this.clientId,
    this.tokenExpiry,
    this.clientSecret = '',
    this.onTokensUpdated,
    http.Client? client,
    GoogleDriveAuth? auth,
  }) : _ownsClient = client == null {
    _client = client ?? http.Client();
    _auth = auth ?? GoogleDriveAuth(httpClient: _client);
  }

  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';
  static const _folderMime = 'application/vnd.google-apps.folder';
  /// My Drive root — used with drive.file (appDataFolder needs drive.appdata).
  static const _root = 'root';

  String accessToken;
  String refreshToken;
  DateTime? tokenExpiry;
  final String clientId;
  final String clientSecret;
  final void Function(GoogleOAuthTokens tokens)? onTokensUpdated;

  late final http.Client _client;
  final bool _ownsClient;
  late final GoogleDriveAuth _auth;

  /// path segment → Drive folder id
  final Map<String, String> _folderIds = {};

  /// full relative path → Drive file id
  final Map<String, String> _fileIds = {};

  @override
  String get label => 'Google Drive';

  Future<void> _ensureFreshToken({bool force = false}) async {
    final expiry = tokenExpiry;
    final stillGood = !force &&
        expiry != null &&
        expiry.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 2)));
    // Prefer the access token we already have. Silent Play Services refresh only
    // when forced (after a 401) or when we have no token left to try.
    if (stillGood && accessToken.isNotEmpty) return;
    if (!force && accessToken.isNotEmpty) return;
    if (refreshToken.isEmpty) {
      throw SyncRemoteException('Google Drive session expired. Sign in again.');
    }
    try {
      // After a 401, drop the dead token from Play Services caches so the next
      // authorizationForScopes call does not hand back the same one.
      if (force &&
          refreshToken == playServicesRefreshMarker &&
          accessToken.isNotEmpty) {
        await _auth.clearCachedAccessToken(accessToken);
      }
      final tokens = await _auth.refresh(
        clientId: clientId,
        refreshToken: refreshToken,
        clientSecret: clientSecret,
      );
      accessToken = tokens.accessToken;
      refreshToken = tokens.refreshToken;
      tokenExpiry = tokens.expiresAt;
      onTokensUpdated?.call(tokens);
    } on StateError catch (e) {
      // Silent Google Sign-In refresh failed — surface as sync error, never UI.
      throw SyncRemoteException(e.message);
    }
  }

  Map<String, String> get _authHeaders => {
        'authorization': 'Bearer $accessToken',
      };

  static const _requestTimeout = Duration(seconds: 20);

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    await _ensureFreshToken();
    Future<http.Response> once() async {
      final request = http.Request(method, uri)
        ..headers.addAll({
          ..._authHeaders,
          ...?headers,
        });
      if (body is String) {
        request.body = body;
      } else if (body is List<int>) {
        request.bodyBytes = body;
      }
      final streamed =
          await _client.send(request).timeout(_requestTimeout);
      return http.Response.fromStream(streamed).timeout(_requestTimeout);
    }

    try {
      var response = await once();
      if (response.statusCode != 401) return response;

      // Force a refresh and retry once.
      await _ensureFreshToken(force: true);
      response = await once();
      return response;
    } on TimeoutException {
      throw SyncRemoteException('Google Drive timed out. Try again.');
    }
  }

  @override
  Future<void> probe({bool requireWrite = true}) async {
    // Confirm the token can talk to Drive (about.get is light and always allowed).
    final response = await _send(
      'GET',
      Uri.parse('$_api/about').replace(queryParameters: {
        'fields': 'user(displayName)',
      }),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SyncRemoteException('Google Drive rejected these credentials.');
    }
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive returned ${response.statusCode}',
      );
    }
  }

  @override
  Future<List<String>> list(String dir) async {
    final folderId = await _folderIdFor(dir, create: false);
    if (folderId == null) return const [];
    final response = await _send(
      'GET',
      Uri.parse('$_api/files').replace(queryParameters: {
        'q': "'$folderId' in parents and trashed=false",
        'fields': 'files(id,name,mimeType)',
        'pageSize': '1000',
        'spaces': 'drive',
      }),
    );
    if (response.statusCode == 404) return const [];
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive list failed (${response.statusCode})',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return const [];
    final files = decoded['files'];
    if (files is! List) return const [];
    final names = <String>[];
    for (final raw in files) {
      if (raw is! Map) continue;
      final mime = raw['mimeType'] as String? ?? '';
      if (mime == _folderMime) continue;
      final name = raw['name'] as String? ?? '';
      if (name.isNotEmpty) names.add(name);
    }
    return names;
  }

  @override
  Future<String?> read(String path) async =>
      (await readWithRevision(path)).contents;

  @override
  Future<RemoteRead> readWithRevision(String path) async {
    final fileId = await _fileIdFor(path);
    if (fileId == null) return RemoteRead.absent;
    // Metadata first so the revision token is something we can re-check
    // cheaply in [writeIfUnchanged] without downloading the whole snapshot.
    final meta = await _send(
      'GET',
      Uri.parse('$_api/files/$fileId').replace(queryParameters: {
        'fields': 'md5Checksum,version',
      }),
    );
    if (meta.statusCode == 404) {
      _fileIds.remove(path);
      return RemoteRead.absent;
    }
    if (meta.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive read failed (${meta.statusCode})',
      );
    }
    final response = await _send(
      'GET',
      Uri.parse('$_api/files/$fileId').replace(queryParameters: {
        'alt': 'media',
      }),
    );
    if (response.statusCode == 404) {
      _fileIds.remove(path);
      return RemoteRead.absent;
    }
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive read failed (${response.statusCode})',
      );
    }
    final contents = utf8.decode(response.bodyBytes);
    return RemoteRead(
      contents: contents,
      revision: _revisionFromMeta(meta.body) ?? fingerprint(contents),
    );
  }

  @override
  Future<void> write(String path, String contents) =>
      _overwrite(path, contents);

  @override
  Future<bool> writeIfUnchanged(
    String path,
    String contents, {
    required String? expectedRevision,
  }) async {
    // Drive v3 ignores If-Match, so re-check with a cheap metadata GET before
    // writing. That narrows the race without re-downloading the snapshot.
    final current = await _revisionFor(path);
    if (current != expectedRevision) return false;
    await _overwrite(path, contents);
    return true;
  }

  /// Content revision for [path], or null when the file is absent.
  Future<String?> _revisionFor(String path) async {
    final fileId = await _fileIdFor(path);
    if (fileId == null) return null;
    final meta = await _send(
      'GET',
      Uri.parse('$_api/files/$fileId').replace(queryParameters: {
        'fields': 'md5Checksum,version',
      }),
    );
    if (meta.statusCode == 404) {
      _fileIds.remove(path);
      return null;
    }
    if (meta.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive read failed (${meta.statusCode})',
      );
    }
    return _revisionFromMeta(meta.body);
  }

  static String? _revisionFromMeta(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final md5 = (decoded['md5Checksum'] as String?)?.trim();
      if (md5 != null && md5.isNotEmpty) return md5;
      final version = decoded['version'];
      if (version != null) return 'v$version';
    } catch (_) {}
    return null;
  }

  /// Overwrites [path], creating it — or re-creating it, if another device
  /// deleted it under us — when there is nothing there to patch.
  Future<void> _overwrite(String path, String contents) async {
    final fileId = await _fileIdFor(path);
    if (fileId == null) {
      await _createFile(path, contents);
      return;
    }
    final response = await _uploadMedia(fileId, contents);
    if (response.statusCode == 404) {
      _fileIds.remove(path);
      await _createFile(path, contents);
      return;
    }
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive write failed (${response.statusCode})',
      );
    }
  }

  @override
  Future<void> delete(String path) async {
    final fileId = await _fileIdFor(path);
    if (fileId == null) return;
    final response = await _send('DELETE', Uri.parse('$_api/files/$fileId'));
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw SyncRemoteException(
        'Google Drive delete failed (${response.statusCode})',
      );
    }
    _fileIds.remove(path);
  }

  Future<http.Response> _uploadMedia(String fileId, String contents) {
    return _send(
      'PATCH',
      Uri.parse('$_upload/files/$fileId').replace(queryParameters: {
        'uploadType': 'media',
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
      body: utf8.encode(contents),
    );
  }

  Future<void> _createFile(String path, String contents) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      throw SyncRemoteException('Cannot write an empty Google Drive path');
    }
    final fileName = parts.last;
    final parentPath = parts.length == 1
        ? ''
        : parts.sublist(0, parts.length - 1).join('/');
    final parentId = await _folderIdFor(parentPath, create: true);
    if (parentId == null) {
      throw SyncRemoteException('Could not create Google Drive folders');
    }

    final metadata = jsonEncode({
      'name': fileName,
      'parents': [parentId],
      'mimeType': 'application/json',
    });
    final boundary = 'javp_${DateTime.now().microsecondsSinceEpoch}';
    final body = utf8.encode(
      '--$boundary\r\n'
      'Content-Type: application/json; charset=UTF-8\r\n\r\n'
      '$metadata\r\n'
      '--$boundary\r\n'
      'Content-Type: application/json; charset=UTF-8\r\n\r\n'
      '$contents\r\n'
      '--$boundary--',
    );
    final response = await _send(
      'POST',
      Uri.parse('$_upload/files').replace(queryParameters: {
        'uploadType': 'multipart',
      }),
      headers: {
        'content-type': 'multipart/related; boundary=$boundary',
      },
      body: body,
    );
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive create failed (${response.statusCode})',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      final id = decoded['id'] as String?;
      if (id != null && id.isNotEmpty) _fileIds[path] = id;
    }
  }

  Future<String?> _fileIdFor(String path) async {
    final cached = _fileIds[path];
    if (cached != null) return cached;
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final fileName = parts.last;
    final parentPath = parts.length == 1
        ? ''
        : parts.sublist(0, parts.length - 1).join('/');
    final parentId = await _folderIdFor(parentPath, create: false);
    if (parentId == null) return null;
    final found = await _findChild(parentId, fileName, folder: false);
    if (found != null) _fileIds[path] = found;
    return found;
  }

  Future<String?> _folderIdFor(String dir, {required bool create}) async {
    final normalized = dir.split('/').where((s) => s.isNotEmpty).join('/');
    if (normalized.isEmpty) return _root;

    final cached = _folderIds[normalized];
    if (cached != null) return cached;

    final parts = normalized.split('/');
    var parentId = _root;
    var prefix = '';
    for (final part in parts) {
      prefix = prefix.isEmpty ? part : '$prefix/$part';
      final existing = _folderIds[prefix];
      if (existing != null) {
        parentId = existing;
        continue;
      }
      var id = await _findChild(parentId, part, folder: true);
      if (id == null && create) {
        id = await _createFolder(parentId, part);
      }
      if (id == null) return null;
      _folderIds[prefix] = id;
      parentId = id;
    }
    return parentId;
  }

  Future<String?> _findChild(
    String parentId,
    String name, {
    required bool folder,
  }) async {
    final escaped = name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final mimeClause = folder
        ? "mimeType='$_folderMime'"
        : "mimeType!='$_folderMime'";
    final response = await _send(
      'GET',
      Uri.parse('$_api/files').replace(queryParameters: {
        'q': "'$parentId' in parents and name='$escaped' and "
            '$mimeClause and trashed=false',
        'fields': 'files(id,name,createdTime)',
        // Drive allows duplicate names; two devices setting up together will
        // create two `javp` folders. Prefer the oldest so every device lands
        // on the same one. Sorted here rather than via orderBy — some API
        // clients reject orderBy without extra params and we'd silently miss
        // the folder and create yet another copy.
        'pageSize': '10',
        'spaces': 'drive',
      }),
    );
    if (response.statusCode >= 400) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final files = decoded['files'];
    if (files is! List || files.isEmpty) return null;
    Map? oldest;
    DateTime? oldestAt;
    for (final raw in files) {
      if (raw is! Map) continue;
      final created = DateTime.tryParse('${raw['createdTime'] ?? ''}');
      if (oldest == null ||
          (created != null && (oldestAt == null || created.isBefore(oldestAt)))) {
        oldest = raw;
        oldestAt = created;
      }
    }
    if (oldest == null) return null;
    return oldest['id'] as String?;
  }

  Future<String?> _createFolder(String parentId, String name) async {
    final response = await _send(
      'POST',
      Uri.parse('$_api/files'),
      headers: {'content-type': 'application/json; charset=utf-8'},
      body: jsonEncode({
        'name': name,
        'mimeType': _folderMime,
        'parents': [parentId],
      }),
    );
    if (response.statusCode >= 400) {
      throw SyncRemoteException(
        'Google Drive could not create folder $name '
        '(${response.statusCode})',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    return decoded['id'] as String?;
  }

  @override
  void close() {
    // Auth shares [_client] and does not own it.
    if (_ownsClient) _client.close();
  }
}
