import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/sync_worker/sync_scheduler.dart';

/// Detects UI-isolate stalls that make Windows drop focus / clicks.
///
/// Flutter frame logs only fire *after* a frame paints, and untagged CPU
/// work shows up as `tags=-`. A periodic timer on the UI isolate is delayed
/// by the same stall — when it finally runs, [phase] is whatever [enter]
/// was still holding.
///
/// Journal tiers (always-on, rate-limited in production):
/// * gap ≥ [warnJournalMs] → `W/ui-stall`
/// * gap ≥ [freezeMs] → `E/ui-freeze` (flushed to disk immediately)
///
/// Use [UiDebug.mark] / [mark] around critical paths so a freeze line can
/// name the last breadcrumbs even when [phase] is `-`.
class UiStallWatchdog {
  UiStallWatchdog._();

  static const Duration beat = Duration(milliseconds: 100);

  /// Gap above interval+this counts as a stall for blame / listeners.
  static const int thresholdMs = 200;

  /// Production journal floor for `W/ui-stall` (verbose hitch keeps [thresholdMs]).
  static const int warnJournalMsProduction = 500;

  /// Hard freeze → `E/ui-freeze` (always journaled, not rate-limited).
  static const int freezeMs = 2000;

  /// Min gap between `W/ui-stall` journal lines (blame / listeners still run).
  static const int warnMinIntervalMs = 2000;

  static const int _markCapacity = 16;

  static final List<String> _stack = [];
  static final Queue<String> _marks = Queue<String>();
  static Timer? _timer;
  static int _lastBeatMs = 0;
  static int _lastYieldMs = 0;
  static int _lastWarnJournalMs = 0;
  static bool _started = false;
  static final List<void Function(int gapMs, String phase)> _stallListeners =
      [];

  /// Optional LibraryProvider crumbs (`useVodDb=… syncClients=…`).
  ///
  /// Injected rather than imported so the watchdog stays free of providers.
  static String Function()? desktopHintsProvider;

  /// Per-phase stall ledger, drained into the hitch summary.
  ///
  /// A single stall line only names the phase that happened to be on the stack
  /// when the beat came back. Answering "what actually ate this cold start" of
  /// dozens of hitches needs the totals, so keep them until something reports.
  static final Map<String, _PhaseBlame> _blame = {};

  /// Cap so a build with logging off (nothing drains) cannot grow forever.
  static const int _maxBlamePhases = 24;

  /// Nested scopes, newest last. `-` when nothing is marked.
  static String get phase => _stack.isEmpty ? '-' : _stack.join('>');

  /// Recent [mark] breadcrumbs, oldest→newest. `-` when empty.
  static String get recentMarks =>
      _marks.isEmpty ? '-' : _marks.join('>');

  /// Milliseconds since the last cooperative [noteYield].
  static int get lastYieldAgeMs {
    if (_lastYieldMs <= 0) return 0;
    return DateTime.now().millisecondsSinceEpoch - _lastYieldMs;
  }

  static bool get isStarted => _started;

  /// Journal floor for warn lines (verbose hitch = detection threshold).
  static int get warnJournalMs => JavpLog.instance.verboseHitch
      ? thresholdMs
      : warnJournalMsProduction;

  static void start() {
    if (kIsWeb || _started) return;
    _started = true;
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastBeatMs = now;
    _lastYieldMs = now;
    _lastWarnJournalMs = 0;
    // Injected rather than imported: JavpLog is the summary writer, and it
    // must not depend on the watchdog it is being fed by.
    JavpLog.stallBlameProvider = takeBlameSummary;
    _timer = Timer.periodic(beat, _onBeat);
    mark('watchdog:start');
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _stack.clear();
    _marks.clear();
    _blame.clear();
    _lastBeatMs = 0;
    _lastYieldMs = 0;
    _lastWarnJournalMs = 0;
    JavpLog.stallBlameProvider = null;
  }

