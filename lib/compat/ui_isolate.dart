import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';

/// Max time a UI-isolate loop may run before yielding.
///
/// Comfortably inside a 60 Hz frame so Windows can pump focus / clicks.
const kUiSliceBudgetMs = 8;

/// Phase-boundary delay. [Duration.zero] is not enough on Windows — the
/// embedder needs a real timer turn for WM_ACTIVATE / pointer events.
const kUiPumpMs = 16;

/// Rows per isolate message. A single [Isolate.run] of 10k+ maps copies
/// the whole payload on the UI isolate and freezes Windows.
const kIsolateListChunk = 400;

/// Yield when this slice has used its frame budget (check every iteration).
///
/// Pass [label] naming the loop. When a slice overruns, that is the only clue
/// to which loop held the UI isolate — a release build cannot symbolize a
/// stack trace, so an unlabeled overrun only ever logs `phase=-`.
Future<void> yieldUiIfDue(
  Stopwatch slice, {
  int budgetMs = kUiSliceBudgetMs,
  String? label,
}) async {
  if (slice.elapsedMilliseconds < budgetMs) return;
  UiStallWatchdog.noteYield(sliceMs: slice.elapsedMilliseconds, label: label);
  await yieldAfterIsolateChunk();
  slice.reset();
}

/// Yield when [i] hits [checkMask] **and** the slice budget is spent.
///
/// Skip the clock on most rows — reading it every item can cost more than
/// the work. Use [yieldUiIfDue] when each step is expensive.
Future<void> yieldUiSlice(
  Stopwatch slice, {
  required int i,
  int checkMask = 63,
  int budgetMs = kUiSliceBudgetMs,
  String? label,
}) async {
  if ((i & checkMask) != checkMask) return;
  await yieldUiIfDue(slice, budgetMs: budgetMs, label: label);
}

/// Let the Windows embedder pump focus / clicks between heavy phases.
///
/// Always stamps [UiStallWatchdog.noteYield] so `yieldAge=` in stall / hwnd
/// traces means "ms since the last cooperative pump", not "ms since some
/// unrelated loop last yielded before an idle stretch".
Future<void> pumpUi({int milliseconds = kUiPumpMs, String? label}) async {
  UiStallWatchdog.noteYield(label: label ?? 'pumpUi');
  if (kIsWeb) {
    await Future<void>.delayed(Duration.zero);
    return;
  }
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  // Windows: Dart timers alone can keep the isolate "reactive" (status
  // text updates) while WM_LBUTTONDOWN / title-bar messages sit unpumped.
  // Ending a frame forces the embedder to drain the Win32 queue.
  //
  // Obscured / paused / no-vsync HWNDs: [endOfFrame] can hang forever. That
  // stalled post-hydrate group-index with ~0 CPU after cold start. Cap wait
  // like [persistAfterFrame] — the timer delay above already yielded.
  if (defaultTargetPlatform == TargetPlatform.windows) {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      scheduler.scheduleFrame();
    }
    try {
      await scheduler.endOfFrame.timeout(const Duration(milliseconds: 64));
    } on TimeoutException {
      // No frame arrived — continue; caller still got a Dart event-loop yield.
    }
  }
}

/// Bytes per isolate / download slice. Larger copies freeze Windows.
const kIsolateByteChunk = 256 * 1024;

/// Collect a byte stream without monopolizing the UI isolate.
///
/// `http.get` / `bodyBytes` buffers the whole payload on this isolate and
/// hitches Windows at the start of sync. Yield between chunks, then concat
/// with the same budget so a multi-MB guide/catalog does not freeze.
Future<Uint8List> collectBytesYielding(
  Stream<List<int>> stream, {
  required int maxBytes,
  void Function(int bytesReceived)? onProgress,
  String tooLargeMessage = 'Download is too large',
}) async {
  final parts = <Uint8List>[];
  var total = 0;
  var lastProgress = 0;
  var lastPumpBytes = 0;
  final slice = Stopwatch()..start();
  final sincePump = Stopwatch()..start();
  await for (final chunk in stream) {
    total += chunk.length;
    if (total > maxBytes) {
      throw StateError(tooLargeMessage);
    }
    parts.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    await yieldUiIfDue(slice, label: 'download');
    // Guide downloads under 256KB used to finish in one stream event with
    // zero pumpUi — HWND stayed dead for the whole « Mise à jour du guide »
    // wait. Also pump on a wall-clock budget so slow connects still breathe.
    final crossedChunk = total - lastPumpBytes >= kIsolateByteChunk;
    final dueByTime = sincePump.elapsedMilliseconds >= 32;
    if (crossedChunk || dueByTime || chunk.isEmpty) {
      lastPumpBytes = total;
      sincePump.reset();
      if (onProgress != null &&
          (total - lastProgress >= kIsolateByteChunk || chunk.isEmpty)) {
        lastProgress = total;
        onProgress(total);
      }
      await pumpUi(label: 'download');
    }
  }
  if (parts.isEmpty) return Uint8List(0);
  if (parts.length == 1) return parts.first;
  final out = Uint8List(total);
  var offset = 0;
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
    await yieldUiSlice(slice, i: i, checkMask: 7);
  }
  onProgress?.call(total);
  return out;
}

/// Catch errors around async work and always yield a frame.
///
/// This is **not** a way to make CPU non-blocking. A `try/catch` never
/// preempts a tight loop on the UI isolate — Windows stays frozen until
/// the loop `await`s. Use isolates + [yieldUiIfDue] for that.
Future<T?> runUnblocking<T>(
  String name,
  Future<T> Function() body, {
  T? fallback,
}) async {
  await pumpUi();
  try {
    return await UiStallWatchdog.span(name, body);
  } catch (e) {
    debugPrint('W/ui-stall: unblocking $name failed: $e');
    return fallback;
  } finally {
    await pumpUi();
  }
}

/// Yield after one isolate chunk has been copied onto this isolate.
///
/// [Duration.zero] stays in Dart's timer queue on Windows and does **not**
/// let the embedder pump WM_ACTIVATE / clicks. A 1ms timer does (Windows
/// quantizes it to ~15ms). Use [pumpUi] at phase boundaries.
Future<void> yieldAfterIsolateChunk() {
  if (kIsWeb) return Future<void>.delayed(Duration.zero);
  return Future<void>.delayed(const Duration(milliseconds: 1));
}

/// Map a large list on the UI isolate without monopolizing a frame.
Future<List<T>> mapYielding<S, T>(
  List<S> source,
  T Function(S) map, {
  int checkMask = 63,
  String? label,
}) async {
  if (source.isEmpty) return const [];
  final out = <T>[];
  final slice = Stopwatch()..start();
  for (var i = 0; i < source.length; i++) {
    out.add(map(source[i]));
    await yieldUiSlice(slice, i: i, checkMask: checkMask, label: label);
  }
  return out;
}

/// Filter a large list on the UI isolate without monopolizing a frame.
Future<List<T>> filterYielding<T>(
  List<T> source,
  bool Function(T) test, {
  int checkMask = 63,
  String? label,
}) async {
  if (source.isEmpty) return const [];
  final out = <T>[];
  final slice = Stopwatch()..start();
  for (var i = 0; i < source.length; i++) {
    if (test(source[i])) out.add(source[i]);
    await yieldUiSlice(slice, i: i, checkMask: checkMask, label: label);
  }
  return out;
}
