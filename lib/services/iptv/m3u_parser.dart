import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/javp_compute.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/iptv/live_ingest_plan.dart';
import 'package:javp/services/iptv/m3u_playlist_io.dart';
import 'package:javp/services/iptv/vod_ingest_plan.dart';
import 'package:javp/services/metadata/external_ids.dart';
import 'package:javp/services/parental/adult_content.dart';
import 'package:javp/services/playback/audio_stream.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:uuid/uuid.dart';

class M3uParseResult {
  const M3uParseResult({required this.items, this.epgUrl});

  final List<MediaItem> items;
  final String? epgUrl;
}

/// M3U ingest for native sync: live and VOD stay packed SQL maps.
class M3uIngestResult {
  const M3uIngestResult({required this.live, required this.vod, this.epgUrl});

  final LiveIngestPlan live;
  final VodIngestPlan vod;
  final String? epgUrl;

  int get liveCount => live.liveCount;
  int get vodCount => vod.vodCount;
}

class _MediaUrlRef {
  const _MediaUrlRef({required this.index, this.group, this.drmKind});

  final int index;
  final String? group;
  final DrmKind? drmKind;
}

/// Minimal EXTINF M3U / M3U8 playlist parser for Live + VOD entries.
///
/// Also accepts basic M3U (URL/path per line, no `#EXTINF`) and common
/// mid-entry directives (`#EXTVLCOPT`, `#KODIPROP`, `#EXTGRP`).
class M3uParser {
  static const _uuid = Uuid();

  /// Decode + parse off the UI isolate (large playlists otherwise ANR).
  static M3uParseResult parseBytes(
    List<int> bytes, {
    required String sourceId,
    MediaKind defaultKind = MediaKind.live,
  }) {
    return M3uParser().parse(
      _decodePlaylistBytes(bytes),
      sourceId: sourceId,
      defaultKind: defaultKind,
    );
  }

