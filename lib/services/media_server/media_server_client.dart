import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/media_server_stream_quality.dart';

class MediaServerLibrary {
  const MediaServerLibrary({
    required this.id,
    required this.name,
    this.collectionType,
    this.itemCount = 0,
  });

  final String id;
  final String name;
  final String? collectionType;
  final int itemCount;
}

class MediaServerPage {
  const MediaServerPage({
    required this.items,
    this.totalCount = 0,
    this.startIndex = 0,
    this.scannedCount = 0,
  });

  final List<MediaItem> items;
  final int totalCount;
  final int startIndex;

  /// Backend rows consumed for this page, before client-side drops.
  ///
  /// `0` means "same as [items.length]" so callers that do not filter can omit it.
  final int scannedCount;

  int get consumedCount => scannedCount > 0 ? scannedCount : items.length;

  bool get hasMore => startIndex + consumedCount < totalCount;
}

class MediaServerSession {
  const MediaServerSession({
    required this.userId,
    required this.accessToken,
    this.serverName,
    this.baseUrl,
  });

  final String userId;
  final String accessToken;
  final String? serverName;

  /// Resolved reachable base (Plex may pick LAN vs remote per device).
  final String? baseUrl;
}

/// Shared contract for Jellyfin / Emby (and adapters toward Plex mapping).
abstract class MediaServerClient {
  Future<MediaServerSession> authenticate(IptvSource source);

  Future<List<MediaServerLibrary>> libraries(
    IptvSource source,
    MediaServerSession session,
  );

  Future<MediaServerPage> browse(
    IptvSource source,
    MediaServerSession session, {
    String? parentId,
    String? search,
    int startIndex = 0,
    int limit = 50,
  });

  Future<MediaDetails?> details(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  );

  Future<String> streamUrl(
    IptvSource source,
    MediaServerSession session,
    String itemId, {
    MediaServerStreamQuality quality = MediaServerStreamQuality.original,
  });

  Future<List<MediaSegment>> mediaSegments(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  );

  Future<void> reportProgress(
    IptvSource source,
    MediaServerSession session, {
    required String itemId,
    required Duration position,
    required bool isPaused,
    Duration? duration,
    bool stopped = false,
  });

  /// Mark [itemId] played or unplayed on the server (watched / resume state).
  Future<void> setPlayed(
    IptvSource source,
    MediaServerSession session,
    String itemId, {
    required bool played,
  });

  /// Latest 0…1 watch progress from the server, or null if unavailable.
  Future<double?> remoteProgress(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  );
}
