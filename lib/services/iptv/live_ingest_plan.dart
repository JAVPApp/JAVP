import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/live_channel_index.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/iptv_search_query.dart';
import 'package:javp/services/iptv/live_channel_indexer.dart';

/// Packed live ingest: channel SQL rows + collapsed listings + variants.
///
/// Built off the UI isolate so [LiveChannelDb] can insert maps without
/// hydrating [MediaItem] graphs or packing them a second time for the
/// quality index.
class LiveIngestPlan {
  const LiveIngestPlan({
    required this.contentFingerprint,
    required this.indexFingerprint,
    required this.channelRows,
    required this.listingRows,
    required this.variantRows,
  });

  /// Same hash as [LiveChannelDb] used to skip identical rewrites.
  final String contentFingerprint;

  /// Cheap index stamp (`count|first|last|epgNames`).
  final String indexFingerprint;

  /// `live_channels` insert maps (SQL column names).
  final List<Map<String, Object?>> channelRows;

  /// `live_listings` insert maps without [position] — caller assigns it.
  final List<Map<String, Object?>> listingRows;

  /// `live_variants` insert maps (`family_key`, `channel_id`, `rank`).
  final List<Map<String, Object?>> variantRows;

  int get liveCount => channelRows.length;
}

/// Column names of `live_channels`. Packed insert maps must only use these —
/// sqflite INSERT treats every map key as a column name.
const liveChannelSqlColumns = <String>{
  'id',
  'source_id',
  'title',
  'play_url',
  'origin',
  'thumbnail_url',
  'group_name',
  'channel_id',
  'channel_name',
  'stream_id',
  'epg_channel_id',
  'server_item_id',
  'catchup_days',
  'http_headers_json',
  'is_adult',
};

/// Pack one live row for isolate transfer + SQLite insert.
Map<String, Object?> packLiveChannelRow(MediaItem c) {
  return {
    'id': c.id,
    'source_id': c.sourceId ?? '',
    'title': c.title,
    'play_url': c.playUrl,
    'origin': c.origin.name,
    'thumbnail_url': c.thumbnailUrl,
    'group_name': c.group,
    'channel_id': c.channelId,
    'channel_name': c.channelName,
    'stream_id': c.streamId,
    'epg_channel_id': c.epgChannelId,
    'server_item_id': c.serverItemId,
    'catchup_days': c.catchupDays,
    'http_headers_json': c.httpHeaders.isEmpty
        ? null
        : jsonEncode(c.httpHeaders),
    'is_adult': c.isAdult ? 1 : 0,
  };
}

/// Drop keys that are not `live_channels` columns (Xtream packing used to
/// include `subtitle` / `extra_json` and SQLite rejected the INSERT).
Map<String, Object?> sanitizeLiveChannelRow(Map<String, Object?> row) {
  if (row.keys.every(liveChannelSqlColumns.contains)) return row;
  return {
    for (final key in liveChannelSqlColumns)
      if (row.containsKey(key)) key: row[key],
  };
}

/// Pack on the UI isolate without monopolizing a frame.
Future<List<Map<String, Object?>>> packLiveChannelRowsYielding(
  List<MediaItem> channels,
) {
  if (channels.isEmpty) return Future.value(const []);
  return mapYielding(channels, packLiveChannelRow, label: 'live-pack-rows');
}

/// Keep only EPG display-names referenced by packed [channels].
Map<String, String> scopedEpgDisplayNamesForPacked(
  List<Map<String, Object?>> channels,
  Map<String, String> epgDisplayNames,
) {
  if (epgDisplayNames.isEmpty || channels.isEmpty) return const {};
  if (epgDisplayNames.length <= 512) return epgDisplayNames;
  final out = <String, String>{};
  for (final c in channels) {
    final tvg = '${c['epg_channel_id'] ?? ''}'.trim();
    if (tvg.isEmpty) continue;
    final name = epgDisplayNames[tvg];
    if (name != null) out[tvg] = name;
  }
  return out;
}

