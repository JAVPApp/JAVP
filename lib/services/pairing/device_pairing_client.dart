import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:javp/models/sync_settings.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';
import 'package:javp/services/pairing/pairing_sync_settings.dart';
import 'package:javp/services/storage/sources_export.dart';

/// Lightweight source row from a pairing host session (no secrets).
class DevicePairSourceInfo {
  const DevicePairSourceInfo({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;

  /// [IptvSourceType] name (`m3u`, `xtream`, …).
  final String type;

  static DevicePairSourceInfo? tryFromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? '';
    final type = (json['type'] as String?)?.trim() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    return DevicePairSourceInfo(
      id: id,
      name: name,
      type: type.isEmpty ? 'custom' : type,
    );
  }
}

/// Result of a pairing session handshake.
class DevicePairSession {
  const DevicePairSession({
    required this.sourceCount,
    required this.sources,
    this.syncConfigured = false,
    this.syncBackend = SyncBackend.none,
  });

  final int sourceCount;
  final List<DevicePairSourceInfo> sources;

  /// Host has a configured sync backend (no secrets in session).
  final bool syncConfigured;
  final SyncBackend syncBackend;
}

/// Result of pushing a sources document to a pairing host.
class DevicePairPushResult {
  const DevicePairPushResult({
    required this.count,
    required this.mode,
    this.syncApply,
    this.profileName,
  });

  final int count;
  final SourcesImportMode mode;
  final PairingSyncApplyResult? syncApply;

  /// Host created a new profile with this name.
  final String? profileName;
}

/// Result of pulling sources from a pairing host.
class DevicePairPullResult {
  const DevicePairPullResult({
    required this.document,
    required this.sourceCount,
    this.syncSettings,
  });

  final SourcesExportDocument document;
  final int sourceCount;

  /// Present when the guest asked for sync settings and the host had them.
  final SyncSettings? syncSettings;
}

/// Phone/desktop HTTP client for a short-lived LAN pairing session.
///
/// Talks to [SourcePairingServer] on the other device. Never logs secrets.
class DevicePairingClient {
  DevicePairingClient({
    required this.request,
    HttpClient? httpClient,
  }) : _client = httpClient ?? HttpClient();

  final JavpPairRequest request;
  final HttpClient _client;

  Uri _api(String path) => request.httpOrigin.replace(path: path);

  Future<DevicePairSession> fetchSession() async {
    final res = await _postJson('/api/session', {});
    if (res['ok'] != true) {
      throw StateError(res['error']?.toString() ?? 'Session check failed');
    }
    final count = (res['sourceCount'] as num?)?.toInt() ?? 0;
    final sources = <DevicePairSourceInfo>[];
    final raw = res['sources'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final info = DevicePairSourceInfo.tryFromJson(
          Map<String, dynamic>.from(entry),
        );
        if (info != null) sources.add(info);
      }
    }
    return DevicePairSession(
      sourceCount: count > 0 ? count : sources.length,
      sources: sources,
      syncConfigured: res['syncConfigured'] == true,
      syncBackend: SyncBackendX.fromName(res['syncBackend'] as String?),
    );
  }

  /// Push local sources to the host (TV/desktop). Secrets travel over LAN only.
  Future<DevicePairPushResult> pushSources({
    required SourcesExportDocument document,
    required SourcesImportMode mode,
    SyncSettings? syncSettings,
    bool addAsNewProfile = false,
    String? profileName,
  }) async {
    final body = <String, dynamic>{
      'mode': mode.name,
      'document': document.toJson(),
    };
    if (syncSettings != null) {
      body['syncSettings'] = syncSettings.toJson();
    }
    if (addAsNewProfile) {
      body['addAsNewProfile'] = true;
      final name = profileName?.trim();
      if (name != null && name.isNotEmpty) body['profileName'] = name;
    }
    final res = await _postJson('/api/import', body);
    if (res['ok'] != true) {
      throw StateError(res['error']?.toString() ?? 'Import failed');
    }
    final count = (res['count'] as num?)?.toInt() ?? document.sources.length;
    final modeName = res['mode'] as String? ?? mode.name;
    final parsed = SourcesImportMode.values.asNameMap()[modeName] ?? mode;
    PairingSyncApplyResult? syncApply;
    if (res.containsKey('syncApplied') || res.containsKey('syncNeedsFolder')) {
      syncApply = PairingSyncApplyResult(
        applied: res['syncApplied'] == true,
        needsLocalFolderSetup: res['syncNeedsFolder'] == true,
        backend: SyncBackendX.fromName(res['syncBackend'] as String?),
      );
    }
    return DevicePairPushResult(
      count: count,
      mode: parsed,
      syncApply: syncApply,
      profileName: (res['profileName'] as String?)?.trim(),
    );
  }

  /// Pull sources from the host (includes plaintext secrets for the session).
  ///
  /// When [sourceIds] is set, only those host sources are returned.
  /// When [includeSyncSettings] is true, host may return [syncSettings].
  Future<DevicePairPullResult> pullSources({
    Set<String>? sourceIds,
    bool includeSyncSettings = false,
  }) async {
    final body = <String, dynamic>{};
    if (sourceIds != null) {
      body['sourceIds'] = sourceIds.toList(growable: false);
    }
    if (includeSyncSettings) {
      body['includeSyncSettings'] = true;
    }
    final res = await _postJson('/api/export', body);
    if (res['ok'] != true) {
      throw StateError(res['error']?.toString() ?? 'Export failed');
    }
    final raw = res['document'];
    if (raw is! Map) {
      throw StateError('Host returned no sources document');
    }
    final doc = SourcesExportDocument.tryFromJson(
      Map<String, dynamic>.from(raw),
    );
    if (doc == null) {
      throw StateError('Host returned an invalid sources document');
    }
    SyncSettings? syncSettings;
    final rawSync = res['syncSettings'];
    if (rawSync is Map) {
      syncSettings = SyncSettings.fromJson(Map<String, dynamic>.from(rawSync));
    }
    return DevicePairPullResult(
      document: doc,
      sourceCount: doc.sources.length,
      syncSettings: syncSettings,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final req = await _client.postUrl(_api(path));
    req.headers.contentType = ContentType.json;
    req.headers.set('Cache-Control', 'no-store');
    final payload = <String, dynamic>{
      'token': request.authSecret,
      ...body,
    };
    req.write(jsonEncode(payload));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decoder.bind(res).join();
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw StateError(
        res.statusCode == 401
            ? 'Invalid or expired pairing code'
            : 'Bad response from device (${res.statusCode})',
      );
    }
    if (res.statusCode == 401) {
      throw StateError(
        json['error']?.toString() ?? 'Invalid or expired pairing code',
      );
    }
    if (res.statusCode >= 400) {
      throw StateError(
        json['error']?.toString() ?? 'Request failed (${res.statusCode})',
      );
    }
    return json;
  }

  void close() => _client.close(force: true);
}
