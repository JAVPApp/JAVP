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

/// Jellyfin REST client (Emby-compatible endpoints with small differences).
class JellyfinClient implements MediaServerClient {
  JellyfinClient({
    http.Client? httpClient,
    this.clientName = 'JAVP',
    this.isEmby = false,
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String clientName;
  final bool isEmby;
  final Set<String> _activePlaybackIds = {};

  /// Prefix for Live TV [MediaItem.serverItemId] values.
  static const liveServerItemPrefix = 'live:';

  /// Last opened LiveStreamId (closed on zap / dispose).
  String? lastLiveStreamId;

  static String liveServerItemId(String channelId, {DateTime? startAt}) {
    final id = channelId.trim();
    if (startAt == null) return '$liveServerItemPrefix$id';
    return '$liveServerItemPrefix$id@${startAt.toUtc().millisecondsSinceEpoch}';
  }

  static ({String channelId, DateTime? startAt})? parseLiveServerItemId(
    String itemId,
  ) {
    if (!itemId.startsWith(liveServerItemPrefix)) return null;
    final rest = itemId.substring(liveServerItemPrefix.length).trim();
    if (rest.isEmpty) return null;
    final at = rest.lastIndexOf('@');
    if (at <= 0) return (channelId: rest, startAt: null);
    final channelId = rest.substring(0, at).trim();
    final ms = int.tryParse(rest.substring(at + 1));
    if (channelId.isEmpty) return null;
    return (
      channelId: channelId,
      startAt: ms == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    );
  }

  String _base(IptvSource source) {
    final raw = (source.serverUrl ?? '').trim();
    if (raw.isEmpty) throw Exception('Server URL required');
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  Map<String, String> _headers(MediaServerSession? session) {
    final auth = StringBuffer(
      'MediaBrowser Client="$clientName", Device="Android", '
      'DeviceId="javp-android", Version="0.1.0"',
    );
    if (session != null) {
      auth.write(', Token="${session.accessToken}"');
    }
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Emby-Authorization': auth.toString(),
      if (session != null) 'X-Emby-Token': session.accessToken,
    };
  }

  @override
  Future<MediaServerSession> authenticate(IptvSource source) async {
    final base = _base(source);
    final user = source.username?.trim() ?? '';
    final pass = source.password ?? '';
    if (user.isEmpty) throw Exception('Username required');

    final uri = Uri.parse('$base/Users/AuthenticateByName');
    final response = await _http.post(
      uri,
      headers: _headers(null),
      body: jsonEncode({'Username': user, 'Pw': pass}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        '${isEmby ? 'Emby' : 'Jellyfin'} auth failed (${response.statusCode})',
      );
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final userMap = map['User'] as Map<String, dynamic>? ?? const {};
    final token = map['AccessToken'] as String? ?? '';
    final userId = userMap['Id'] as String? ?? '';
    if (token.isEmpty || userId.isEmpty) {
      throw Exception('Invalid auth response');
    }
    return MediaServerSession(
      userId: userId,
      accessToken: token,
      serverName: map['ServerName'] as String? ?? source.name,
    );
  }

  @override
  Future<List<MediaServerLibrary>> libraries(
    IptvSource source,
    MediaServerSession session,
  ) async {
    final base = _base(source);
    final uri = Uri.parse('$base/Users/${session.userId}/Views');
    final response = await _http.get(uri, headers: _headers(session));
    if (response.statusCode >= 400) return const [];
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final items = map['Items'] as List? ?? const [];
    return items.whereType<Map>().map((raw) {
      final m = Map<String, dynamic>.from(raw);
      return MediaServerLibrary(
        id: m['Id'] as String? ?? '',
        name: m['Name'] as String? ?? '',
        collectionType: m['CollectionType'] as String?,
        itemCount: (m['ChildCount'] as num?)?.toInt() ?? 0,
      );
    }).where((l) => l.id.isNotEmpty).toList();
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
    final base = _base(source);
    final params = <String, String>{
      'IncludeItemTypes': 'Movie,Series,Episode',
      'Recursive': 'true',
      'Fields':
          'Overview,Genres,Tags,OfficialRating,PrimaryImageAspectRatio,BasicSyncInfo,Path,MediaSources',
      'ImageTypeLimit': '1',
      'EnableImageTypes': 'Primary,Backdrop,Thumb',
      'StartIndex': '$startIndex',
      'Limit': '$limit',
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
    };
    if (parentId != null && parentId.isNotEmpty) {
      // Keep IncludeItemTypes + Recursive so library sync pulls movies/shows
      // (including nested ones) and never music/photo/book rows as VOD.
      params['ParentId'] = parentId;
    }
    if (search != null && search.trim().isNotEmpty) {
      params['SearchTerm'] = search.trim();
      params['Recursive'] = 'true';
      // Avoid flat episode hits — search should surface series shells + movies.
      params['IncludeItemTypes'] = 'Movie,Series';
    }

    final uri = Uri.parse('$base/Users/${session.userId}/Items')
        .replace(queryParameters: params);
    final response = await _http.get(uri, headers: _headers(session));
    if (response.statusCode >= 400) {
      return const MediaServerPage(items: []);
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final rawItems = map['Items'] as List? ?? const [];
    final items = <MediaItem>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final item = _mapItem(
        Map<String, dynamic>.from(raw),
        source: source,
        session: session,
      );
      if (item != null) items.add(item);
    }
    return MediaServerPage(
      items: items,
      totalCount: (map['TotalRecordCount'] as num?)?.toInt() ?? items.length,
      startIndex: startIndex,
    );
  }

  @override
  Future<MediaDetails?> details(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  ) async {
    final base = _base(source);
    final uri = Uri.parse('$base/Users/${session.userId}/Items/$itemId');
    final response = await _http.get(uri, headers: _headers(session));
    if (response.statusCode >= 400) return null;
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    var seasons = const <SeriesSeasonDetails>[];
    if ((map['Type'] as String?) == 'Series') {
      seasons = await _fetchShowSeasons(source, session, itemId);
    }
    return _mapDetails(
      map,
      source: source,
      session: session,
      seasons: seasons,
    );
  }

  /// Season → episode tree for series shells (mirrors Plex `_fetchShowSeasons`).
  Future<List<SeriesSeasonDetails>> _fetchShowSeasons(
    IptvSource source,
    MediaServerSession session,
    String seriesId,
  ) async {
    final seasonsRaw = await _children(source, session, seriesId);
    final seasons = <SeriesSeasonDetails>[];
    for (final seasonMap in seasonsRaw) {
      if ((seasonMap['Type'] as String?) != 'Season') continue;
      final seasonId = seasonMap['Id'] as String? ?? '';
      if (seasonId.isEmpty) continue;
      final seasonNum = (seasonMap['IndexNumber'] as num?)?.toInt() ?? 0;
      final seasonTitle =
          seasonMap['Name'] as String? ?? 'Season $seasonNum';

      final episodesRaw = await _children(source, session, seasonId);
      final episodes = <SeriesEpisodeDetails>[];
      for (final ep in episodesRaw) {
        if ((ep['Type'] as String?) != 'Episode') continue;
        final epId = ep['Id'] as String? ?? '';
        if (epId.isEmpty) continue;
        final epNum =
            (ep['IndexNumber'] as num?)?.toInt() ?? episodes.length + 1;
        final runtimeTicks = (ep['RunTimeTicks'] as num?)?.toInt();
        final imageTag = (ep['ImageTags'] as Map?)?['Primary'];
        final base = _base(source);
        final thumb = imageTag == null
            ? null
            : '$base/Items/$epId/Images/Primary?tag=$imageTag'
                '&api_key=${session.accessToken}';
        episodes.add(
          SeriesEpisodeDetails(
            id: epId,
            episodeNumber: epNum,
            seasonNumber: seasonNum,
            title: ep['Name'] as String? ?? 'Episode $epNum',
            plot: ep['Overview'] as String?,
            thumbnailUrl: thumb,
            duration: runtimeTicks == null
                ? null
                : Duration(microseconds: runtimeTicks ~/ 10),
            // Play URL resolved at playback via [serverItemId] = Jellyfin Id.
            playUrl: null,
          ),
        );
      }
      episodes.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

      final seasonImageTag = (seasonMap['ImageTags'] as Map?)?['Primary'];
      final seasonPoster = seasonImageTag == null
          ? null
          : '${_base(source)}/Items/$seasonId/Images/Primary'
              '?tag=$seasonImageTag&api_key=${session.accessToken}';
      seasons.add(
        SeriesSeasonDetails(
          seasonNumber: seasonNum,
          name: seasonTitle,
          posterUrl: seasonPoster,
          episodes: episodes,
        ),
      );
    }
    seasons.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
  }

  Future<List<Map<String, dynamic>>> _children(
    IptvSource source,
    MediaServerSession session,
    String parentId,
  ) async {
    final base = _base(source);
    final uri = Uri.parse('$base/Users/${session.userId}/Items').replace(
      queryParameters: {
        'ParentId': parentId,
        'Recursive': 'false',
        'Fields': 'Overview,RunTimeTicks,PrimaryImageAspectRatio',
        'ImageTypeLimit': '1',
        'EnableImageTypes': 'Primary,Thumb',
        'SortBy': 'IndexNumber,SortName',
        'SortOrder': 'Ascending',
      },
    );
    final response = await _http.get(uri, headers: _headers(session));
    if (response.statusCode >= 400) return const [];
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final list = map['Items'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Live TV channels (empty when Live TV isn't configured).
  Future<List<MediaItem>> liveChannels(
    IptvSource source,
    MediaServerSession session,
  ) async {
    final base = _base(source);
    final uri = Uri.parse('$base/LiveTv/Channels').replace(
      queryParameters: {
        'UserId': session.userId,
        'AddCurrentProgram': 'true',
        'EnableImages': 'true',
        'EnableUserData': 'false',
        'Fields': 'PrimaryImageAspectRatio,ChannelNumber,ChannelName,OfficialRating,Tags,Genres',
      },
    );
    final response = await _http.get(uri, headers: _headers(session));
    if (response.statusCode >= 400) {
      throw Exception(
        '${isEmby ? 'Emby' : 'Jellyfin'} Live TV channels failed '
        '(${response.statusCode})',
      );
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    final items = map['Items'] as List? ?? const [];
    final out = <MediaItem>[];
    for (final raw in items.whereType<Map>()) {
      final item = _mapLiveChannel(
        Map<String, dynamic>.from(raw),
        source: source,
        session: session,
      );
      if (item != null) out.add(item);
    }
    return out;
  }

  /// Completed DVR recordings as on-demand items.
  Future<List<MediaItem>> dvrRecordings(
    IptvSource source,
    MediaServerSession session, {
    int limit = 200,
  }) async {
    final base = _base(source);
    final uri = Uri.parse('$base/LiveTv/Recordings').replace(
      queryParameters: {
        'UserId': session.userId,
        'IsInProgress': 'false',
        'EnableImages': 'true',
        'Fields': 'Overview,RunTimeTicks,Genres,Tags,OfficialRating,PrimaryImageAspectRatio',
        'Limit': '$limit',
        'SortBy': 'DateCreated,SortName',
        'SortOrder': 'Descending',
      },
    );
    try {
      final response = await _http.get(uri, headers: _headers(session));
      if (response.statusCode >= 400) return const [];
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final items = map['Items'] as List? ?? const [];
      final out = <MediaItem>[];
      for (final raw in items.whereType<Map>()) {
        final m = Map<String, dynamic>.from(raw);
        // Force VOD mapping even when Type is Recording / Episode.
        m['Type'] = m['Type'] == 'Series' ? 'Series' : 'Video';
        final item = _mapItem(m, source: source, session: session);
        if (item == null) continue;
        out.add(
          item.copyWith(
            group: 'DVR Recordings',
            subtitle: [
              'Recording',
              if ((item.subtitle ?? '').isNotEmpty) item.subtitle!,
            ].join(' · '),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<EpgProgram>> liveGuide(
    IptvSource source,
    MediaServerSession session, {
    required String channelId,
  }) async {
    final id = channelId.trim();
    if (id.isEmpty) return const [];
    final base = _base(source);
    final now = DateTime.now().toUtc();
    final uri = Uri.parse('$base/LiveTv/Programs').replace(
      queryParameters: {
        'UserId': session.userId,
        'ChannelIds': id,
        'MinStartDate': now.subtract(const Duration(hours: 6)).toIso8601String(),
        'MaxStartDate': now.add(const Duration(hours: 36)).toIso8601String(),
        'EnableImages': 'true',
        'SortBy': 'StartDate',
        'SortOrder': 'Ascending',
        'Limit': '80',
      },
    );
    try {
      final response = await _http.get(uri, headers: _headers(session));
      if (response.statusCode >= 400) return const [];
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final items = map['Items'] as List? ?? const [];
      final out = <EpgProgram>[];
      for (final raw in items.whereType<Map>()) {
        final m = Map<String, dynamic>.from(raw);
        final startRaw = m['StartDate'] as String?;
        final endRaw = m['EndDate'] as String?;
        final title = (m['Name'] as String?)?.trim();
        if (startRaw == null || endRaw == null || title == null || title.isEmpty) {
          continue;
        }
        final start = DateTime.tryParse(startRaw)?.toUtc();
        final end = DateTime.tryParse(endRaw)?.toUtc();
        if (start == null || end == null || !end.isAfter(start)) continue;
        final imageTag = (m['ImageTags'] as Map?)?['Primary'];
        final programId = m['Id'] as String?;
        final imageUrl = (imageTag != null && programId != null)
            ? '$base/Items/$programId/Images/Primary?tag=$imageTag&api_key=${session.accessToken}'
            : null;
        out.add(
          EpgProgram(
            channelId: id,
            title: title,
            start: start,
            end: end,
            description: (m['Overview'] as String?)?.trim(),
            imageUrl: imageUrl,
            hasArchive: m['HasAired'] == true || m['IsRepeat'] == true,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> closeLiveStream(
    IptvSource source,
    MediaServerSession session, {
    String? liveStreamId,
  }) async {
    final id = (liveStreamId ?? lastLiveStreamId)?.trim();
    if (id == null || id.isEmpty) return;
    final base = _base(source);
    try {
      await _http.post(
        Uri.parse('$base/LiveStreams/Close').replace(
          queryParameters: {'LiveStreamId': id},
        ),
        headers: _headers(session),
      );
    } catch (_) {}
    if (lastLiveStreamId == id) lastLiveStreamId = null;
  }

  @override
  Future<String> streamUrl(
    IptvSource source,
    MediaServerSession session,
    String itemId, {
    MediaServerStreamQuality quality = MediaServerStreamQuality.original,
  }) async {
    final live = parseLiveServerItemId(itemId);
    if (live != null) {
      return _liveStreamUrl(
        source,
        session,
        channelId: live.channelId,
        startAt: live.startAt,
        quality: quality,
      );
    }

    final base = _base(source);
    final token = Uri.encodeQueryComponent(session.accessToken);
    final bitrate = quality.maxBitrateKbps;
    if (bitrate != null) {
      // HLS transcode at the chosen ceiling.
      final bits = bitrate * 1000;
      return '$base/Videos/$itemId/master.m3u8'
          '?MaxStreamingBitrate=$bits'
          '&api_key=$token';
    }
    // Direct stream — media_kit handles containers.
    return '$base/Videos/$itemId/stream'
        '?static=true'
        '&api_key=$token';
  }

  Future<String> _liveStreamUrl(
    IptvSource source,
    MediaServerSession session, {
    required String channelId,
    DateTime? startAt,
    MediaServerStreamQuality quality = MediaServerStreamQuality.original,
  }) async {
    final base = _base(source);
    final token = Uri.encodeQueryComponent(session.accessToken);
    final bitrateKbps = quality.maxBitrateKbps ?? 20000;
    final bitrate = bitrateKbps * 1000;
    final startTicks = startAt == null
        ? null
        : startAt.toUtc().microsecondsSinceEpoch * 10;

    // Close any prior tuner session before opening a new one.
    await closeLiveStream(source, session);

    final openBody = <String, dynamic>{
      'ItemId': channelId,
      'UserId': session.userId,
      'MaxStreamingBitrate': bitrate,
      'EnableDirectPlay': quality == MediaServerStreamQuality.original,
      'EnableDirectStream': true,
      if (startTicks != null) 'StartTimeTicks': startTicks,
    };

    try {
      final openResponse = await _http.post(
        Uri.parse('$base/LiveStreams/Open'),
        headers: _headers(session),
        body: jsonEncode(openBody),
      );
      if (openResponse.statusCode < 400) {
        final map = jsonDecode(openResponse.body) as Map<String, dynamic>;
        final sources = (map['MediaSources'] as List?)?.whereType<Map>().toList() ??
            const <Map>[];
        final mediaSource = map['MediaSource'] as Map<String, dynamic>? ??
            (sources.isEmpty
                ? null
                : Map<String, dynamic>.from(sources.first));
        final liveStreamId =
            '${mediaSource?['LiveStreamId'] ?? map['LiveStreamId'] ?? ''}'
                .trim();
        if (liveStreamId.isNotEmpty) lastLiveStreamId = liveStreamId;
        final transcoding = '${mediaSource?['TranscodingUrl'] ?? ''}'.trim();
        if (transcoding.isNotEmpty) {
          if (transcoding.startsWith('http')) return transcoding;
          return '$base$transcoding${transcoding.contains('?') ? '&' : '?'}api_key=$token';
        }
        if (liveStreamId.isNotEmpty) {
          return '$base/Videos/$channelId/master.m3u8'
              '?LiveStreamId=${Uri.encodeQueryComponent(liveStreamId)}'
              '&MaxStreamingBitrate=$bitrate'
              '&api_key=$token';
        }
      }
    } catch (_) {}

    // Fallback used by many clients when Open isn't required.
    final qs = <String, String>{
      'MaxStreamingBitrate': '$bitrate',
      'api_key': session.accessToken,
      if (startTicks != null) 'StartTimeTicks': '$startTicks',
    };
    return Uri.parse('$base/Videos/$channelId/master.m3u8')
        .replace(queryParameters: qs)
        .toString();
  }

  MediaItem? _mapLiveChannel(
    Map<String, dynamic> map, {
    required IptvSource source,
    required MediaServerSession session,
  }) {
    final id = map['Id'] as String?;
    final name = (map['Name'] as String?)?.trim() ??
        (map['ChannelName'] as String?)?.trim();
    if (id == null || name == null || name.isEmpty) return null;
    final base = _base(source);
    final number = '${map['ChannelNumber'] ?? map['Number'] ?? ''}'.trim();
    final imageTag = (map['ImageTags'] as Map?)?['Primary'];
    final thumb = imageTag == null
        ? null
        : '$base/Items/$id/Images/Primary?tag=$imageTag&api_key=${session.accessToken}';
    final current = map['CurrentProgram'] as Map<String, dynamic>?;
    final hasGuide = current != null || map['HasGuideData'] == true;
    return MediaItem(
      id: '${isEmby ? 'emby' : 'jf'}-live-${source.id}-$id',
      title: name,
      playUrl: '',
      kind: MediaKind.live,
      origin: isEmby ? MediaOrigin.emby : MediaOrigin.jellyfin,
      subtitle: [
        if (number.isNotEmpty) number,
        'Live TV',
        if (current?['Name'] != null) '${current!['Name']}',
      ].where((s) => s.toString().isNotEmpty).join(' · '),
      thumbnailUrl: thumb,
      posterUrl: thumb,
      group: 'Live TV',
      channelId: number.isEmpty ? id : number,
      channelName: name,
      streamId: id,
      epgChannelId: id,
      // Enable Start Over / short timeshift when guide data exists.
      catchupDays: hasGuide ? 1 : 0,
      sourceId: source.id,
      serverItemId: liveServerItemId(id),
      contentRating: (map['OfficialRating'] as String?)?.trim(),
      isAdult: resolveIsAdult(
        flag: map['IsAdult'] ?? map['Adult'],
        contentRating: (map['OfficialRating'] as String?)?.trim(),
        tags: (map['Tags'] as List?)?.map((e) => '$e'),
        genres: (map['Genres'] as List?)?.map((e) => '$e'),
      ),
    );
  }

  @override
  Future<List<MediaSegment>> mediaSegments(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  ) async {
    final base = _base(source);
    try {
      final uri = Uri.parse('$base/MediaSegments/$itemId');
      final response = await _http.get(uri, headers: _headers(session));
      if (response.statusCode >= 400) return const [];
      final decoded = jsonDecode(response.body);
      final list = decoded is List
          ? decoded
          : (decoded is Map && decoded['Items'] is List)
              ? decoded['Items'] as List
              : const [];
      final out = <MediaSegment>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final typeName = (m['Type'] as String?)?.toLowerCase() ?? '';
        final type = switch (typeName) {
          'intro' || 'opening' => MediaSegmentType.intro,
          'recap' || 'preview' => typeName == 'recap'
              ? MediaSegmentType.recap
              : MediaSegmentType.preview,
          'outro' || 'credits' || 'endcredits' => MediaSegmentType.credits,
          _ => null,
        };
        if (type == null) continue;
        final startTicks = (m['StartTicks'] as num?)?.toInt() ?? 0;
        final endTicks = (m['EndTicks'] as num?)?.toInt();
        out.add(
          MediaSegment(
            type: type,
            start: Duration(microseconds: startTicks ~/ 10),
            end: endTicks == null
                ? null
                : Duration(microseconds: endTicks ~/ 10),
            source: isEmby ? 'emby' : 'jellyfin',
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
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
    final base = _base(source);
    final ticks = position.inMicroseconds * 10;
    final body = jsonEncode({
      'ItemId': itemId,
      'PositionTicks': ticks,
      'IsPaused': isPaused,
      if (duration != null) 'RunTimeTicks': duration.inMicroseconds * 10,
    });
    final headers = _headers(session);
    try {
      if (stopped) {
        _activePlaybackIds.remove(itemId);
        await _http.post(
          Uri.parse('$base/Sessions/Playing/Stopped'),
          headers: headers,
          body: body,
        );
        return;
      }
      final uri = _activePlaybackIds.add(itemId)
          ? Uri.parse('$base/Sessions/Playing')
          : Uri.parse('$base/Sessions/Playing/Progress');
      await _http.post(uri, headers: headers, body: body);
    } catch (_) {}
  }

  @override
  Future<void> setPlayed(
    IptvSource source,
    MediaServerSession session,
    String itemId, {
    required bool played,
  }) async {
    final base = _base(source);
    final playedUri =
        Uri.parse('$base/Users/${session.userId}/PlayedItems/$itemId');
    final headers = _headers(session);
    try {
      if (played) {
        await _http.post(playedUri, headers: headers);
        return;
      }
      await _http.delete(playedUri, headers: headers);
      // Clear resume point so the item does not stay mid-progress remotely.
      await _http.post(
        Uri.parse('$base/Users/${session.userId}/Items/$itemId/UserData'),
        headers: headers,
        body: jsonEncode({
          'PlaybackPositionTicks': 0,
          'Played': false,
          'PlayedPercentage': 0,
        }),
      );
    } catch (_) {}
  }

  @override
  Future<double?> remoteProgress(
    IptvSource source,
    MediaServerSession session,
    String itemId,
  ) async {
    final base = _base(source);
    final uri = Uri.parse('$base/Users/${session.userId}/Items/$itemId');
    try {
      final response = await _http.get(uri, headers: _headers(session));
      if (response.statusCode >= 400) return null;
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final userData = map['UserData'] as Map<String, dynamic>? ?? const {};
      if (userData['Played'] == true) return 1.0;
      final pct = (userData['PlayedPercentage'] as num?)?.toDouble();
      if (pct != null) return (pct / 100).clamp(0.0, 1.0);
      final positionTicks = (userData['PlaybackPositionTicks'] as num?)?.toInt();
      final runtimeTicks = (map['RunTimeTicks'] as num?)?.toInt();
      if (positionTicks == null ||
          positionTicks <= 0 ||
          runtimeTicks == null ||
          runtimeTicks <= 0) {
        return 0.0;
      }
      return (positionTicks / runtimeTicks).clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  MediaItem? _mapItem(
    Map<String, dynamic> map, {
    required IptvSource source,
    required MediaServerSession session,
  }) {
    final id = map['Id'] as String?;
    final name = map['Name'] as String?;
    if (id == null || name == null) return null;
    final type = map['Type'] as String? ?? '';
    // Drop music / photos / folders / seasons — same idea as Plex (_mapMeta).
    final kind = switch (type) {
      'Series' => MediaKind.series,
      'Episode' || 'Movie' || 'Video' || 'MusicVideo' => MediaKind.vod,
      _ => null,
    };
    if (kind == null) return null;
    final base = _base(source);
    final imageTag = (map['ImageTags'] as Map?)?['Primary'];
    final poster = imageTag == null
        ? null
        : '$base/Items/$id/Images/Primary?tag=$imageTag&api_key=${session.accessToken}';
    final backdropTags = map['BackdropImageTags'] as List? ?? const [];
    final backdrop = backdropTags.isEmpty
        ? null
        : '$base/Items/$id/Images/Backdrop/0?tag=${backdropTags.first}&api_key=${session.accessToken}';
    final genres = (map['Genres'] as List?)?.map((e) => '$e').toList() ??
        const <String>[];
    final tags = (map['Tags'] as List?)?.map((e) => '$e').toList() ??
        const <String>[];
    final contentRating = (map['OfficialRating'] as String?)?.trim();
    final isAdult = resolveIsAdult(
      flag: map['IsAdult'] ?? map['Adult'],
      contentRating: contentRating,
      genres: genres,
      tags: tags,
    );
    final userData = map['UserData'] as Map<String, dynamic>? ?? const {};
    final runtimeTicks = (map['RunTimeTicks'] as num?)?.toInt();
    final provider = map['ProviderIds'] as Map<String, dynamic>? ?? const {};
    final year = (map['ProductionYear'] as num?)?.toInt();

    return MediaItem(
      id: '${isEmby ? 'emby' : 'jf'}-${source.id}-$id',
      title: name,
      playUrl: '', // resolved at play time
      kind: kind,
      origin: isEmby ? MediaOrigin.emby : MediaOrigin.jellyfin,
      subtitle: [
        if (year != null) '$year',
        if (type == 'Episode')
          'S${(map['ParentIndexNumber'] as num?)?.toInt() ?? 0}'
          'E${(map['IndexNumber'] as num?)?.toInt() ?? 0}',
        if (genres.isNotEmpty) genres.take(2).join(', '),
      ].join(' · '),
      thumbnailUrl: poster,
      posterUrl: poster,
      backdropUrl: backdrop,
      group: map['SeriesName'] as String? ?? type,
      duration: runtimeTicks == null
          ? null
          : Duration(microseconds: runtimeTicks ~/ 10),
      progress: (userData['PlayedPercentage'] as num?)?.toDouble() != null
          ? ((userData['PlayedPercentage'] as num).toDouble() / 100)
          : 0,
      sourceId: source.id,
      serverItemId: id,
      seriesId: type == 'Episode' && map['SeriesId'] != null
          ? '${isEmby ? 'emby' : 'jf'}-${source.id}-${map['SeriesId']}'
          : null,
      tmdbId: int.tryParse('${provider['Tmdb'] ?? ''}'),
      imdbId: provider['Imdb'] as String?,
      tvdbId: int.tryParse('${provider['Tvdb'] ?? ''}'),
      plot: map['Overview'] as String?,
      genres: genres,
      rating: (map['CommunityRating'] as num?)?.toDouble(),
      year: year,
      seasonNumber: type == 'Episode'
          ? (map['ParentIndexNumber'] as num?)?.toInt()
          : null,
      episodeNumber: type == 'Episode'
          ? (map['IndexNumber'] as num?)?.toInt()
          : null,
      contentRating: contentRating,
      isAdult: isAdult,
      tags: tags,
    );
  }

  MediaDetails _mapDetails(
    Map<String, dynamic> map, {
    required IptvSource source,
    required MediaServerSession session,
    List<SeriesSeasonDetails> seasons = const [],
  }) {
    final item = _mapItem(map, source: source, session: session)!;
    final people = map['People'] as List? ?? const [];
    final cast = <CastMember>[];
    for (final raw in people.take(20)) {
      if (raw is! Map) continue;
      final p = Map<String, dynamic>.from(raw);
      if ((p['Type'] as String?) != 'Actor') continue;
      cast.add(
        CastMember(
          name: p['Name'] as String? ?? '',
          character: p['Role'] as String?,
          order: cast.length,
        ),
      );
    }
    return MediaDetails(
      id: item.id,
      title: item.title,
      mediaItemId: item.id,
      tmdbId: item.tmdbId,
      imdbId: item.imdbId,
      tvdbId: item.tvdbId,
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

  void close() => _http.close();
}