String liveContentFingerprint(List<Map<String, Object?>> channels) {
  if (channels.isEmpty) return '0';
  final buf = StringBuffer('${channels.length}');
  for (final c in channels) {
    buf.write(_contentFingerprintLine(c));
  }
  return sha1.convert(utf8.encode(buf.toString())).toString();
}

Future<String> liveContentFingerprintAsync(
  List<Map<String, Object?>> channels,
) async {
  if (channels.length < 400) return liveContentFingerprint(channels);
  final out = _DigestSink();
  final input = sha1.startChunkedConversion(out);
  input.add(utf8.encode('${channels.length}'));
  final slice = Stopwatch()..start();
  for (var i = 0; i < channels.length; i++) {
    input.add(utf8.encode(_contentFingerprintLine(channels[i])));
    await yieldUiSlice(slice, i: i, checkMask: 127, label: 'live-fingerprint');
  }
  input.close();
  return out.value!.toString();
}

String _contentFingerprintLine(Map<String, Object?> c) {
  final adult = ((c['is_adult'] as num?)?.toInt() ?? 0) != 0;
  return '\n${c['id']}\t${c['play_url']}\t${c['title']}\t'
      '${c['thumbnail_url'] ?? ''}\t${c['stream_id'] ?? ''}\t'
      '${c['epg_channel_id'] ?? ''}\t${c['catchup_days'] ?? 0}\t'
      '${adult ? '1' : '0'}';
}

String liveIndexFingerprint(
  List<Map<String, Object?>> channels,
  Map<String, String> epgDisplayNames,
) {
  if (channels.isEmpty) return '0';
  return '${channels.length}|${channels.first['id']}|${channels.last['id']}|'
      '${epgDisplayNames.length}';
}

Map<String, dynamic> _indexRowFromPacked(Map<String, Object?> c) {
  return {
    'id': c['id'],
    'title': c['title'],
    'group': c['group_name'],
    'sourceId': c['source_id'],
    'streamId': c['stream_id'],
    'epgChannelId': c['epg_channel_id'],
    'channelName': c['channel_name'],
    'catchupDays': c['catchup_days'],
  };
}

/// Pure build used by the isolate and unit tests.
LiveIngestPlan buildLiveIngestPlan({
  required String sourceId,
  required List<Map<String, Object?>> channels,
  Map<String, String> epgDisplayNames = const {},
  Map<String, String> preferredLiveQualities = const {},
}) {
  final scoped = scopedEpgDisplayNamesForPacked(channels, epgDisplayNames);
  final index = buildLiveChannelIndexFromIsolatePayload({
    'fingerprint': liveIndexFingerprint(channels, scoped),
    'epgNames': scoped,
    'channels': [for (final c in channels) _indexRowFromPacked(c)],
  });
  return _planFromIndex(
    sourceId: sourceId,
    channels: channels,
    index: index,
    preferredLiveQualities: preferredLiveQualities,
  );
}

LiveIngestPlan _planFromIndex({
  required String sourceId,
  required List<Map<String, Object?>> channels,
  required LiveChannelIndex index,
  required Map<String, String> preferredLiveQualities,
}) {
  final byId = <String, Map<String, Object?>>{
    for (final c in channels) '${c['id']}': c,
  };
  final listingRows = <Map<String, Object?>>[];
  for (final id in index.allIds) {
    final channel = byId[id];
    if (channel == null) continue;
    final family = index.familyByChannelId[id];
    final resolved = _resolvePreferredPacked(
      channel: channel,
      family: family,
      index: index,
      byId: byId,
      preferredLiveQualities: preferredLiveQualities,
    );
    listingRows.add(
      _listingRow(
        resolved: resolved,
        sourceId: sourceId,
        groupName: _stringOrNull(resolved['group_name']),
        family: family,
        variantCount: index.variantCountById[id] ?? 1,
        catchupDays: _familyCatchupDaysPacked(
          family: family,
          index: index,
          byId: byId,
          fallback: resolved,
        ),
      ),
    );
  }
  final variantRows = <Map<String, Object?>>[];
  for (final entry in index.variantIdsByFamily.entries) {
    var rank = 0;
    for (final channelId in entry.value) {
      variantRows.add({
        'family_key': entry.key,
        'channel_id': channelId,
        'rank': rank++,
      });
    }
  }
  return LiveIngestPlan(
    contentFingerprint: liveContentFingerprint(channels),
    indexFingerprint: index.fingerprint,
    channelRows: channels,
    listingRows: listingRows,
    variantRows: variantRows,
  );
}

