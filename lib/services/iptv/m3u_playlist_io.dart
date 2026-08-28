import 'package:javp/models/media_item.dart';
import 'package:javp/services/local_source_path.dart';

/// Helpers for loading M3U playlists from HTTP(S) URLs or local files.
///
/// Thin facade over [LocalSourcePath] so existing M3U call sites stay stable.
abstract final class M3uPlaylistIo {
  /// True when [location] is an http(s) playlist URL.
  static bool isRemotePlaylistUrl(String location) =>
      LocalSourcePath.isRemoteUrl(location);

  /// True for a remote `.m3u` channel list (not HLS `.m3u8` media).
  ///
  /// Opening these as a single stream fails — import as an M3U source instead.
  static bool looksLikeChannelListUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m3u8')) return false;
    return path.endsWith('.m3u');
  }

  /// Filesystem path for a local playlist location, or null if remote/invalid.
  static String? tryLocalFilePath(String location) =>
      LocalSourcePath.tryLocalFilePath(location);

  /// Directory containing a local playlist, or null when [location] is remote.
  static String? localBaseDir(String location) =>
      LocalSourcePath.localBaseDir(location);

  /// Resolve a playlist entry against [baseDir] when the entry is relative.
  static String resolveEntryUrl(String entry, {String? baseDir}) =>
      LocalSourcePath.resolveEntryUrl(entry, baseDir: baseDir);

  /// Apply [resolveEntryUrl] to every item's [MediaItem.playUrl].
  static List<MediaItem> resolveEntryUrls(
    List<MediaItem> items, {
    String? baseDir,
  }) =>
      LocalSourcePath.resolveEntryUrls(items, baseDir: baseDir);
}
