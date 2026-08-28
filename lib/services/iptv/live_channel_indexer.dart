import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/live_channel_index.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:javp/services/iptv/channel_quality.dart';

/// Builds a [LiveChannelIndex] from live rows + EPG display names.
///
/// Pure / isolate-safe: no Flutter, no I/O.
LiveChannelIndex buildLiveChannelIndex({
  required String fingerprint,
  required List<MediaItem> channels,
  required Map<String, String> epgDisplayNames,
}) {
  final familyBuckets = <String, List<MediaItem>>{};
  final familyByChannelId = <String, String>{};
  final firstSeen = <String>[]; // family key or `id:<channelId>`
  final singles = <String, MediaItem>{};

  for (final channel in channels) {
    final official = _officialName(channel, epgDisplayNames);
    final key = ChannelQuality.preferenceKey(channel, officialName: official);
    if (key == null) {
      final token = 'id:${channel.id}';
      if (!singles.containsKey(channel.id)) {
        singles[channel.id] = channel;
        firstSeen.add(token);
      }
      continue;
    }
    if (!familyBuckets.containsKey(key)) {
      firstSeen.add(key);
    }
    familyBuckets.putIfAbsent(key, () => []).add(channel);
    familyByChannelId[channel.id] = key;
  }

  final variantIdsByFamily = <String, List<String>>{};
  for (final entry in familyBuckets.entries) {
    final variants = [...entry.value]..sort(ChannelQuality.compareVariants);
    variantIdsByFamily[entry.key] = [for (final v in variants) v.id];
  }

  final allIds = <String>[];
  final idsByGroup = <String, List<String>>{};
  final variantCountById = <String, int>{};

  void addRow(MediaItem channel, {required int variantCount}) {
    allIds.add(channel.id);
    variantCountById[channel.id] = variantCount;
    final group = (channel.group ?? '').trim();
    if (group.isNotEmpty) {
      idsByGroup.putIfAbsent(group, () => []).add(channel.id);
    }
  }

  for (final token in firstSeen) {
    if (token.startsWith('id:')) {
      final id = token.substring(3);
      final channel = singles[id];
      if (channel == null) continue;
      addRow(channel, variantCount: 1);
      continue;
    }
    final variantIds = variantIdsByFamily[token];
    if (variantIds == null || variantIds.isEmpty) continue;
    final bestId = variantIds.first;
    MediaItem? best;
    for (final channel in familyBuckets[token]!) {
      if (channel.id == bestId) {
        best = channel;
        break;
      }
    }
    best ??= familyBuckets[token]!.first;
    addRow(best, variantCount: variantIds.length);
  }

  return LiveChannelIndex(
    fingerprint: fingerprint,
    allIds: allIds,
    idsByGroup: idsByGroup,
    variantCountById: variantCountById,
    familyByChannelId: familyByChannelId,
    variantIdsByFamily: variantIdsByFamily,
  );
}

/// Compact payload for [Isolate.run] — avoids shipping full [MediaItem] JSON.
Map<String, dynamic> liveIndexIsolatePayload({
  required String fingerprint,
  required List<MediaItem> channels,
  required Map<String, String> epgDisplayNames,
}) {
  return {
    'fingerprint': fingerprint,
    'epgNames': epgDisplayNames,
    'channels': [
      for (final c in channels)
        {
          'id': c.id,
          'title': c.title,
          'group': c.group,
          'sourceId': c.sourceId,
          'streamId': c.streamId,
          'epgChannelId': c.epgChannelId,
          'channelName': c.channelName,
          'catchupDays': c.catchupDays,
        },
    ],
  };
}

