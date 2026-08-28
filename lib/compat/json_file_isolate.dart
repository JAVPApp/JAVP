import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';

/// Encode [value] to JSON and write [path] on a worker.
///
/// The encoded string stays on the worker — a `javpCompute(jsonEncode)` plus
/// `writeAsString(flush: true)` on the UI isolate was a 500ms+ stall.
Future<void> writeJsonValueToFileInIsolate({
  required String path,
  required Object? value,
}) {
  if (kIsWeb) {
    throw UnsupportedError('writeJsonValueToFileInIsolate needs dart:io');
  }
  return UiStallWatchdog.span('json-write', () {
    return Isolate.run(() {
      File(path).writeAsStringSync(jsonEncode(value));
    });
  });
}

/// Encode [maps] to JSON and write [path] on a worker.
///
/// A one-shot [Isolate.run] of 10k catalog maps copies the list *and* the
/// encoded string onto the UI isolate — that was `phase=compute` plus a
/// 500ms+ `writeAsString(flush: true)` while Windows dropped focus.
/// Chunks go to the worker; only an ack comes back.
Future<void> writeJsonMapsToFileInIsolate({
  required String path,
  required List<Map<String, dynamic>> maps,
}) {
  if (kIsWeb) {
    throw UnsupportedError('writeJsonMapsToFileInIsolate needs dart:io');
  }
  return UiStallWatchdog.span('catalog-save', () async {
    if (maps.length < kIsolateListChunk) {
      await Isolate.run(() {
        File(path).writeAsStringSync(jsonEncode(maps));
      });
      return;
    }

    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _jsonMapsFileWriterMain,
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
        throw StateError('json file writer exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final port = iter.current as SendPort;
      port.send(path);
      await yieldAfterIsolateChunk();
      const chunk = kIsolateListChunk;
      for (var i = 0; i < maps.length; i += chunk) {
        if (isolateError != null) throw isolateError!;
        final end = i + chunk > maps.length ? maps.length : i + chunk;
        port.send(List<Map<String, dynamic>>.from(maps.getRange(i, end)));
        await yieldAfterIsolateChunk();
      }
      port.send(null);
      if (!await iter.moveNext()) {
        throw StateError('json file writer exited before ack');
      }
      if (isolateError != null) throw isolateError!;
      final ack = iter.current;
      if (ack != true) {
        throw StateError('json file writer failed: $ack');
      }
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
void _jsonMapsFileWriterMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  String? path;
  final maps = <Map<String, dynamic>>[];
  inbox.listen((message) {
    if (message is String) {
      path = message;
      return;
    }
    if (message == null) {
      final out = path;
      if (out == null) {
        reply.send('missing-path');
        inbox.close();
        return;
      }
      try {
        File(out).writeAsStringSync(jsonEncode(maps));
        reply.send(true);
      } catch (e) {
        reply.send('$e');
      }
      inbox.close();
      return;
    }
    if (message is List) {
      for (final row in message) {
        if (row is Map) {
          maps.add(Map<String, dynamic>.from(row));
        }
      }
    }
  });
}

/// Decode a JSON array on a worker and stream maps back in chunks.
///
/// A one-shot [Isolate.run] of 10k catalog maps copies the whole list onto
/// the UI isolate and Windows drops clicks (no Not Responding banner).
Future<List<Map<String, dynamic>>> decodeJsonListMapsInIsolate(String raw) {
  if (kIsWeb) {
    return Future.value(_mapsFromJsonList(raw));
  }
  return UiStallWatchdog.span('json-list', () async {
    if (raw.length < 32 * 1024) {
      return _mapsFromJsonList(raw);
    }
    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _jsonListDecodeMain,
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
        throw StateError('json list decode exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final port = iter.current as SendPort;
      port.send(raw);
      await yieldAfterIsolateChunk();

      final out = <Map<String, dynamic>>[];
      while (await iter.moveNext()) {
        if (isolateError != null) throw isolateError!;
        final message = iter.current;
        if (message == null) break;
        if (message is List) {
          for (final row in message) {
            if (row is Map) {
              out.add(Map<String, dynamic>.from(row));
            }
          }
        }
        await yieldAfterIsolateChunk();
      }
      if (isolateError != null) throw isolateError!;
      return out;
    } finally {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  });
}

/// Decode a JSON object of maps on a worker and stream entries back in chunks.
Future<Map<String, Map<String, dynamic>>> decodeJsonObjectMapsInIsolate(
  String raw,
) {
  if (kIsWeb) {
    return Future.value(_mapsFromJsonObject(raw));
  }
  return UiStallWatchdog.span('json-object', () async {
    if (raw.length < 32 * 1024) {
      return _mapsFromJsonObject(raw);
    }
    final receive = ReceivePort();
    final errors = ReceivePort();
    late final Isolate worker;
    try {
      worker = await Isolate.spawn(
        _jsonObjectDecodeMain,
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
        throw StateError('json object decode exited before handshake');
      }
      if (isolateError != null) throw isolateError!;
      final port = iter.current as SendPort;
      port.send(raw);
      await yieldAfterIsolateChunk();

      final out = <String, Map<String, dynamic>>{};
      while (await iter.moveNext()) {
        if (isolateError != null) throw isolateError!;
        final message = iter.current;
        if (message == null) break;
        if (message is List) {
          for (final row in message) {
            if (row is! List || row.length < 2) continue;
            final value = row[1];
            if (value is Map) {
              out['${row[0]}'] = Map<String, dynamic>.from(value);
            }
          }
        }
        await yieldAfterIsolateChunk();
      }
      if (isolateError != null) throw isolateError!;
      return out;
    } finally {
      await errorSub.cancel();
      await iter.cancel();
      receive.close();
      errors.close();
      worker.kill(priority: Isolate.immediate);
    }
  });
}

List<Map<String, dynamic>> _mapsFromJsonList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return [
    for (final e in decoded)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

Map<String, Map<String, dynamic>> _mapsFromJsonObject(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const {};
  return {
    for (final e in decoded.entries)
      if (e.value is Map) '${e.key}': Map<String, dynamic>.from(e.value as Map),
  };
}

@pragma('vm:entry-point')
void _jsonListDecodeMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! String) return;
    try {
      final maps = _mapsFromJsonList(message);
      const chunk = kIsolateListChunk;
      for (var i = 0; i < maps.length; i += chunk) {
        final end = i + chunk > maps.length ? maps.length : i + chunk;
        reply.send(maps.sublist(i, end));
      }
      reply.send(null);
    } catch (_) {
      reply.send(null);
    }
    inbox.close();
  });
}

@pragma('vm:entry-point')
void _jsonObjectDecodeMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! String) return;
    try {
      final maps = _mapsFromJsonObject(message);
      final entries = maps.entries.toList(growable: false);
      const chunk = kIsolateListChunk;
      for (var i = 0; i < entries.length; i += chunk) {
        final end = i + chunk > entries.length ? entries.length : i + chunk;
        reply.send([
          for (final e in entries.sublist(i, end)) [e.key, e.value],
        ]);
      }
      reply.send(null);
    } catch (_) {
      reply.send(null);
    }
    inbox.close();
  });
}
