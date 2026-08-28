import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';
import 'package:xml/xml.dart';

/// Max compressed / on-the-wire EPG body size before we refuse to parse.
const int kMaxEpgDownloadBytes = 32 * 1024 * 1024;

/// Max decoded XMLTV size ([String.length] / UTF-16 code units).
///
/// Large regional guides (e.g. JP IPTV `guide.xml.gz`) expand well past 25MB
/// even when the gzip download is only a few MB.
const int kMaxEpgDecodedChars = 64 * 1024 * 1024;

class EpgParseResult {
  const EpgParseResult({required this.programs, this.channelNames = const {}});

  final List<EpgProgram> programs;

  /// XMLTV `channel id` → first `display-name`.
  final Map<String, String> channelNames;

  factory EpgParseResult.fromJson(Map<String, dynamic> json) {
    final programsRaw = json['programs'];
    final namesRaw = json['channelNames'];
    return EpgParseResult(
      programs: programsRaw is List
          ? programsRaw
                .whereType<Map>()
                .map((e) => EpgProgram.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      channelNames: namesRaw is Map
          ? {
              for (final e in namesRaw.entries)
                e.key.toString(): e.value.toString(),
            }
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'programs': programs.map((p) => p.toJson()).toList(),
    'channelNames': channelNames,
  };
}

/// Native ingest: worker streams packed rows; UI writes SQL maps and never
/// accumulates [EpgProgram] lists. Web / tests still use
/// [parseEpgResponseInIsolate].
class EpgIngestResult {
  const EpgIngestResult({
    required this.channelNames,
    required this.programCount,
  });

  final Map<String, String> channelNames;
  final int programCount;
}

/// Decode + parse XMLTV on a background isolate (avoids UI jank on large guides).
///
/// Crosses the isolate with packed parallel arrays (ms epochs + strings) —
/// not per-programme JSON maps — so the UI isolate does cheap list walks
/// instead of tens of thousands of [DateTime.parse] / map casts.
///
/// Prefer [ingestEpgPackedInIsolate] on native — this entry still hydrates
/// every programme for web and unit tests.
Future<EpgParseResult> parseEpgResponseInIsolate({
  required List<int> bytes,
  String? url,
  String? contentEncoding,
  int maxDownloadBytes = kMaxEpgDownloadBytes,
  int maxDecodedChars = kMaxEpgDecodedChars,
}) {
  return UiStallWatchdog.span('epg-parse', () async {
    if (kIsWeb) {
      final packed = _parseEpgBytesWorker({
        'bytes': bytes,
        'url': url,
        'contentEncoding': contentEncoding,
        'maxDownloadBytes': maxDownloadBytes,
        'maxDecodedChars': maxDecodedChars,
      });
      return _epgResultFromPacked(packed);
    }
    return _parseEpgBytesChunked(
      bytes,
      url: url,
      contentEncoding: contentEncoding,
      maxDownloadBytes: maxDownloadBytes,
      maxDecodedChars: maxDecodedChars,
    );
  });
}

class _EpgParseIsolateArgs {
  const _EpgParseIsolateArgs({
    required this.reply,
    this.url,
    this.contentEncoding,
    required this.maxDownloadBytes,
    required this.maxDecodedChars,
  });

  final SendPort reply;
  final String? url;
  final String? contentEncoding;
  final int maxDownloadBytes;
  final int maxDecodedChars;
}

/// Stream packed XMLTV rows into [onChunk] (SQL maps). Does not build
/// [EpgProgram] lists on the UI isolate.
Future<EpgIngestResult> ingestEpgPackedInIsolate({
  required List<int> bytes,
  required Future<void> Function(List<Map<String, Object?>> rows) onChunk,
  String? url,
  String? contentEncoding,
  int maxDownloadBytes = kMaxEpgDownloadBytes,
  int maxDecodedChars = kMaxEpgDecodedChars,
}) {
  return UiStallWatchdog.span('epg-ingest', () async {
    if (kIsWeb) {
      final packed = _parseEpgBytesWorker({
        'bytes': bytes,
        'url': url,
        'contentEncoding': contentEncoding,
        'maxDownloadBytes': maxDownloadBytes,
        'maxDecodedChars': maxDecodedChars,
      });
      return _ingestPackedOnCaller(packed, onChunk);
    }
    return _ingestEpgBytesChunked(
      bytes,
      onChunk: onChunk,
      url: url,
      contentEncoding: contentEncoding,
      maxDownloadBytes: maxDownloadBytes,
      maxDecodedChars: maxDecodedChars,
    );
  });
}

Future<EpgIngestResult> _ingestPackedOnCaller(
  Map<String, dynamic> packed,
  Future<void> Function(List<Map<String, Object?>> rows) onChunk,
) async {
  final channelIds = (packed['c'] as List?)?.cast<String>() ?? const <String>[];
  final titles = (packed['t'] as List?)?.cast<String>() ?? const <String>[];
  final starts = (packed['s'] as List?)?.cast<int>() ?? const <int>[];
  final ends = (packed['e'] as List?)?.cast<int>() ?? const <int>[];
  final descs = packed['d'] as List?;
  final images = packed['i'] as List?;
  final n = channelIds.length;
  var count = 0;
  const chunk = kIsolateListChunk;
  for (var i = 0; i < n; i += chunk) {
    final end = i + chunk > n ? n : i + chunk;
    final rows = _sqlRowsFromPackedSlice(
      channelIds: channelIds,
      titles: titles,
      starts: starts,
      ends: ends,
      descs: descs,
      images: images,
      start: i,
      end: end,
    );
    if (rows.isNotEmpty) {
      await onChunk(rows);
      count += rows.length;
    }
    await yieldAfterIsolateChunk();
  }
  final namesRaw = packed['n'];
  final channelNames = namesRaw is Map
      ? {for (final e in namesRaw.entries) e.key.toString(): e.value.toString()}
      : const <String, String>{};
  return EpgIngestResult(channelNames: channelNames, programCount: count);
}

Future<EpgIngestResult> _ingestEpgBytesChunked(
  List<int> bytes, {
  required Future<void> Function(List<Map<String, Object?>> rows) onChunk,
  String? url,
  String? contentEncoding,
  required int maxDownloadBytes,
  required int maxDecodedChars,
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _epgParseIsolateMain,
      _EpgParseIsolateArgs(
        reply: receive.sendPort,
        url: url,
        contentEncoding: contentEncoding,
        maxDownloadBytes: maxDownloadBytes,
        maxDecodedChars: maxDecodedChars,
      ),
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    receive.close();
    errors.close();
    rethrow;
  }

  var channelNames = const <String, String>{};
  var programCount = 0;
  Object? isolateError;
  final errorSub = errors.listen((msg) {
    isolateError ??= msg;
  });
  try {
    await for (final message in receive) {
      if (isolateError != null) throw isolateError!;
      if (message == null) break;
      if (message is SendPort) {
        await _streamBytesToEpgWorker(message, bytes);
        continue;
      }
      if (message is! Map) continue;
      final kind = '${message['k'] ?? ''}';
      if (kind == 'err') {
        throw StateError('epg parse failed: ${message['v']}');
      }
      if (kind == 'n') {
        final namesRaw = message['v'];
        if (namesRaw is Map) {
          channelNames = {
            for (final e in namesRaw.entries)
              e.key.toString(): e.value.toString(),
          };
        }
        await pumpUi(label: 'epg-names');
        continue;
      }
      if (kind == 'p') {
        final rows = _sqlRowsFromPackedMessage(message);
        if (rows.isNotEmpty) {
          await onChunk(rows);
          programCount += rows.length;
        }
        // 1ms yieldAfterIsolateChunk is not enough for Win32 during
        // « Mise à jour du guide » — force an embedder frame like SQL insert.
        await pumpUi(label: 'epg-chunk');
      }
    }
    if (isolateError != null) throw isolateError!;
    return EpgIngestResult(
      channelNames: channelNames,
      programCount: programCount,
    );
  } finally {
    await errorSub.cancel();
    receive.close();
    errors.close();
    worker.kill(priority: Isolate.immediate);
  }
}

List<Map<String, Object?>> _sqlRowsFromPackedMessage(
  Map<dynamic, dynamic> chunk,
) {
  final channelIds = (chunk['c'] as List?)?.cast<String>() ?? const <String>[];
  final titles = (chunk['ti'] as List?)?.cast<String>() ?? const <String>[];
  final starts = (chunk['s'] as List?)?.cast<int>() ?? const <int>[];
  final ends = (chunk['e'] as List?)?.cast<int>() ?? const <int>[];
  return _sqlRowsFromPackedSlice(
    channelIds: channelIds,
    titles: titles,
    starts: starts,
    ends: ends,
    descs: chunk['d'] as List?,
    images: chunk['i'] as List?,
    start: 0,
    end: channelIds.length,
  );
}

List<Map<String, Object?>> _sqlRowsFromPackedSlice({
  required List<String> channelIds,
  required List<String> titles,
  required List<int> starts,
  required List<int> ends,
  required List<dynamic>? descs,
  required List<dynamic>? images,
  required int start,
  required int end,
}) {
  final rows = <Map<String, Object?>>[];
  for (var i = start; i < end; i++) {
    final id = i < channelIds.length ? channelIds[i].trim() : '';
    if (id.isEmpty) continue;
    final desc = descs != null && i < descs.length ? descs[i] as String? : null;
    final image = images != null && i < images.length
        ? images[i] as String?
        : null;
    rows.add({
      'channel_id': id,
      'start_ms': i < starts.length ? starts[i] : 0,
      'end_ms': i < ends.length ? ends[i] : 0,
      'title': i < titles.length ? titles[i] : 'Program',
      'description': desc,
      'image_url': image,
      'catchup_id': null,
      'has_archive': 0,
    });
  }
  return rows;
}

/// Worker sends channel names, then packed programme rows in chunks.
Future<EpgParseResult> _parseEpgBytesChunked(
  List<int> bytes, {
  String? url,
  String? contentEncoding,
  required int maxDownloadBytes,
  required int maxDecodedChars,
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  late final Isolate worker;
  try {
    worker = await Isolate.spawn(
      _epgParseIsolateMain,
      _EpgParseIsolateArgs(
        reply: receive.sendPort,
        url: url,
        contentEncoding: contentEncoding,
        maxDownloadBytes: maxDownloadBytes,
        maxDecodedChars: maxDecodedChars,
      ),
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    receive.close();
    errors.close();
    rethrow;
  }

  final programs = <EpgProgram>[];
  var channelNames = const <String, String>{};
  Object? isolateError;
  final errorSub = errors.listen((msg) {
    isolateError ??= msg;
  });
  try {
    await for (final message in receive) {
      if (isolateError != null) throw isolateError!;
      if (message == null) break;
      if (message is SendPort) {
        await _streamBytesToEpgWorker(message, bytes);
        continue;
      }
      if (message is! Map) continue;
      final kind = '${message['k'] ?? ''}';
      if (kind == 'err') {
        throw StateError('epg parse failed: ${message['v']}');
      }
      if (kind == 'n') {
        final namesRaw = message['v'];
        if (namesRaw is Map) {
          channelNames = {
            for (final e in namesRaw.entries)
              e.key.toString(): e.value.toString(),
          };
        }
        await yieldAfterIsolateChunk();
        continue;
      }
      if (kind == 'p') {
        await _appendPackedEpgChunk(programs, message);
        await yieldAfterIsolateChunk();
      }
    }
    if (isolateError != null) throw isolateError!;
    return EpgParseResult(programs: programs, channelNames: channelNames);
  } finally {
    await errorSub.cancel();
    receive.close();
    errors.close();
    worker.kill(priority: Isolate.immediate);
  }
}

@pragma('vm:entry-point')
void _epgParseIsolateMain(_EpgParseIsolateArgs args) {
  unawaited(_epgParseIsolateBody(args));
}

Future<void> _epgParseIsolateBody(_EpgParseIsolateArgs args) async {
  final inbound = ReceivePort();
  args.reply.send(inbound.sendPort);
  final buffer = BytesBuilder(copy: false);
  try {
    await for (final message in inbound) {
      if (message == null) break;
      if (message is List<int>) buffer.add(message);
    }
    final packed = _parseEpgBytesWorker({
      'bytes': buffer.takeBytes(),
      'url': args.url,
      'contentEncoding': args.contentEncoding,
      'maxDownloadBytes': args.maxDownloadBytes,
      'maxDecodedChars': args.maxDecodedChars,
    });
    args.reply.send({'k': 'n', 'v': packed['n']});
    final channelIds =
        (packed['c'] as List?)?.cast<String>() ?? const <String>[];
    final titles = (packed['t'] as List?)?.cast<String>() ?? const <String>[];
    final starts = (packed['s'] as List?)?.cast<int>() ?? const <int>[];
    final ends = (packed['e'] as List?)?.cast<int>() ?? const <int>[];
    final descs = packed['d'] as List?;
    final images = packed['i'] as List?;
    final n = channelIds.length;
    const chunk = kIsolateListChunk;
    for (var i = 0; i < n; i += chunk) {
      final end = i + chunk > n ? n : i + chunk;
      args.reply.send({
        'k': 'p',
        'c': channelIds.sublist(i, end),
        'ti': titles.sublist(i, end > titles.length ? titles.length : end),
        's': starts.sublist(i, end > starts.length ? starts.length : end),
        'e': ends.sublist(i, end > ends.length ? ends.length : end),
        'd': descs == null
            ? null
            : descs.sublist(i, end > descs.length ? descs.length : end),
        'i': images == null
            ? null
            : images.sublist(i, end > images.length ? images.length : end),
      });
    }
  } catch (e) {
    args.reply.send({'k': 'err', 'v': '$e'});
  } finally {
    inbound.close();
    args.reply.send(null);
  }
}

Future<void> _streamBytesToEpgWorker(SendPort worker, List<int> bytes) async {
  for (var i = 0; i < bytes.length; i += kIsolateByteChunk) {
    final end = i + kIsolateByteChunk > bytes.length
        ? bytes.length
        : i + kIsolateByteChunk;
    worker.send(bytes.sublist(i, end));
    // Copying multi-MB XMLTV onto the worker used 1ms yields and froze HWND
    // under « Mise à jour du guide ».
    await pumpUi(label: 'epg-stream-worker');
  }
  worker.send(null);
}

Future<void> _appendPackedEpgChunk(
  List<EpgProgram> programs,
  Map<dynamic, dynamic> chunk,
) async {
  final channelIds = (chunk['c'] as List?)?.cast<String>() ?? const <String>[];
  final titles = (chunk['ti'] as List?)?.cast<String>() ?? const <String>[];
  final starts = (chunk['s'] as List?)?.cast<int>() ?? const <int>[];
  final ends = (chunk['e'] as List?)?.cast<int>() ?? const <int>[];
  final descs = chunk['d'] as List?;
  final images = chunk['i'] as List?;
  final n = channelIds.length;
  final slice = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final desc = descs != null && i < descs.length ? descs[i] as String? : null;
    final image = images != null && i < images.length
        ? images[i] as String?
        : null;
    programs.add(
      EpgProgram(
        channelId: channelIds[i],
        title: i < titles.length ? titles[i] : 'Program',
        start: DateTime.fromMillisecondsSinceEpoch(
          i < starts.length ? starts[i] : 0,
          isUtc: true,
        ),
        end: DateTime.fromMillisecondsSinceEpoch(
          i < ends.length ? ends[i] : 0,
          isUtc: true,
        ),
        description: desc,
        imageUrl: image,
      ),
    );
    await yieldUiSlice(slice, i: i, label: 'epg-chunk-append');
  }
}

/// Packed isolate payload → [EpgParseResult] (UI isolate, yielded list walk).
Future<EpgParseResult> _epgResultFromPacked(
  Map<String, dynamic> payload,
) async {
  final channelIds = (payload['c'] as List?)?.cast<String>() ?? const [];
  final titles = (payload['t'] as List?)?.cast<String>() ?? const [];
  final starts = (payload['s'] as List?)?.cast<int>() ?? const [];
  final ends = (payload['e'] as List?)?.cast<int>() ?? const [];
  final descs = payload['d'] as List?;
  final images = payload['i'] as List?;
  final n = channelIds.length;
  final programs = <EpgProgram>[];
  final slice = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final desc = descs != null && i < descs.length ? descs[i] as String? : null;
    final image = images != null && i < images.length
        ? images[i] as String?
        : null;
    programs.add(
      EpgProgram(
        channelId: channelIds[i],
        title: i < titles.length ? titles[i] : 'Program',
        start: DateTime.fromMillisecondsSinceEpoch(
          i < starts.length ? starts[i] : 0,
          isUtc: true,
        ),
        end: DateTime.fromMillisecondsSinceEpoch(
          i < ends.length ? ends[i] : 0,
          isUtc: true,
        ),
        description: desc,
        imageUrl: image,
      ),
    );
    await yieldUiSlice(slice, i: i, label: 'epg-programmes');
  }
  final namesRaw = payload['n'];
  final channelNames = namesRaw is Map
      ? {for (final e in namesRaw.entries) e.key.toString(): e.value.toString()}
      : const <String, String>{};
  return EpgParseResult(programs: programs, channelNames: channelNames);
}

Map<String, dynamic> _parseEpgBytesWorker(Map<String, dynamic> args) {
  final raw = args['bytes'];
  final bytes = raw is Uint8List
      ? raw
      : Uint8List.fromList((raw as List).cast<int>());
  final url = args['url'] as String?;
  final contentEncoding = args['contentEncoding'] as String?;
  final maxDownloadBytes =
      args['maxDownloadBytes'] as int? ?? kMaxEpgDownloadBytes;
  final maxDecodedChars =
      args['maxDecodedChars'] as int? ?? kMaxEpgDecodedChars;

  if (bytes.length > maxDownloadBytes) {
    return const {
      'c': <String>[],
      't': <String>[],
      's': <int>[],
      'e': <int>[],
      'n': <String, String>{},
    };
  }
  final body = decodeEpgResponseBody(
    bytes,
    url: url,
    contentEncoding: contentEncoding,
  );
  if (body.length > maxDecodedChars) {
    return const {
      'c': <String>[],
      't': <String>[],
      's': <int>[],
      'e': <int>[],
      'n': <String, String>{},
    };
  }
  final doc = EpgParser().parseDocument(body);
  final n = doc.programs.length;
  final channelIds = List<String>.filled(n, '', growable: false);
  final titles = List<String>.filled(n, '', growable: false);
  final starts = List<int>.filled(n, 0, growable: false);
  final ends = List<int>.filled(n, 0, growable: false);
  final descs = List<String?>.filled(n, null, growable: false);
  final images = List<String?>.filled(n, null, growable: false);
  for (var i = 0; i < n; i++) {
    final p = doc.programs[i];
    channelIds[i] = p.channelId;
    titles[i] = p.title;
    starts[i] = p.start.toUtc().millisecondsSinceEpoch;
    ends[i] = p.end.toUtc().millisecondsSinceEpoch;
    descs[i] = p.description;
    images[i] = p.imageUrl;
  }
  return {
    'c': channelIds,
    't': titles,
    's': starts,
    'e': ends,
    'd': descs,
    'i': images,
    'n': doc.channelNames,
  };
}

/// Split `#EXTM3U` `url-tvg` / `x-tvg-url` (or a manual EPG field) into
/// individual guide URLs. Values are commonly comma-separated.
List<String> splitEpgUrls(String? raw) {
  if (raw == null) return const [];
  return raw
      .split(',')
      .map((u) => u.trim())
      .where((u) => u.isNotEmpty)
      .toList(growable: false);
}

/// Decode an EPG HTTP body that may be plain XML or gzip (`.xml.gz`).
String decodeEpgResponseBody(
  List<int> bytes, {
  String? url,
  String? contentEncoding,
}) {
  if (bytes.isEmpty) return '';
  // The HTTP client often already inflated gzip. A leftover
  // Content-Encoding: gzip header must not gzip-decode XML (that throws,
  // and the isolate used to report 0 programmes).
  if (_bytesLookLikeXmltv(bytes)) {
    return utf8.decode(bytes, allowMalformed: true);
  }
  final encoding = contentEncoding?.toLowerCase() ?? '';
  final path = Uri.tryParse(url ?? '')?.path.toLowerCase() ?? '';
  final magicGzip = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  final looksGzip =
      magicGzip ||
      encoding.contains('gzip') ||
      path.endsWith('.gz') ||
      path.endsWith('.xml.gz');
  final raw = looksGzip ? gzip.decode(bytes) : bytes;
  return utf8.decode(raw, allowMalformed: true);
}

bool _bytesLookLikeXmltv(List<int> bytes) {
  var i = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    i = 3;
  }
  while (i < bytes.length && bytes[i] <= 0x20) {
    i++;
  }
  if (i >= bytes.length) return false;
  // '<' of <?xml / <tv / <!DOCTYPE
  return bytes[i] == 0x3c;
}

/// Drop SYSTEM/PUBLIC doctype so the parser never tries to fetch xmltv.dtd.
String _xmltvWithoutExternalDoctype(String xml) {
  return xml.replaceFirst(
    RegExp(r'<!DOCTYPE[\s\S]*?>', caseSensitive: false),
    '',
  );
}

/// XMLTV EPG parser used for Live + Catchup guide data.
class EpgParser {
  List<EpgProgram> parse(String xmlContent) =>
      parseDocument(xmlContent).programs;

