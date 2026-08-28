import 'dart:async';

import 'package:javp/models/iptv_source.dart';
import 'package:javp/services/diagnostics/hwnd_sync_trace.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/iptv/xtream_client.dart';
import 'package:javp/services/storage/epg_program_db.dart';
import 'package:javp/services/storage/live_channel_db.dart';
import 'package:javp/services/storage/vod_catalog_db.dart';
import 'package:javp/sync_worker/epg_feed_ingest.dart';
import 'package:javp/sync_worker/sync_protocol.dart';

typedef SyncEventSink = void Function(SyncEvent event);

/// Owns catalog SQLite writers. Desktop runs this in a `--javp-sync` child
/// process; mobile / fallback runs it in-process via [SyncClient].
class SyncEngine {
  Future<SyncJobResult> run(
    SyncJob job, {
    SyncEventSink? onEvent,
  }) async {
    switch (job.op) {
      case SyncOp.xtreamVod:
        return _runXtreamVod(job, onEvent: onEvent);
      case SyncOp.xtreamLive:
        return _runXtreamLive(job, onEvent: onEvent);
      case SyncOp.xmltvEpg:
        return _runXmltvEpg(job, onEvent: onEvent);
    }
  }

  Future<SyncJobResult> _runXmltvEpg(
    SyncJob job, {
    SyncEventSink? onEvent,
  }) async {
    final urls = [
      for (final u in job.epgUrls)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    if (urls.isEmpty) {
      final result = const SyncJobResult(skipped: true, sqlCount: 0);
      onEvent?.call(SyncEvent.done(skipped: true, sqlCount: 0));
      return result;
    }

    final warm = job.warmEpgUrls.toSet();
    final trigger = job.trigger.isEmpty ? job.reason.name : job.trigger;
    onEvent?.call(
      SyncEvent.progress(phase: 'epg', status: 'fetching'),
    );

    final db = EpgProgramDb(profileId: job.profileId);
    final ingest = EpgFeedIngest();
    final hwnd = HwndSyncTrace.begin(
      'sync-engine-epg',
      sourceId: job.source.id,
    );
    try {
      await db.ensureOpen();
      var any = false;
      var ingested = 0;
      var reused = 0;
      var parsedFeeds = 0;
      final totalFeeds = urls.length;
      var feedIndex = 0;
      final heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        onEvent?.call(
          SyncEvent.progress(phase: 'epg', status: 'working'),
        );
      });
      try {
        hwnd.mark('engine-epg-start', 'feeds=$totalFeeds trigger=$trigger');
        for (final epgUrl in urls) {
          feedIndex++;
          if (warm.contains(epgUrl) && await db.hasFeed(epgUrl)) {
            reused++;
            any = true;
            onEvent?.call(
              SyncEvent.progress(
                phase: 'epg',
                status: 'warm',
                committed: feedIndex,
                total: totalFeeds,
              ),
            );
            continue;
          }
          onEvent?.call(
            SyncEvent.progress(
              phase: 'epg',
              status: 'fetching',
              committed: feedIndex,
              total: totalFeeds,
            ),
          );
          final loaded = await ingest.loadBytes(epgUrl);
          if (loaded == null) continue;
          final bytes = loaded.bytes;
          if (bytes.isEmpty) continue;

          onEvent?.call(
            SyncEvent.progress(
              phase: 'epg',
              status: 'parsing',
              committed: feedIndex,
              total: totalFeeds,
            ),
          );
          final count = await ingest.ingestFeed(
            db: db,
            url: epgUrl,
            bytes: bytes,
            contentEncoding: loaded.contentEncoding,
          );
          parsedFeeds++;
          if (count == 0) continue;
          ingested += count;
          any = true;
        }
      } finally {
        heartbeat.cancel();
      }

      if (!any) {
        hwnd.end('engine-epg-empty');
        JavpLog.w(
          'epg',
          'engine empty feeds=$totalFeeds trigger=$trigger',
        );
        final result = const SyncJobResult(skipped: false, sqlCount: 0);
        onEvent?.call(SyncEvent.done(skipped: false, sqlCount: 0));
        return result;
      }

      await db.keepFeeds(urls.toSet());
      final programCount = await db.countPrograms();
      hwnd.end(
        'engine-epg-complete programs=$programCount ingested=$ingested '
        'reused=$reused parsed=$parsedFeeds',
      );
      JavpLog.i(
        'epg',
        'engine done programs=$programCount ingested=$ingested '
            'reused=$reused parsed=$parsedFeeds trigger=$trigger',
      );
      final result = SyncJobResult(
        skipped: parsedFeeds == 0 && reused == urls.length,
        sqlCount: programCount,
        written: parsedFeeds > 0,
      );
      onEvent?.call(
        SyncEvent.done(
          skipped: result.skipped,
          sqlCount: programCount,
          written: result.written,
        ),
      );
      return result;
    } finally {
      ingest.close();
      try {
        await db.close();
      } catch (e) {
        JavpLog.w('sync', 'epg db close: $e');
      }
    }
  }

  Future<SyncJobResult> _runXtreamLive(
    SyncJob job, {
    SyncEventSink? onEvent,
  }) async {
    final source = job.source;
    if (source.type != IptvSourceType.xtream) {
      throw ArgumentError('xtreamLive requires an xtream source');
    }

    onEvent?.call(
      SyncEvent.progress(phase: 'live', status: 'fetching'),
    );

    final db = LiveChannelDb(profileId: job.profileId);
    final xtream = XtreamClient();
    final hwnd = HwndSyncTrace.begin(
      'sync-engine-live',
      sourceId: source.id,
    );
    try {
      var expectedTotal = 0;
      var lastProgressMs = 0;
      final session = await db.beginStreamingMerge(
        sourceId: source.id,
        onProgress: (committed, total) async {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (lastProgressMs != 0 && now - lastProgressMs < 750) return;
          lastProgressMs = now;
          onEvent?.call(
            SyncEvent.progress(
              phase: 'live',
              status: 'saving',
              committed: committed,
              total: total,
            ),
          );
        },
      );

      XtreamPackedIngest dumped;
      final heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        onEvent?.call(
          SyncEvent.progress(phase: 'live', status: 'working'),
        );
      });
      try {
        hwnd.mark('engine-live-stream-start');
        onEvent?.call(
          SyncEvent.progress(
            phase: 'live',
            status: job.liveCategories.isEmpty ? 'categories' : 'dump',
          ),
        );
        dumped = await xtream.streamLiveCatalog(
          source,
          liveCategories:
              job.liveCategories.isEmpty ? null : job.liveCategories,
          epgDisplayNames: job.epgDisplayNames,
          preferredLiveQualities: job.preferredLiveQualities,
          skipIf: (fp, n) async {
            expectedTotal = n;
            final skip = await session.skipIfFingerprint(fp);
            if (!skip) {
              onEvent?.call(
                SyncEvent.progress(
                  phase: 'live',
                  status: 'saving',
                  committed: 0,
                  total: n,
                ),
              );
            }
            return skip;
          },
          onSqlChunk: (chunk) =>
              session.addChannelChunk(chunk, total: expectedTotal),
          onListingChunk: session.addListingChunk,
          onVariantChunk: session.addVariantChunk,
        );
        hwnd.mark(
          'engine-live-stream-done',
          'skipped=${dumped.skipped} n=${dumped.sqlCount}',
        );
      } catch (e) {
        await session.abort();
        hwnd.mark('engine-live-stream-fail', 'err=$e');
        rethrow;
      } finally {
        heartbeat.cancel();
      }

      if (dumped.sqlCount == 0) {
        hwnd.end('engine-live-empty');
        final result = const SyncJobResult(skipped: false, sqlCount: 0);
        onEvent?.call(SyncEvent.done(skipped: false, sqlCount: 0));
        return result;
      }

      if (dumped.skipped) {
        await db.touchSourceLiveDumpAt(sourceId: source.id);
        hwnd.end('engine-live-skipped');
        final result = SyncJobResult(
          skipped: true,
          sqlCount: dumped.sqlCount,
          fingerprint: dumped.fingerprint,
          indexFingerprint: dumped.indexFingerprint,
        );
        onEvent?.call(
          SyncEvent.done(
            skipped: true,
            sqlCount: dumped.sqlCount,
            fingerprint: dumped.fingerprint,
            indexFingerprint: dumped.indexFingerprint,
          ),
        );
        return result;
      }

      session.indexFingerprint = dumped.indexFingerprint;
      final written = await session.finish(fingerprint: dumped.fingerprint);
      hwnd.end('engine-live-complete');
      final result = SyncJobResult(
        skipped: false,
        sqlCount: dumped.sqlCount,
        fingerprint: dumped.fingerprint,
        indexFingerprint: dumped.indexFingerprint,
        written: written,
      );
      onEvent?.call(
        SyncEvent.done(
          skipped: false,
          sqlCount: dumped.sqlCount,
          fingerprint: dumped.fingerprint,
          indexFingerprint: dumped.indexFingerprint,
          written: written,
        ),
      );
      return result;
    } finally {
      xtream.close();
      try {
        await db.close();
      } catch (e) {
        JavpLog.w('sync', 'live db close: $e');
      }
    }
  }

  Future<SyncJobResult> _runXtreamVod(
    SyncJob job, {
    SyncEventSink? onEvent,
  }) async {
    final source = job.source;
    if (source.type != IptvSourceType.xtream) {
      throw ArgumentError('xtreamVod requires an xtream source');
    }

    onEvent?.call(
      SyncEvent.progress(phase: 'vod', status: 'fetching'),
    );

    final db = VodCatalogDb(profileId: job.profileId);
    final xtream = XtreamClient();
    final hwnd = HwndSyncTrace.begin(
      'sync-engine-vod',
      sourceId: source.id,
    );
    try {
      await db.ensureOpen();
      var expectedTotal = 0;
      // UI rebuilds Sources on every progress event — unthrottled chunks
      // (~200ms) make « Enregistrement VOD » feel laggy even though HWND pumps.
      var lastProgressMs = 0;
      final session = await db.beginStreamingReplace(
        sourceId: source.id,
        onProgress: (progress) {
          if (progress.finalized &&
              progress.total == 0 &&
              progress.committed == 0) {
            return;
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          if (!progress.finalized &&
              lastProgressMs != 0 &&
              now - lastProgressMs < 750) {
            return;
          }
          lastProgressMs = now;
          onEvent?.call(
            SyncEvent.progress(
              phase: 'vod',
              status: progress.finalized ? 'saved' : 'saving',
              committed: progress.committed,
              total: progress.total,
              finalized: progress.finalized,
            ),
          );
        },
      );

      XtreamPackedIngest dumped;
      try {
        hwnd.mark('engine-vod-stream-start');
        dumped = await xtream.streamOnDemandCatalog(
          source,
          hwnd: hwnd,
          openSqlSink: () async {
            final sink = await session.ensureSqlWriterSink();
            if (sink != null) hwnd.mark('engine-vod-sql-writer-ready');
            return sink;
          },
          skipIf: (fp, n) async {
            expectedTotal = n;
            session.noteExpectedTotal(n);
            final skip = await session.skipIfFingerprint(fp);
            if (!skip) {
              onEvent?.call(
                SyncEvent.progress(
                  phase: 'vod',
                  status: 'saving',
                  committed: 0,
                  total: n,
                ),
              );
            }
            return skip;
          },
          skipIfBody: (bodyFp) async {
            final skip = await session.skipIfBodyFingerprint(bodyFp);
            if (skip) hwnd.mark('engine-vod-skip-body');
            return skip;
          },
          rememberBody: session.storeBodyFingerprint,
          onSqlChunk: (chunk) => session.addChunk(chunk, total: expectedTotal),
        );
        hwnd.mark(
          'engine-vod-stream-done',
          'skipped=${dumped.skipped} n=${dumped.sqlCount}',
        );
      } catch (e) {
        await session.abort();
        hwnd.mark('engine-vod-stream-fail', 'err=$e');
        rethrow;
      }

      if (dumped.skipped) {
        hwnd.end('engine-vod-skipped');
        final result = const SyncJobResult(skipped: true, sqlCount: 0);
        onEvent?.call(
          SyncEvent.done(
            skipped: true,
            sqlCount: 0,
            fingerprint: dumped.fingerprint,
          ),
        );
        return result;
      }

      if (dumped.sqlCount == 0) {
        // Empty dump: leave existing rows alone (caller decides keep-cache).
        await session.abort();
        hwnd.end('engine-vod-empty');
        final result = const SyncJobResult(skipped: false, sqlCount: 0);
        onEvent?.call(SyncEvent.done(skipped: false, sqlCount: 0));
        return result;
      }

      await session.finish(
        fingerprint: dumped.fingerprint,
        total: dumped.sqlCount,
      );
      hwnd.end('engine-vod-complete');
      final result = SyncJobResult(
        skipped: false,
        sqlCount: dumped.sqlCount,
        fingerprint: dumped.fingerprint,
      );
      onEvent?.call(
        SyncEvent.done(
          skipped: false,
          sqlCount: dumped.sqlCount,
          fingerprint: dumped.fingerprint,
        ),
      );
      return result;
    } finally {
      xtream.close();
      try {
        await db.close();
      } catch (e) {
        JavpLog.w('sync', 'vod db close: $e');
      }
    }
  }
}
