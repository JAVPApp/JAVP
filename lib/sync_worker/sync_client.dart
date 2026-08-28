import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:javp/models/iptv_source.dart';
import 'package:javp/models/iptv_category.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/sync_worker/sync_engine.dart';
import 'package:javp/sync_worker/sync_protocol.dart';
import 'package:javp/sync_worker/sync_scheduler.dart';

typedef SyncProgressCallback = void Function(SyncEvent event);

/// UI-side handle for catalog writes (desktop: child process).
class SyncClient {
  SyncClient();

  Process? _process;

  /// True while a SyncEngine child process is alive (desktop OOP path).
  bool get hasWorker => _process != null;

  /// Cancel an in-flight out-of-process job (best-effort).
  void cancel() {
    final p = _process;
    _process = null;
    if (p == null) return;
    try {
      p.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  Future<SyncJobResult> runXtreamVod({
    required String profileId,
    required IptvSource source,
    SyncReason reason = SyncReason.manual,
    SyncProgressCallback? onProgress,
  }) {
    final job = SyncJob(
      op: SyncOp.xtreamVod,
      reason: reason,
      profileId: profileId,
      source: source,
    );
    return run(job, onProgress: onProgress);
  }

  Future<SyncJobResult> runXtreamLive({
    required String profileId,
    required IptvSource source,
    Map<String, String> epgDisplayNames = const {},
    Map<String, String> preferredLiveQualities = const {},
    List<IptvCategory> liveCategories = const [],
    SyncReason reason = SyncReason.manual,
    SyncProgressCallback? onProgress,
  }) {
    final job = SyncJob(
      op: SyncOp.xtreamLive,
      reason: reason,
      profileId: profileId,
      source: source,
      epgDisplayNames: epgDisplayNames,
      preferredLiveQualities: preferredLiveQualities,
      liveCategories: liveCategories,
    );
    return run(job, onProgress: onProgress);
  }

  Future<SyncJobResult> runXmltvEpg({
    required String profileId,
    required List<String> epgUrls,
    List<String> warmEpgUrls = const [],
    String trigger = '',
    SyncReason reason = SyncReason.manual,
    SyncProgressCallback? onProgress,
  }) {
    final job = SyncJob(
      op: SyncOp.xmltvEpg,
      reason: reason,
      profileId: profileId,
      source: IptvSource(
        id: 'xmltv-merged',
        name: 'XMLTV',
        type: IptvSourceType.xmltv,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        epgUrl: epgUrls.isEmpty ? null : epgUrls.first,
      ),
      epgUrls: epgUrls,
      warmEpgUrls: warmEpgUrls,
      trigger: trigger,
    );
    return run(job, onProgress: onProgress);
  }

  Future<SyncJobResult> run(
    SyncJob job, {
    SyncProgressCallback? onProgress,
  }) {
    return SyncScheduler.instance.enqueue(
      () async {
        if (_shouldRunOutOfProcess) {
          return _runOutOfProcess(job, onProgress: onProgress);
        }
        return SyncEngine().run(job, onEvent: onProgress);
      },
      label: '${job.op.name}:${job.source.id}',
    );
  }

  bool get _shouldRunOutOfProcess {
    if (kIsWeb) return false;
    if (!DesktopUi.isDesktopOs) return false;
    // Tests / forced in-process.
    if (Platform.environment['JAVP_SYNC_INPROCESS'] == '1') return false;
    return true;
  }

  Future<SyncJobResult> _runOutOfProcess(
    SyncJob job, {
    SyncProgressCallback? onProgress,
  }) async {
    final exe = Platform.resolvedExecutable;
    final cwd = File(exe).parent.path;
    JavpLog.i(
      'sync',
      'spawn worker exe=$exe source=${job.source.id} op=${job.op.name}',
    );

    final process = await Process.start(
      exe,
      const ['--javp-sync'],
      workingDirectory: cwd,
      environment: {
        ...Platform.environment,
        'JAVP_SYNC_WORKER': '1',
      },
      // Inherit nothing — we own stdin/stdout pipes.
      mode: ProcessStartMode.normal,
    );
    _process = process;

    SyncJobResult? result;
    Object? error;
    var lastEventAt = DateTime.now();

    void handleLine(String line) {
      final trimmed = line.trim();
      // Worker stdout is NDJSON only; ignore plugin banners / stray prints.
      if (!trimmed.startsWith('{')) return;
      try {
        final raw = jsonDecode(trimmed);
        if (raw is! Map) return;
        final event = SyncEvent.fromJson(Map<String, Object?>.from(raw));
        lastEventAt = DateTime.now();
        if (event.type == 'hello') {
          JavpLog.i('sync', 'worker hello');
          return;
        }
        if (event.type == 'progress') {
          onProgress?.call(event);
          return;
        }
        if (event.type == 'done') {
          result = SyncJobResult(
            skipped: event.skipped ?? false,
            sqlCount: event.sqlCount ?? 0,
            fingerprint: event.fingerprint ?? '',
            indexFingerprint: event.indexFingerprint ?? '',
            written: event.written ?? false,
          );
          return;
        }
        if (event.type == 'error') {
          error = StateError(event.error ?? 'sync worker error');
        }
      } catch (e) {
        JavpLog.w('sync', 'bad worker line: $trimmed ($e)');
      }
    }

    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine)
        .asFuture<void>();
    // Worker hwnd/sync breadcrumbs used to be mirrored line-by-line onto the
    // UI isolate (and into javp.log). That competed with hover frames during
    // « Enregistrement VOD » / body-hash. Keep errors only.
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final t = line.trim();
          if (t.isEmpty) return;
          final isErr = t.contains(' E/') ||
              t.contains(' W/') ||
              t.startsWith('E/') ||
              t.startsWith('W/') ||
              t.contains(' error') ||
              t.contains('Exception');
          if (!isErr) return;
          JavpLog.w('sync', 'worker stderr: $t');
        })
        .asFuture<void>();

    // Kill workers that stop emitting events (e.g. hung getCategories).
    final watchdog = Timer.periodic(const Duration(seconds: 30), (_) {
      final idle = DateTime.now().difference(lastEventAt);
      if (idle > const Duration(minutes: 3)) {
        JavpLog.w(
          'sync',
          'worker idle ${idle.inSeconds}s — killing op=${job.op.name}',
        );
        cancel();
      }
    });

    try {
      process.stdin.writeln(jsonEncode(job.toJson()));
      await process.stdin.flush();
      await process.stdin.close();

      final code = await process.exitCode.timeout(
        const Duration(hours: 2),
        onTimeout: () {
          cancel();
          throw TimeoutException('sync worker timed out');
        },
      );
      // Drain pipes after exit so the final `done` line is not lost.
      await Future.wait([outDone, errDone]);

      if (error != null) {
        throw error!;
      }
      final r = result;
      if (r == null) {
        throw StateError(
          code == 0
              ? 'sync worker finished without done event'
              : 'sync worker exited $code',
        );
      }
      JavpLog.i(
        'sync',
        'worker result skipped=${r.skipped} sqlCount=${r.sqlCount}',
      );
      return r;
    } catch (e) {
      cancel();
      rethrow;
    } finally {
      watchdog.cancel();
      _process = null;
    }
  }
}
