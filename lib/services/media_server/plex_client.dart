import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/media_details.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/parental/adult_content.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/services/media_server/media_server_client.dart';
import 'package:javp/services/media_server/plex_cloud_playable.dart';

/// Plex Media Server client using an auth token (BYO).
///
/// [IptvSource.password] holds the X-Plex-Token; [serverUrl] is the PMS base
/// (e.g. http://192.168.1.10:32400). Username may hold the machine id.
///
/// Live TV channels use [serverItemId] values shaped like
/// `live:{dvrId}:{channel}` so [streamUrl] can tune before returning HLS.
class PlexClient implements MediaServerClient {
  PlexClient({http.Client? httpClient, String clientIdentifier = 'javp'})
    : _http = httpClient ?? http.Client(),
      clientIdentifier = clientIdentifier.trim().isEmpty
          ? 'javp'
          : clientIdentifier.trim();

  final http.Client _http;

  /// Matches plex.tv device registration / auth when set by [LibraryProvider].
  String clientIdentifier;

  /// Last `/identity` winner per source, so later calls reuse the reachable base.
  final Map<String, String> _resolvedBaseBySourceId = {};

  static const _identityProbeTimeout = Duration(seconds: 4);

  /// Last tuned Live TV session key (`/livetv/sessions/{uuid}`) for keepalive.
  String? lastLiveSessionKey;

  /// Prefix for Live TV [MediaItem.serverItemId] values.
  static const liveServerItemPrefix = 'live:';

  /// Prefix for plex.tv FAST / Live TV [MediaItem.serverItemId] values.
  static const fastServerItemPrefix = 'fast:';

  /// Cloud EPG provider that hosts Plex FAST (free ad-supported) channels.
  static const fastProviderHost = 'epg.provider.plex.tv';

  /// Base URL for [fastProviderHost].
  static const fastProviderUrl = 'https://$fastProviderHost';

  /// Cloud VOD provider for Plex free movies & shows (AVOD).
  static const vodProviderHost = 'vod.provider.plex.tv';

  /// Base URL for [vodProviderHost].
  static const vodProviderUrl = 'https://$vodProviderHost';

  static const _discoverProviderUrl = 'https://discover.provider.plex.tv';

  /// Stored in [IptvSource.username] so FAST sources dedupe separately from PMS.
  static const fastUsername = 'plex-fast';

  static const _fastVodLibraries = [
    MediaServerLibrary(id: 'movies', name: 'Movies', collectionType: 'movie'),
    MediaServerLibrary(id: 'tv', name: 'TV Shows', collectionType: 'show'),
  ];

  static const _watchPlexHeaders = {
    'Origin': 'https://watch.plex.tv',
    'Referer': 'https://watch.plex.tv/',
  };

  /// Compound FAST channel ids are `{24-hex-server}-{24-hex-channel}`.
  static final _fastCompoundId = RegExp(r'^[0-9a-f]{24}-([0-9a-f]{24})$');

  /// True when [source] is the plex.tv FAST Live TV provider (not a PMS).
  static bool isFastProvider(IptvSource source) {
    final url = (source.serverUrl ?? '').trim().toLowerCase();
    if (url.contains(fastProviderHost)) return true;
    return (source.username ?? '').trim() == fastUsername;
  }

  /// Encode a plex.tv FAST channel id for [MediaItem.serverItemId].
  static String fastServerItemId(String channelId) {
    return '$fastServerItemPrefix${Uri.encodeComponent(channelId.trim())}';
  }

  /// Parse [fastServerItemId]; returns null when [itemId] is VOD or DVR live.
  static String? parseFastServerItemId(String itemId) {
    if (!itemId.startsWith(fastServerItemPrefix)) return null;
    final id = Uri.decodeComponent(
      itemId.substring(fastServerItemPrefix.length),
    ).trim();
    return id.isEmpty ? null : id;
  }

  /// Stable grid/EPG key from a compound FAST channel id.
  static String? normalizeFastChannelId(String? raw) {
    final id = (raw ?? '').trim();
    if (id.isEmpty) return null;
    final match = _fastCompoundId.firstMatch(id.toLowerCase());
    return match?.group(1) ?? id;
  }

  /// Encode a DVR + tune channel id for [MediaItem.serverItemId].
  ///
  /// Optional [startAt] enables Start Over / timeshift via transcoder offset.
  static String liveServerItemId({
    required String dvrId,
    required String channelId,
    DateTime? startAt,
  }) {
    final base =
        '$liveServerItemPrefix$dvrId:${Uri.encodeComponent(channelId)}';
    if (startAt == null) return base;
    return '$base@${startAt.toUtc().millisecondsSinceEpoch}';
  }

  /// Parse [liveServerItemId]; returns null when [itemId] is VOD metadata.
  static ({String dvrId, String channelId, DateTime? startAt})?
  parseLiveServerItemId(String itemId) {
    if (!itemId.startsWith(liveServerItemPrefix)) return null;
    var rest = itemId.substring(liveServerItemPrefix.length);
    DateTime? startAt;
    final at = rest.lastIndexOf('@');
    if (at > 0) {
      final ms = int.tryParse(rest.substring(at + 1));
      if (ms != null) {
        startAt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
        rest = rest.substring(0, at);
      }
    }
    final sep = rest.indexOf(':');
    if (sep <= 0 || sep >= rest.length - 1) return null;
    final dvrId = rest.substring(0, sep).trim();
    final channelId = Uri.decodeComponent(rest.substring(sep + 1)).trim();
    if (dvrId.isEmpty || channelId.isEmpty) return null;
    return (dvrId: dvrId, channelId: channelId, startAt: startAt);
  }

  String _base(IptvSource source, [MediaServerSession? session]) {
    final fromSession = normalizeMediaServerBase(session?.baseUrl);
    if (fromSession.isNotEmpty) {
      rememberResolvedBase(source.id, fromSession);
      return fromSession;
    }
    final resolved = _resolvedBaseBySourceId[source.id];
    if (resolved != null && resolved.isNotEmpty) return resolved;
    final candidates = source.serverUrlCandidates;
    if (candidates.isNotEmpty) return candidates.first;
    throw Exception('Plex server URL required');
  }

  void rememberResolvedBase(String sourceId, String base) {
    final normalized = normalizeMediaServerBase(base);
    if (normalized.isEmpty) return;
    _resolvedBaseBySourceId[sourceId] = normalized;
  }

  /// Movies/shows for a plex.tv cloud source live on [vodProviderUrl], not EPG.
  String _contentBase(IptvSource source, [MediaServerSession? session]) {
    if (isFastProvider(source)) return vodProviderUrl;
    return _base(source, session);
  }

  String _token(IptvSource source) {
    final token = (source.password ?? source.username ?? '').trim();
    if (token.isEmpty) throw Exception('Plex token required (password field)');
    return token;
  }

  Map<String, String> _headers(IptvSource source) => {
    'Accept': 'application/json',
    'X-Plex-Token': _token(source),
    'X-Plex-Product': 'JAVP',
    'X-Plex-Client-Identifier': clientIdentifier,
    'X-Plex-Version': '0.1.0',
    if (isFastProvider(source)) ...{
      'X-Plex-Provider-Version': '6.5.0',
      'X-Plex-Model': 'hosted',
      ..._watchPlexHeaders,
    },
  };

