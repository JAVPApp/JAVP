import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:javp/compat/ui_isolate.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';

/// [Isolate.run] that falls back to the current isolate on web.
///
/// Flutter web + `dart:io` in the same program makes worker isolates throw
/// `Unsupported operation: _Namespace`. Prefer this for JSON encode/decode
/// and other **small** pure computations shared across platforms.
///
/// The result is copied onto the calling isolate when the worker finishes.
/// Never return a huge `List`/`Map` (10k+ catalog / live / EPG rows) from
/// this helper — that copy **is** UI work and freezes Windows. Stream
/// [kIsolateListChunk]-sized messages instead (`ingestM3uBytesInIsolate`,
/// `ingestEpgPackedInIsolate`, `parseM3uBytesInIsolate` on web,
/// `parseCatalogBodyInIsolate`, `buildLiveIngestPlanInIsolate`,
/// `VodVariantIndex.buildInIsolate`). Native catalogs write SQLite.
Future<R> javpCompute<R>(
  FutureOr<R> Function() computation, {
  String? debugLabel,
}) {
  if (kIsWeb) return Future<R>.sync(computation);
  return UiStallWatchdog.span(debugLabel ?? 'compute', () async {
    final result = await Isolate.run(computation);
    // Copy-back is sync UI work; pump so Windows can take the click that
    // arrived while the worker was finishing.
    await yieldAfterIsolateChunk();
    return result;
  });
}
