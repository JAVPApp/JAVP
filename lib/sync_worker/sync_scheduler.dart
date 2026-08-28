import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:javp/services/diagnostics/javp_log.dart';

/// Serializes catalog SyncEngine jobs so only one writer process runs at a time.
///
/// Parallel live + VOD workers (and UI reads mid-write) produced SQLite
/// `database is locked` waits of ~10s. One job at a time keeps the HWND free
/// while writers no longer fight each other for the profile DB files.
class SyncScheduler {
  SyncScheduler._();

  static final SyncScheduler instance = SyncScheduler._();

  Future<void> _tail = Future<void>.value();
  var _depth = 0;
  String? _activeLabel;

  /// True while at least one SyncEngine job is queued or running.
  bool get isBusy => _depth > 0;

  /// Queued + running job count (for stall breadcrumbs).
  int get depth => _depth;

  /// Active job label (`xtreamVod:…`), or null when idle.
  String? get activeLabel => _activeLabel;

  /// True when a live/VOD writer owns (or is queued for) `vod_catalog` /
  /// `live_channels`. XMLTV EPG uses a different DB and must not block
  /// Catalog group-index.
  bool get isCatalogWriterBusy {
    if (_depth <= 0) return false;
    final label = _activeLabel ?? '';
    return label.startsWith('xtreamVod:') || label.startsWith('xtreamLive:');
  }

  /// Test-only: clear queue state between cases.
  @visibleForTesting
  void debugReset() {
    _tail = Future<void>.value();
    _depth = 0;
    _activeLabel = null;
  }

  /// Run [job] after any previously enqueued SyncEngine work finishes.
  Future<T> enqueue<T>(
    Future<T> Function() job, {
    String label = 'job',
  }) {
    final gate = Completer<T>();
    _depth++;
    final queued = _depth;
    JavpLog.i('sync', 'scheduler enqueue $label depth=$queued');
    _tail = _tail.then((_) async {
      _activeLabel = label;
      try {
        JavpLog.i('sync', 'scheduler start $label');
        final value = await job();
        if (!gate.isCompleted) gate.complete(value);
      } catch (e, st) {
        if (!gate.isCompleted) gate.completeError(e, st);
      } finally {
        _depth = (_depth - 1).clamp(0, 1 << 20);
        _activeLabel = null;
        JavpLog.i('sync', 'scheduler done $label depth=$_depth');
      }
    }).catchError((Object e, StackTrace st) {
      // Keep the chain alive so a failed job does not block later work.
      if (!gate.isCompleted) gate.completeError(e, st);
    });
    return gate.future;
  }
}
