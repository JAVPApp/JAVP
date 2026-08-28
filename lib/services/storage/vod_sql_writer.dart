import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Background SQLite writer for Xtream VOD ingest.
///
/// JSON workers send packed SQL row chunks here so the **UI isolate never
/// copies ~400 maps per message** (that froze the Windows HWND for the whole
/// Synchroniser). Progress is tiny ints only.
class VodSqlWriter {
  VodSqlWriter._({
    required this.sink,
    required Isolate isolate,
    required ReceivePort progressPort,
    required StreamController<int> progress,
  }) : _isolate = isolate,
       _progressPort = progressPort,
       _progress = progress;

  /// Workers send `{t:'sql', v:<rows>, ack:<SendPort>}` / `{t:'close'}`.
  final SendPort sink;

  final Isolate _isolate;
  final ReceivePort _progressPort;
  final StreamController<int> _progress;
  var _closed = false;

  /// Cumulative rows committed (UI status only).
  Stream<int> get committed => _progress.stream;

  static Future<VodSqlWriter> start({
    required String dbPath,
    required String sourceId,
    required int generation,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('VodSqlWriter is native-only');
    }
    final progressPort = ReceivePort();
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _vodSqlWriterMain,
      ready.sendPort,
      errorsAreFatal: true,
    );
    final handshake = await ready.first;
    ready.close();
    if (handshake is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      progressPort.close();
      throw StateError('vod sql writer handshake failed');
    }
    final progress = StreamController<int>.broadcast();
    progressPort.listen((msg) {
      if (msg is int) {
        progress.add(msg);
      } else if (msg == null) {
        unawaited(progress.close());
      }
    });
    handshake.send(<String, Object?>{
      'dbPath': dbPath,
      'sourceId': sourceId,
      'generation': generation,
      'progress': progressPort.sendPort,
    });
    return VodSqlWriter._(
      sink: handshake,
      isolate: isolate,
      progressPort: progressPort,
      progress: progress,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      sink.send(const <String, Object?>{'t': 'close'});
    } catch (_) {}
    await _progress.done.timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
    _progressPort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _vodSqlWriterMain(SendPort reply) async {
  sqfliteFfiInit();
  // Run SQLite on this isolate — no second hop back through the UI thread.
  databaseFactory = databaseFactoryFfiNoIsolate;

  final inbound = ReceivePort();
  reply.send(inbound.sendPort);

  Database? db;
  SendPort? progress;
  var generation = 0;
  var committed = 0;
  var lastProgressAt = 0;
  var lastProgressN = 0;

  try {
    await for (final raw in inbound) {
      if (raw is! Map) continue;
      final msg = Map<String, Object?>.from(raw);
      final t = '${msg['t'] ?? ''}';

      if (t.isEmpty && msg['dbPath'] is String) {
        generation = (msg['generation'] as num?)?.toInt() ?? 0;
        progress = msg['progress'] as SendPort?;
        db = await openDatabase('${msg['dbPath']}');
        try {
          // Android sqflite rejects these PRAGMAs via execute() — use rawQuery.
          await db.rawQuery('PRAGMA busy_timeout = 30000');
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA synchronous=NORMAL');
        } catch (_) {}
        progress?.send(0);
        continue;
      }

      if (t == 'close') {
        break;
      }

      if (t == 'sql' && db != null) {
        final rowsRaw = msg['v'];
        final ack = msg['ack'];
        if (rowsRaw is List && rowsRaw.isNotEmpty) {
          final rows = <Map<String, Object?>>[
            for (final e in rowsRaw)
              if (e is Map)
                {...Map<String, Object?>.from(e), 'sync_generation': generation},
          ];
          await db.transaction((txn) async {
            const batchSize = 100;
            for (var i = 0; i < rows.length; i += batchSize) {
              final end =
                  i + batchSize > rows.length ? rows.length : i + batchSize;
              final batch = txn.batch();
              for (var j = i; j < end; j++) {
                batch.insert(
                  'vod_items',
                  rows[j],
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              }
              await batch.commit(noResult: true);
            }
          });
          committed += rows.length;
          // Throttle UI progress ints — every chunk was waking the UI isolate.
          final now = DateTime.now().millisecondsSinceEpoch;
          if (committed - lastProgressN >= 2000 || now - lastProgressAt >= 500) {
            lastProgressN = committed;
            lastProgressAt = now;
            progress?.send(committed);
          }
        }
        if (ack is SendPort) {
          ack.send(true);
        }
        continue;
      }
    }
  } finally {
    if (committed != lastProgressN) {
      progress?.send(committed);
    }
    try {
      await db?.close();
    } catch (_) {}
    progress?.send(null);
    inbound.close();
  }
}
