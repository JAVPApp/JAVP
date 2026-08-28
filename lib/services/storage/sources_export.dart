import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:javp/models/iptv_source.dart';

/// How secrets (passwords / Plex tokens / catalog bearer tokens) are carried
/// in a [SourcesExportDocument].
enum SourcesSecretsMode {
  /// Metadata only — user must re-enter passwords after import.
  omitted,

  /// Secrets encrypted with a user passphrase (AES-256-GCM + PBKDF2).
  encrypted,

  /// Secrets in plaintext inside each source. Only after explicit confirmation.
  plaintext,
}

/// Portable `javp-sources.json` document for migrating library sources without
/// Google Drive / folder sync.
///
/// Drive profile sync already embeds source passwords in its private snapshot;
/// this file is meant for share sheets and USB sticks, so secrets default to
/// omitted or passphrase-encrypted.
class SourcesExportDocument {
  const SourcesExportDocument({
    required this.exportedAt,
    required this.secretsMode,
    required this.sources,
    this.secrets,
    this.schema = currentSchema,
  });

  static const currentSchema = 1;
  static const kind = 'javp-sources';
  static const defaultFileName = 'javp-sources.json';

  static const _kdfName = 'pbkdf2-hmac-sha256';
  static const _defaultIterations = 120000;

  final int schema;
  final DateTime exportedAt;
  final SourcesSecretsMode secretsMode;
  final List<IptvSource> sources;

  /// Present when [secretsMode] is [SourcesSecretsMode.encrypted].
  final SourcesExportSecrets? secrets;

  bool get hasEncryptedSecrets =>
      secretsMode == SourcesSecretsMode.encrypted && secrets != null;

  int get secretCount => sources.where((s) {
    final p = s.password;
    final plex = s.plexAccountToken;
    return (p != null && p.isNotEmpty) || (plex != null && plex.isNotEmpty);
  }).length;

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'kind': kind,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'secretsMode': secretsMode.name,
    'sources': [for (final s in sources) _sourceJson(s, secretsMode)],
    if (secrets != null) 'secrets': secrets!.toJson(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static SourcesExportDocument? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return tryFromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static SourcesExportDocument? tryFromJson(Map<String, dynamic> json) {
    if (json['kind'] != kind) return null;
    final schema = (json['schema'] as num?)?.toInt() ?? currentSchema;
    if (schema > currentSchema) return null;
    final exportedAt = DateTime.tryParse(
      json['exportedAt'] as String? ?? '',
    )?.toUtc();
    if (exportedAt == null) return null;
    final modeName = json['secretsMode'] as String? ?? 'omitted';
    final mode =
        SourcesSecretsMode.values.asNameMap()[modeName] ??
        SourcesSecretsMode.omitted;
    final rawSources = json['sources'];
    if (rawSources is! List) return null;
    final sources = <IptvSource>[];
    for (final entry in rawSources) {
      if (entry is! Map) continue;
      final source = IptvSource.tryFromJson(Map<String, dynamic>.from(entry));
      if (source != null) sources.add(source);
    }
    SourcesExportSecrets? secrets;
    final rawSecrets = json['secrets'];
    if (rawSecrets is Map) {
      secrets = SourcesExportSecrets.tryFromJson(
        Map<String, dynamic>.from(rawSecrets),
      );
    }
    if (mode == SourcesSecretsMode.encrypted && secrets == null) {
      return null;
    }
    return SourcesExportDocument(
      schema: schema,
      exportedAt: exportedAt,
      secretsMode: mode,
      sources: sources,
      secrets: secrets,
    );
  }

  /// Build an export from hydrated sources (passwords already loaded).
  static Future<SourcesExportDocument> create({
    required List<IptvSource> sources,
    required SourcesSecretsMode secretsMode,
    String? passphrase,
    DateTime? exportedAt,
  }) async {
    final at = (exportedAt ?? DateTime.now()).toUtc();
    final hasSecrets = sources.any((s) {
      final p = s.password;
      final plex = s.plexAccountToken;
      return (p != null && p.isNotEmpty) || (plex != null && plex.isNotEmpty);
    });

    if (secretsMode == SourcesSecretsMode.encrypted) {
      if (!hasSecrets) {
        return SourcesExportDocument(
          exportedAt: at,
          secretsMode: SourcesSecretsMode.omitted,
          sources: sources,
        );
      }
      final pass = passphrase?.trim() ?? '';
      if (pass.isEmpty) {
        throw ArgumentError('Passphrase required to encrypt source secrets');
      }
      final secrets = await SourcesExportSecrets.encrypt({
        for (final s in sources) ...{
          if (s.password != null && s.password!.isNotEmpty) s.id: s.password!,
          if (s.plexAccountToken != null && s.plexAccountToken!.isNotEmpty)
            '${s.id}::plexAccount': s.plexAccountToken!,
        },
      }, pass);
      return SourcesExportDocument(
        exportedAt: at,
        secretsMode: SourcesSecretsMode.encrypted,
        sources: sources,
        secrets: secrets,
      );
    }

    if (secretsMode == SourcesSecretsMode.plaintext) {
      return SourcesExportDocument(
        exportedAt: at,
        secretsMode: SourcesSecretsMode.plaintext,
        sources: sources,
      );
    }

    return SourcesExportDocument(
      exportedAt: at,
      secretsMode: SourcesSecretsMode.omitted,
      sources: sources,
    );
  }

  /// Resolve passwords for import (decrypt when needed).
  Future<List<IptvSource>> materialize({String? passphrase}) async {
    switch (secretsMode) {
      case SourcesSecretsMode.plaintext:
      case SourcesSecretsMode.omitted:
        return List<IptvSource>.from(sources);
      case SourcesSecretsMode.encrypted:
        final pack = secrets;
        if (pack == null) return List<IptvSource>.from(sources);
        final pass = passphrase?.trim() ?? '';
        if (pass.isEmpty) {
          throw const SourcesExportPassphraseException('Passphrase required');
        }
        final map = await pack.decrypt(pass);
        return [for (final s in sources) _applyImportedSecrets(s, map)];
    }
  }

  static Map<String, dynamic> _sourceJson(
    IptvSource source,
    SourcesSecretsMode mode,
  ) {
    final json = source.toJson();
    if (mode != SourcesSecretsMode.plaintext) {
      json.remove('password');
      json.remove('plexAccountToken');
    }
    return json;
  }

  static IptvSource _applyImportedSecrets(
    IptvSource source,
    Map<String, String> map,
  ) {
    var next = source;
    final password = map[source.id];
    if (password != null && password.isNotEmpty) {
      next = next.copyWith(password: password);
    }
    final plex = map['${source.id}::plexAccount'];
    if (plex != null && plex.isNotEmpty) {
      next = next.copyWith(plexAccountToken: plex);
    }
    return next;
  }
}

class SourcesExportSecrets {
  const SourcesExportSecrets({
    required this.salt,
    required this.nonce,
    required this.ciphertext,
    this.kdf = SourcesExportDocument._kdfName,
    this.iterations = SourcesExportDocument._defaultIterations,
  });