  /// Compact desktop-oriented suffix for stall / freeze lines.
  ///
  /// Always includes `platform=` (Windows freezes are the common case). On
  /// desktop OS also includes SyncScheduler busy state; [desktopHintsProvider]
  /// may add `useVodDb=` / worker counts.
  static String desktopContextSuffix() {
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    final buf = StringBuffer('platform=$platform');
    if (!DesktopUi.isDesktopOs) return buf.toString();
    final sync = SyncScheduler.instance;
    if (sync.isBusy) {
      buf.write(
        ' sync=busy syncDepth=${sync.depth} '
        'syncJob=${sync.activeLabel ?? '-'} '
        'syncCatalogWriter=${sync.isCatalogWriterBusy}',
      );
    } else {
      buf.write(' sync=idle');
    }
    final hints = desktopHintsProvider?.call();
    if (hints != null && hints.isNotEmpty) {
      buf.write(' $hints');
    }
    return buf.toString();
  }

  /// Lightweight breadcrumb (ring of [_markCapacity]). Does not log by itself.
  ///
  /// Prefer `UiDebug.mark('loadMediaDetails:start')` around critical paths so
  /// the next `E/ui-freeze` line can show what last ran.
  static void mark(String name) {
    if (name.isEmpty) return;
    _marks.addLast(name);
    while (_marks.length > _markCapacity) {
      _marks.removeFirst();
    }
  }

  /// Attribute [ms] of held UI isolate to [phase].
  static void _noteBlame(String phase, int ms) {
    final entry = _blame[phase];
    if (entry == null) {
      if (_blame.length >= _maxBlamePhases) {
        // Drop the cheapest phase rather than the newest signal.
        var lightestKey = _blame.keys.first;
        var lightestMs = _blame[lightestKey]!.totalMs;
        for (final e in _blame.entries) {
          if (e.value.totalMs < lightestMs) {
            lightestKey = e.key;
            lightestMs = e.value.totalMs;
          }
        }
        _blame.remove(lightestKey);
      }
      _blame[phase] = _PhaseBlame(count: 1, totalMs: ms, worstMs: ms);
      return;
    }
    entry.count++;
    entry.totalMs += ms;
    if (ms > entry.worstMs) entry.worstMs = ms;
  }

  /// Phases that held the UI isolate since the last call, worst total first.
  ///
  /// Format: `phase=totalMs/nx/worstMs`. Drains the ledger.
  static String takeBlameSummary({int max = 4}) {
    if (_blame.isEmpty) return '';
    final entries = _blame.entries.toList()
      ..sort((a, b) => b.value.totalMs.compareTo(a.value.totalMs));
    _blame.clear();
    final parts = <String>[];
    for (final e in entries.take(max)) {
      parts.add(
        '${e.key}=${e.value.totalMs}ms/${e.value.count}x/'
        '${e.value.worstMs}ms',
      );
    }
    if (entries.length > max) parts.add('+${entries.length - max}');
    return parts.join(',');
  }

  /// Called after a stall is logged (the UI isolate is runnable again).
  ///
  /// Cannot interrupt the tight loop that caused the gap — Dart is
  /// single-threaded. Listeners should drop queued idle work so the hitch
  /// does not immediately pile on another.
  static void addStallListener(
    void Function(int gapMs, String phase) listener,
  ) {
    if (_stallListeners.contains(listener)) return;
    _stallListeners.add(listener);
  }

  static void removeStallListener(
    void Function(int gapMs, String phase) listener,
  ) {
    _stallListeners.remove(listener);
  }

  static void enter(String name) {
    if (name.isEmpty) return;
    _stack.add(name);
    if (_stack.length > 16) _stack.removeAt(0);
    mark(name);
  }

  static void leave([String? name]) {
    if (_stack.isEmpty) return;
    if (name == null) {
      _stack.removeLast();
      return;
    }
    // Nested concurrent spans (live dump + VOD prefetch) must not pop the
    // wrong frame — that left stall=xtream-live-stream after live had exited.
    for (var i = _stack.length - 1; i >= 0; i--) {
      if (_stack[i] == name) {
        _stack.removeAt(i);
        return;
      }
    }
  }

  static Future<T> span<T>(String name, Future<T> Function() body) async {
    enter(name);
    developer.Timeline.startSync('ui:$name');
    try {
      return await body();
    } finally {
      developer.Timeline.finishSync();
      leave(name);
    }
  }