LiveChannelIndex buildLiveChannelIndexFromIsolatePayload(
  Map<String, dynamic> payload,
) {
  final fingerprint = '${payload['fingerprint'] ?? ''}';
  final epgNames = <String, String>{
    for (final e in (payload['epgNames'] as Map? ?? {}).entries)
      '${e.key}': '${e.value}',
  };
  final raw = payload['channels'];
  final channels = <MediaItem>[];
  if (raw is List) {
    for (final row in raw.whereType<Map>()) {
      final m = Map<String, dynamic>.from(row);
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) continue;
      channels.add(
        MediaItem(
          id: id,
          title: '${m['title'] ?? id}',
          kind: MediaKind.live,
          origin: MediaOrigin.iptvXtream,
          playUrl: '',
          group: m['group']?.toString(),
          sourceId: m['sourceId']?.toString(),
          streamId: m['streamId']?.toString(),
          epgChannelId: m['epgChannelId']?.toString(),
          channelName: m['channelName']?.toString(),
          catchupDays: (m['catchupDays'] as num?)?.toInt() ?? 0,
        ),
      );
    }
  }
  return buildLiveChannelIndex(
    fingerprint: fingerprint,
    channels: channels,
    epgDisplayNames: epgNames,
  );
}

/// Build a live index off the UI isolate without a one-shot [Isolate.run]
/// copy of the packed rows / result maps.
Future<LiveChannelIndex> buildLiveChannelIndexInIsolate({
  required String fingerprint,
  required List<Map<String, dynamic>> rows,
  required Map<String, String> epgNames,
}) {
  return UiStallWatchdog.span('live-index', () async {
  if (rows.isEmpty) {
    return LiveChannelIndex(
      fingerprint: fingerprint,
      allIds: const [],
      idsByGroup: const {},
      variantCountById: const {},
      familyByChannelId: const {},
      variantIdsByFamily: const {},
    );
  }
  if (kIsWeb || rows.length < kIsolateListChunk) {
    return Isolate.run(
      () => buildLiveChannelIndexFromIsolatePayload({
        'fingerprint': fingerprint,
        'epgNames': epgNames,
        'channels': rows,
      }),
    );
  }

  final receive = ReceivePort();
  final errors = ReceivePort();
  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _liveIndexIsolateMain,
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
      throw StateError('live index isolate exited before handshake');
    }
    if (isolateError != null) throw isolateError!;
    final workerPort = iter.current as SendPort;
    workerPort.send({'fingerprint': fingerprint, 'epgNames': epgNames});
    await yieldAfterIsolateChunk();
    const chunk = kIsolateListChunk;
    for (var i = 0; i < rows.length; i += chunk) {
      if (isolateError != null) throw isolateError!;
      final end = i + chunk > rows.length ? rows.length : i + chunk;
      workerPort.send(List<Map<String, dynamic>>.from(rows.getRange(i, end)));
      await yieldAfterIsolateChunk();
    }
    workerPort.send(null);

    var outFingerprint = fingerprint;
    final allIds = <String>[];
    final idsByGroup = <String, List<String>>{};
    final variantCountById = <String, int>{};
    final familyByChannelId = <String, String>{};
    final variantIdsByFamily = <String, List<String>>{};
    while (await iter.moveNext()) {
      if (isolateError != null) throw isolateError!;
      final message = iter.current;
      if (message == null) break;
      if (message is Map) {
        final type = '${message['t'] ?? ''}';
        final raw = message['v'];
        switch (type) {
          case 'fp':
            outFingerprint = '$raw';
          case 'allIds':
            if (raw is List) {
              allIds.addAll([for (final e in raw) '$e']);
            }
          case 'idsByGroup':
            _absorbStringListMap(idsByGroup, raw);
          case 'variantCount':
            if (raw is List) {
              for (final e in raw) {
                if (e is! List || e.length < 2) continue;
                final n = e[1];
                variantCountById['${e[0]}'] = n is num
                    ? n.toInt()
                    : int.tryParse('$n') ?? 1;
              }
            }
          case 'familyById':
            if (raw is List) {
              for (final e in raw) {
                if (e is! List || e.length < 2) continue;
                familyByChannelId['${e[0]}'] = '${e[1]}';
              }
            }
          case 'variantIds':
            _absorbStringListMap(variantIdsByFamily, raw);
        }
      }
      await yieldAfterIsolateChunk();
    }
    if (isolateError != null) throw isolateError!;
    return LiveChannelIndex(
      fingerprint: outFingerprint,
      allIds: allIds,
      idsByGroup: idsByGroup,
      variantCountById: variantCountById,
      familyByChannelId: familyByChannelId,
      variantIdsByFamily: variantIdsByFamily,
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

void _absorbStringListMap(Map<String, List<String>> out, Object? raw) {
  if (raw is! List) return;
  for (final e in raw) {
    if (e is! List || e.length < 2) continue;
    out['${e[0]}'] = [
      for (final id in (e[1] is List ? e[1] as List : const [])) '$id',
    ];
  }
}

String? _officialName(MediaItem channel, Map<String, String> epgDisplayNames) {
  // Only XMLTV display-name counts as "official" here. Raw tvg-name /
  // stream titles are handled inside [ChannelQuality.preferenceKey] so
  // quality suffixes can be stripped consistently.
  final tvg = channel.epgChannelId?.trim();
  if (tvg != null && tvg.isNotEmpty) {
    final name = epgDisplayNames[tvg]?.trim();
    if (name != null && name.isNotEmpty) return name;
  }
  return null;
}

@pragma('vm:entry-point')
void _liveIndexIsolateMain(SendPort reply) {
  unawaited(_liveIndexIsolateBody(reply));
}

void _sendStringChunks(SendPort reply, String type, List<String> values) {
  const chunk = kIsolateListChunk;
  for (var i = 0; i < values.length; i += chunk) {
    final end = i + chunk > values.length ? values.length : i + chunk;
    reply.send({'t': type, 'v': values.sublist(i, end)});
  }
}

void _sendPairChunks(
  SendPort reply,
  String type,
  Iterable<MapEntry<String, Object?>> entries,
) {
  const chunk = kIsolateListChunk;
  final list = entries.toList(growable: false);
  for (var i = 0; i < list.length; i += chunk) {
    final end = i + chunk > list.length ? list.length : i + chunk;
    reply.send({
      't': type,
      'v': [
        for (final e in list.sublist(i, end)) [e.key, e.value],
      ],
    });
  }
}

Future<void> _liveIndexIsolateBody(SendPort reply) async {
  final inbound = ReceivePort();
  reply.send(inbound.sendPort);
  var fingerprint = '';
  var epgNames = <String, String>{};
  final rows = <Map<String, dynamic>>[];
  await for (final message in inbound) {
    if (message == null) break;
    if (message is Map && message.containsKey('fingerprint')) {
      fingerprint = '${message['fingerprint'] ?? ''}';
      epgNames = {
        for (final e in (message['epgNames'] as Map? ?? {}).entries)
          '${e.key}': '${e.value}',
      };
      continue;
    }
    if (message is List) {
      for (final e in message) {
        if (e is Map<String, dynamic>) {
          rows.add(e);
        } else if (e is Map) {
          rows.add(Map<String, dynamic>.from(e));
        }
      }
    }
  }
  final index = buildLiveChannelIndexFromIsolatePayload({
    'fingerprint': fingerprint,
    'epgNames': epgNames,
    'channels': rows,
  });
  reply.send({'t': 'fp', 'v': index.fingerprint});
  _sendStringChunks(reply, 'allIds', index.allIds);
  _sendPairChunks(reply, 'idsByGroup', index.idsByGroup.entries);
  _sendPairChunks(reply, 'variantCount', index.variantCountById.entries);
  _sendPairChunks(reply, 'familyById', index.familyByChannelId.entries);
  _sendPairChunks(reply, 'variantIds', index.variantIdsByFamily.entries);
  reply.send(null);
  inbound.close();
}
