import 'package:javp/models/media_item.dart';
import 'package:javp/services/deep_links/javp_source_link.dart';

/// Whether [uri] is an Android/iOS "Open with" / VIEW media location that
/// must not be treated as a GoRouter path (e.g. `content://…`, `file://…`).
bool isExternalMediaLocation(Uri uri) => isExternalMediaScheme(uri);

/// Strip a common media/torrent extension from a path segment for display.
String displayTitleFromFileName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return name;
  return name.replaceFirst(
    RegExp(
      r'\.(mp4|mkv|avi|mov|webm|m4v|ts|m2ts|mpg|mpeg|wmv|flv|mp3|m4a|aac|flac|ogg|opus|wav|torrent)$',
      caseSensitive: false,
    ),
    '',
  );
}

/// Builds a playable [MediaItem] from an external open URI.
MediaItem mediaItemFromExternalUri(String uriString, {String? id}) {
  final uri = Uri.tryParse(uriString);
  if (uri != null && uri.scheme.toLowerCase() == 'magnet') {
    final dn = uri.queryParameters['dn'];
    final title = (dn != null && dn.isNotEmpty)
        ? Uri.decodeComponent(dn.replaceAll('+', ' '))
        : 'Torrent';
    return MediaItem(
      id: id ?? 'external-${uriString.hashCode}',
      title: title,
      playUrl: uriString,
      kind: MediaKind.vod,
      origin: MediaOrigin.torrent,
      subtitle: 'Opened magnet',
      group: 'Torrents',
    );
  }

  final segments =
      uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const <String>[];
  final decoded =
      segments.isEmpty ? null : Uri.decodeComponent(segments.last);
  final fileName =
      (decoded == null || decoded.isEmpty) ? 'Opened media' : decoded;
  final isLocal =
      uri != null && (uri.scheme == 'content' || uri.scheme == 'file');
  final isTorrentFile =
      isLocal && fileName.toLowerCase().endsWith('.torrent');
  final title = displayTitleFromFileName(fileName);

  if (isTorrentFile) {
    return MediaItem(
      id: id ?? 'external-${uriString.hashCode}',
      title: title.isNotEmpty ? title : fileName,
      playUrl: uriString.startsWith('file:')
          ? Uri.parse(uriString).toFilePath()
          : uriString,
      kind: MediaKind.vod,
      origin: MediaOrigin.torrent,
      subtitle: 'Opened torrent',
      group: 'Torrents',
    );
  }

  return MediaItem(
    id: id ?? 'external-${uriString.hashCode}',
    title: title.isNotEmpty ? title : fileName,
    playUrl: uriString,
    kind: isLocal ? MediaKind.local : MediaKind.network,
    origin: isLocal ? MediaOrigin.localFile : MediaOrigin.url,
    subtitle: isLocal ? 'Opened from device' : 'Opened link',
    group: isLocal ? 'Local' : 'Network',
  );
}