  final String kdf;
  final int iterations;
  final List<int> salt;
  final List<int> nonce;
  final List<int> ciphertext;

  Map<String, dynamic> toJson() => {
    'kdf': kdf,
    'iterations': iterations,
    'salt': base64Encode(salt),
    'nonce': base64Encode(nonce),
    'ciphertext': base64Encode(ciphertext),
  };

  static SourcesExportSecrets? tryFromJson(Map<String, dynamic> json) {
    try {
      final salt = base64Decode(json['salt'] as String);
      final nonce = base64Decode(json['nonce'] as String);
      final ciphertext = base64Decode(json['ciphertext'] as String);
      return SourcesExportSecrets(
        kdf: json['kdf'] as String? ?? SourcesExportDocument._kdfName,
        iterations:
            (json['iterations'] as num?)?.toInt() ??
            SourcesExportDocument._defaultIterations,
        salt: salt,
        nonce: nonce,
        ciphertext: ciphertext,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<SourcesExportSecrets> encrypt(
    Map<String, String> secretsBySourceId,
    String passphrase,
  ) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final key = await _deriveKey(passphrase, salt);
    final algorithm = AesGcm.with256bits();
    final clear = utf8.encode(jsonEncode(secretsBySourceId));
    final box = await algorithm.encrypt(clear, secretKey: key);
    // cipherText || mac — nonce stored separately for readability.
    return SourcesExportSecrets(
      salt: salt,
      nonce: box.nonce,
      ciphertext: [...box.cipherText, ...box.mac.bytes],
    );
  }

  Future<Map<String, String>> decrypt(String passphrase) async {
    if (kdf != SourcesExportDocument._kdfName) {
      throw const SourcesExportPassphraseException('Unsupported KDF');
    }
    final key = await _deriveKey(passphrase, salt, iterations: iterations);
    final algorithm = AesGcm.with256bits();
    try {
      const macLength = 16;
      if (ciphertext.length <= macLength) {
        throw const SourcesExportPassphraseException('Invalid secrets payload');
      }
      final clear = await algorithm.decrypt(
        SecretBox(
          ciphertext.sublist(0, ciphertext.length - macLength),
          nonce: nonce,
          mac: Mac(ciphertext.sublist(ciphertext.length - macLength)),
        ),
        secretKey: key,
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map) {
        throw const SourcesExportPassphraseException('Invalid secrets payload');
      }
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } on SecretBoxAuthenticationError {
      throw const SourcesExportPassphraseException('Wrong passphrase');
    } catch (e) {
      if (e is SourcesExportPassphraseException) rethrow;
      throw const SourcesExportPassphraseException('Wrong passphrase');
    }
  }

  static Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt, {
    int iterations = SourcesExportDocument._defaultIterations,
  }) {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return kdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: Uint8List.fromList(salt),
    );
  }
}

class SourcesExportPassphraseException implements Exception {
  const SourcesExportPassphraseException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How an imported source list combines with the local list.
enum SourcesImportMode {
  /// Drop local sources and use the file as-is.
  replace,