  static String _decodePlaylistBytes(List<int> bytes) {
    var start = 0;
    // UTF-8 BOM.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    return utf8.decode(
      start == 0 ? bytes : bytes.sublist(start),
      allowMalformed: true,
    );
  }

  M3uParseResult parse(
    String content, {
    required String sourceId,
    MediaKind defaultKind = MediaKind.live,
  }) {
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    String? epgUrl;
    String? pendingGroup;
    final items = <MediaItem>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXTM3U')) {
        epgUrl ??= _attr(line, 'url-tvg') ?? _attr(line, 'x-tvg-url');
        continue;
      }

      final extGrp = _parseExtGrp(line);
      if (extGrp != null) {
        pendingGroup = extGrp;
        continue;
      }

      if (line.startsWith('#EXTINF')) {
        final media = _nextMediaUrl(lines, i + 1);
        if (media == null) break;

        final url = lines[media.index];
        final attrs = _parseExtInf(line);
        final title = attrs['name']?.trim().isNotEmpty == true
            ? attrs['name']!.trim()
            : _titleFromUrl(url);
        final groupFromAttrs = attrs['group-title']?.trim();
        final group = (groupFromAttrs != null && groupFromAttrs.isNotEmpty)
            ? groupFromAttrs
            : (media.group ?? pendingGroup);
        final logo = attrs['tvg-logo'];
        final tvgId = attrs['tvg-id'];
        final tvgName = attrs['tvg-name']?.trim();
        final catchupDays = int.tryParse(attrs['catchup-days'] ?? '') ?? 0;
        final kind = _inferKind(
          url,
          group,
          defaultKind,
          hasEpgId: tvgId != null && tvgId.isNotEmpty,
          runtime: _parseRuntime(line),
        );
        final audioOnly =
            kind == MediaKind.live &&
            (looksLikeAudioOnlyUrl(url) || looksLikeRadioGroup(group));
        final tmdbId =
            ExternalIds.parsePositiveInt(
              attrs['tmdb-id'] ?? attrs['tmdb_id'] ?? attrs['tmdb'],
            ) ??
            ExternalIds.tmdbFromText(title);
        final imdbId =
            ExternalIds.parseImdb(
              attrs['imdb'] ?? attrs['imdb-id'] ?? attrs['imdb_id'] ?? tvgId,
            ) ??
            ExternalIds.imdbFromText(title);

        items.add(
          MediaItem(
            id: _uuid.v4(),
            title: title,
            playUrl: url,
            kind: kind,
            origin: MediaOrigin.iptvM3u,
            subtitle: group,
            thumbnailUrl: logo,
            group: group,
            channelId: tvgId,
            channelName: (tvgName != null && tvgName.isNotEmpty)
                ? tvgName
                : null,
            epgChannelId: tvgId,
            catchupDays: catchupDays,
            sourceId: sourceId,
            tmdbId: kind == MediaKind.vod ? tmdbId : null,
            imdbId: kind == MediaKind.vod ? imdbId : null,
            httpHeaders: media.drmKind == null
                ? const {}
                : drmHintHeadersFor(media.drmKind!),
            tags: audioOnly ? withAudioOnlyTag(const []) : const [],
            isAdult: resolveIsAdult(
              flag:
                  attrs['tvg-adult'] ??
                  attrs['adult'] ??
                  attrs['is_adult'] ??
                  attrs['is-adult'],
            ),
          ),
        );
        pendingGroup = null;
        i = media.index;
        continue;
      }

      if (line.startsWith('#')) continue;

      // Basic M3U entry (no preceding `#EXTINF`).
      final group = pendingGroup;
      final kind = _inferKind(
        line,
        group,
        defaultKind,
        hasEpgId: false,
        runtime: null,
      );
      final audioOnly =
          kind == MediaKind.live &&
          (looksLikeAudioOnlyUrl(line) || looksLikeRadioGroup(group));
      items.add(
        MediaItem(
          id: _uuid.v4(),
          title: _titleFromUrl(line),
          playUrl: line,
          kind: kind,
          origin: MediaOrigin.iptvM3u,
          subtitle: group,
          group: group,
          sourceId: sourceId,
          tags: audioOnly ? withAudioOnlyTag(const []) : const [],
        ),
      );
      pendingGroup = null;
    }

    return M3uParseResult(items: items, epgUrl: epgUrl);
  }

  /// Next non-directive media URL after [from], skipping mid-entry tags.
  _MediaUrlRef? _nextMediaUrl(List<String> lines, int from) {
    String? group;
    DrmKind? drmKind;
    for (var i = from; i < lines.length; i++) {
      final line = lines[i];
      final grp = _parseExtGrp(line);
      if (grp != null) {
        group = grp;
        continue;
      }
      if (line.startsWith('#')) {
        final upper = line.toUpperCase();
        // A new entry header means this EXTINF had no URL.
        if (upper.startsWith('#EXTINF') || upper.startsWith('#EXTM3U')) {
          return null;
        }
        drmKind ??= drmKindFromKodiprop(line);
        // Skip `#EXTVLCOPT`, `#KODIPROP`, and other comments/directives.
        continue;
      }
      return _MediaUrlRef(index: i, group: group, drmKind: drmKind);
    }
    return null;
  }

  String? _parseExtGrp(String line) {
    final upper = line.toUpperCase();
    if (!upper.startsWith('#EXTGRP:')) return null;
    final value = line.substring('#EXTGRP:'.length).trim();
    return value.isEmpty ? null : value;
  }

  MediaKind _inferKind(
    String url,
    String? group,
    MediaKind fallback, {
    required bool hasEpgId,
    required double? runtime,
  }) {
    final urlLower = url.toLowerCase();
    final groupLower = (group ?? '').toLowerCase();

    // Strong path signals used by Xtream / VOD libraries.
    if (urlLower.contains('/movie/') ||
        urlLower.contains('/series/') ||
        urlLower.contains('/vod/') ||
        urlLower.contains('/movies/')) {
      return MediaKind.vod;
    }

    // A stated runtime means the entry is a file. Channels use -1.
    if (runtime != null && runtime > 0) return MediaKind.vod;

    // Everything below reads group-title, which providers overload. iptv-org
    // files Pluto's single-show channels under "Series" and "Movies;Series"
    // as *genres* — Baywatch there is a 24/7 linear channel, not a download.
    // A tvg-id means the provider expects a guide for it, which settles it.
    if (hasEpgId) return fallback;

    // Group titles that clearly mean on-demand (avoid matching live
    // channels like "Movie Plus" whose URL path contains "movie_").
    if (RegExp(r'(^|[^a-z0-9])vods?([^a-z0-9]|$)').hasMatch(groupLower) ||
        groupLower.contains('on demand') ||
        groupLower.contains('on-demand') ||
        groupLower.contains('catch up vod') ||
        RegExp(r'(^|[^a-z0-9])series([^a-z0-9]|$)').hasMatch(groupLower)) {
      return MediaKind.vod;
    }

    return fallback;
  }

  /// The seconds right after `#EXTINF:`. `-1` for channels, a real runtime
  /// for files, absent when the playlist omits it.
  double? _parseRuntime(String line) {
    final colon = line.indexOf(':');
    if (colon == -1) return null;
    final match = RegExp(
      r'^\s*(-?\d+(?:\.\d+)?)',
    ).firstMatch(line.substring(colon + 1));
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  Map<String, String> _parseExtInf(String line) {
    final attrs = <String, String>{};
    final comma = line.lastIndexOf(',');
    if (comma != -1 && comma < line.length - 1) {
      attrs['name'] = line.substring(comma + 1);
    }

    final attrPart = comma == -1 ? line : line.substring(0, comma);
    final regex = RegExp(r'([\w-]+)="([^"]*)"');
    for (final match in regex.allMatches(attrPart)) {
      attrs[match.group(1)!] = match.group(2)!;
    }
    return attrs;
  }

  String? _attr(String line, String key) {
    final match = RegExp('$key="([^"]*)"').firstMatch(line);
    return match?.group(1);
  }

  String _titleFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return 'Untitled';

    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      if (uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
        if (last.isNotEmpty) {
          try {
            return Uri.decodeComponent(last);
          } catch (_) {
            return last;
          }
        }
      }
      if (uri.host.isNotEmpty) return uri.host;
    }

    final normalized = trimmed.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash != -1 && slash < normalized.length - 1) {
      return normalized.substring(slash + 1);
    }
    return trimmed;
  }
}

