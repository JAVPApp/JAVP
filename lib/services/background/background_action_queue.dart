import 'dart:async';
import 'dart:collection';

import 'package:javp/services/diagnostics/javp_log.dart';

/// Coarse priority for background work that must not stampede the UI isolate.
enum BackgroundPriority {
  /// User-facing sync (SIMKL Watching pull, forced refresh).
  high,

  /// Follow-up linking / relink after catalogs settle.
  normal,

  /// Idle catalog deep-sync, VOD warm, etc.
  low,
}

class _QueuedAction {
  _QueuedAction({
    required this.id,
    required this.priority,
    required this.run,
    required this.completer,
  });

  final String id;
  final BackgroundPriority priority;
  final Future<void> Function() run;
  final Completer<void> completer;
}

/// Single-worker priority queue for LibraryProvider background jobs.
///
/// Higher priority always jumps ahead of lower. Enqueueing the same [id]
/// replaces a still-pending job (so force-refresh wins over a soft one).
///
/// When [setPaused] is true, the in-flight job finishes but no further pending
/// jobs start until resumed — so AFK/PiP freezes do not thaw into a stampede.
///
/// Desktop blur does **not** pause this queue (only [setAppForeground]); callers
/// should gate idle work on shell focus and [cancelPending] stale low jobs on
/// wake instead of relying on pause alone.
class BackgroundActionQueue {
  BackgroundActionQueue({
    this.lowPriorityResumeGrace = const Duration(seconds: 8),
    this.lowPriorityStagger = const Duration(milliseconds: 750),
  });

  /// Hold low jobs this long after [setPaused](false) so first paint wins.
  final Duration lowPriorityResumeGrace;

  /// Gap between consecutive low-priority jobs after a lifecycle resume.
  final Duration lowPriorityStagger;

  final ListQueue<_QueuedAction> _pending = ListQueue<_QueuedAction>();
  bool _draining = false;
  bool _paused = false;
  DateTime? _unpausedAt;
  bool _staggerNextLow = false;

  /// Accueil cold start: space low jobs further so Drive/shelf paint can settle.
  bool _coldStart = false;

  /// Extra gap between low jobs while [_coldStart] is true.
  static const _coldStartLowStagger = Duration(milliseconds: 1400);

  bool get isBusy => _draining || _pending.isNotEmpty;

  bool get isPaused => _paused;

  bool get coldStartMode => _coldStart;

  /// Enable until Accueil reveal settles — longer low-job gaps, no stampede.
  void setColdStartMode(bool enabled) {
    if (_coldStart == enabled) return;
    _coldStart = enabled;
    if (!enabled) {
      _staggerNextLow = true;
    }
    JavpLog.i(
      'bg',
      'queue coldStart=${enabled ? 'on' : 'off'} pending=$pendingCount',
    );
  }

  /// Pending jobs waiting to start (excludes the in-flight worker).
  int get pendingCount => _pending.length;

  /// True when high-priority work is waiting (or running).
  ///
  /// Idle jobs that are currently executing should exit and re-enqueue so the
  /// single worker can pick up the high job (waiting in a loop would deadlock).
  bool get shouldDeferIdleWork =>
      _pending.any((a) => a.priority == BackgroundPriority.high);

  /// Stop starting new jobs (in-flight work still completes).
  void setPaused(bool paused) {
    if (_paused == paused) return;
    _paused = paused;
    if (!paused) {
      _unpausedAt = DateTime.now();
      _staggerNextLow = false;
      JavpLog.i('bg', 'queue resume pending=$pendingCount');
      unawaited(_drain());
    } else {
      JavpLog.i('bg', 'queue pause pending=$pendingCount');
    }
  }