Map<String, Object?> _resolvePreferredPacked({
  required Map<String, Object?> channel,
  required String? family,
  required LiveChannelIndex index,
  required Map<String, Map<String, Object?>> byId,
  required Map<String, String> preferredLiveQualities,
}) {
  if (family == null) return channel;
  final variantIds = index.variantIdsByFamily[family];
  if (variantIds == null || variantIds.isEmpty) return channel;
  final preferredStream = preferredLiveQualities[family];
  if (preferredStream != null) {
    for (final id in variantIds) {
      final v = byId[id];
      if (v == null) continue;
      if ('${v['stream_id'] ?? ''}' == preferredStream) return v;
    }
  }
  return byId[variantIds.first] ?? channel;
}

int _familyCatchupDaysPacked({
  required String? family,
  required LiveChannelIndex index,
  required Map<String, Map<String, Object?>> byId,
  required Map<String, Object?> fallback,
}) {
  if (family == null) {
    return (fallback['catchup_days'] as num?)?.toInt() ?? 0;
  }
  final ids = index.variantIdsByFamily[family];
  if (ids == null || ids.isEmpty) {
    return (fallback['catchup_days'] as num?)?.toInt() ?? 0;
  }
  var max = (fallback['catchup_days'] as num?)?.toInt() ?? 0;
  for (final id in ids) {
    final days = (byId[id]?['catchup_days'] as num?)?.toInt() ?? 0;
    if (days > max) max = days;
  }
  return max;
}

Map<String, Object?> _listingRow({
  required Map<String, Object?> resolved,
  required String sourceId,
  required String? groupName,
  required String? family,
  required int variantCount,
  required int catchupDays,
}) {
  final title = '${resolved['title'] ?? ''}';
  final cleaned = ChannelQuality.baseTitle(title);
  return {
    'id': '${resolved['id']}',
    'source_id': sourceId,
    'group_name': groupName,
    'family_key': family,
    'variant_count': variantCount,
    'sort_title': title.toLowerCase(),
    'search_title': IptvSearchQuery.hay(
      title: cleaned.isNotEmpty ? cleaned : title,
      group: groupName,
      channelName: _stringOrNull(resolved['channel_name']),
      streamId: _stringOrNull(resolved['stream_id']),
      channelId: _stringOrNull(resolved['channel_id']),
      epgChannelId: _stringOrNull(resolved['epg_channel_id']),
    ),
    'catchup_days': catchupDays,
  };
}

String? _stringOrNull(Object? value) {
  if (value == null) return null;
  final s = '$value';
  return s.isEmpty ? null : s;
}