  @override
  Future<MediaServerSession> authenticate(
    IptvSource source, {
    String? preferredBase,
  }) async {
    if (isFastProvider(source)) {
      return _authenticateFast(source);
    }
    final base = await _resolveReachableBase(
      source,
      preferredBase: preferredBase,
    );
    rememberResolvedBase(source.id, base);
    return MediaServerSession(
      userId: 'plex',
      accessToken: _token(source),
      // Keep the user-facing source name (PMS identity is a UUID, not a label).
      serverName: source.name,
      baseUrl: base,
    );
  }

  /// Candidate bases: last-good on this device, then [IptvSource.serverUrlCandidates].
  static List<String> identityCandidates(
    IptvSource source, {
    String? preferredBase,
  }) {
    final out = <String>[];
    void add(String? raw) {
      final n = normalizeMediaServerBase(raw);
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }

    add(preferredBase);
    for (final url in source.serverUrlCandidates) {
      add(url);
    }
    return out;
  }

  Future<String> _resolveReachableBase(
    IptvSource source, {
    String? preferredBase,
  }) async {
    final bases = identityCandidates(source, preferredBase: preferredBase);
    if (bases.isEmpty) throw Exception('Plex server URL required');
    if (bases.length == 1) {
      await _probeIdentity(bases.single, source);
      return bases.single;
    }

    final done = Completer<String>();
    var pending = bases.length;
    for (final base in bases) {
      unawaited(() async {
        try {
          await _probeIdentity(base, source);
          if (!done.isCompleted) done.complete(base);
        } catch (e, st) {
          pending--;
          if (pending == 0 && !done.isCompleted) {
            done.completeError(Exception('Plex auth failed ($e)'), st);
          }
        }
      }());
    }
    return done.future;
  }

  Future<void> _probeIdentity(String base, IptvSource source) async {
    final uri = Uri.parse('$base/identity');
    final response = await _http
        .get(uri, headers: _headers(source))
        .timeout(_identityProbeTimeout);
    if (response.statusCode >= 400) {
      throw Exception('Plex auth failed (${response.statusCode})');
    }
  }

  Future<MediaServerSession> _authenticateFast(IptvSource source) async {
    final base = _base(source);
    final uri = Uri.parse(
      '$base/lineups/plex/channels',
    ).replace(queryParameters: {'X-Plex-Container-Size': '0'});
    final response = await _http.get(uri, headers: _headers(source));
    if (response.statusCode >= 400) {
      throw Exception('Plex Live TV auth failed (${response.statusCode})');
    }
    return MediaServerSession(
      userId: fastUsername,
      accessToken: _token(source),
      serverName: source.name,
    );
  }

  @override
  Future<List<MediaServerLibrary>> libraries(
    IptvSource source,
    MediaServerSession session,
  ) async {
    final fallback = isFastProvider(source)
        ? _fastVodLibraries
        : const <MediaServerLibrary>[];
    try {
      final base = _contentBase(source, session);
      final uri = Uri.parse('$base/library/sections');
      final response = await _http.get(uri, headers: _headers(source));
      if (response.statusCode >= 400) return fallback;
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
      final dirs = container['Directory'] as List? ?? const [];
      final out = dirs.whereType<Map>().map((raw) {
        final m = Map<String, dynamic>.from(raw);
        return MediaServerLibrary(
          id: '${m['key']}',
          name: m['title'] as String? ?? '',
          collectionType: m['type'] as String?,
          itemCount: (m['count'] as num?)?.toInt() ?? 0,
        );
      }).toList();
      return out.isEmpty ? fallback : out;
    } catch (_) {
      return fallback;
    }
  }

  @override
  Future<MediaServerPage> browse(
    IptvSource source,
    MediaServerSession session, {
    String? parentId,
    String? search,
    int startIndex = 0,
    int limit = 50,
  }) async {
    final isSearch = search != null && search.trim().isNotEmpty;
    if (!isSearch && (parentId == null || parentId.isEmpty)) {
      return const MediaServerPage(items: []);
    }

    if (isFastProvider(source) && isSearch) {
      return _browseCloudSearch(source, query: search.trim(), limit: limit);
    }

    final base = _contentBase(source, session);
    late final Uri uri;
    if (isSearch) {
      uri = Uri.parse(
        '$base/hubs/search',
      ).replace(queryParameters: {'query': search.trim(), 'limit': '$limit'});
    } else {
      uri = Uri.parse('$base/library/sections/$parentId/all').replace(
        queryParameters: {
          'X-Plex-Container-Start': '$startIndex',
          'X-Plex-Container-Size': '$limit',
          if (isFastProvider(source)) ...{
            'availabilityType': 'free',
            'includeGuids': '1',
          },
        },
      );
    }

    final response = await _http.get(uri, headers: _headers(source));
    if (response.statusCode >= 400) return const MediaServerPage(items: []);
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
    final itemsRaw = _extractMetadataList(container);

    final items = isSearch
        ? _collapseSearchResults(itemsRaw, source: source, limit: limit)
        : _mapList(itemsRaw, source: source);

    final scannedCount = itemsRaw.length;
    final totalSize = (container['totalSize'] as num?)?.toInt();
    return MediaServerPage(
      items: items.take(limit).toList(),
      scannedCount: scannedCount,
      totalCount: totalSize ?? (startIndex + scannedCount),
      startIndex: startIndex,
    );
  }

  List<MediaItem> _mapList(
    List<Map<String, dynamic>> raw, {
    required IptvSource source,
  }) {
    final items = <MediaItem>[];
    for (final m in raw) {
      final item = _mapCatalogMeta(m, source: source);
      if (item != null) items.add(item);
    }
    return items;
  }

  /// Search hubs mix movies, shows, and loose episodes. Prefer movies/shows and
  /// roll episode hits up to their parent series so results aren't a flat ep list.
  List<MediaItem> _collapseSearchResults(
    List<Map<String, dynamic>> raw, {
    required IptvSource source,
    required int limit,
  }) {
    final movies = <MediaItem>[];
    final shows = <MediaItem>[];
    final showKeys = <String>{};
    final fromEpisodes = <String, MediaItem>{};

    for (final m in raw) {
      final type = m['type'] as String? ?? '';
      if (type == 'movie') {
        final item = _mapCatalogMeta(m, source: source);
        if (item != null) movies.add(item);
        continue;
      }
      if (type == 'show') {
        final item = _mapCatalogMeta(m, source: source);
        if (item != null) {
          shows.add(item);
          final key = item.serverItemId;
          if (key != null && key.isNotEmpty) showKeys.add(key);
        }
        continue;
      }
      if (type != 'episode') continue;

      final grandparent = '${m['grandparentRatingKey'] ?? ''}';
      if (grandparent.isEmpty || showKeys.contains(grandparent)) continue;
      if (fromEpisodes.containsKey(grandparent)) continue;

      final show = _showShellFromEpisode(m, source: source);
      if (show != null) {
        fromEpisodes[grandparent] = show;
        showKeys.add(grandparent);
      }
    }

    return [...movies, ...shows, ...fromEpisodes.values].take(limit).toList();
  }

  List<Map<String, dynamic>> _extractMetadataList(
    Map<String, dynamic> container,
  ) {
    final itemsRaw = <Map<String, dynamic>>[];
    void addMeta(dynamic raw) {
      if (raw is Map) itemsRaw.add(Map<String, dynamic>.from(raw));
    }

    if (container['Metadata'] is List) {
      for (final raw in container['Metadata'] as List) {
        addMeta(raw);
      }
    } else if (container['Hub'] is List) {
      for (final hub in container['Hub'] as List) {
        if (hub is! Map) continue;
        final meta = hub['Metadata'];
        if (meta is List) {
          for (final raw in meta) {
            addMeta(raw);
          }
        }
      }
    } else if (container['SearchResults'] is List) {
      for (final group in container['SearchResults'] as List) {
        if (group is! Map) continue;
        final results = group['SearchResult'];
        if (results is! List) continue;
        for (final result in results) {
          if (result is! Map) continue;
          addMeta(result['Metadata'] ?? result);
        }
      }
    }
    return itemsRaw;
  }