  EpgParseResult parseDocument(String xmlContent) {
    final document = XmlDocument.parse(_xmltvWithoutExternalDoctype(xmlContent));
    final programs = <EpgProgram>[];
    final channelNames = <String, String>{};

    for (final node in document.findAllElements('channel')) {
      final id = node.getAttribute('id')?.trim();
      if (id == null || id.isEmpty) continue;
      final display = node
          .findElements('display-name')
          .map((e) => e.innerText.trim())
          .firstWhere((t) => t.isNotEmpty, orElse: () => '');
      if (display.isNotEmpty) {
        channelNames[id] = display;
      }
    }

    for (final node in document.findAllElements('programme')) {
      final channelId = node.getAttribute('channel');
      final startRaw = node.getAttribute('start');
      final stopRaw = node.getAttribute('stop');
      if (channelId == null || startRaw == null || stopRaw == null) continue;

      final start = _parseXmltvDate(startRaw);
      final end = _parseXmltvDate(stopRaw);
      if (start == null || end == null) continue;

      final title = node.getElement('title')?.innerText.trim() ?? 'Program';
      final description = node.getElement('desc')?.innerText.trim();
      final iconSrc = node
          .findElements('icon')
          .map((e) => e.getAttribute('src')?.trim() ?? '')
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');

      programs.add(
        EpgProgram(
          channelId: channelId,
          title: title,
          start: start,
          end: end,
          description: description,
          imageUrl: iconSrc.isEmpty ? null : iconSrc,
        ),
      );
    }

    programs.sort((a, b) => a.start.compareTo(b.start));
    return EpgParseResult(programs: programs, channelNames: channelNames);
  }