/// Build listings + variants off the UI isolate from packed channel rows.
///
/// [channelRows] stay with the caller — the worker only sends back the
/// collapsed listing / variant maps (plus fingerprints).
Future<LiveIngestPlan> buildLiveIngestPlanInIsolate({
  required String sourceId,
  required List<Map<String, Object?>> channels,
  Map<String, String> epgDisplayNames = const {},
  Map<String, String> preferredLiveQualities = const {},
}) {
  return UiStallWatchdog.span('live-ingest', () async {
    if (channels.isEmpty) {
      return LiveIngestPlan(
        contentFingerprint: '0',
        indexFingerprint: '0',
        channelRows: const [],
        listingRows: const [],
        variantRows: const [],
      );
    }
    if (kIsWeb || channels.length < kIsolateListChunk) {
      return buildLiveIngestPlan(
        sourceId: sourceId,
        channels: channels,
        epgDisplayNames: epgDisplayNames,
        preferredLiveQualities: preferredLiveQualities,
      );
    }

    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _liveIngestIsolateMain,
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
        throw StateError('live ingest isolate exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final workerPort = iter.current as SendPort;
      workerPort.send({
        'sourceId': sourceId,
        'epgNames': epgDisplayNames,
        'preferred': preferredLiveQualities,
      });
      await yieldAfterIsolateChunk();
      const chunk = kIsolateListChunk;
      for (var i = 0; i < channels.length; i += chunk) {
        if (isolateError != null) throw isolateError!;
        final end = i + chunk > channels.length ? channels.length : i + chunk;
        workerPort.send(
          List<Map<String, Object?>>.from(channels.getRange(i, end)),
        );
        await pumpUi();
      }
      workerPort.send(null);

      var contentFingerprint = '';
      var indexFingerprint = '';
      final listingRows = <Map<String, Object?>>[];
      final variantRows = <Map<String, Object?>>[];
      while (await iter.moveNext()) {
        if (isolateError != null) throw isolateError!;
        final message = iter.current;
        if (message == null) break;
        if (message is Map) {
          final type = '${message['t'] ?? ''}';
          final raw = message['v'];
          switch (type) {
            case 'meta':
              if (raw is Map) {
                contentFingerprint = '${raw['contentFp'] ?? ''}';
                indexFingerprint = '${raw['indexFp'] ?? ''}';
              }
            case 'listings':
              if (raw is List) {
                for (final e in raw) {
                  if (e is Map<String, Object?>) {
                    listingRows.add(e);
                  } else if (e is Map) {
                    listingRows.add(Map<String, Object?>.from(e));
                  }
                }
              }
            case 'variants':
              if (raw is List) {
                for (final e in raw) {
                  if (e is Map<String, Object?>) {
                    variantRows.add(e);
                  } else if (e is Map) {
                    variantRows.add(Map<String, Object?>.from(e));
                  }
                }
              }
          }
        }
        await pumpUi();
      }
      if (isolateError != null) throw isolateError!;
      return LiveIngestPlan(
        contentFingerprint: contentFingerprint,
        indexFingerprint: indexFingerprint,
        channelRows: channels,
        listingRows: listingRows,
        variantRows: variantRows,
      );
    } finally {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  });
}

@pragma('vm:entry-point')
void _liveIngestIsolateMain(SendPort reply) {
  unawaited(_liveIngestIsolateBody(reply));
}

Future<void> _liveIngestIsolateBody(SendPort reply) async {
  final inbound = ReceivePort();
  reply.send(inbound.sendPort);
  var sourceId = '';
  var epgNames = <String, String>{};
  var preferred = <String, String>{};
  final rows = <Map<String, Object?>>[];
  await for (final message in inbound) {
    if (message == null) break;
    if (message is Map && message.containsKey('sourceId')) {
      sourceId = '${message['sourceId'] ?? ''}';
      epgNames = {
        for (final e in (message['epgNames'] as Map? ?? {}).entries)
          '${e.key}': '${e.value}',
      };
      preferred = {
        for (final e in (message['preferred'] as Map? ?? {}).entries)
          '${e.key}': '${e.value}',
      };
      continue;
    }
    if (message is List) {
      for (final e in message) {
        if (e is Map<String, Object?>) {
          rows.add(e);
        } else if (e is Map) {
          rows.add(Map<String, Object?>.from(e));
        }
      }
    }
  }
  final plan = buildLiveIngestPlan(
    sourceId: sourceId,
    channels: rows,
    epgDisplayNames: epgNames,
    preferredLiveQualities: preferred,
  );
  reply.send({
    't': 'meta',
    'v': {
      'contentFp': plan.contentFingerprint,
      'indexFp': plan.indexFingerprint,
    },
  });
  const chunk = kIsolateListChunk;
  for (var i = 0; i < plan.listingRows.length; i += chunk) {
    final end = i + chunk > plan.listingRows.length
        ? plan.listingRows.length
        : i + chunk;
    reply.send({'t': 'listings', 'v': plan.listingRows.sublist(i, end)});
  }
  for (var i = 0; i < plan.variantRows.length; i += chunk) {
    final end = i + chunk > plan.variantRows.length
        ? plan.variantRows.length
        : i + chunk;
    reply.send({'t': 'variants', 'v': plan.variantRows.sublist(i, end)});
  }
  reply.send(null);
  inbound.close();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
