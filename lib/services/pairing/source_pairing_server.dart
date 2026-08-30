import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/sync_settings.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/profile_provider.dart';
import 'package:javp/services/deep_links/javp_pair_link.dart';
import 'package:javp/services/deep_links/javp_source_link.dart';
import 'package:javp/services/pairing/pairing_sync_settings.dart';
import 'package:javp/services/storage/sources_export.dart';

/// Result of a successful phone → TV source add.
class SourcePairingAdded {
  const SourcePairingAdded({
    required this.name,
    required this.type,
  });

  final String name;
  final IptvSourceType type;
}

/// Result of a successful bulk sources import over LAN pairing.
class SourcePairingImported {
  const SourcePairingImported({
    required this.count,
    required this.mode,
    this.syncApply,
    this.profileName,
  });

  final int count;
  final SourcesImportMode mode;
  final PairingSyncApplyResult? syncApply;

  /// Set when the guest asked to create a new profile on the host.
  final String? profileName;
}

/// LAN pairing surface — instance methods so fakes can stub adds/imports
/// (extension methods on [LibraryProvider] are not overridable in tests).
abstract class PairingLibraryHost {
  List<IptvSource> get sources;

  Future<SourcesExportDocument> buildSourcesExport({
    required SourcesSecretsMode secretsMode,
    String? passphrase,
    Set<String>? sourceIds,
  });

  Future<int> importSourcesDocument({
    required SourcesExportDocument document,
    required SourcesImportMode mode,
    String? passphrase,
  });

  Future<void> addM3uSource({
    required String name,
    required String playlistUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled,
    bool acceptXtreamPlaylistExport,
  });

  Future<void> addXmltvSource({
    required String name,
    required String epgUrl,
  });

  Future<void> addXtreamSource({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
    String? alternateServerUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled,
    bool vodEnabled,
  });

  Future<void> addStalkerSource({
    required String name,
    required String portalUrl,
    required String macAddress,
    String? serial,
  });

  Future<void> addCustomCatalogSource({
    required String name,
    required String catalogUrl,
    String? authToken,
    String? vastUrl,
  });

  Future<void> addMediaServerSource({
    required String name,
    required IptvSourceType type,
    required String serverUrl,
    String? username,
    String? password,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled,
  });
}

/// Forwards pairing calls to [LibraryProvider] extension methods.
class LibraryProviderPairingHost implements PairingLibraryHost {
  LibraryProviderPairingHost(this._library);

  final LibraryProvider _library;

  @override
  List<IptvSource> get sources => _library.sources;

  @override
  Future<SourcesExportDocument> buildSourcesExport({
    required SourcesSecretsMode secretsMode,
    String? passphrase,
    Set<String>? sourceIds,
  }) =>
      _library.buildSourcesExport(
        secretsMode: secretsMode,
        passphrase: passphrase,
        sourceIds: sourceIds,
      );

  @override
  Future<int> importSourcesDocument({
    required SourcesExportDocument document,
    required SourcesImportMode mode,
    String? passphrase,
  }) =>
      _library.importSourcesDocument(
        document: document,
        mode: mode,
        passphrase: passphrase,
      );

  @override
  Future<void> addM3uSource({
    required String name,
    required String playlistUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    bool acceptXtreamPlaylistExport = false,
  }) =>
      _library.addM3uSource(
        name: name,
        playlistUrl: playlistUrl,
        epgUrl: epgUrl,
        epgSourceId: epgSourceId,
        epgEnabled: epgEnabled,
        acceptXtreamPlaylistExport: acceptXtreamPlaylistExport,
      );

  @override
  Future<void> addXmltvSource({
    required String name,
    required String epgUrl,
  }) =>
      _library.addXmltvSource(name: name, epgUrl: epgUrl);

  @override
  Future<void> addXtreamSource({
    required String name,
    required String serverUrl,
    required String username,
    required String password,
    String? alternateServerUrl,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
    bool vodEnabled = true,
  }) =>
      _library.addXtreamSource(
        name: name,
        serverUrl: serverUrl,
        username: username,
        password: password,
        alternateServerUrl: alternateServerUrl,
        epgUrl: epgUrl,
        epgSourceId: epgSourceId,
        epgEnabled: epgEnabled,
        vodEnabled: vodEnabled,
      );

  @override
  Future<void> addStalkerSource({
    required String name,
    required String portalUrl,
    required String macAddress,
    String? serial,
  }) =>
      _library.addStalkerSource(
        name: name,
        portalUrl: portalUrl,
        macAddress: macAddress,
        serial: serial,
      );

  @override
  Future<void> addCustomCatalogSource({
    required String name,
    required String catalogUrl,
    String? authToken,
    String? vastUrl,
  }) =>
      _library.addCustomCatalogSource(
        name: name,
        catalogUrl: catalogUrl,
        authToken: authToken,
        vastUrl: vastUrl,
      );