  Map<String, EpgProgram?> currentByChannel(
    List<EpgProgram> programs, {
    DateTime? at,
  }) {
    final moment = at ?? DateTime.now();
    final map = <String, EpgProgram?>{};
    for (final program in programs) {
      map.putIfAbsent(program.channelId, () => null);
      if (program.isAiringAt(moment)) {
        map[program.channelId] = program;
      }
    }
    return map;
  }

  List<EpgProgram> forChannel(
    List<EpgProgram> programs,
    String channelId, {
    DateTime? from,
    DateTime? to,
  }) {
    return programs.where((p) {
      if (p.channelId != channelId) return false;
      if (from != null && p.end.isBefore(from)) return false;
      if (to != null && p.start.isAfter(to)) return false;
      return true;
    }).toList();
  }

  /// XMLTV timestamps look like: 20260808123000 +0000
  DateTime? _parseXmltvDate(String raw) {
    final cleaned = raw.trim();
    if (cleaned.length < 14) return null;
    final y = int.tryParse(cleaned.substring(0, 4));
    final mo = int.tryParse(cleaned.substring(4, 6));
    final d = int.tryParse(cleaned.substring(6, 8));
    final h = int.tryParse(cleaned.substring(8, 10));
    final mi = int.tryParse(cleaned.substring(10, 12));
    final s = int.tryParse(cleaned.substring(12, 14));
    if ([y, mo, d, h, mi, s].contains(null)) return null;

    var offset = Duration.zero;
    final parts = cleaned.split(RegExp(r'\s+'));
    if (parts.length > 1) {
      final tz = parts[1];
      if (tz.length == 5 && (tz.startsWith('+') || tz.startsWith('-'))) {
        final sign = tz.startsWith('-') ? -1 : 1;
        final oh = int.tryParse(tz.substring(1, 3)) ?? 0;
        final om = int.tryParse(tz.substring(3, 5)) ?? 0;
        offset = Duration(hours: sign * oh, minutes: sign * om);
      }
    }

    final utc = DateTime.utc(y!, mo!, d!, h!, mi!, s!);
    return utc.subtract(offset);
  }
}
