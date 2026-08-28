import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:javp/platform/portable_mode.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/sync_worker/sync_engine.dart';
import 'package:javp/sync_worker/sync_protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Headless catalog worker entry (`--javp-sync`).
///
/// Speaks NDJSON on stdin/stdout. Does **not** call [runApp] or window_manager.
Future<void> runSyncWorkerMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerPortablePathProviderIfNeeded();

  // stdout is the NDJSON control channel — never print() logs there.
  JavpLog.consoleToStderr = true;

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  await JavpLog.instance.start();
  JavpLog.i('sync', 'worker start args=${args.join(' ')}');

  void emit(SyncEvent event) {
    stdout.writeln(jsonEncode(event.toJson()));
  }

  emit(SyncEvent.hello());

  try {
    final job = await _readJob(stdin);
    JavpLog.i(
      'sync',
      'worker job op=${job.op.name} source=${job.source.id} '
          'reason=${job.reason.name}',
    );
    final engine = SyncEngine();
    await engine.run(job, onEvent: emit);
    JavpLog.i('sync', 'worker done');
    await stdout.flush();
    await stderr.flush();
    exit(0);
  } catch (e, st) {
    JavpLog.e('sync', 'worker failed: $e', stack: st);
    emit(SyncEvent.error('$e'));
    await stdout.flush();
    exit(1);
  }
}

Future<SyncJob> _readJob(Stream<List<int>> input) async {
  final lines = input
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final raw = jsonDecode(trimmed);
    if (raw is! Map) continue;
    final map = Map<String, Object?>.from(raw);
    final t = '${map['t'] ?? ''}';
    if (t == 'job') {
      return SyncJob.fromJson(map);
    }
  }
  throw StateError('sync worker: no job on stdin');
}

/// True when this process was launched as the catalog sync worker.
bool isJavpSyncWorkerArgs(List<String> args) =>
    args.any((a) => a == '--javp-sync' || a.startsWith('--javp-sync='));