/// Isolate entry — must stay top-level so the closure cannot capture
/// [LibraryProvider] (streams / plugins are unsendable).
///
/// Large playlists stream items back in chunks so Windows can pump focus /
/// clicks instead of freezing on a single Isolate.run handoff.
Future<M3uParseResult> parseM3uBytesInIsolate(
  List<int> bytes, {
  required String sourceId,
  String? baseDir,
}) {
  if (kIsWeb) {
    return javpCompute(() => parseM3uBytesSync(bytes, sourceId, baseDir));
  }
  return _parseM3uBytesChunked(bytes, sourceId: sourceId, baseDir: baseDir);
}

const _m3uParseChunkSize = 400;

class _M3uParseIsolateArgs {
  const _M3uParseIsolateArgs({
    required this.reply,
    required this.bytes,
    required this.sourceId,
    this.baseDir,
  });

  final SendPort reply;
  final List<int> bytes;
  final String sourceId;
  final String? baseDir;
}

Future<M3uParseResult> _parseM3uBytesChunked(
  List<int> bytes, {
  required String sourceId,
  String? baseDir,
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _m3uParseIsolateMain,
      _M3uParseIsolateArgs(
        reply: receive.sendPort,
        bytes: bytes,
        sourceId: sourceId,
        baseDir: baseDir,
      ),
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    receive.close();
    errors.close();
    rethrow;
  }

  final items = <MediaItem>[];
  String? epgUrl;
  var header = false;
  Object? isolateError;
  final errorSub = errors.listen((msg) {
    isolateError ??= msg;
  });
  try {
    await for (final message in receive) {
      if (isolateError != null) throw isolateError!;
      if (message == null) break;
      if (!header) {
        header = true;
        if (message is Map) {
          final raw = message['epgUrl'];
          if (raw is String && raw.isNotEmpty) epgUrl = raw;
        }
        await yieldAfterIsolateChunk();
        continue;
      }
      if (message is List<MediaItem>) {
        items.addAll(message);
        await yieldAfterIsolateChunk();
      } else if (message is List) {
        for (final e in message) {
          if (e is MediaItem) items.add(e);
        }
        await yieldAfterIsolateChunk();
      }
    }
    if (isolateError != null) throw isolateError!;
    return M3uParseResult(items: items, epgUrl: epgUrl);
  } finally {
    await errorSub.cancel();
    receive.close();
    errors.close();
    worker.kill(priority: Isolate.immediate);
  }
}

@pragma('vm:entry-point')
void _m3uParseIsolateMain(_M3uParseIsolateArgs args) {
  try {
    final parsed = parseM3uBytesSync(args.bytes, args.sourceId, args.baseDir);
    args.reply.send({'epgUrl': parsed.epgUrl});
    final items = parsed.items;
    for (var i = 0; i < items.length; i += _m3uParseChunkSize) {
      final end = (i + _m3uParseChunkSize > items.length)
          ? items.length
          : i + _m3uParseChunkSize;
      args.reply.send(List<MediaItem>.from(items.getRange(i, end)));
    }
  } finally {
    args.reply.send(null);
  }
}

