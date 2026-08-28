import 'package:javp/models/media_item.dart';
import 'package:path/path.dart' as p;

/// Helpers for treating local files (or `file://` URIs) as catalog/playlist
/// sources alongside http(s) URLs.
abstract final class LocalSourcePath {
  static const relativeExtensions = [
    '.m3u',
    '.m3u8',
    '.json',
    '.xml',
    '.xml.gz',
    '.gz',
  ];

  /// True when [location] is an http(s) URL.
  static bool isRemoteUrl(String location) {
    final uri = Uri.tryParse(location.trim());
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// Filesystem path for a local source location, or null if remote/invalid.
  ///
  /// Accepts bare paths (`/…`, `C:\…`), `file://` URIs, and relative paths
  /// ending in [relativeExtensions] (`.m3u`, `.m3u8`, `.json`).
  static String? tryLocalFilePath(String location) {
    final trimmed = location.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      final scheme = uri.scheme.toLowerCase();
      if (scheme == 'http' || scheme == 'https') return null;
      if (scheme == 'asset') return null;
      if (scheme == 'file') {
        try {
          return uri.toFilePath();
        } catch (_) {
          return null;
        }
      }
      // Windows drive letter paths parse as scheme `c` / `d` / …
      if (_isWindowsDriveScheme(scheme) &&
          trimmed.length >= 2 &&
          trimmed[1] == ':') {
        return trimmed;
      }
      if (scheme.isNotEmpty) return null;
    }

    if (_looksLikeAbsolutePath(trimmed)) return trimmed;

    final lower = trimmed.toLowerCase();
    for (final ext in relativeExtensions) {
      if (lower.endsWith(ext)) return trimmed;
    }
    return null;
  }

  /// Directory containing a local source file, or null when [location] is remote.
  static String? localBaseDir(String location) {
    final path = tryLocalFilePath(location);
    if (path == null) return null;
    return p.dirname(path);
  }

  /// Resolve a media entry against [baseDir] when the entry is relative.
  ///
  /// Absolute http(s)/rtsp/file/magnet URLs and rooted filesystem paths are
  /// left unchanged. When [baseDir] is null, [entry] is returned as-is.
  static String resolveEntryUrl(String entry, {String? baseDir}) {
    final trimmed = entry.trim();
    if (baseDir == null || baseDir.isEmpty || trimmed.isEmpty) {
      return trimmed;
    }

    if (_isAbsolutePlayUrl(trimmed)) return trimmed;

    return p.normalize(p.join(baseDir, trimmed));
  }

  /// Apply [resolveEntryUrl] to every item's [MediaItem.playUrl].
  static List<MediaItem> resolveEntryUrls(
    List<MediaItem> items, {
    String? baseDir,
  }) {
    if (baseDir == null || baseDir.isEmpty || items.isEmpty) return items;
    return [
      for (final item in items)
        item.copyWith(playUrl: resolveEntryUrl(item.playUrl, baseDir: baseDir)),
    ];
  }

  /// Same as [resolveEntryUrls] for packed `vod_items` maps.
  static List<Map<String, Object?>> resolvePackedPlayUrls(
    List<Map<String, Object?>> rows, {
    String? baseDir,
  }) {
    if (baseDir == null || baseDir.isEmpty || rows.isEmpty) return rows;
    return [
      for (final row in rows)
        {
          ...row,
          'play_url': resolveEntryUrl(
            '${row['play_url'] ?? ''}',
            baseDir: baseDir,
          ),
        },
    ];
  }

  static bool _isWindowsDriveScheme(String scheme) =>
      scheme.length == 1 &&
      scheme.codeUnitAt(0) >= 97 &&
      scheme.codeUnitAt(0) <= 122;

  static bool _looksLikeAbsolutePath(String value) {
    if (value.startsWith('/')) return true;
    if (value.startsWith(r'\\')) return true;
    return value.length >= 2 &&
        ((value.codeUnitAt(0) >= 65 && value.codeUnitAt(0) <= 90) ||
            (value.codeUnitAt(0) >= 97 && value.codeUnitAt(0) <= 122)) &&
        value[1] == ':';
  }

  static bool _isAbsolutePlayUrl(String value) {
    if (_looksLikeAbsolutePath(value)) return true;

    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return false;

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'rtsp' ||
        scheme == 'rtspt' ||
        scheme == 'rtmp' ||
        scheme == 'rtp' ||
        scheme == 'udp' ||
        scheme == 'mms' ||
        scheme == 'mmsh' ||
        scheme == 'file' ||
        scheme == 'magnet' ||
        scheme == 'content') {
      return true;
    }
    // Windows drive letter.
    if (_isWindowsDriveScheme(scheme) && value.length >= 2 && value[1] == ':') {
      return true;
    }
    return false;
  }
}