  @override
  Future<void> addMediaServerSource({
    required String name,
    required IptvSourceType type,
    required String serverUrl,
    String? username,
    String? password,
    String? epgUrl,
    String? epgSourceId,
    bool epgEnabled = true,
  }) =>
      _library.addMediaServerSource(
        name: name,
        type: type,
        serverUrl: serverUrl,
        username: username,
        password: password,
        epgUrl: epgUrl,
        epgSourceId: epgSourceId,
        epgEnabled: epgEnabled,
      );
}

/// LAN HTTP server: phone browser / JAVP app → [PairingLibraryHost].
///
/// Host (TV/desktop) shows a QR (`javp://pair`) and an optional browser form.
/// Guests can add one source, push a full [SourcesExportDocument], or pull
/// sources from this device — all token-gated, LAN-only, no cloud account.
class SourcePairingServer {
  SourcePairingServer({
    PairingLibraryHost? library,
    LibraryProvider? libraryProvider,
    required this.profiles,
    this.port = 19287,
  }) : library = library ??
            LibraryProviderPairingHost(
              libraryProvider ??
                  (throw ArgumentError(
                    'library or libraryProvider is required',
                  )),
            );

  final PairingLibraryHost library;
  final ProfileProvider profiles;
  final int port;

  HttpServer? _server;
  String? _token;
  String? _pin;
  DateTime? _tokenExpiresAt;
  String? _lanIp;
  int _boundPort = 19287;
  final _addedController = StreamController<SourcePairingAdded>.broadcast();
  final _importedController =
      StreamController<SourcePairingImported>.broadcast();

  Stream<SourcePairingAdded> get onSourceAdded => _addedController.stream;
  Stream<SourcePairingImported> get onSourcesImported =>
      _importedController.stream;

  bool get isRunning => _server != null;
  String? get token => _token;
  /// Short human-friendly PIN (same session as [token]).
  String? get pin => _pin;
  String? get lanIp => _lanIp;
  int get boundPort => _boundPort;

  /// Emulator / AVD private IP — not reachable from a phone on Wi‑Fi.
  bool get isEmulatorNetwork => looksLikeEmulatorIpv4(_lanIp);

  /// Optional host override for QR / URL (e.g. PC LAN IP via dart-define).
  String? hostOverride;

  /// Browser form URL (fallback when the guest has no JAVP install).
  Uri? get pairingUri {
    final host = effectiveHost;
    if (_server == null || _token == null || host == null) return null;
    return Uri(
      scheme: 'http',
      host: host,
      port: _boundPort,
      path: '/pair',
      queryParameters: {'t': _token},
    );
  }

  /// App deep link encoded in the QR — opens JAVP on the phone for push/pull.
  Uri? get appPairUri {
    final host = effectiveHost;
    if (_server == null || _token == null || host == null) return null;
    return buildJavpPairLink(
      host: host,
      port: _boundPort,
      token: _token!,
      pin: _pin,
    );
  }

  /// HTTPS App Link / landing page when the guest has no JAVP install.
  Uri? get httpsPairUri {
    final host = effectiveHost;
    if (_server == null || _token == null || host == null) return null;
    return buildJavpPairHttpsLink(
      host: host,
      port: _boundPort,
      token: _token!,
      pin: _pin,
    );
  }

  /// Preferred payload for the on-screen QR (HTTPS first → browser fallback).
  Uri? get qrPayloadUri => httpsPairUri ?? appPairUri ?? pairingUri;

  /// Host shown in QR / copyable URL.
  String? get effectiveHost {
    final override = hostOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    if (isEmulatorNetwork) return '127.0.0.1';
    return _lanIp;
  }

  /// `adb forward` command for emulator → host browser / phone via PC IP.
  String? get adbForwardCommand {
    if (!isEmulatorNetwork && hostOverride == null) return null;
    return 'adb forward tcp:$_boundPort tcp:$_boundPort';
  }

  static bool looksLikeEmulatorIpv4(String? ip) {
    if (ip == null || ip.isEmpty) return false;
    return ip.startsWith('10.0.2.') || ip.startsWith('10.0.3.');
  }

  Future<void> start() async {
    await stop();
    _lanIp = await _resolveLanIpv4();
    _rotateToken();
    HttpServer? server;
    Object? lastError;
    for (var p = port; p < port + 20; p++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _boundPort = p;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (server == null) {
      throw StateError('Could not bind pairing port: $lastError');
    }
    _server = server;
    server.listen(_handleRequest, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    _pin = null;
    _tokenExpiresAt = null;
    await server?.close(force: true);
  }

  void rotateToken() => _rotateToken();

  void _rotateToken() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    _token = base64UrlEncode(bytes).replaceAll('=', '');
    _pin = _generatePin(6);
    _tokenExpiresAt = DateTime.now().add(const Duration(minutes: 15));
  }

  static String _generatePin(int length) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(
      length,
      (_) => alphabet[rnd.nextInt(alphabet.length)],
    ).join();
  }