/// Parse + optional relative-URL resolve. Used by [parseM3uBytesInIsolate].
M3uParseResult parseM3uBytesSync(
  List<int> bytes,
  String sourceId,
  String? baseDir,
) {
  final result = M3uParser.parseBytes(bytes, sourceId: sourceId);
  if (baseDir == null || baseDir.isEmpty) return result;
  return M3uParseResult(
    items: M3uPlaylistIo.resolveEntryUrls(result.items, baseDir: baseDir),
    epgUrl: result.epgUrl,
  );
}

/// Parse + split + live/VOD indexes in one worker. Neither list returns as [MediaItem].
Future<M3uIngestResult> ingestM3uBytesInIsolate(
  List<int> bytes, {
  required String sourceId,
  String? baseDir,
  Map<String, String> epgDisplayNames = const {},
  Map<String, String> preferredLiveQualities = const {},
}) {
  if (kIsWeb) {
    return javpCompute(
      () => ingestM3uBytesSync(
        bytes,
        sourceId,
        baseDir,
        epgDisplayNames: epgDisplayNames,
        preferredLiveQualities: preferredLiveQualities,
      ),
    );
  }
  return _ingestM3uBytesChunked(
    bytes,
    sourceId: sourceId,
    baseDir: baseDir,
    epgDisplayNames: epgDisplayNames,
    preferredLiveQualities: preferredLiveQualities,
  );
}

M3uIngestResult ingestM3uBytesSync(
  List<int> bytes,
  String sourceId,
  String? baseDir, {
  Map<String, String> epgDisplayNames = const {},
  Map<String, String> preferredLiveQualities = const {},
}) {
  final parsed = parseM3uBytesSync(bytes, sourceId, baseDir);
  final live = <Map<String, Object?>>[];
  final vodItems = <MediaItem>[];
  for (final item in parsed.items) {
    if (item.kind == MediaKind.live) {
      live.add(packLiveChannelRow(item));
    } else {
      vodItems.add(item);
    }
  }
  return M3uIngestResult(
    epgUrl: parsed.epgUrl,
    vod: buildVodIngestPlan(vodItems, fallbackSourceId: sourceId),
    live: buildLiveIngestPlan(
      sourceId: sourceId,
      channels: live,
      epgDisplayNames: epgDisplayNames,
      preferredLiveQualities: preferredLiveQualities,
    ),
  );
}

Future<M3uIngestResult> _ingestM3uBytesChunked(
  List<int> bytes, {
  required String sourceId,
  String? baseDir,
  Map<String, String> epgDisplayNames = const {},
  Map<String, String> preferredLiveQualities = const {},
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _m3uIngestIsolateMain,
      receive.sendPort,
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    receive.close();
    errors.close();
    rethrow;
  }

  Object? isolateError;
  final errorSub = errors.listen((msg) {
    isolateError ??= msg;
  });
  final iter = StreamIterator(receive);
  try {
    if (!await iter.moveNext()) {
      throw StateError('m3u ingest isolate exited before handshake');
    }
    if (isolateError != null) throw isolateError!;
    final workerPort = iter.current as SendPort;
    workerPort.send({
      'sourceId': sourceId,
      'baseDir': baseDir,
      'epgNames': epgDisplayNames,
      'preferred': preferredLiveQualities,
    });
    await yieldAfterIsolateChunk();
    const byteChunk = 256 * 1024;
    for (var i = 0; i < bytes.length; i += byteChunk) {
      if (isolateError != null) throw isolateError!;
      final end = i + byteChunk > bytes.length ? bytes.length : i + byteChunk;
      workerPort.send(bytes.sublist(i, end));
      await yieldAfterIsolateChunk();
    }
    workerPort.send(null);

    String? epgUrl;
    var contentFingerprint = '0';
    var indexFingerprint = '0';
    final channelRows = <Map<String, Object?>>[];
    final listingRows = <Map<String, Object?>>[];
    final variantRows = <Map<String, Object?>>[];
    final vodRows = <Map<String, Object?>>[];
    final vodFamilies = <String, List<String>>{};
    final vodCanonical = <String, String>{};
    var header = false;
    while (await iter.moveNext()) {
      if (isolateError != null) throw isolateError!;
      final message = iter.current;
      if (message == null) break;
      if (!header) {
        header = true;
        if (message is Map) {
          final raw = message['epgUrl'];
          if (raw is String && raw.isNotEmpty) epgUrl = raw;
          contentFingerprint = '${message['contentFp'] ?? '0'}';
          indexFingerprint = '${message['indexFp'] ?? '0'}';
        }
        await yieldAfterIsolateChunk();
        continue;
      }
      if (message is Map) {
        final type = '${message['t'] ?? ''}';
        final raw = message['v'];
        if (raw is List) {
          switch (type) {
            case 'channels':
              _absorbMaps(channelRows, raw);
            case 'listings':
              _absorbMaps(listingRows, raw);
            case 'variants':
              _absorbMaps(variantRows, raw);
            case 'vod':
              _absorbMaps(vodRows, raw);
            case 'vodFamilies':
              for (final e in raw) {
                if (e is! List || e.length < 2) continue;
                vodFamilies['${e[0]}'] = [
                  for (final id in (e[1] is List ? e[1] as List : const []))
                    '$id',
                ];
              }
            case 'vodCanonical':
              for (final e in raw) {
                if (e is! List || e.length < 2) continue;
                vodCanonical['${e[0]}'] = '${e[1]}';
              }
          }
        }
        await yieldAfterIsolateChunk();
      }
    }
    if (isolateError != null) throw isolateError!;
    return M3uIngestResult(
      epgUrl: epgUrl,
      vod: VodIngestPlan(
        rows: vodRows,
        families: vodFamilies,
        canonical: vodCanonical,
      ),
      live: LiveIngestPlan(
        contentFingerprint: contentFingerprint,
        indexFingerprint: indexFingerprint,
        channelRows: channelRows,
        listingRows: listingRows,
        variantRows: variantRows,
      ),
    );
  } finally {
    await errorSub.cancel();
    await iter.cancel();
    receive.close();
    errors.close();
    worker.kill(priority: Isolate.immediate);
  }
}

