import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:javp/compat/javp_compute.dart';
import 'package:path_provider/path_provider.dart';

/// Disk + memory cache for remote artwork (posters, backdrops, channel logos).
///
/// Artwork is the heaviest network traffic in the app: a single catalog screen
/// can reference hundreds of posters, and without a disk cache every scroll
/// back re-downloads them. This store adds three things `Image.network` lacks:
///
/// * a persistent disk cache with LRU trimming, so art survives restarts;
/// * in-flight de-duplication, so N tiles pointing at one URL fetch once;
/// * a bounded download queue, so scrolling a grid cannot open 200 sockets and
///   starve playback / catalog requests of bandwidth.
class JavpImageCache {
  JavpImageCache._();

  static final JavpImageCache instance = JavpImageCache._();

  /// Simultaneous artwork downloads. Kept small so artwork never competes with
  /// playback or catalog sync for sockets.
  static const _maxConcurrent = 6;

  /// Cold-start / Accueil reveal: fewer concurrent fetches so shelf rematerialize
  /// does not decode a full viewport of posters in one hitch.
  static const _startupMaxConcurrent = 2;

  /// Reserved slots that only visible artwork may use, so speculative
  /// prefetching can never block what the user is actually looking at.
  static const _prefetchConcurrent = 2;

  /// When true, [load] uses [_startupMaxConcurrent] and drops prefetch.
  bool _startupThrottle = false;

  /// Cap artwork sockets during Accueil reveal / post-reveal settle.
  void setStartupThrottle(bool enabled) {
    if (_startupThrottle == enabled) return;
    _startupThrottle = enabled;
    _pump();
  }

  int get _effectiveMaxConcurrent =>
      _startupThrottle ? _startupMaxConcurrent : _maxConcurrent;

  static const _maxDiskBytes = 320 * 1024 * 1024;
  static const _maxEntryBytes = 12 * 1024 * 1024;
  static const _failureTtl = Duration(minutes: 5);
  static const _requestTimeout = Duration(seconds: 20);

  http.Client? _client;
  http.Client get _http => _client ??= http.Client();

  Directory? _dir;
  Future<Directory>? _dirFuture;

  final _inFlight = <String, Future<Uint8List?>>{};
  final _failures = <String, DateTime>{};
  final _queue = <_PendingFetch>[];
  var _active = 0;
  var _activePrefetch = 0;

  var _writesSinceTrim = 0;
  var _trimming = false;

  /// Swap in the app's shared client so artwork honors proxy + DNS fallback
  /// settings. Safe to call repeatedly (e.g. when proxy settings change).
  void attachHttpClient(http.Client client) => _client = client;