  /// Call from [yieldUiIfDue] after a real yield so "last yield" is visible
  /// on the next stall line.
  /// [label] names the yielding loop (see `yieldUiIfDue`). It is more precise
  /// than [phase], which only knows about enclosing spans.
  static void noteYield({int? sliceMs, String? label}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastYieldMs = now;
    if (sliceMs == null || sliceMs < thresholdMs) return;
    final where = label == null
        ? phase
        : (_stack.isEmpty ? label : '$phase>$label');
    // A slice measures wall time, so a loop that awaits inside its window
    // (streaming a catalog over HTTP) looks identical to one that pins the
    // isolate. Only one of them freezes the window.
    //
    // Do not wait for a beat to come back *late*: [noteYield] runs before the
    // await that would let [_onBeat] fire, so a stale late-beat stamp reads
    // every CPU overrun as I/O. On-time beats do keep [_lastBeatMs] moving
    // while the loop is parked on I/O, so measure how long it has been since
    // any beat — time the loop provably held the isolate. Time rather than a
    // yes/no also catches a block at the tail of a mostly-awaited slice,
    // where a beat did land inside the window.
    final heldMs = _started
        ? uiStallHeldMs(
            sliceMs: sliceMs,
            nowMs: now,
            lastBeatMs: _lastBeatMs,
            beatMs: beat.inMilliseconds,
          )
        // No beat to compare against (not started / web): keep the signal.
        : sliceMs;
    if (!uiStallSliceWasBlocking(heldMs: heldMs, sliceMs: sliceMs)) {
      JavpLog.i(
        'ui-stall',
        'slice-io ${sliceMs}ms held=${heldMs}ms phase=$where '
            'route=${JavpLog.currentRoute ?? '-'} '
            '(mostly awaited I/O — event loop stayed live)',
      );
      return;
    }
    _noteBlame(where, heldMs);
    _journalHeld(
      heldMs: heldMs,
      sliceMs: sliceMs,
      where: where,
      nowMs: now,
    );
  }

  static void _onBeat(Timer _) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final gap = now - _lastBeatMs;
    _lastBeatMs = now;
    if (gap < beat.inMilliseconds + thresholdMs) return;
    final yieldAgo = now - _lastYieldMs;
    _noteBlame(phase, gap);
    _journalGap(gapMs: gap, yieldAgoMs: yieldAgo, nowMs: now);
    final listeners = List<void Function(int gapMs, String phase)>.from(
      _stallListeners,
    );
    for (final listener in listeners) {
      listener(gap, phase);
    }
  }

  static void _journalGap({
    required int gapMs,
    required int yieldAgoMs,
    required int nowMs,
  }) {
    if (!_shouldJournal(gapMs: gapMs, nowMs: nowMs)) return;
    final freeze = gapMs >= freezeMs;
    final desktop = desktopContextSuffix();
    final msg =
        'gap=${gapMs}ms phase=$phase lastYield=${yieldAgoMs}ms '
        '(ms since last pump/yield — NOT sync duration; '
        'focus/click death ≠ Not Responding) '
        'route=${JavpLog.currentRoute ?? '-'} '
        'marks=$recentMarks $desktop'
        '${freeze ? ' log=${JavpLog.recentTagsBrief()}' : ''}';
    if (freeze) {
      JavpLog.e('ui-freeze', msg);
      JavpLog.noteSlowTag('ui-freeze');
      unawaited(JavpLog.instance.flush());
    } else {
      _lastWarnJournalMs = nowMs;
      JavpLog.w('ui-stall', msg);
      JavpLog.noteSlowTag('ui-stall');
    }
  }

  static void _journalHeld({
    required int heldMs,
    required int sliceMs,
    required String where,
    required int nowMs,
  }) {
    if (!_shouldJournal(gapMs: heldMs, nowMs: nowMs)) return;
    final freeze = heldMs >= freezeMs;
    final desktop = desktopContextSuffix();
    final msg =
        'slice ${sliceMs}ms held=${heldMs}ms phase=$where '
        'route=${JavpLog.currentRoute ?? '-'} '
        'marks=$recentMarks $desktop '
        '(loop held the isolate this long before yielding)'
        '${freeze ? ' log=${JavpLog.recentTagsBrief()}' : ''}';
    if (freeze) {
      JavpLog.e('ui-freeze', msg);
      JavpLog.noteSlowTag('ui-freeze');
      unawaited(JavpLog.instance.flush());
    } else {
      _lastWarnJournalMs = nowMs;
      JavpLog.w('ui-stall', msg);
      JavpLog.noteSlowTag('ui-stall');
    }
  }

  /// Blame always runs; journal is tiered + rate-limited for Release noise.
  static bool _shouldJournal({required int gapMs, required int nowMs}) {
    if (gapMs >= freezeMs) return true;
    if (gapMs < warnJournalMs) return false;
    if (_lastWarnJournalMs > 0 &&
        nowMs - _lastWarnJournalMs < warnMinIntervalMs) {
      return false;
    }
    return true;
  }

  @visibleForTesting
  static void debugNoteBlame(String phase, int ms) => _noteBlame(phase, ms);

  @visibleForTesting
  static void debugNotifyStallListeners({
    required int gapMs,
    String phase = 'test',
  }) {
    final listeners = List<void Function(int gapMs, String phase)>.from(
      _stallListeners,
    );
    for (final listener in listeners) {
      listener(gapMs, phase);
    }
  }

  @visibleForTesting
  static void debugResetWarnJournalClock() => _lastWarnJournalMs = 0;
}