void _absorbMaps(List<Map<String, Object?>> out, List<dynamic> raw) {
  for (final e in raw) {
    if (e is Map<String, Object?>) {
      out.add(e);
    } else if (e is Map) {
      out.add(Map<String, Object?>.from(e));
    }
  }
}

@pragma('vm:entry-point')
void _m3uIngestIsolateMain(SendPort reply) {
  unawaited(_m3uIngestIsolateBody(reply));
}

Future<void> _m3uIngestIsolateBody(SendPort reply) async {
  final inbound = ReceivePort();
  reply.send(inbound.sendPort);
  var sourceId = '';
  String? baseDir;
  var epgDisplayNames = <String, String>{};
  var preferredLiveQualities = <String, String>{};
  final buffer = BytesBuilder(copy: false);
  try {
    await for (final message in inbound) {
      if (message == null) break;
      if (message is Map && message.containsKey('sourceId')) {
        sourceId = '${message['sourceId'] ?? ''}';
        final rawDir = message['baseDir'];
        baseDir = rawDir is String && rawDir.isNotEmpty ? rawDir : null;
        epgDisplayNames = {
          for (final e in (message['epgNames'] as Map? ?? {}).entries)
            '${e.key}': '${e.value}',
        };
        preferredLiveQualities = {
          for (final e in (message['preferred'] as Map? ?? {}).entries)
            '${e.key}': '${e.value}',
        };
        continue;
      }
      if (message is List<int>) buffer.add(message);
    }
    final ingested = ingestM3uBytesSync(
      buffer.takeBytes(),
      sourceId,
      baseDir,
      epgDisplayNames: epgDisplayNames,
      preferredLiveQualities: preferredLiveQualities,
    );
    reply.send({
      'epgUrl': ingested.epgUrl,
      'contentFp': ingested.live.contentFingerprint,
      'indexFp': ingested.live.indexFingerprint,
    });
    const chunk = _m3uParseChunkSize;
    void sendMaps(String type, List<Map<String, Object?>> rows) {
      for (var i = 0; i < rows.length; i += chunk) {
        final end = i + chunk > rows.length ? rows.length : i + chunk;
        reply.send({
          't': type,
          'v': List<Map<String, Object?>>.from(rows.getRange(i, end)),
        });
      }
    }

    sendMaps('channels', ingested.live.channelRows);
    sendMaps('listings', ingested.live.listingRows);
    sendMaps('variants', ingested.live.variantRows);
    sendMaps('vod', ingested.vod.rows);
    void sendPairs(String type, List<List<Object>> pairs) {
      for (var i = 0; i < pairs.length; i += chunk) {
        final end = i + chunk > pairs.length ? pairs.length : i + chunk;
        reply.send({'t': type, 'v': pairs.sublist(i, end)});
      }
    }

    sendPairs('vodFamilies', [
      for (final e in ingested.vod.families.entries) [e.key, e.value],
    ]);
    sendPairs('vodCanonical', [
      for (final e in ingested.vod.canonical.entries) [e.key, e.value],
    ]);
  } finally {
    inbound.close();
    reply.send(null);
  }
}