  bool _sessionLive() {
    if (_token == null || _tokenExpiresAt == null) return false;
    return DateTime.now().isBefore(_tokenExpiresAt!);
  }

  bool _tokenValid(String? candidate) {
    if (candidate == null || candidate.isEmpty) return false;
    if (!_sessionLive()) return false;
    if (candidate == _token) return true;
    final pin = _pin;
    if (pin != null && candidate.toUpperCase() == pin) return true;
    return false;
  }

  String? _extractToken(HttpRequest request, Map<String, dynamic>? json) {
    return json?['token'] as String? ??
        request.uri.queryParameters['t'] ??
        request.uri.queryParameters['c'] ??
        request.headers.value('x-javp-token');
  }

  /// Bare `http://host:port/` for typing on a phone (PIN unlock on the page).
  Uri? get pairingHomeUri {
    final host = effectiveHost;
    if (_server == null || host == null) return null;
    return Uri(scheme: 'http', host: host, port: _boundPort, path: '/');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && (path == '/' || path == '/pair')) {
        final t = request.uri.queryParameters['t'] ??
            request.uri.queryParameters['c'];
        if (_tokenValid(t)) {
          await _write(
            request,
            HttpStatus.ok,
            _formHtml(appPairUri: appPairUri),
            contentType: ContentType.html,
          );
          return;
        }
        if (_sessionLive()) {
          final wrongCode = t != null && t.isNotEmpty;
          await _write(
            request,
            HttpStatus.ok,
            _unlockHtml(invalidCode: wrongCode),
            contentType: ContentType.html,
          );
          return;
        }
        await _write(
          request,
          HttpStatus.ok,
          _inactiveHtml(),
          contentType: ContentType.html,
        );
        return;
      }