/// Convenience facade for freeze breadcrumbs — same as [UiStallWatchdog.mark].
///
/// ```dart
/// UiDebug.mark('loadMediaDetails:start');
/// try { ... } finally { UiDebug.mark('loadMediaDetails:end'); }
/// ```
class UiDebug {
  UiDebug._();

  static void mark(String name) => UiStallWatchdog.mark(name);

  static void enter(String name) => UiStallWatchdog.enter(name);

  static void leave([String? name]) => UiStallWatchdog.leave(name);

  static Future<T> span<T>(String name, Future<T> Function() body) =>
      UiStallWatchdog.span(name, body);

  static String get phase => UiStallWatchdog.phase;

  static String get recentMarks => UiStallWatchdog.recentMarks;
}

class _PhaseBlame {
  _PhaseBlame({
    required this.count,
    required this.totalMs,
    required this.worstMs,
  });

  int count;
  int totalMs;
  int worstMs;
}

/// Lower bound on how long the isolate was held before [nowMs].
///
/// The beat can only run while the event loop is free, so time since the last
/// beat (less the interval it was due in) is time the isolate was busy. A loop
/// parked on I/O keeps the beat running and measures ~0; a loop pinning the
/// isolate measures its whole run. Capped at [sliceMs] since work before this
/// slice is not this slice's to claim.
int uiStallHeldMs({
  required int sliceMs,
  required int nowMs,
  required int lastBeatMs,
  required int beatMs,
}) {
  // No beat observed yet — nothing to compare against, so assume the worst
  // rather than quietly writing a real stall off as I/O.
  if (lastBeatMs <= 0) return sliceMs;
  final held = nowMs - lastBeatMs - beatMs;
  if (held <= 0) return 0;
  return held > sliceMs ? sliceMs : held;
}

/// Whether a slice held the isolate long enough to be a stall rather than a
/// wait. Half the window catches short blocks that sit under [thresholdMs].
bool uiStallSliceWasBlocking({
  required int heldMs,
  required int sliceMs,
  int thresholdMs = UiStallWatchdog.thresholdMs,
}) {
  if (heldMs >= thresholdMs) return true;
  return heldMs * 2 >= sliceMs;
}

/// Pure helper for tests — a beat is late when the gap exceeds interval+threshold.
int? uiStallGapMs({
  required int nowMs,
  required int lastBeatMs,
  required int intervalMs,
  required int thresholdMs,
}) {
  final gap = nowMs - lastBeatMs;
  if (gap < intervalMs + thresholdMs) return null;
  return gap;
}

/// Whether a late beat should write a journal line (tiers + rate limit).
bool uiStallShouldJournal({
  required int gapMs,
  required int warnJournalMs,
  required int freezeMs,
  required int nowMs,
  required int lastWarnJournalMs,
  required int warnMinIntervalMs,
}) {
  if (gapMs >= freezeMs) return true;
  if (gapMs < warnJournalMs) return false;
  if (lastWarnJournalMs > 0 &&
      nowMs - lastWarnJournalMs < warnMinIntervalMs) {
    return false;
  }
  return true;
}