  /// Drop still-pending jobs. In-flight work is not cancelled.
  ///
  /// When [ids] is set, only those ids are removed. When [priority] is set,
  /// only that priority is removed. Completers resolve successfully so awaiters
  /// do not hang. Returns how many entries were dropped.
  int cancelPending({
    Set<String>? ids,
    BackgroundPriority? priority,
  }) {
    if (_pending.isEmpty) return 0;
    var dropped = 0;
    final kept = <_QueuedAction>[];
    for (final a in _pending) {
      final idMatch = ids == null || ids.contains(a.id);
      final priMatch = priority == null || a.priority == priority;
      if (idMatch && priMatch) {
        if (!a.completer.isCompleted) a.completer.complete();
        dropped++;
      } else {
        kept.add(a);
      }
    }
    if (dropped == 0) return 0;
    _pending
      ..clear()
      ..addAll(kept);
    JavpLog.i(
      'bg',
      'queue cancelPending dropped=$dropped pending=$pendingCount'
      '${ids != null ? ' ids=${ids.join(',')}' : ''}'
      '${priority != null ? ' priority=${priority.name}' : ''}',
    );
    return dropped;
  }

  /// Schedule [action]. Completes when this job finishes (or is replaced).
  Future<void> enqueue({
    required String id,
    required BackgroundPriority priority,
    required Future<void> Function() action,
  }) {
    // Drop an older pending job with the same id.
    _pending.removeWhere((a) {
      if (a.id != id) return false;
      if (!a.completer.isCompleted) {
        a.completer.complete();
      }
      return true;
    });

    final completer = Completer<void>();
    final entry = _QueuedAction(
      id: id,
      priority: priority,
      run: action,
      completer: completer,
    );

    final values = BackgroundPriority.values;
    final rest = _pending.toList();
    var insertAt = rest.length;
    for (var i = 0; i < rest.length; i++) {
      if (values.indexOf(priority) < values.indexOf(rest[i].priority)) {
        insertAt = i;
        break;
      }
    }
    _pending
      ..clear()
      ..addAll(rest.sublist(0, insertAt))
      ..add(entry)
      ..addAll(rest.sublist(insertAt));

    unawaited(_drain());
    return completer.future;
  }

  bool _inLowResumeGrace() {
    final at = _unpausedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < lowPriorityResumeGrace;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        if (_paused) break;

        final peek = _pending.first;
        if (peek.priority == BackgroundPriority.low && _inLowResumeGrace()) {
          final at = _unpausedAt!;
          final remaining =
              lowPriorityResumeGrace - DateTime.now().difference(at);
          final wait = remaining > Duration.zero
              ? (remaining < const Duration(milliseconds: 250)
                  ? remaining
                  : const Duration(milliseconds: 250))
              : const Duration(milliseconds: 50);
          await Future<void>.delayed(wait);
          continue;
        }

        if (peek.priority == BackgroundPriority.low &&
            _staggerNextLow) {
          final stagger = _coldStart
              ? _coldStartLowStagger
              : lowPriorityStagger;
          if (stagger > Duration.zero) {
            _staggerNextLow = false;
            await Future<void>.delayed(stagger);
            if (_paused) break;
            if (_pending.isEmpty) break;
            continue;
          }
        }

        final next = _pending.removeFirst();
        final watch = Stopwatch()..start();
        try {
          await next.run();
          if (!next.completer.isCompleted) next.completer.complete();
        } catch (e, st) {
          if (!next.completer.isCompleted) {
            next.completer.completeError(e, st);
          }
        }
        final ms = watch.elapsedMilliseconds;
        final depth = _pending.length;
        final summary =
            '${next.id} ran in ${ms}ms priority=${next.priority.name} '
            'depth=$depth';
        if (ms >= 500) {
          JavpLog.w('bg', summary);
        } else {
          JavpLog.i('bg', summary);
        }
        if (next.priority == BackgroundPriority.low &&
            _pending.isNotEmpty &&
            (_coldStart || _unpausedAt != null)) {
          _staggerNextLow = true;
        }
        // Cold start: also breathe after high/normal so simkl-relink trains
        // don't land back-to-back with Accueil rematerialize.
        if (_coldStart && _pending.isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 220));
        } else {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      _draining = false;
      if (!_paused && _pending.isNotEmpty) {
        unawaited(_drain());
      }
    }
  }
}