  /// Keep local sources; add file sources whose ids are new. Matching ids are
  /// updated from the file (credentials included when present).
  merge,
}

/// Counted impact of applying [incomingIds] onto [existingIds] with [mode].
///
/// Uses id overlap plus [IptvSource.dedupeKey] when previewing merge impact
/// is not possible from ids alone — keep id-based preview for UI counts.
class SourcesImportPreview {
  const SourcesImportPreview({
    required this.mode,
    required this.added,
    required this.updated,
    required this.removed,
    required this.kept,
    required this.incoming,
    required this.existing,
  });

  final SourcesImportMode mode;
  final int added;
  final int updated;

  /// Existing ids dropped by replace (always 0 for merge).
  final int removed;

  /// Existing ids left untouched (merge only; 0 for replace).
  final int kept;

  final int incoming;
  final int existing;
}

/// Preview merge/replace impact from id sets (no source payloads required).
SourcesImportPreview previewSourcesImport({
  required Iterable<String> existingIds,
  required Iterable<String> incomingIds,
  required SourcesImportMode mode,
}) {
  final existing = existingIds.toSet();
  final incoming = incomingIds.toSet();
  final overlap = existing.intersection(incoming);
  final added = incoming.difference(existing).length;
  final updated = overlap.length;
  if (mode == SourcesImportMode.replace) {
    return SourcesImportPreview(
      mode: mode,
      added: added,
      updated: updated,
      removed: existing.difference(incoming).length,
      kept: 0,
      incoming: incoming.length,
      existing: existing.length,
    );
  }
  return SourcesImportPreview(
    mode: mode,
    added: added,
    updated: updated,
    removed: 0,
    kept: existing.difference(incoming).length,
    incoming: incoming.length,
    existing: existing.length,
  );
}

/// Apply [imported] onto [existing] according to [mode].
///
/// Merge matches by id first, then by [IptvSource.dedupeKey] (same panel /
/// playlist / account) so a second push does not clone sources under new UUIDs.
/// Matched duplicates keep the local id so live/VOD caches stay attached.
List<IptvSource> mergeImportedSources({
  required List<IptvSource> existing,
  required List<IptvSource> imported,
  required SourcesImportMode mode,
}) {
  if (mode == SourcesImportMode.replace) {
    return List<IptvSource>.from(imported);
  }
  final byId = <String, IptvSource>{for (final s in existing) s.id: s};
  final keyToId = <String, String>{
    for (final s in existing)
      if (s.dedupeKey.isNotEmpty) s.dedupeKey: s.id,
  };
  for (final incoming in imported) {
    final existingById = byId[incoming.id];
    if (existingById != null) {
      byId[incoming.id] = _mergeImportedOntoLocal(existingById, incoming);
      final key = byId[incoming.id]!.dedupeKey;
      if (key.isNotEmpty) keyToId[key] = incoming.id;
      continue;
    }
    final key = incoming.dedupeKey;
    final localId = key.isEmpty ? null : keyToId[key];
    if (localId != null) {
      final local = byId[localId]!;
      byId[localId] = _mergeImportedOntoLocal(local, incoming);
      continue;
    }
    byId[incoming.id] = incoming;
    if (key.isNotEmpty) keyToId[key] = incoming.id;
  }
  // Preserve local order for survivors, then append brand-new ids in file order.
  final seen = <String>{};
  final out = <IptvSource>[];
  for (final s in existing) {
    final next = byId[s.id];
    if (next != null) {
      out.add(next);
      seen.add(s.id);
    }
  }
  for (final s in imported) {
    final key = s.dedupeKey;
    final resolvedId = byId.containsKey(s.id)
        ? s.id
        : (key.isNotEmpty ? keyToId[key] : null);
    if (resolvedId == null) continue;
    if (seen.add(resolvedId)) out.add(byId[resolvedId]!);
  }
  return out;
}

/// Prefer incoming credentials/config; keep local id + createdAt + sync counts
/// when the import has zeros (fresh export before a sync on the guest).
IptvSource _mergeImportedOntoLocal(IptvSource local, IptvSource incoming) {
  return incoming.copyWith(
    id: local.id,
    createdAt: local.createdAt,
    channelCount: incoming.channelCount > 0
        ? incoming.channelCount
        : local.channelCount,
    vodCount: incoming.vodCount > 0 ? incoming.vodCount : local.vodCount,
    lastSyncedAt: incoming.lastSyncedAt ?? local.lastSyncedAt,
    lastVodSyncedAt: incoming.lastVodSyncedAt ?? local.lastVodSyncedAt,
  );
}