  Future<Directory> _ensureDir() {
    if (kIsWeb) {
      return Future.error(
        UnsupportedError('Image disk cache is unavailable on web'),
      );
    }
    final ready = _dir;
    if (ready != null) return Future.value(ready);
    return _dirFuture ??= () async {
      Directory base;
      try {
        base = await getApplicationSupportDirectory();
      } catch (_) {
        base = Directory.systemTemp;
      }
      final dir = Directory('${base.path}/image_cache');
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        // Fall through: reads/writes below fail softly to network-only mode.
      }
      _dir = dir;
      unawaited(_trimIfNeeded(force: true));
      return dir;
    }();
  }

  /// Resolves artwork bytes, preferring disk. Returns null when the URL is
  /// unusable so callers can fall back to their placeholder art.
  ///
  /// When [prefetch] is set the request yields to visible artwork and is
  /// dropped rather than queued if the pipeline is already saturated.
  Future<Uint8List?> load(String url, {bool prefetch = false}) {
    final key = url.trim();
    if (key.isEmpty) return Future.value(null);

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final failedAt = _failures[key];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < _failureTtl) {
        return Future.value(null);
      }
      _failures.remove(key);
    }

    final future = _load(key, prefetch: prefetch);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// Warms the disk cache without decoding. Used to pull artwork for content
  /// that is about to scroll into view.
  Future<void> prefetch(String url) async {
    // Accueil cold paint — don't speculate; visible tiles already queue.
    if (_startupThrottle) return;
    try {
      await load(url, prefetch: true);
    } catch (_) {
      // Prefetch is best-effort by definition.
    }
  }

  Future<Uint8List?> _load(String url, {required bool prefetch}) async {
    final file = await _fileFor(url);
    if (file != null) {
      try {
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            // Touch for LRU ordering; failure here only affects eviction order.
            unawaited(
              file.setLastModified(DateTime.now()).catchError((_) {}),
            );
            return bytes;
          }
        }
      } catch (_) {
        // Corrupt/unreadable entry: fall through and refetch.
      }
    }

    final bytes = await _enqueue(url, prefetch: prefetch);
    if (bytes == null) {
      _rememberFailure(url);
      return null;
    }
    if (file != null && bytes.length <= _maxEntryBytes) {
      unawaited(_write(file, bytes));
    }
    return bytes;
  }

  Future<Uint8List?> _enqueue(String url, {required bool prefetch}) {
    final pending = _PendingFetch(url, prefetch);
    _queue.add(pending);
    _pump();
    return pending.completer.future;
  }

  void _pump() {
    while (_active < _effectiveMaxConcurrent && _queue.isNotEmpty) {
      final index = _nextIndex();
      if (index < 0) return;
      final next = _queue.removeAt(index);
      _active++;
      if (next.prefetch) _activePrefetch++;
      unawaited(
        _download(next.url).then(
          (bytes) => next.completer.complete(bytes),
          onError: (_) => next.completer.complete(null),
        ).whenComplete(() {
          _active--;
          if (next.prefetch) _activePrefetch--;
          _pump();
        }),
      );
    }
  }

  /// Visible artwork always wins; prefetch only fills the reserved slack.
  int _nextIndex() {
    for (var i = 0; i < _queue.length; i++) {
      if (!_queue[i].prefetch) return i;
    }
    if (_activePrefetch >= _prefetchConcurrent) return -1;
    return _queue.isEmpty ? -1 : 0;
  }

  Future<Uint8List?> _download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    try {
      final response = await _http.get(uri).timeout(_requestTimeout);
      if (response.statusCode >= 400) return null;
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(File file, Uint8List bytes) async {
    try {
      await file.writeAsBytes(bytes, flush: false);
      _writesSinceTrim++;
      if (_writesSinceTrim >= 250) unawaited(_trimIfNeeded());
    } catch (_) {
      // Out of space / permission: keep serving from network.
    }
  }

  void _rememberFailure(String url) {
    // Bounded so a broken source cannot grow the map without limit.
    if (_failures.length > 600) _failures.clear();
    _failures[url] = DateTime.now();
  }

  Future<File?> _fileFor(String url) async {
    try {
      final dir = await _ensureDir();
      return File('${dir.path}/${cacheKeyFor(url)}');
    } catch (_) {
      return null;
    }
  }

  Future<void> _trimIfNeeded({bool force = false}) async {
    if (_trimming) return;
    if (!force && _writesSinceTrim < 250) return;
    _trimming = true;
    _writesSinceTrim = 0;
    try {
      final dir = _dir;
      if (dir == null) return;
      final path = dir.path;
      // Stat-ing thousands of files would stall the UI isolate.
      await javpCompute(() => _trimDirectory(path, _maxDiskBytes));
    } catch (_) {
      // Eviction is opportunistic.
    } finally {
      _trimming = false;
    }
  }

  /// Drop in-memory bookkeeping under OS memory pressure.
  ///
  /// Disk entries stay put (they aren't resident RAM). Queued prefetch is
  /// cancelled so speculative downloads stop competing for heap/sockets;
  /// visible loads already in flight are left alone.
  void dropTransientMemory() {
    _failures.clear();
    if (_queue.isEmpty) return;
    final kept = <_PendingFetch>[];
    for (final pending in _queue) {
      if (pending.prefetch) {
        if (!pending.completer.isCompleted) {
          pending.completer.complete(null);
        }
      } else {
        kept.add(pending);
      }
    }
    _queue
      ..clear()
      ..addAll(kept);
  }

  /// Clears the on-disk artwork cache (Settings → storage).
  Future<void> clear() async {
    _failures.clear();
    try {
      final dir = await _ensureDir();
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
    } catch (_) {
      // Nothing to clear.
    }
  }

  /// Total bytes currently held on disk, for Settings reporting.
  Future<int> diskUsage() async {
    try {
      final dir = await _ensureDir();
      final path = dir.path;
      return await javpCompute(() => _measureDirectory(path));
    } catch (_) {
      return 0;
    }
  }
}

class _PendingFetch {
  _PendingFetch(this.url, this.prefetch);

  final String url;
  final bool prefetch;
  final completer = Completer<Uint8List?>();
}

/// Stable filename for a URL. FNV-1a plus djb2 over the code units keeps the
/// odds of a collision negligible while staying dependency-free.
String cacheKeyFor(String url) {
  var fnv = 0x811c9dc5;
  var djb = 5381;
  for (var i = 0; i < url.length; i++) {
    final c = url.codeUnitAt(i);
    fnv = ((fnv ^ c) * 0x01000193) & 0xffffffff;
    djb = ((djb << 5) + djb + c) & 0xffffffff;
  }
  final a = fnv.toRadixString(16).padLeft(8, '0');
  final b = djb.toRadixString(16).padLeft(8, '0');
  return '$a$b${url.length.toRadixString(16)}';
}

Future<void> _trimDirectory(String path, int maxBytes) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  final entries = <_DiskEntry>[];
  var total = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    try {
      final stat = entity.statSync();
      total += stat.size;
      entries.add(_DiskEntry(entity, stat.size, stat.modified));
    } catch (_) {
      continue;
    }
  }
  if (total <= maxBytes) return;
  entries.sort((a, b) => a.modified.compareTo(b.modified));
  // Trim to 80% so eviction runs rarely instead of on every write.
  final target = (maxBytes * 0.8).round();
  for (final entry in entries) {
    if (total <= target) break;
    try {
      entry.file.deleteSync();
      total -= entry.size;
    } catch (_) {
      continue;
    }
  }
}

Future<int> _measureDirectory(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  var total = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    try {
      total += entity.statSync().size;
    } catch (_) {
      continue;
    }
  }
  return total;
}

class _DiskEntry {
  _DiskEntry(this.file, this.size, this.modified);

  final File file;
  final int size;
  final DateTime modified;
}
