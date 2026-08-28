import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/models/profile.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// User-visible app files that used to sit in the OS Documents folder.
///
/// Desktop `getApplicationDocumentsDirectory()` is `~/Documents` (or
/// `Documents` on Windows), so `live_channels.db` and friends were landing
/// next to the user's real documents. Everything we write there now lives
/// in a `JAVP` subfolder, with a one-shot move of known legacy names.
class AppDocuments {
  AppDocuments._();

  static const folderName = 'JAVP';

  static const _legacyFiles = [
    'live_channels.db',
    'vod_catalog.db',
    'epg_programs.db',
    'media_catalog.json',
    'vod_stream_cache.json',
    'live_channel_index.json',
    'home_shelf_snapshot.json',
  ];

  static const _legacyDirs = ['downloads', 'profiles'];

  static const _sqliteSidecars = ['-wal', '-shm', '-journal'];

  static Future<void>? _gate;
  static String? _lastDocumentsPath;
  static String? _lastJavpPath;

  /// `{Documents}/JAVP`, creating it and migrating leftover root files.
  static Future<Directory> directory() async {
    if (kIsWeb) {
      throw UnsupportedError('App documents directory is unavailable on web');
    }
    final docs = await getApplicationDocumentsDirectory();
    final javp = Directory(p.join(docs.path, folderName));

    Future<void> prepare() async {
      await javp.create(recursive: true);
      await migrateLegacy(from: docs, to: javp);
      _lastDocumentsPath = docs.path;
      _lastJavpPath = javp.path;
    }

    final existing = _gate;
    if (existing != null) {
      await existing;
      if (_lastDocumentsPath != docs.path) {
        await prepare();
      } else if (!await javp.exists()) {
        await javp.create(recursive: true);
      }
      return javp;
    }

    final future = prepare();
    _gate = future;
    try {
      await future;
    } finally {
      if (identical(_gate, future)) _gate = null;
    }
    return javp;
  }

  /// Default profile: `{Documents}/JAVP/{fileName}`.
  /// Other profiles: `{Documents}/JAVP/profiles/{id}/{fileName}`.
  static Future<String> profileFilePath({
    required String profileId,
    required String fileName,
  }) async {
    final root = await directory();
    if (profileId == Profile.defaultId) {
      return p.join(root.path, fileName);
    }
    return p.join(root.path, 'profiles', profileId, fileName);
  }

  /// Directory for [profileId] under the JAVP folder.
  static Future<Directory> profileDirectory(String profileId) async {
    final root = await directory();
    if (profileId == Profile.defaultId) return root;
    final scoped = Directory(p.join(root.path, 'profiles', profileId));
    if (!await scoped.exists()) {
      await scoped.create(recursive: true);
    }
    return scoped;
  }

  /// Maps a pre-subfolder Documents path to `{Documents}/JAVP/…` when the
  /// file was moved. Returns [path] unchanged when it still exists, is not
  /// under Documents, or the relocated file is missing.
  static Future<String> relocateIfMoved(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || kIsWeb) return trimmed;
    try {
      if (File(trimmed).existsSync() || Directory(trimmed).existsSync()) {
        return trimmed;
      }
    } catch (_) {
      return trimmed;
    }
    try {
      await directory();
    } catch (_) {
      return trimmed;
    }
    final relocated = tryRelocateSync(trimmed);
    if (relocated == trimmed) return trimmed;
    try {
      if (File(relocated).existsSync() || Directory(relocated).existsSync()) {
        return relocated;
      }
    } catch (_) {}
    return trimmed;
  }

  /// Sync remap using the last [directory] result. No-op until that ran.
  static String tryRelocateSync(String path) {
    final trimmed = path.trim();
    final docs = _lastDocumentsPath;
    final javp = _lastJavpPath;
    if (trimmed.isEmpty || docs == null || javp == null) return trimmed;
    return _relocate(trimmed, documentsPath: docs, javpPath: javp);
  }

  /// One-shot move of known JAVP files from [from] (Documents root) into [to].
  @visibleForTesting
  static Future<void> migrateLegacy({
    required Directory from,
    required Directory to,
  }) async {
    if (p.equals(from.path, to.path)) return;
    if (!await from.exists()) return;
    await to.create(recursive: true);

    for (final name in _legacyFiles) {
      final moved = await _moveFile(
        File(p.join(from.path, name)),
        File(p.join(to.path, name)),
      );
      // Sidecars must travel with their DB. If the main move was skipped
      // (destination already exists), leave root WAL/SHM/journal alone.
      if (moved && name.endsWith('.db')) {
        for (final suffix in _sqliteSidecars) {
          await _moveFile(
            File(p.join(from.path, '$name$suffix')),
            File(p.join(to.path, '$name$suffix')),
          );
        }
      }
    }

    for (final name in _legacyDirs) {
      await _moveDirectory(
        Directory(p.join(from.path, name)),
        Directory(p.join(to.path, name)),
      );
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _gate = null;
    _lastDocumentsPath = null;
    _lastJavpPath = null;
  }

  static String _relocate(
    String path, {
    required String documentsPath,
    required String javpPath,
  }) {
    final normalized = p.normalize(path);
    final docs = p.normalize(documentsPath);
    final javp = p.normalize(javpPath);
    if (p.equals(normalized, javp) || p.isWithin(javp, normalized)) {
      return path;
    }
    if (!p.equals(normalized, docs) && !p.isWithin(docs, normalized)) {
      return path;
    }
    final rel = p.relative(normalized, from: docs);
    if (rel == '.' || rel == folderName || p.isWithin(folderName, rel)) {
      return path;
    }
    return p.join(javp, rel);
  }

  /// Returns true when [src] was moved onto [dest].
  static Future<bool> _moveFile(File src, File dest) async {
    if (!await src.exists()) return false;
    if (await dest.exists()) return false;
    await dest.parent.create(recursive: true);
    try {
      await src.rename(dest.path);
    } on FileSystemException {
      await src.copy(dest.path);
      await src.delete();
    }
    return true;
  }

  static Future<void> _moveDirectory(Directory src, Directory dest) async {
    if (!await src.exists()) return;
    if (!await dest.exists()) {
      await dest.parent.create(recursive: true);
      try {
        await src.rename(dest.path);
        return;
      } on FileSystemException {
        // Cross-device rename: fall through to copy + delete.
      }
    }
    // Merge into an existing (possibly partial) destination so an interrupted
    // cross-filesystem copy can finish on a later launch.
    await _copyDirectory(src, dest);
    await src.delete(recursive: true);
  }

  static Future<void> _copyDirectory(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File) {
        final out = File(p.join(dest.path, name));
        if (await out.exists()) continue;
        await entity.copy(out.path);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(p.join(dest.path, name)));
      }
    }
  }
}