  Future<MediaServerPage> _browseCloudSearch(
    IptvSource source, {
    required String query,
    required int limit,
  }) async {
    final uri = Uri.parse('$_discoverProviderUrl/library/search').replace(
      queryParameters: {
        'query': query,
        'limit': '$limit',
        'searchTypes': 'movies,tv',
        'searchProviders': 'PLEXAVOD',
        'includeMetadata': '1',
      },
    );
    try {
      final response = await _http.get(uri, headers: _headers(source));
      if (response.statusCode >= 400) {
        return const MediaServerPage(items: []);
      }
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
      final items = _collapseSearchResults(
        _extractMetadataList(container),
        source: source,
        limit: limit,
      );
      return MediaServerPage(items: items, totalCount: items.length);
    } catch (_) {
      return const MediaServerPage(items: []);
    }
  }

  MediaItem? _showShellFromEpisode(
    Map<String, dynamic> episode, {
    required IptvSource source,
  }) {
    if (isFastProvider(source) && !plexCloudMetadataIsListed(episode)) {
      return null;
    }
    final ratingKey = '${episode['grandparentRatingKey'] ?? ''}';
    final title = episode['grandparentTitle'] as String?;
    if (ratingKey.isEmpty || title == null || title.isEmpty) return null;
    final base = _contentBase(source);
    final token = _token(source);
    String? abs(String? path) {
      if (path == null || path.isEmpty) return null;
      if (path.startsWith('http')) return path;
      return '$base$path?X-Plex-Token=${Uri.encodeQueryComponent(token)}';
    }

    final thumb =
        episode['grandparentThumb'] as String? ??
        episode['parentThumb'] as String?;
    final art = episode['art'] as String?;
    final year = (episode['year'] as num?)?.toInt();

    return MediaItem(
      id: 'plex-${source.id}-$ratingKey',
      title: title,
      playUrl: '',
      kind: MediaKind.series,
      origin: MediaOrigin.plex,
      subtitle: [if (year != null) '$year', 'Series'].join(' · '),
      thumbnailUrl: abs(thumb),
      posterUrl: abs(thumb),
      backdropUrl: abs(art),
      group: episode['librarySectionTitle'] as String? ?? 'show',
      sourceId: source.id,
      serverItemId: ratingKey,
      year: year,
      httpHeaders: isFastProvider(source) ? _watchPlexHeaders : const {},
    );
  }

  @override
  Future<MediaDetails?> details(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  ) async {
    if (parseFastServerItemId(itemId) != null ||
        parseLiveServerItemId(itemId) != null) {
      return null;
    }
    final base = _contentBase(source, session);
    final uri = Uri.parse('$base/library/metadata/$itemId');
    final response = await _http.get(uri, headers: _headers(source));
    if (response.statusCode >= 400) return null;
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
    final list = container['Metadata'] as List? ?? const [];
    if (list.isEmpty || list.first is! Map) return null;
    final meta = Map<String, dynamic>.from(list.first as Map);
    final item = _mapMeta(meta, source: source);
    if (item == null) return null;
    final roles = meta['Role'] as List? ?? const [];
    final cast = <CastMember>[];
    for (final raw in roles.take(20)) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      cast.add(
        CastMember(
          name: r['tag'] as String? ?? '',
          character: r['role'] as String?,
          order: cast.length,
        ),
      );
    }

    var seasons = const <SeriesSeasonDetails>[];
    if ((meta['type'] as String?) == 'show') {
      seasons = await _fetchShowSeasons(source, itemId);
    }