      if (request.method == 'POST' && path == '/api/session') {
        await _handleAuthedJson(request, (json) async {
          await _writeJson(request, HttpStatus.ok, {
            'ok': true,
            'sourceCount': library.sources.length,
            'sources': [
              for (final s in library.sources)
                {
                  'id': s.id,
                  'name': s.name,
                  'type': s.type.name,
                },
            ],
            ...pairingSyncSessionSummary(profiles.syncSettings),
            'capabilities': ['add', 'import', 'export', 'syncSettings'],
          });
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/add') {
        await _handleAuthedJson(request, (json) async {
          try {
            final added = await applyPairingPayload(library, json);
            _addedController.add(added);
            await _writeJson(request, HttpStatus.ok, {
              'ok': true,
              'name': added.name,
              'type': added.type.name,
            });
          } catch (e) {
            await _writeJson(request, HttpStatus.badRequest, {
              'ok': false,
              'error': e.toString(),
            });
          }
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/import') {
        await _handleAuthedJson(request, (json) async {
          try {
            final imported = await applyPairingImport(
              library,
              json,
              profiles: profiles,
            );
            _importedController.add(imported);
            await _writeJson(request, HttpStatus.ok, {
              'ok': true,
              'count': imported.count,
              'mode': imported.mode.name,
              if (imported.profileName != null)
                'profileName': imported.profileName,
              if (imported.syncApply != null) ...{
                'syncApplied': imported.syncApply!.applied,
                'syncNeedsFolder': imported.syncApply!.needsLocalFolderSetup,
                'syncBackend': imported.syncApply!.backend.name,
              },
            });
          } catch (e) {
            await _writeJson(request, HttpStatus.badRequest, {
              'ok': false,
              'error': e.toString(),
            });
          }
        });
        return;
      }

      if (request.method == 'POST' && path == '/api/export') {
        await _handleAuthedJson(request, (json) async {
          try {
            Set<String>? sourceIds;
            final rawIds = json['sourceIds'];
            if (rawIds is List) {
              sourceIds = {
                for (final id in rawIds)
                  if (id != null && '$id'.trim().isNotEmpty) '$id'.trim(),
              };
              if (sourceIds.isEmpty) {
                await _writeJson(request, HttpStatus.badRequest, {
                  'ok': false,
                  'error': 'No sources selected',
                });
                return;
              }
            }
            // LAN session only — plaintext so the guest can restore passwords.
            final doc = await library.buildSourcesExport(
              secretsMode: SourcesSecretsMode.plaintext,
              sourceIds: sourceIds,
            );
            final includeSync = json['includeSyncSettings'] == true;
            await _writeJson(request, HttpStatus.ok, {
              'ok': true,
              'count': doc.sources.length,
              'document': doc.toJson(),
              if (includeSync && profiles.syncSettings.isConfigured)
                'syncSettings': profiles.syncSettings.toJson(),
            });
          } catch (e) {
            await _writeJson(request, HttpStatus.badRequest, {
              'ok': false,
              'error': e.toString(),
            });
          }
        });
        return;
      }

      await _write(request, HttpStatus.notFound, 'Not found');
    } catch (_) {
      try {
        await _write(request, HttpStatus.internalServerError, 'Error');
      } catch (_) {}
    }
  }

  Future<void> _handleAuthedJson(
    HttpRequest request,
    Future<void> Function(Map<String, dynamic> json) onOk,
  ) async {
    final body = await utf8.decoder.bind(request).join();
    Map<String, dynamic> json;
    try {
      json = body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      await _writeJson(request, HttpStatus.badRequest, {
        'ok': false,
        'error': 'Invalid JSON',
      });
      return;
    }
    final t = _extractToken(request, json);
    if (!_tokenValid(t)) {
      await _writeJson(request, HttpStatus.unauthorized, {
        'ok': false,
        'error': 'Invalid or expired token',
      });
      return;
    }
    await onOk(json);
  }

  Future<void> _write(
    HttpRequest request,
    int status,
    String body, {
    ContentType? contentType,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType =
        contentType ?? ContentType.text;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  static Future<String?> _resolveLanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('virtual') ||
            name.contains('vethernet') ||
            name.contains('docker') ||
            name.contains('vbox')) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          return ip;
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    unawaited(stop());
    unawaited(_addedController.close());
    unawaited(_importedController.close());
  }
}

/// Bulk import from a pairing POST body (`document` + `mode`).
///
/// Optional `syncSettings` applies profile sync config on [profiles] (LAN only).
Future<SourcePairingImported> applyPairingImport(
  PairingLibraryHost library,
  Map<String, dynamic> json, {
  ProfileProvider? profiles,
}) async {
  final modeName = (json['mode'] as String?)?.trim().toLowerCase() ?? 'merge';
  final mode = SourcesImportMode.values.asNameMap()[modeName] ??
      (modeName == 'replace' ? SourcesImportMode.replace : SourcesImportMode.merge);

  Map<String, dynamic>? docJson;
  final rawDoc = json['document'];
  if (rawDoc is Map) {
    docJson = Map<String, dynamic>.from(rawDoc);
  } else if (json['kind'] == SourcesExportDocument.kind) {
    docJson = Map<String, dynamic>.from(json)
      ..remove('token')
      ..remove('mode')
      ..remove('syncSettings');
  }
  if (docJson == null) {
    throw ArgumentError('Sources document required');
  }
  final document = SourcesExportDocument.tryFromJson(docJson);
  if (document == null) {
    throw ArgumentError('Invalid javp-sources document');
  }
  final passphrase = (json['passphrase'] as String?)?.trim();
  final rawSync = json['syncSettings'];
  final hostProfiles = profiles;

  if (json['addAsNewProfile'] == true && hostProfiles != null) {
    final imported = await document.materialize(
      passphrase: (passphrase == null || passphrase.isEmpty) ? null : passphrase,
    );
    final name = (json['profileName'] as String?)?.trim();
    final profile = await hostProfiles.createProfileWithSources(
      name: (name == null || name.isEmpty) ? 'Profile' : name,
      sources: imported,
    );
    PairingSyncApplyResult? syncApply;
    if (rawSync is Map) {
      final settings =
          SyncSettings.fromJson(Map<String, dynamic>.from(rawSync));
      syncApply = await applyPairingSyncSettings(
        profiles: hostProfiles,
        incoming: settings,
        profileId: profile.id,
      );
    }
    return SourcePairingImported(
      count: imported.length,
      mode: mode,
      syncApply: syncApply,
      profileName: profile.name,
    );
  }

  final count = await library.importSourcesDocument(
    document: document,
    mode: mode,
    passphrase: (passphrase == null || passphrase.isEmpty) ? null : passphrase,
  );

  PairingSyncApplyResult? syncApply;
  if (profiles != null && rawSync is Map) {
    final settings = SyncSettings.fromJson(Map<String, dynamic>.from(rawSync));
    syncApply = await applyPairingSyncSettings(
      profiles: profiles,
      incoming: settings,
    );
  }

  return SourcePairingImported(
    count: count,
    mode: mode,
    syncApply: syncApply,
  );
}

/// Maps phone form JSON → [LibraryProvider.add*] (also used by unit tests).
Future<SourcePairingAdded> applyPairingPayload(
  PairingLibraryHost library,
  Map<String, dynamic> json,
) async {
  final parsed = parsePairingPayload(json);
  switch (parsed.type) {
    case IptvSourceType.m3u:
      await library.addM3uSource(
        name: parsed.name,
        playlistUrl: parsed.url!,
        epgUrl: parsed.epgUrl,
      );
    case IptvSourceType.xmltv:
      await library.addXmltvSource(
        name: parsed.name,
        epgUrl: parsed.epgUrl ?? parsed.url!,
      );
    case IptvSourceType.xtream:
      await library.addXtreamSource(
        name: parsed.name,
        serverUrl: parsed.serverUrl!,
        username: parsed.username ?? '',
        password: parsed.password ?? '',
        alternateServerUrl: parsed.alternateServerUrl,
      );
    case IptvSourceType.stalker:
      await library.addStalkerSource(
        name: parsed.name,
        portalUrl: parsed.serverUrl!,
        macAddress: parsed.username ?? '',
        serial: parsed.password,
      );
    case IptvSourceType.custom:
      await library.addCustomCatalogSource(
        name: parsed.name,
        catalogUrl: parsed.url!,
      );
    case IptvSourceType.jellyfin:
    case IptvSourceType.emby:
    case IptvSourceType.plex:
      await library.addMediaServerSource(
        name: parsed.name,
        type: parsed.type,
        serverUrl: parsed.serverUrl!,
        username: parsed.username,
        password: parsed.password,
      );
  }
  return SourcePairingAdded(name: parsed.name, type: parsed.type);
}

class ParsedPairingPayload {
  const ParsedPairingPayload({
    required this.type,
    required this.name,
    this.url,
    this.epgUrl,
    this.serverUrl,
    this.username,
    this.password,
    this.alternateServerUrl,
  });

  final IptvSourceType type;
  final String name;
  final String? url;
  final String? epgUrl;
  final String? serverUrl;
  final String? username;
  final String? password;
  final String? alternateServerUrl;
}

/// Pure validation/normalization for pairing form JSON.
///
/// Accepts either typed fields (`type`/`url`/…) or a `javpLink` / `link`
/// containing a `javp://add?…` quicklink (or the same query as `/add?…`).
ParsedPairingPayload parsePairingPayload(Map<String, dynamic> json) {
  final linkRaw = (json['javpLink'] as String?)?.trim() ??
      (json['link'] as String?)?.trim() ??
      '';
  if (linkRaw.isNotEmpty) {
    final uri = Uri.tryParse(linkRaw);
    if (uri == null) {
      throw ArgumentError('Invalid javp://add link');
    }
    final req = parseJavpSourceAddLink(uri);
    if (req == null) {
      throw ArgumentError('Not a valid javp://add quicklink');
    }
    final overrideName = (json['name'] as String?)?.trim();
    return ParsedPairingPayload(
      type: req.type,
      name: (overrideName != null && overrideName.isNotEmpty)
          ? overrideName
          : (req.name ??
              (req.type == IptvSourceType.custom
                  ? 'Custom catalog'
                  : req.type == IptvSourceType.xtream
                      ? 'Xtream Source'
                      : req.type == IptvSourceType.stalker
                          ? 'Stalker Source'
                          : 'M3U Source')),
      url: req.type == IptvSourceType.xtream ||
              req.type == IptvSourceType.stalker
          ? null
          : req.url,
      epgUrl: req.epgUrl,
      serverUrl: req.type == IptvSourceType.xtream ||
              req.type == IptvSourceType.stalker
          ? req.url
          : null,
      username: req.username,
      password: req.password,
      alternateServerUrl: req.alternateServerUrl,
    );
  }

  final typeRaw = (json['type'] as String?)?.trim().toLowerCase() ?? '';
  final name = (json['name'] as String?)?.trim() ?? '';

  switch (typeRaw) {
    case 'm3u':
      final url = (json['url'] as String?)?.trim() ?? '';
      if (url.isEmpty) throw ArgumentError('Playlist URL required');
      return ParsedPairingPayload(
        type: IptvSourceType.m3u,
        name: name.isEmpty ? 'M3U Source' : name,
        url: url,
        epgUrl: (json['epgUrl'] as String?)?.trim(),
      );
    case 'xtream':
      final server = (json['serverUrl'] as String?)?.trim() ?? '';
      final user = (json['username'] as String?)?.trim() ?? '';
      final pass = json['password'] as String? ?? '';
      if (server.isEmpty || user.isEmpty) {
        throw ArgumentError('Server URL and username required');
      }
      return ParsedPairingPayload(
        type: IptvSourceType.xtream,
        name: name.isEmpty ? 'Xtream Source' : name,
        serverUrl: server,
        username: user,
        password: pass,
        alternateServerUrl: (json['alternateServerUrl'] as String?)?.trim(),
      );
    case 'stalker':
    case 'ministra':
      final portal = (json['serverUrl'] as String?)?.trim() ?? '';
      final mac = (json['username'] as String?)?.trim() ?? '';
      if (portal.isEmpty || mac.isEmpty) {
        throw ArgumentError('Portal URL and MAC address required');
      }
      return ParsedPairingPayload(
        type: IptvSourceType.stalker,
        name: name.isEmpty ? 'Stalker Source' : name,
        serverUrl: portal,
        username: mac,
        password: (json['password'] as String?)?.trim(),
      );
    case 'custom':
      final url = (json['url'] as String?)?.trim() ?? '';
      if (url.isEmpty) throw ArgumentError('Catalog URL required');
      return ParsedPairingPayload(
        type: IptvSourceType.custom,
        name: name.isEmpty ? 'Custom catalog' : name,
        url: url,
      );
    case 'jellyfin':
    case 'emby':
    case 'plex':
      final server = (json['serverUrl'] as String?)?.trim() ?? '';
      if (server.isEmpty) throw ArgumentError('Server URL required');
      final type = switch (typeRaw) {
        'jellyfin' => IptvSourceType.jellyfin,
        'emby' => IptvSourceType.emby,
        _ => IptvSourceType.plex,
      };
      return ParsedPairingPayload(
        type: type,
        name: name.isEmpty ? typeRaw : name,
        serverUrl: server,
        username: (json['username'] as String?)?.trim(),
        password: json['password'] as String?,
      );
    default:
      throw ArgumentError('Unknown source type: $typeRaw');
  }
}

String _htmlPage(String title, String body) => '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>$title · JAVP</title>
<style>
  :root { color-scheme: dark; --bg:#0B0C0F; --card:#14161C; --accent:#E11D48; --text:#F4F5F7; --muted:#9AA3B2; }
  * { box-sizing: border-box; }
  body { margin:0; font-family: system-ui, sans-serif; background:var(--bg); color:var(--text); padding:24px; }
  h1 { font-size:1.4rem; margin:0 0 8px; }
  p { color:var(--muted); }
  .card { background:var(--card); border-radius:16px; padding:20px; max-width:440px; margin:0 auto; }
  label { display:block; font-size:.85rem; margin:14px 0 6px; color:var(--muted); }
  input, select, textarea { width:100%; padding:12px 14px; border-radius:10px; border:1px solid #2A2F3A; background:#1C1F28; color:var(--text); font-size:16px; }
  textarea { min-height:96px; resize:vertical; font-family:ui-monospace, monospace; font-size:13px; }
  form button, #addLink, #importJson, #exportJson, #useLink { width:100%; margin-top:20px; padding:14px; border:0; border-radius:12px; background:var(--accent); color:#fff; font-weight:700; font-size:16px; }
  #exportJson, #useLink { background:#1C1F28; border:1px solid var(--accent); }
  a.app { display:block; text-align:center; margin:12px 0 4px; padding:14px; border-radius:12px; background:#1C1F28; border:1px solid var(--accent); color:#fff; font-weight:700; text-decoration:none; }
  .row { display:none; }
  .row.on { display:block; }
  .ok { color:#22C55E; }
  .err { color:#F87171; }
  .pin { letter-spacing:.2em; text-transform:uppercase; font-size:1.25rem; text-align:center; }
  .src-list { list-style:none; padding:0; margin:8px 0 0; }
  .src-list li { padding:8px 0; border-bottom:1px solid #2A2F3A; font-size:.9rem; }
  .src-list li span { color:var(--muted); font-size:.8rem; margin-left:6px; }
  .divider { display:flex; align-items:center; gap:12px; color:var(--muted); font-size:.8rem; margin:18px 0 8px; }
  .divider::before, .divider::after { content:""; flex:1; height:1px; background:#2A2F3A; }
</style>
</head>
<body>
<div class="card">
  <h1>$title</h1>
  $body
</div>
</body>
</html>
''';

String _inactiveHtml() => _htmlPage(
      'Pairing not active',
      '''
  <p>Open <strong>Sources → Pair device</strong> on the TV or desktop, then come back to this address or scan the QR.</p>
  <p>The on-screen code lasts about 15 minutes.</p>
''',
    );

String _unlockHtml({required bool invalidCode}) {
  final err = invalidCode
      ? '<p class="err">That code or link is invalid. Check the TV screen and try again.</p>'
      : '';
  return _htmlPage(
    'Enter pairing code',
    '''
  <p>Same Wi‑Fi as the TV. Enter the <strong>6-character code</strong> shown next to the QR, or paste a pairing link.</p>
  $err
  <form method="get" action="/pair" id="pinForm">
    <label for="c">Pairing code</label>
    <input class="pin" id="c" name="c" maxlength="12" autocomplete="one-time-code"
      autocapitalize="characters" spellcheck="false" autofocus
      placeholder="ABC123" inputmode="text"/>
    <button type="submit">Unlock</button>
  </form>
  <div class="divider">or paste a link</div>
  <label for="pairLink">QR / pairing link</label>
  <input id="pairLink" inputmode="url" autocomplete="off"
    placeholder="javp://pair?… or https://javp.app/pair?…"/>
  <button type="button" id="useLink">Use link</button>
  <p style="margin-top:16px;font-size:.85rem">Tip: scan the QR on the TV with your camera — if JAVP is not installed, choose <em>Continue in browser</em>.</p>
  <script>
  (function () {
    var form = document.getElementById('pinForm');
    var pin = document.getElementById('c');
    form.addEventListener('submit', function () {
      pin.value = (pin.value || '').trim().toUpperCase();
    });
    document.getElementById('useLink').addEventListener('click', function () {
      var raw = (document.getElementById('pairLink').value || '').trim();
      if (!raw) return;
      try {
        var u = new URL(raw);
        var t = u.searchParams.get('t') || u.searchParams.get('token') || '';
        var c = u.searchParams.get('c') || u.searchParams.get('pin') || u.searchParams.get('code') || '';
        if (t) { location.href = '/pair?t=' + encodeURIComponent(t); return; }
        if (c) { location.href = '/pair?c=' + encodeURIComponent(c); return; }
      } catch (_) {}
      // Bare PIN pasted into the link field.
      if (/^[A-Za-z0-9]{4,12}\$/.test(raw)) {
        location.href = '/pair?c=' + encodeURIComponent(raw.toUpperCase());
        return;
      }
      alert('Could not read a pairing code from that link.');
    });
  })();
  </script>
''',
  );
}

String _formHtml({Uri? appPairUri}) {
  final openApp = appPairUri == null
      ? ''
      : '''
  <p><a class="app" href="${appPairUri.toString()}">Open in JAVP</a> to push or pull sources from the app on this phone.</p>
  <p style="color:var(--muted);font-size:.85rem;margin:0 0 8px">No JAVP yet? Stay here and use the form below — same Wi‑Fi only.</p>
''';
  final tryOpen = appPairUri == null
      ? ''
      : '''
  <script>
  (function () {
    var link = ${jsonEncode(appPairUri.toString())};
    var frame = document.createElement("iframe");
    frame.style.display = "none";
    frame.src = link;
    document.body.appendChild(frame);
    setTimeout(function () { try { frame.remove(); } catch (_) {} }, 1500);
  })();
  </script>
''';
  return _htmlPage(
      'Pair with this device',
      '''
  <p>Same Wi‑Fi. Credentials stay on your LAN — no account.</p>
  $openApp
  <div class="divider">sources on this device</div>
  <ul class="src-list" id="srcList"><li style="color:var(--muted)">Loading…</li></ul>
  <button type="button" id="exportJson">Download sources JSON</button>
  <div class="divider">add one source</div>
  <label>Paste a <code>javp://add</code> link</label>
  <input id="javpLink" inputmode="url" placeholder="javp://add?type=custom&amp;url=…"/>
  <button type="button" id="addLink">Add from link</button>
  <div class="divider">or fill in manually</div>
  <form id="f">
    <label>Type</label>
    <select id="type" name="type">
      <option value="m3u">M3U playlist</option>
      <option value="xtream">Xtream Codes</option>
      <option value="stalker">Stalker / Ministra</option>
      <option value="custom">Custom JSON catalog</option>
      <option value="jellyfin">Jellyfin</option>
      <option value="emby">Emby</option>
      <option value="plex">Plex (URL + token)</option>
    </select>
    <label>Display name (optional)</label>
    <input id="name" name="name" autocomplete="off"/>
    <div class="row on" data-for="m3u custom">
      <label>URL</label>
      <input id="url" name="url" inputmode="url" placeholder="https://…"/>
    </div>
    <div class="row" data-for="m3u">
      <label>EPG URL (optional)</label>
      <input id="epgUrl" name="epgUrl" inputmode="url"/>
    </div>
    <div class="row" data-for="xtream jellyfin emby plex stalker ministra">
      <label>Server URL</label>
      <input id="serverUrl" name="serverUrl" inputmode="url" placeholder="http://192.168.…"/>
    </div>
    <div class="row" data-for="xtream jellyfin emby stalker ministra">
      <label id="userLabel">Username</label>
      <input id="username" name="username" autocomplete="username"/>
    </div>
    <div class="row" data-for="xtream jellyfin emby plex stalker ministra">
      <label id="passLabel">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password"/>
    </div>
    <div class="row" data-for="xtream">
      <label>Alternate server (optional)</label>
      <input id="alternateServerUrl" name="alternateServerUrl" inputmode="url"/>
    </div>
    <button type="submit">Add &amp; sync</button>
  </form>
  <div class="divider">or paste sources JSON</div>
  <label><code>javp-sources.json</code> export</label>
  <textarea id="sourcesJson" rows="4" placeholder='{"kind":"javp-sources",…}'></textarea>
  <label>Import mode</label>
  <select id="importMode">
    <option value="merge">Merge (add / update)</option>
    <option value="replace">Replace all sources</option>
  </select>
  <button type="button" id="importJson">Import sources</button>
  <p id="msg"></p>
  <script>
  const token = new URLSearchParams(location.search).get('t')
    || new URLSearchParams(location.search).get('c') || '';
  const typeEl = document.getElementById('type');
  const passLabel = document.getElementById('passLabel');
  const userLabel = document.getElementById('userLabel');
  const msg = document.getElementById('msg');
  const srcList = document.getElementById('srcList');
  function typeLabel(t) {
    switch (t) {
      case 'm3u': return 'M3U';
      case 'xtream': return 'Xtream';
      case 'stalker': return 'Stalker';
      case 'custom': return 'Catalog';
      case 'jellyfin': return 'Jellyfin';
      case 'emby': return 'Emby';
      case 'plex': return 'Plex';
      case 'xmltv': return 'XMLTV';
      default: return t || '';
    }
  }
  async function refreshSources() {
    try {
      const res = await fetch('/api/session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
      });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || 'Session failed');
      const sources = data.sources || [];
      if (!sources.length) {
        srcList.innerHTML = '<li style="color:var(--muted)">No sources on this device yet.</li>';
        return;
      }
      srcList.innerHTML = sources.map(function (s) {
        return '<li>' + (s.name || s.id) + '<span>' + typeLabel(s.type) + '</span></li>';
      }).join('');
    } catch (err) {
      srcList.innerHTML = '<li class="err">' + String(err.message || err) + '</li>';
    }
  }
  refreshSources();
  function syncRows() {
    const t = typeEl.value;
    document.querySelectorAll('.row').forEach(row => {
      const kinds = (row.getAttribute('data-for') || '').split(/\\s+/);
      row.classList.toggle('on', kinds.includes(t));
    });
    passLabel.textContent = t === 'plex' ? 'X-Plex-Token' : (t === 'stalker' || t === 'ministra') ? 'Serial (optional)' : 'Password';
    userLabel.textContent = (t === 'stalker' || t === 'ministra') ? 'MAC address' : 'Username';
  }
  typeEl.addEventListener('change', syncRows);
  syncRows();
  async function postAdd(payload) {
    msg.textContent = 'Sending…';
    msg.className = '';
    const res = await fetch('/api/add', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, ...payload }),
    });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || 'Failed');
    msg.className = 'ok';
    msg.textContent = 'Added "' + data.name + '" — saved on this device.';
    refreshSources();
  }
  document.getElementById('addLink').addEventListener('click', async () => {
    try { await postAdd({ javpLink: document.getElementById('javpLink').value }); }
    catch (err) { msg.className = 'err'; msg.textContent = String(err.message || err); }
  });
  document.getElementById('f').addEventListener('submit', async (e) => {
    e.preventDefault();
    const t = typeEl.value;
    const payload = { type: t, name: document.getElementById('name').value };
    if (t === 'm3u' || t === 'custom') payload.url = document.getElementById('url').value;
    if (t === 'm3u') payload.epgUrl = document.getElementById('epgUrl').value;
    if (t === 'xtream' || t === 'jellyfin' || t === 'emby' || t === 'plex' || t === 'stalker' || t === 'ministra') {
      payload.serverUrl = document.getElementById('serverUrl').value;
      payload.password = document.getElementById('password').value;
    }
    if (t === 'xtream' || t === 'jellyfin' || t === 'emby' || t === 'stalker' || t === 'ministra') {
      payload.username = document.getElementById('username').value;
    }
    if (t === 'xtream') payload.alternateServerUrl = document.getElementById('alternateServerUrl').value;
    try { await postAdd(payload); }
    catch (err) { msg.className = 'err'; msg.textContent = String(err.message || err); }
  });
  document.getElementById('exportJson').addEventListener('click', async () => {
    msg.textContent = 'Exporting…';
    msg.className = '';
    try {
      const res = await fetch('/api/export', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
      });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || 'Failed');
      const blob = new Blob([JSON.stringify(data.document, null, 2)], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'javp-sources.json';
      a.click();
      URL.revokeObjectURL(a.href);
      msg.className = 'ok';
      msg.textContent = 'Downloaded ' + (data.count || 0) + ' sources.';
    } catch (err) {
      msg.className = 'err';
      msg.textContent = String(err.message || err);
    }
  });
  document.getElementById('importJson').addEventListener('click', async () => {
    msg.textContent = 'Importing…';
    msg.className = '';
    try {
      const sourcesDoc = JSON.parse(document.getElementById('sourcesJson').value);
      const res = await fetch('/api/import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token,
          mode: document.getElementById('importMode').value,
          document: sourcesDoc,
        }),
      });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || 'Failed');
      msg.className = 'ok';
      msg.textContent = 'Imported ' + data.count + ' sources (' + data.mode + ').';
      refreshSources();
    } catch (err) {
      msg.className = 'err';
      msg.textContent = String(err.message || err);
    }
  });
  </script>
  $tryOpen
''',
    );
}