    return MediaDetails(
      id: item.id,
      title: item.title,
      mediaItemId: item.id,
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      plot: item.plot,
      posterUrl: item.posterUrl,
      backdropUrl: item.backdropUrl,
      genres: item.genres,
      rating: item.rating,
      year: item.year,
      runtime: item.duration,
      cast: cast,
      seasons: seasons,
      seasonNumber: item.seasonNumber,
      episodeNumber: item.episodeNumber,
      updatedAt: DateTime.now(),
    );
  }

  Future<List<SeriesSeasonDetails>> _fetchShowSeasons(
    IptvSource source,
    String showRatingKey,
  ) async {
    final seasonsRaw = await _children(source, showRatingKey);
    final seasons = <SeriesSeasonDetails>[];
    for (final seasonMeta in seasonsRaw) {
      final type = seasonMeta['type'] as String? ?? '';
      if (type != 'season') continue;
      final seasonKey = '${seasonMeta['ratingKey'] ?? ''}';
      final seasonNum = (seasonMeta['index'] as num?)?.toInt() ?? 0;
      final seasonTitle = seasonMeta['title'] as String? ?? 'Season $seasonNum';
      if (seasonKey.isEmpty) continue;

      final episodesRaw = await _children(source, seasonKey);
      final episodes = <SeriesEpisodeDetails>[];
      for (final ep in episodesRaw) {
        if ((ep['type'] as String?) != 'episode') continue;
        final epKey = '${ep['ratingKey'] ?? ''}';
        if (epKey.isEmpty) continue;
        final epNum = (ep['index'] as num?)?.toInt() ?? episodes.length + 1;
        final durationMs = (ep['duration'] as num?)?.toInt();
        final thumb = ep['thumb'] as String?;
        episodes.add(
          SeriesEpisodeDetails(
            id: epKey,
            episodeNumber: epNum,
            seasonNumber: seasonNum,
            title: ep['title'] as String? ?? 'Episode $epNum',
            plot: ep['summary'] as String?,
            thumbnailUrl: _absPath(source, thumb),
            duration: durationMs == null
                ? null
                : Duration(milliseconds: durationMs),
            // Play URL resolved at playback via [serverItemId] = rating key.
            playUrl: null,
          ),
        );
      }
      episodes.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
      seasons.add(
        SeriesSeasonDetails(
          seasonNumber: seasonNum,
          name: seasonTitle,
          posterUrl: _absPath(source, seasonMeta['thumb'] as String?),
          episodes: episodes,
        ),
      );
    }
    seasons.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
  }

  Future<List<Map<String, dynamic>>> _children(
    IptvSource source,
    String ratingKey,
  ) async {
    final base = _contentBase(source);
    final uri = Uri.parse('$base/library/metadata/$ratingKey/children');
    final response = await _http.get(uri, headers: _headers(source));
    if (response.statusCode >= 400) return const [];
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
    final list = container['Metadata'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Live TV channels from configured DVRs (empty when Live TV isn't set up).
  ///
  /// plex.tv FAST sources use [fastProviderUrl] instead of a PMS DVR.
  Future<List<MediaItem>> liveChannels(
    IptvSource source,
    MediaServerSession session,
  ) async {
    if (isFastProvider(source)) {
      return _fastLiveChannels(source);
    }
    _base(source, session);
    final dvrs = await _listDvrs(source);
    if (dvrs.isEmpty) return const [];

    final out = <MediaItem>[];
    final seen = <String>{};
    for (final dvr in dvrs) {
      final dvrId = '${dvr['key'] ?? ''}'.trim();
      if (dvrId.isEmpty) continue;
      // Skip grabber/device rows nested next to DVR entries.
      final protocol = '${dvr['protocol'] ?? ''}'.toLowerCase();
      final uuid = '${dvr['uuid'] ?? ''}';
      if (protocol == 'livetv' && uuid.startsWith('device://')) continue;

      final dvrTitle = (dvr['title'] as String?)?.trim();
      final group = (dvrTitle == null || dvrTitle.isEmpty)
          ? 'Live TV'
          : dvrTitle;
      final channels = await _channelsForDvr(source, dvr);
      for (final raw in channels) {
        final item = _mapLiveChannel(
          raw,
          source: source,
          dvrId: dvrId,
          group: group,
        );
        if (item == null || !seen.add(item.id)) continue;
        out.add(item);
      }
    }
    return out;
  }

  @override
  Future<String> streamUrl(
    IptvSource source,
    MediaServerSession session,
    String itemId, {
    MediaServerStreamQuality quality = MediaServerStreamQuality.original,
  }) async {
    final fastId = parseFastServerItemId(itemId);
    if (fastId != null) {
      return _fastStreamUrl(source, fastId);
    }
    final live = parseLiveServerItemId(itemId);
    if (live != null) {
      return _liveStreamUrl(
        source,
        dvrId: live.dvrId,
        channelId: live.channelId,
        startAt: live.startAt,
        quality: quality,
      );
    }

    if (isFastProvider(source)) {
      return _vodStreamUrl(source, itemId, quality: quality);
    }

    final base = _base(source, session);
    final token = _token(source);
    final bitrate = quality.maxBitrateKbps;
    if (bitrate != null) {
      // Universal transcoder → HLS at the chosen quality.
      return Uri.parse('$base/video/:/transcode/universal/start.m3u8')
          .replace(
            queryParameters: {
              'path': '/library/metadata/$itemId',
              'mediaIndex': '0',
              'partIndex': '0',
              'protocol': 'hls',
              'fastSeek': '1',
              'directPlay': '0',
              'directStream': '0',
              'videoQuality': '100',
              'videoResolution': quality.plexVideoResolution ?? '1280x720',
              'maxVideoBitrate': '$bitrate',
              'subtitleSize': '100',
              'audioBoost': '100',
              'X-Plex-Platform': 'Android',
              'X-Plex-Client-Identifier': clientIdentifier,
              'X-Plex-Product': 'JAVP',
              'X-Plex-Device': 'Android',
              'X-Plex-Token': token,
            },
          )
          .toString();
    }

    // Direct play — original part.
    final uri = Uri.parse('$base/library/metadata/$itemId');
    final response = await _http.get(uri, headers: _headers(source));
    if (response.statusCode >= 400) {
      throw Exception('Could not resolve Plex stream');
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
    final meta = (container['Metadata'] as List?)?.first as Map?;
    final media = (meta?['Media'] as List?)?.first as Map?;
    final part = (media?['Part'] as List?)?.first as Map?;
    final key = part?['key'] as String?;
    if (key == null) throw Exception('No Plex media part');
    final path = key.startsWith('/') ? key : '/$key';
    return '$base$path?X-Plex-Token=${Uri.encodeQueryComponent(token)}';
  }

  Future<String> _liveStreamUrl(
    IptvSource source, {
    required String dvrId,
    required String channelId,
    DateTime? startAt,
    MediaServerStreamQuality quality = MediaServerStreamQuality.original,
  }) async {
    final base = _base(source);
    final token = _token(source);
    // Drop the previous tuner session before retuning (zap / quality change).
    await closeLiveSession(source);
    final tunePath =
        '/livetv/dvrs/${Uri.encodeComponent(dvrId)}/channels/${Uri.encodeComponent(channelId)}/tune';
    final tuneUri = Uri.parse('$base$tunePath');
    final tuneResponse = await _http.post(tuneUri, headers: _headers(source));
    if (tuneResponse.statusCode >= 400) {
      throw Exception('Plex Live TV tune failed (${tuneResponse.statusCode})');
    }
    Map<String, dynamic> tuneMap;
    try {
      final decoded = jsonDecode(tuneResponse.body);
      if (decoded is! Map) {
        throw const FormatException('tune root is not an object');
      }
      tuneMap = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw Exception('Plex Live TV tune returned invalid JSON');
    }
    var sessionUuid = _extractLiveSessionUuid(tuneMap);
    // Some PMS builds return an empty/partial tune body; the session still
    // appears under GET /livetv/sessions a moment later.
    sessionUuid ??= await _resolveLiveSessionUuid(source, channelId: channelId);
    if (sessionUuid == null || sessionUuid.isEmpty) {
      throw Exception('Plex Live TV tune did not return a session');
    }

    final bitrate = quality.maxBitrateKbps ?? 20000;
    final sessionId =
        'javp-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final sessionKey = '/livetv/sessions/$sessionUuid';
    lastLiveSessionKey = sessionKey;
    final offsetSeconds = startAt == null
        ? null
        : DateTime.now().toUtc().difference(startAt.toUtc()).inSeconds;
    return Uri.parse('$base/video/:/transcode/universal/start.m3u8')
        .replace(
          queryParameters: {
            'hasMDE': '1',
            'path': sessionKey,
            'mediaIndex': '0',
            'partIndex': '0',
            'protocol': 'hls',
            'fastSeek': '1',
            'directPlay': '0',
            'directStream': quality == MediaServerStreamQuality.original
                ? '1'
                : '0',
            'videoQuality': '100',
            'videoResolution': quality.plexVideoResolution ?? '1920x1080',
            'maxVideoBitrate': '$bitrate',
            'mediaBufferSize': '102400',
            'session': sessionId,
            'X-Plex-Session-Identifier': sessionId,
            if (offsetSeconds != null && offsetSeconds > 0)
              'offset': '$offsetSeconds',
            'subtitleSize': '100',
            'audioBoost': '100',
            'X-Plex-Platform': 'Android',
            'X-Plex-Client-Identifier': clientIdentifier,
            'X-Plex-Product': 'JAVP',
            'X-Plex-Device': 'Android',
            'X-Plex-Token': token,
          },
        )
        .toString();
  }

  /// Terminate a Live TV transcoder/tuner session (zap / leave player).
  Future<void> closeLiveSession(IptvSource source, {String? sessionKey}) async {
    final key = (sessionKey ?? lastLiveSessionKey)?.trim();
    if (key == null || key.isEmpty) return;
    final base = _base(source);
    final sessionId = key.split('/').where((p) => p.isNotEmpty).last;
    if (sessionId.isEmpty) return;
    try {
      await _http.delete(
        Uri.parse('$base/livetv/sessions/${Uri.encodeComponent(sessionId)}'),
        headers: _headers(source),
      );
    } catch (_) {}
    if (lastLiveSessionKey == key ||
        lastLiveSessionKey?.endsWith(sessionId) == true) {
      lastLiveSessionKey = null;
    }
  }

  /// Completed DVR recordings from configured DVRs (as on-demand items).
  Future<List<MediaItem>> dvrRecordings(
    IptvSource source,
    MediaServerSession session, {
    int limit = 200,
  }) async {
    if (isFastProvider(source)) return const [];
    _base(source, session);
    final dvrs = await _listDvrs(source);
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final dvr in dvrs) {
      final dvrId = '${dvr['key'] ?? ''}'.trim();
      if (dvrId.isEmpty) continue;
      final protocol = '${dvr['protocol'] ?? ''}'.toLowerCase();
      final uuid = '${dvr['uuid'] ?? ''}';
      if (protocol == 'livetv' && uuid.startsWith('device://')) continue;
      for (final path in [
        '/livetv/dvrs/${Uri.encodeComponent(dvrId)}/history',
        '/livetv/dvrs/${Uri.encodeComponent(dvrId)}/recordings',
      ]) {
        final items = await _getRecordingMetadata(source, path, limit: limit);
        if (items.isEmpty) continue;
        for (final raw in items) {
          final mapped = _mapMeta(raw, source: source);
          if (mapped == null || !seen.add(mapped.id)) continue;
          out.add(
            mapped.copyWith(
              group: 'DVR Recordings',
              subtitle: [
                'Recording',
                if ((mapped.subtitle ?? '').isNotEmpty) mapped.subtitle!,
              ].join(' · '),
            ),
          );
        }
        break;
      }
      if (out.length >= limit) break;
    }
    return out.take(limit).toList();
  }

  Future<List<Map<String, dynamic>>> _getRecordingMetadata(
    IptvSource source,
    String path, {
    int limit = 200,
  }) async {
    final base = _base(source);
    final uri = Uri.parse(
      '$base$path',
    ).replace(queryParameters: {'X-Plex-Container-Size': '$limit'});
    try {
      final response = await _http.get(uri, headers: _headers(source));
      if (response.statusCode >= 400) return const [];
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
      final list =
          container['Metadata'] as List? ??
          container['Video'] as List? ??
          const [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Keep a Live TV transcoder session alive (Plex reaps idle sessions).
  Future<void> pingLiveSession(
    IptvSource source, {
    required String sessionKey,
    String state = 'playing',
  }) async {
    final key = sessionKey.trim();
    if (key.isEmpty) return;
    final base = _base(source);
    final uri = Uri.parse('$base/:/timeline').replace(
      queryParameters: {
        'key': key,
        'playbackTime': '0',
        'time': '0',
        'duration': '0',
        'state': state,
      },
    );
    try {
      await _http.get(uri, headers: _headers(source));
    } catch (_) {}
  }

  /// Guide programmes for a Live TV channel (today + tomorrow, local day).
  Future<List<EpgProgram>> liveGuide(
    IptvSource source, {
    required String dvrId,
    required String channelGridKey,
    String? lineup,
  }) async {
    final gridKey = channelGridKey.trim();
    final dvr = dvrId.trim();
    if (gridKey.isEmpty) return const [];
    final useCloudGrid = isFastProvider(source) || dvr.isEmpty;

    final now = DateTime.now();
    final days = <DateTime>[
      DateTime(now.year, now.month, now.day),
      DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
    ];
    final out = <EpgProgram>[];
    final seen = <String>{};
    for (final day in days) {
      final date =
          '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      final epgPaths = useCloudGrid
          ? const <String>['']
          : _epgProviderPaths({
              'key': dvr,
              if (lineup != null && lineup.trim().isNotEmpty) 'lineup': lineup,
            }).toList();
      for (final epgPath in epgPaths) {
        final programs = await _fetchGuideDay(
          source,
          epgPath: epgPath,
          channelGridKey: gridKey,
          date: date,
        );
        if (programs.isEmpty) continue;
        for (final p in programs) {
          final stamp =
              '${p.start.toUtc().millisecondsSinceEpoch}|${p.title}|${p.end.toUtc().millisecondsSinceEpoch}';
          if (seen.add(stamp)) out.add(p);
        }
        break;
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  Future<List<EpgProgram>> _fetchGuideDay(
    IptvSource source, {
    required String epgPath,
    required String channelGridKey,
    required String date,
  }) async {
    final base = _base(source);
    final uri = Uri.parse('$base$epgPath/grid').replace(
      queryParameters: {'channelGridKey': channelGridKey, 'date': date},
    );
    try {
      final response = await _http.get(uri, headers: _headers(source));
      if (response.statusCode >= 400) return const [];
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
      final list = container['Metadata'] as List? ?? const [];
      final out = <EpgProgram>[];
      for (final raw in list.whereType<Map>()) {
        final m = Map<String, dynamic>.from(raw);
        final mediaList =
            (m['Media'] as List?)?.whereType<Map>().toList() ?? const [];
        final media = mediaList.isEmpty ? null : mediaList.first;
        final begins =
            (media?['beginsAt'] as num?)?.toInt() ??
            (m['beginsAt'] as num?)?.toInt();
        final ends =
            (media?['endsAt'] as num?)?.toInt() ??
            (m['endsAt'] as num?)?.toInt();
        if (begins == null || ends == null || ends <= begins) continue;
        final title = (m['title'] as String?)?.trim();
        if (title == null || title.isEmpty) continue;
        final thumbRaw =
            m['thumb'] as String? ??
            media?['channelThumb'] as String? ??
            (m['Image'] as List?)
                ?.whereType<Map>()
                .map((i) => '${i['url'] ?? ''}')
                .firstWhere((u) => u.isNotEmpty, orElse: () => '');
        final thumb = (thumbRaw ?? '').trim();
        out.add(
          EpgProgram(
            channelId: channelGridKey,
            title: title,
            start: DateTime.fromMillisecondsSinceEpoch(
              begins * 1000,
              isUtc: true,
            ),
            end: DateTime.fromMillisecondsSinceEpoch(ends * 1000, isUtc: true),
            description: (m['summary'] as String?)?.trim(),
            imageUrl: _absPath(source, thumb.isEmpty ? null : thumb),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _listDvrs(IptvSource source) async {
    final base = _base(source);
    final uri = Uri.parse('$base/livetv/dvrs');
    final response = await _http.get(uri, headers: _headers(source));
    if (response.statusCode >= 400) {
      throw Exception('Plex Live TV DVR list failed (${response.statusCode})');
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
    final list = container['Dvr'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<List<Map<String, dynamic>>> _channelsForDvr(
    IptvSource source,
    Map<String, dynamic> dvr,
  ) async {
    final dvrId = '${dvr['key'] ?? ''}'.trim();
    if (dvrId.isEmpty) return const [];

    // Prefer the DVR channels endpoint (works for managed users too).
    final fromDvr = await _getChannelList(
      source,
      '/livetv/dvrs/${Uri.encodeComponent(dvrId)}/channels',
    );
    if (fromDvr.isNotEmpty) return fromDvr;

    // Fallback used by official clients / non-admin accounts.
    for (final epgPath in _epgProviderPaths(dvr)) {
      final channels = await _getChannelList(
        source,
        '$epgPath/lineups/dvr/channels',
      );
      if (channels.isNotEmpty) return channels;
    }

    final lineup = '${dvr['lineup'] ?? ''}'.trim();
    if (lineup.isNotEmpty) {
      final fromLineup = await _getChannelList(
        source,
        '/livetv/epg/channels',
        query: {'lineup': lineup},
      );
      if (fromLineup.isNotEmpty) return fromLineup;
    }

    return const [];
  }

  Iterable<String> _epgProviderPaths(Map<String, dynamic> dvr) sync* {
    final dvrId = '${dvr['key'] ?? ''}'.trim();
    if (dvrId.isEmpty) return;

    final lineup = '${dvr['lineup'] ?? ''}';
    // lineup://tv.plex.providers.epg.cloud/... or onconnect / xmltv / custom
    final match = RegExp(
      r'tv\.plex\.providers\.epg\.([a-zA-Z0-9_-]+)',
    ).firstMatch(lineup);
    if (match != null) {
      yield '/tv.plex.providers.epg.${match.group(1)}:$dvrId';
    }
    // Common defaults when lineup URI is missing or unusual.
    yield '/tv.plex.providers.epg.cloud:$dvrId';
    yield '/tv.plex.providers.epg.xmltv:$dvrId';
  }

  Future<List<Map<String, dynamic>>> _getChannelList(
    IptvSource source,
    String path, {
    Map<String, String>? query,
  }) async {
    final base = _base(source);
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    try {
      final response = await _http.get(uri, headers: _headers(source));
      if (response.statusCode >= 400) return const [];
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
      final list =
          container['Channel'] as List? ??
          container['Metadata'] as List? ??
          const [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<MediaItem>> _fastLiveChannels(IptvSource source) async {
    final channels = await _getChannelList(source, '/lineups/plex/channels');
    if (channels.isEmpty) return const [];
    final out = <MediaItem>[];
    final seen = <String>{};
    for (final raw in channels) {
      final item = _mapFastChannel(raw, source: source);
      if (item == null || !seen.add(item.id)) continue;
      out.add(item);
    }
    return out;
  }

  Future<String> _fastStreamUrl(IptvSource source, String channelId) async {
    final id = channelId.trim();
    if (id.isEmpty) {
      throw Exception('Plex Live TV channel id required');
    }
    await _fastTune(source, id);
    final base = _base(source);
    final token = _token(source);
    return Uri.parse('$base/library/parts/$id.m3u8')
        .replace(
          queryParameters: {
            'includeAllStreams': '1',
            'X-Plex-Product': 'JAVP',
            'X-Plex-Client-Identifier': clientIdentifier,
            'X-Plex-Token': token,
          },
        )
        .toString();
  }

  /// HLS for plex.tv free movies/shows (AVOD). Always transcode — hosted VOD
  /// rarely exposes a direct file, and some titles still need DRM we don't have.
  Future<String> _vodStreamUrl(
    IptvSource source,
    String itemId, {
    MediaServerStreamQuality quality = MediaServerStreamQuality.original,
  }) async {
    final id = itemId.trim();
    if (id.isEmpty) {
      throw Exception('Plex movie id required');
    }
    final token = _token(source);
    final bitrate = quality.maxBitrateKbps ?? 20000;
    final resolution = quality.plexVideoResolution ?? '1920x1080';
    return Uri.parse('$vodProviderUrl/video/:/transcode/universal/start.m3u8')
        .replace(
          queryParameters: {
            'path': '/library/metadata/$id',
            'mediaIndex': '0',
            'partIndex': '0',
            'protocol': 'hls',
            'fastSeek': '1',
            'directPlay': '0',
            'directStream': '1',
            'videoQuality': '100',
            'videoResolution': resolution,
            'maxVideoBitrate': '$bitrate',
            'subtitleSize': '100',
            'audioBoost': '100',
            'X-Plex-Platform': 'Chrome',
            'X-Plex-Client-Identifier': clientIdentifier,
            'X-Plex-Product': 'JAVP',
            'X-Plex-Device': 'Chrome',
            'X-Plex-Token': token,
          },
        )
        .toString();
  }

  Future<void> _fastTune(IptvSource source, String channelId) async {
    final base = _base(source);
    try {
      await _http
          .post(
            Uri.parse('$base/channels/${Uri.encodeComponent(channelId)}/tune'),
            headers: _headers(source),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  MediaItem? _mapLiveChannel(
    Map<String, dynamic> m, {
    required IptvSource source,
    required String dvrId,
    required String group,
  }) {
    final tuneId = _liveTuneId(m);
    if (tuneId == null) return null;

    final title = (m['title'] as String?)?.trim().isNotEmpty == true
        ? (m['title'] as String).trim()
        : (m['callSign'] as String?)?.trim().isNotEmpty == true
        ? (m['callSign'] as String).trim()
        : tuneId;
    final channelNumber =
        '${m['vcn'] ?? m['channelNumber'] ?? m['identifier'] ?? tuneId}'.trim();
    final epgId = '${m['gridKey'] ?? m['id'] ?? m['channelKey'] ?? tuneId}'
        .trim();
    final thumb = m['thumb'] as String? ?? m['art'] as String?;
    final stableKey = epgId.isNotEmpty ? epgId : tuneId;

    return MediaItem(
      id: 'plex-live-${source.id}-$dvrId-$stableKey',
      title: title,
      playUrl: '',
      kind: MediaKind.live,
      origin: MediaOrigin.plex,
      subtitle: [
        if (channelNumber.isNotEmpty && channelNumber != title) channelNumber,
        group,
      ].where((s) => s.isNotEmpty).join(' · '),
      thumbnailUrl: _absPath(source, thumb, origin: _base(source)),
      posterUrl: _absPath(source, thumb, origin: _base(source)),
      group: group,
      channelId: channelNumber.isEmpty ? tuneId : channelNumber,
      channelName: title,
      streamId: tuneId,
      epgChannelId: epgId.isEmpty ? null : epgId,
      // Start Over / short timeshift when guide ids exist.
      catchupDays: epgId.isEmpty ? 0 : 1,
      sourceId: source.id,
      serverItemId: liveServerItemId(dvrId: dvrId, channelId: tuneId),
      contentRating: (m['contentRating'] as String?)?.trim(),
      isAdult: resolveIsAdult(
        flag: m['adult'],
        contentRating: (m['contentRating'] as String?)?.trim(),
        labels: (m['Label'] as List?)
            ?.whereType<Map>()
            .map((g) => '${g['tag'] ?? ''}')
            .where((g) => g.isNotEmpty),
      ),
    );
  }

  MediaItem? _mapFastChannel(
    Map<String, dynamic> m, {
    required IptvSource source,
  }) {
    final rawId = '${m['id'] ?? ''}'.trim();
    final gridKey = '${m['gridKey'] ?? ''}'.trim();
    final playId = rawId.isNotEmpty
        ? rawId
        : (normalizeFastChannelId(gridKey) ?? '');
    if (playId.isEmpty) return null;
    final epgId = gridKey.isNotEmpty
        ? gridKey
        : (normalizeFastChannelId(rawId) ?? playId);
    final title = (m['title'] as String?)?.trim().isNotEmpty == true
        ? (m['title'] as String).trim()
        : (m['callSign'] as String?)?.trim().isNotEmpty == true
        ? (m['callSign'] as String).trim()
        : (m['slug'] as String?)?.trim().isNotEmpty == true
        ? (m['slug'] as String).trim()
        : epgId;
    final channelNumber = '${m['vcn'] ?? m['channelNumber'] ?? ''}'.trim();
    final thumb = m['thumb'] as String? ?? m['art'] as String?;
    const group = 'Plex Live TV';
    return MediaItem(
      id: 'plex-fast-${source.id}-$epgId',
      title: title,
      playUrl: '',
      kind: MediaKind.live,
      origin: MediaOrigin.plex,
      subtitle: [
        if (channelNumber.isNotEmpty && channelNumber != title) channelNumber,
        group,
      ].where((s) => s.isNotEmpty).join(' · '),
      thumbnailUrl: _absPath(source, thumb, origin: _base(source)),
      posterUrl: _absPath(source, thumb, origin: _base(source)),
      group: group,
      channelId: channelNumber.isEmpty ? epgId : channelNumber,
      channelName: title,
      streamId: playId,
      epgChannelId: epgId,
      catchupDays: 0,
      sourceId: source.id,
      serverItemId: fastServerItemId(playId),
      contentRating: (m['contentRating'] as String?)?.trim(),
      plot: (m['summary'] as String?)?.trim(),
      httpHeaders: _watchPlexHeaders,
      isAdult: resolveIsAdult(
        flag: m['adult'],
        contentRating: (m['contentRating'] as String?)?.trim(),
        labels: (m['Label'] as List?)
            ?.whereType<Map>()
            .map((g) => '${g['tag'] ?? ''}')
            .where((g) => g.isNotEmpty),
      ),
    );
  }

  String? _liveTuneId(Map<String, dynamic> m) {
    for (final key in const [
      'deviceIdentifier',
      'vcn',
      'channelIdentifier',
      'identifier',
      'key',
      'id',
      'channelKey',
      'gridKey',
    ]) {
      final raw = '${m[key] ?? ''}'.trim();
      if (raw.isEmpty) continue;
      // key may be a path like /library/metadata/…
      if (key == 'key' && raw.contains('/')) continue;
      // Prefer short tune ids; keep long EPG keys as last-resort fallbacks.
      if ((key == 'channelKey' || key == 'gridKey' || key == 'id') &&
          raw.contains('-') &&
          raw.length > 20) {
        continue;
      }
      return raw;
    }
    for (final key in const ['channelKey', 'gridKey', 'id']) {
      final raw = '${m[key] ?? ''}'.trim();
      if (raw.isNotEmpty) return raw;
    }
    return null;
  }

  String? _extractLiveSessionUuid(Map<String, dynamic> root) {
    final container = root['MediaContainer'] is Map
        ? Map<String, dynamic>.from(root['MediaContainer'] as Map)
        : root;

    // Official tune sample: MediaContainer.Metadata[].Media[].uuid
    // PMS often returns a single object instead of a one-element array.
    for (final meta in _asList(container['Metadata'])) {
      final fromMeta =
          _uuidFromMediaNode(meta) ??
          _liveSessionUuidFromString('${meta['uuid'] ?? meta['key'] ?? ''}');
      if (fromMeta != null) return fromMeta;
    }

    // Alternate shapes: MediaSubscription → MediaGrabOperation → Video/Metadata
    // and MediaGrabOperation directly under MediaContainer.
    final ops = <Map<String, dynamic>>[
      for (final sub in _asList(container['MediaSubscription']))
        ..._asList(sub['MediaGrabOperation']),
      ..._asList(container['MediaGrabOperation']),
    ];
    for (final op in ops) {
      for (final videoKey in const ['Video', 'Metadata', 'Media']) {
        final node = op[videoKey];
        if (node is Map) {
          final uuid =
              _uuidFromMediaNode(Map<String, dynamic>.from(node)) ??
              _liveSessionUuidFromString(
                '${node['uuid'] ?? node['key'] ?? ''}',
              );
          if (uuid != null) return uuid;
        } else if (videoKey == 'Media') {
          final uuid = _uuidFromMediaNode(op);
          if (uuid != null) return uuid;
        }
      }
    }

    // Last resort: any Media.uuid / /livetv/sessions/{uuid} key in the tree.
    return _findMediaUuid(root);
  }

  /// Poll active Live TV sessions after a tune that omitted Media.uuid.
  Future<String?> _resolveLiveSessionUuid(
    IptvSource source, {
    required String channelId,
  }) async {
    final wanted = channelId.trim().toLowerCase();
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
      final sessions = await _listLiveSessions(source);
      if (sessions.isEmpty) continue;
      for (final meta in sessions) {
        final channelMatch = _sessionMatchesChannel(meta, wanted);
        final uuid =
            _uuidFromMediaNode(meta) ??
            _liveSessionUuidFromString('${meta['uuid'] ?? meta['key'] ?? ''}');
        if (uuid != null && (channelMatch || wanted.isEmpty)) return uuid;
      }
      // No channel match — still prefer the newest session with a uuid.
      for (final meta in sessions.reversed) {
        final uuid =
            _uuidFromMediaNode(meta) ??
            _liveSessionUuidFromString('${meta['uuid'] ?? meta['key'] ?? ''}');
        if (uuid != null) return uuid;
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _listLiveSessions(
    IptvSource source,
  ) async {
    final base = _base(source);
    try {
      final response = await _http.get(
        Uri.parse('$base/livetv/sessions'),
        headers: _headers(source),
      );
      if (response.statusCode >= 400) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return const [];
      final root = Map<String, dynamic>.from(decoded);
      final container = root['MediaContainer'] is Map
          ? Map<String, dynamic>.from(root['MediaContainer'] as Map)
          : root;
      return _asList(container['Metadata']);
    } catch (_) {
      return const [];
    }
  }

  bool _sessionMatchesChannel(Map<String, dynamic> meta, String wanted) {
    if (wanted.isEmpty) return true;
    final candidates = <String>[
      '${meta['channelIdentifier'] ?? ''}',
      '${meta['channelID'] ?? ''}',
      '${meta['channelId'] ?? ''}',
      '${meta['sourceTitle'] ?? ''}',
      '${meta['title'] ?? ''}',
      '${meta['index'] ?? ''}',
    ];
    for (final media in _asList(meta['Media'])) {
      candidates.addAll([
        '${media['channelIdentifier'] ?? ''}',
        '${media['channelID'] ?? ''}',
        '${media['channelId'] ?? ''}',
        '${media['deviceIdentifier'] ?? ''}',
        '${media['vcn'] ?? ''}',
      ]);
    }
    for (final raw in candidates) {
      final value = raw.trim().toLowerCase();
      if (value.isEmpty) continue;
      if (value == wanted || value.endsWith(wanted) || wanted.endsWith(value)) {
        return true;
      }
    }
    return false;
  }

  String? _uuidFromMediaNode(Map<String, dynamic> node) {
    for (final media in _asList(node['Media'])) {
      // Media.uuid is the session id when present (not always a RFC UUID).
      final rawUuid = '${media['uuid'] ?? ''}'.trim();
      if (rawUuid.isNotEmpty && !rawUuid.contains('/')) return rawUuid;
      final fromKey = _liveSessionUuidFromString('${media['key'] ?? ''}');
      if (fromKey != null) return fromKey;
    }
    return null;
  }

  String? _liveSessionUuidFromString(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final sessionPath = RegExp(
      r'/livetv/sessions/([^/?#]+)',
      caseSensitive: false,
    ).firstMatch(value);
    if (sessionPath != null) {
      final id = Uri.decodeComponent(sessionPath.group(1)!).trim();
      if (id.isNotEmpty) return id;
    }
    // Bare session ids are usually UUIDs; ignore unrelated strings/paths.
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).firstMatch(value);
    if (uuid != null) return uuid.group(0);
    return null;
  }

  /// Plex JSON collapses one-element arrays into bare objects.
  List<Map<String, dynamic>> _asList(dynamic value) {
    if (value is List) {
      return [
        for (final e in value)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    if (value is Map) return [Map<String, dynamic>.from(value)];
    return const [];
  }

  String? _findMediaUuid(dynamic node) {
    if (node is Map) {
      final asMap = Map<String, dynamic>.from(node);
      final fromMedia = _uuidFromMediaNode(asMap);
      if (fromMedia != null) return fromMedia;
      final direct = _liveSessionUuidFromString(
        '${asMap['uuid'] ?? asMap['key'] ?? ''}',
      );
      if (direct != null) return direct;
      for (final value in asMap.values) {
        final found = _findMediaUuid(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findMediaUuid(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  @override
  Future<List<MediaSegment>> mediaSegments(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  ) async {
    // Plex markers vary by version; fail soft.
    return const [];
  }

  @override
  Future<void> reportProgress(
    IptvSource source,
    MediaServerSession session, {
    required String itemId,
    required Duration position,
    required bool isPaused,
    Duration? duration,
    bool stopped = false,
  }) async {
    if (parseFastServerItemId(itemId) != null ||
        parseLiveServerItemId(itemId) != null) {
      return;
    }
    final base = _contentBase(source, session);
    final state = stopped ? 'stopped' : (isPaused ? 'paused' : 'playing');
    final durationMs = duration?.inMilliseconds ?? 0;
    final rawTime = position.inMilliseconds;
    final timeMs = durationMs > 0
        ? rawTime.clamp(0, durationMs)
        : (rawTime < 0 ? 0 : rawTime);
    final timeline = Uri.parse('$base/:/timeline').replace(
      queryParameters: {
        'ratingKey': itemId,
        'key': '/library/metadata/$itemId',
        'state': state,
        'time': '$timeMs',
        'duration': '$durationMs',
      },
    );
    try {
      await _http.get(timeline, headers: _headers(source));
    } catch (_) {}
  }

  @override
  Future<void> setPlayed(
    IptvSource source,
    MediaServerSession session,
    String itemId, {
    required bool played,
  }) async {
    if (parseFastServerItemId(itemId) != null ||
        parseLiveServerItemId(itemId) != null) {
      return;
    }
    final base = _contentBase(source, session);
    final action = played ? 'scrobble' : 'unscrobble';
    final uri = Uri.parse('$base/:/$action').replace(
      queryParameters: {
        'key': itemId,
        'identifier': 'com.plexapp.plugins.library',
      },
    );
    try {
      await _http.get(uri, headers: _headers(source));
    } catch (_) {}
  }

  @override
  Future<double?> remoteProgress(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  ) async {
    if (parseFastServerItemId(itemId) != null ||
        parseLiveServerItemId(itemId) != null) {
      return null;
    }
    final base = _contentBase(source, session);
    final uri = Uri.parse('$base/library/metadata/$itemId');
    try {
      final response = await _http.get(uri, headers: _headers(source));
      if (response.statusCode >= 400) return null;
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final container = map['MediaContainer'] as Map<String, dynamic>? ?? map;
      final list = container['Metadata'] as List? ?? const [];
      if (list.isEmpty || list.first is! Map) return null;
      final meta = Map<String, dynamic>.from(list.first as Map);
      final durationMs = (meta['duration'] as num?)?.toInt();
      final viewOffset = (meta['viewOffset'] as num?)?.toInt();
      if (durationMs == null || durationMs <= 0) {
        // Fully watched items often clear viewOffset; treat viewCount as done.
        final viewCount = (meta['viewCount'] as num?)?.toInt() ?? 0;
        return viewCount > 0 ? 1.0 : null;
      }
      if (viewOffset == null || viewOffset <= 0) {
        final viewCount = (meta['viewCount'] as num?)?.toInt() ?? 0;
        return viewCount > 0 ? 1.0 : 0.0;
      }
      return (viewOffset / durationMs).clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  String? _absPath(IptvSource source, String? path, {String? origin}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final base = origin ?? _contentBase(source);
    final token = _token(source);
    return '$base$path?X-Plex-Token=${Uri.encodeQueryComponent(token)}';
  }

  MediaItem? _mapCatalogMeta(
    Map<String, dynamic> m, {
    required IptvSource source,
  }) {
    if (isFastProvider(source) && !plexCloudMetadataIsListed(m)) return null;
    return _mapMeta(m, source: source);
  }

  MediaItem? _mapMeta(Map<String, dynamic> m, {required IptvSource source}) {
    final ratingKey = '${m['ratingKey'] ?? ''}';
    final title = m['title'] as String?;
    if (ratingKey.isEmpty || title == null) return null;
    final type = m['type'] as String? ?? '';
    if (type == 'season' ||
        type == 'artist' ||
        type == 'album' ||
        type == 'track' ||
        type == 'clip' ||
        type == 'trailer' ||
        type == 'extra' ||
        type == 'collection' ||
        type == 'playlist' ||
        type == 'person' ||
        type == 'photo' ||
        type == 'photoalbum') {
      return null;
    }
    final kind = type == 'show' ? MediaKind.series : MediaKind.vod;
    final thumb = m['thumb'] as String?;
    final art = m['art'] as String?;

    final genres =
        (m['Genre'] as List?)
            ?.whereType<Map>()
            .map((g) => '${g['tag'] ?? ''}')
            .where((g) => g.isNotEmpty)
            .toList() ??
        const <String>[];
    final labels =
        (m['Label'] as List?)
            ?.whereType<Map>()
            .map((g) => '${g['tag'] ?? ''}')
            .where((g) => g.isNotEmpty)
            .toList() ??
        const <String>[];
    final contentRating = (m['contentRating'] as String?)?.trim();
    final isAdult = resolveIsAdult(
      flag: m['adult'],
      contentRating: contentRating,
      labels: labels,
      genres: genres,
    );
    final guids = m['Guid'] as List? ?? const [];
    int? tmdbId;
    String? imdbId;
    for (final g in guids) {
      if (g is! Map) continue;
      final id = '${g['id'] ?? ''}';
      if (id.startsWith('tmdb://')) {
        tmdbId = int.tryParse(id.replaceFirst('tmdb://', ''));
      } else if (id.startsWith('imdb://')) {
        imdbId = id.replaceFirst('imdb://', '');
      }
    }

    final durationMs = (m['duration'] as num?)?.toInt();
    final viewOffset = (m['viewOffset'] as num?)?.toInt();
    final progress =
        (durationMs != null &&
            durationMs > 0 &&
            viewOffset != null &&
            viewOffset > 0)
        ? (viewOffset / durationMs).clamp(0.0, 1.0)
        : 0.0;

    final grandparentKey = '${m['grandparentRatingKey'] ?? ''}';
    final seriesId = type == 'episode' && grandparentKey.isNotEmpty
        ? 'plex-${source.id}-$grandparentKey'
        : null;

    return MediaItem(
      id: 'plex-${source.id}-$ratingKey',
      title: title,
      playUrl: '',
      kind: kind,
      origin: MediaOrigin.plex,
      subtitle: [
        if (m['year'] != null) '${m['year']}',
        if (type == 'episode') 'S${m['parentIndex'] ?? 0}E${m['index'] ?? 0}',
        if (genres.isNotEmpty) genres.take(2).join(', '),
      ].join(' · '),
      thumbnailUrl: _absPath(source, thumb),
      posterUrl: _absPath(source, thumb),
      backdropUrl: _absPath(source, art),
      group: m['librarySectionTitle'] as String? ?? type,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      progress: progress,
      sourceId: source.id,
      serverItemId: ratingKey,
      seriesId: seriesId,
      tmdbId: tmdbId,
      imdbId: imdbId,
      plot: m['summary'] as String?,
      genres: genres,
      rating:
          (m['rating'] as num?)?.toDouble() ??
          (m['audienceRating'] as num?)?.toDouble(),
      year: (m['year'] as num?)?.toInt(),
      seasonNumber: type == 'episode'
          ? (m['parentIndex'] as num?)?.toInt()
          : null,
      episodeNumber: type == 'episode' ? (m['index'] as num?)?.toInt() : null,
      contentRating: contentRating,
      isAdult: isAdult,
      httpHeaders: isFastProvider(source) ? _watchPlexHeaders : const {},
    );
  }

  void close() => _http.close();
}
