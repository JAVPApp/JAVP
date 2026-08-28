import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:javp/config/distribution.dart';
import 'package:javp/config/javp_host.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/services/diagnostics/log_redactor.dart';
import 'package:javp/services/ui/persist_after_frame.dart';
import 'package:javp/services/update/update_channel.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LogLevel { debug, info, warn, error }

/// Rotating on-device log file, so a bug that only reproduces on a user's TV
/// can still be diagnosed after the fact.
///
/// The console this app already prints to is unreachable on a sideloaded TV
/// build, which is exactly where the awkward bugs live. This persists the same
/// stream to `{applicationSupport}/logs/javp.log` with a hard size ceiling and
/// a 24-hour retention window, and [LogRedactor] runs before a line is buffered
/// so no credential is ever written down — see that class for why the write
/// path is the only safe place for it.
///
/// Cost matters, because [capture] is wired into every `debugPrint` in the app:
///
/// * lines batch behind a 2 second timer and only reach disk in one append, so
///   ordinary logging never touches the filesystem on the UI isolate;
/// * rotation stats and renames run in [Isolate.run];
/// * the active file's size is tracked in memory rather than re-stat'ed.
///
/// The directory is device-wide rather than profile-scoped: logging starts
/// before the active profile is resolved, which is the window most worth
/// capturing.
class JavpLog {
  JavpLog._();

  static final JavpLog instance = JavpLog._();

  /// Device-global on purpose — read before any provider exists, and a user
  /// disabling logging means it off everywhere, not per profile.
  static const String prefsKey = 'diagnostics_logging_enabled';

  /// Verbose hitch / light profiler toggle (Diagnostics). Device-global.
  static const String verboseHitchPrefsKey = 'diagnostics_verbose_hitch';

  static const String logFileName = 'javp.log';
  static const String dirName = 'logs';

  static const int _maxFileBytes = 1024 * 1024;

  /// Drop on-disk lines older than this. Size rotation still caps the folder.
  static const Duration keepDuration = Duration(hours: 24);

  /// Re-scan files at most this often during a long-lived session.
  static const Duration _pruneInterval = Duration(hours: 1);

  /// Active file plus four archives, so the folder cannot exceed ~5 MB.
  static const int _maxFiles = 5;

  static const int _ringCapacity = 500;
  static const int _flushThreshold = 200;
  static const Duration _flushInterval = Duration(seconds: 2);

  /// Enough tail for a bug report without pushing megabytes at the clipboard.
  static const int _defaultExportBytes = 512 * 1024;

  static const int _productionJankThresholdMs = 40;
  static const int _verboseJankThresholdMs = 16;
  static const int _productionJankMinIntervalMs = 1000;
  static const int _verboseJankMinIntervalMs = 400;
  static const int _productionSlowThresholdMs = 50;
  static const int _verboseSlowThresholdMs = 16;
  static const Duration _hitchSummaryInterval = Duration(seconds: 5);
  static const int _maxRecentSlowTags = 8;

  final LogRedactor _redactor = LogRedactor.instance;

  /// Feeds the in-app viewer, so it never reads files back.
  final Queue<String> _ring = Queue<String>();
  final List<String> _pending = <String>[];

  /// Bumped once per flush rather than per line, so a chatty phase cannot
  /// rebuild the viewer hundreds of times.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Directory? _dir;
  Future<Directory>? _dirFuture;
  Timer? _timer;
  Timer? _hitchSummaryTimer;
  Future<void> _writes = Future<void>.value();
  int? _activeBytes;
  DateTime? _lastPrunedAt;
  bool _started = false;

  /// Optimistically on: startup lines are the point of this, and they happen
  /// before a preference read could finish. [_restoreEnabled] corrects it and
  /// discards anything buffered if the user had opted out.
  bool _enabled = true;

  /// Optimistic default before prefs resolve: Dev channel ON, Stable OFF.
  bool _verboseHitch = UpdateChannel.current.isDev;

  /// When false, skip `print`/`stderr` mirroring (file + ring only).
  static bool mirrorConsole = true;

  /// SyncEngine `--javp-sync` workers: keep NDJSON on stdout, logs on stderr.
  static bool consoleToStderr = false;

  /// Set when the user toggles verbose in Diagnostics so a late prefs restore
  /// cannot stomp the in-session choice.
  bool _verboseHitchUserSet = false;

  /// Completes when [_restoreVerboseHitch] finishes (or immediately if already
  /// done). Session header and Diagnostics wait on this so they don't freeze
  /// the optimistic [UpdateChannel.current] value forever.
  Future<void>? _verboseHitchRestore;

  int _hitchJankCount = 0;
  int _hitchJankWorstMs = 0;
  int _hitchNotifyCount = 0;
  final List<String> _hitchSlowTags = <String>[];
  int _lastDesktopEventMs = 0;

  /// Last known GoRouter path, updated from [noteRoute]. Used by the jank
  /// callback so a hitch line can say which screen was on screen — no
  /// Navigator walk on the timing path.
  static String? _route;

  bool get enabled => _enabled;

  /// When true: lower jank/slow thresholds, rebuild counts, periodic summaries.
  ///
  /// Not a sampling profiler — spam-guarded hitch diagnostics only. Default is
  /// ON for Dev (`JAVP_UPDATE_CHANNEL=dev` / sideloadDev), OFF for Stable.
  bool get verboseHitch => _verboseHitch;

  /// Frame hitch threshold used by the timings callback in `main.dart`.
  int get jankThresholdMs =>
      _verboseHitch ? _verboseJankThresholdMs : _productionJankThresholdMs;

  /// Minimum gap between jank journal lines.
  int get jankMinIntervalMs =>
      _verboseHitch ? _verboseJankMinIntervalMs : _productionJankMinIntervalMs;

  /// Default for [slow] when the call site omits an explicit threshold.
  int get effectiveSlowThresholdMs =>
      _verboseHitch ? _verboseSlowThresholdMs : _productionSlowThresholdMs;

  LogRedactor get redactor => _redactor;

  /// Cheap breadcrumb for hitch journals. Path only (no query), overwritten
  /// on each navigation — never logs by itself.
  static void noteRoute(String? path) {
    if (path == null || path.isEmpty) return;
    _route = path;
  }

  /// Current app route path if [noteRoute] has been called; otherwise null.
  static String? get currentRoute => _route;

  /// Newest last, for the Diagnostics viewer.
  List<String> get recentLines => _ring.toList(growable: false);

  /// Compact recent `L/tag` crumbs for freeze lines (newest last).
  ///
  /// Example: `I/hwnd,W/jank,W/ui-stall`. Empty ring → `-`.
  static String recentTagsBrief({int max = 6}) {
    if (instance._ring.isEmpty || max <= 0) return '-';
    final tags = <String>[];
    for (final line in instance._ring.toList().reversed) {
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final rest = line.substring(space + 1);
      final colon = rest.indexOf(':');
      if (colon <= 0) continue;
      tags.add(rest.substring(0, colon));
      if (tags.length >= max) break;
    }
    if (tags.isEmpty) return '-';
    return tags.reversed.join(',');
  }

  /// Begins capture and resolves the stored preference in the background. Cheap
  /// by design: awaiting a `SharedPreferences` read here would push the cost we
  /// just took out of startup straight back in.
  Future<void> start() {
    if (_started) return Future<void>.value();
    _started = true;
    unawaited(_restoreEnabled());
    _verboseHitchRestore = _restoreVerboseHitch();
    unawaited(pruneExpired());
    return Future<void>.value();
  }

  /// Waits until the stored preference (or Dev/Stable default) is applied.
  Future<void> ensureVerboseHitchReady() =>
      _verboseHitchRestore ?? _restoreVerboseHitch();

  static void d(String tag, String message) =>
      instance._add(LogLevel.debug, tag, message);

  static void i(String tag, String message) =>
      instance._add(LogLevel.info, tag, message);

  static void w(String tag, String message, {Object? error}) =>
      instance._add(LogLevel.warn, tag, message, error: error);

  static void e(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) => instance._add(LogLevel.error, tag, message, error: error, stack: stack);

  /// Times [body] and writes one completion line: `{label} in {ms}ms …`.
  ///
  /// Failures get a warn line with the same label so a hang vs throw is
  /// distinguishable in the journal without wrapping every call site.
  static Future<T> span<T>(
    String tag,
    String label,
    Future<T> Function() body, {
    String Function(T value)? detail,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final value = await body();
      final extra = detail == null ? '' : ' ${detail(value)}';
      i(tag, '$label in ${watch.elapsedMilliseconds}ms$extra');
      instance._noteSlowTag(tag);
      return value;
    } catch (e) {
      w(tag, '$label failed after ${watch.elapsedMilliseconds}ms', error: e);
      rethrow;
    }
  }

  /// Logs [message] only when [ms] meets [thresholdMs]. Keeps hot-path journals
  /// readable — cache hits and sub-frame work stay silent.
  ///
  /// When [thresholdMs] is omitted, uses [effectiveSlowThresholdMs] (16ms in
  /// verbose hitch mode, 50ms otherwise).
  static void slow(String tag, String message, int ms, {int? thresholdMs}) {
    final threshold = thresholdMs ?? instance.effectiveSlowThresholdMs;
    if (ms < threshold) return;
    i(tag, message);
    instance._noteSlowTag(tag);
  }

  /// Counts a Flutter frame hitch for the verbose summary (no journal line).
  static void noteJank(int totalMs) => instance._noteJank(totalMs);

  /// Records [tag] for the next hitch summary (`tags=`).
  static void noteSlowTag(String tag) => instance._noteSlowTag(tag);

  /// Drains the UI-stall phase ledger for the hitch summary (`stalls=`).
  ///
  /// Set by `UiStallWatchdog.start()`. A function rather than an import so the
  /// log writer does not depend on the watchdog that feeds it.
  static String Function()? stallBlameProvider;

  /// Counts a [ChangeNotifier] fan-out when verbose hitch mode is on.
  static void noteNotify() => instance._noteNotify();

  /// Rate-limited desktop shell breadcrumb (resize / focus / tray).
  ///
  /// Resize events only journal in verbose mode; focus/tray always log at most
  /// once per second so hide→show cycles stay visible without spam.
  static void noteDesktopEvent(String event, {String? detail}) =>
      instance._noteDesktopEvent(event, detail: detail);

  /// Entry point for the global `debugPrint` hook. Deliberately does no work
  /// beyond redaction and buffering, and never prints anything itself.
  void capture(String? message) {
    if (message == null || message.isEmpty) return;
    _add(LogLevel.debug, 'print', message);
  }

  void _add(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (!_enabled) return;
    final buffer = StringBuffer()
      ..write(DateTime.now().toUtc().toIso8601String())
      ..write(' ')
      ..write(_levelLabel(level))
      ..write('/')
      ..write(tag)
      ..write(': ')
      ..write(message);
    if (error != null) buffer.write(' | $error');
    var line = _redactor.scrub(buffer.toString());
    if (stack != null) {
      line = '$line\n${_redactor.scrub(_trimStack(stack))}';
    }

    _ring.addLast(line);
    while (_ring.length > _ringCapacity) {
      _ring.removeFirst();
    }
    _pending.add('$line\n');

    // Sideloaded release APKs are not debuggable — `run-as` cannot pull the
    // log file, and `developer.log` never reaches logcat without a VM service.
    // `print` still shows as I/flutter on Android release builds.
    // SyncEngine children must not touch stdout (NDJSON protocol).
    if (level != LogLevel.debug && mirrorConsole) {
      if (consoleToStderr) {
        stderr.writeln(line);
      } else {
        print(line);
      }
    }

    // An error may be the last thing that happens before the process dies, so
    // it does not get to wait for the timer.
    if (level == LogLevel.error || _pending.length >= _flushThreshold) {
      unawaited(flush());
      return;
    }
    _timer ??= Timer(_flushInterval, () => unawaited(flush()));
  }

  static String _levelLabel(LogLevel level) => switch (level) {
    LogLevel.debug => 'D',
    LogLevel.info => 'I',
    LogLevel.warn => 'W',
    LogLevel.error => 'E',
  };

  /// Deep frames are rarely the interesting part and would blow the size cap.
  static String _trimStack(StackTrace stack) {
    final lines = stack.toString().split('\n');
    final kept = lines.take(24).where((l) => l.trim().isNotEmpty);
    return kept.map((l) => '    $l').join('\n');
  }

  /// Writes buffered lines to disk. Safe to call concurrently: appends are
  /// serialized through [_writes] so two flushes cannot interleave a batch.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return _writes;
    final batch = _pending.join();
    _pending.clear();
    revision.value++;
    return _writes = _writes
        .then((_) => _append(batch))
        .catchError((Object _) {});
  }

  Future<void> _append(String batch) async {
    if (!_enabled) return;
    final Directory dir;
    try {
      dir = await _ensureDir();
    } catch (_) {
      return;
    }
    final file = File('${dir.path}/$logFileName');
    final data = utf8.encode(batch);
    var size = _activeBytes;
    if (size == null) {
      try {
        size = await file.exists() ? await file.length() : 0;
      } catch (_) {
        size = 0;
      }
    }
    try {
      await file.writeAsBytes(data, mode: FileMode.append, flush: false);
    } catch (_) {
      // Out of space or a revoked permission: drop the batch, keep the app up.
      _activeBytes = null;
      return;
    }
    _activeBytes = size + data.length;
    if (_activeBytes! >= _maxFileBytes) {
      await _rotate(dir);
    } else if (_shouldPrune()) {
      await _pruneFilesNow(dir);
    }
  }

  Future<void> _rotate(Directory dir) async {
    final path = dir.path;
    final cutoffMs = _cutoffUtc().millisecondsSinceEpoch;
    try {
      await Isolate.run(() => _rotateAndPrune(path, _maxFiles, cutoffMs));
      _activeBytes = 0;
      _lastPrunedAt = DateTime.now().toUtc();
    } catch (_) {
      // Re-stat on the next append rather than trusting a stale count.
      _activeBytes = null;
    }
  }

  bool _shouldPrune() {
    final last = _lastPrunedAt;
    if (last == null) return true;
    return DateTime.now().toUtc().difference(last) >= _pruneInterval;
  }

  DateTime _cutoffUtc() => DateTime.now().toUtc().subtract(keepDuration);

  /// Drops on-disk lines older than [keepDuration]. Serialized through
  /// [_writes] so a rewrite cannot interleave with an append.
  @visibleForTesting
  Future<void> pruneExpired() {
    return _writes = _writes
        .then((_) async {
          if (!_enabled) return;
          final dir = await _ensureDir();
          await _pruneFilesNow(dir);
        })
        .catchError((Object _) {});
  }

  /// Already on the [_writes] chain (or equivalent). Runs the file scan in an
  /// isolate because reading and rewriting log files can block.
  Future<void> _pruneFilesNow(Directory dir) async {
    final now = DateTime.now().toUtc();
    final cutoffMs = now.subtract(keepDuration).millisecondsSinceEpoch;
    final path = dir.path;
    try {
      final bytes = await Isolate.run(
        () => _pruneLogFiles(path, _maxFiles, cutoffMs),
      );
      _activeBytes = bytes;
      _lastPrunedAt = now;
    } catch (_) {
      _activeBytes = null;
    }
  }

  Future<Directory> _ensureDir() {
    final ready = _dir;
    if (ready != null) return Future<Directory>.value(ready);
    return _dirFuture ??= () async {
      Directory base;
      try {
        base = await getApplicationSupportDirectory();
      } catch (_) {
        // Tizen/webOS may not provide one; a temp dir still beats no logs.
        // On web, dart:io temp is also unavailable — leave base nullish path.
        if (kIsWeb) {
          base = Directory('/javp_web/support');
        } else {
          base = Directory.systemTemp;
        }
      }
      final dir = Directory('${base.path}/$dirName');
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        // Appends below fail softly, leaving the ring buffer as the only sink.
      }
      _dir = dir;
      return dir;
    }();
  }

  /// Absolute path of the log folder, for the desktop "open folder" action.
  Future<String> directoryPath() async {
    try {
      final dir = await _ensureDir();
      return dir.path;
    } catch (_) {
      return '';
    }
  }

  Future<void> _restoreEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(prefsKey);
      if (stored == false) {
        _enabled = false;
        _pending.clear();
        _ring.clear();
        _timer?.cancel();
        _timer = null;
        _stopHitchSummary();
        revision.value++;
      }
    } catch (_) {
      // Preferences unavailable: stay on, which is the documented default.
    }
  }

  Future<void> _restoreVerboseHitch() async {
    if (_verboseHitchUserSet) {
      _syncHitchSummaryTimer();
      return;
    }
    final before = _verboseHitch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_verboseHitchUserSet) {
        _syncHitchSummaryTimer();
        return;
      }
      final stored = prefs.getBool(verboseHitchPrefsKey);
      final resolved = stored ?? await _defaultVerboseHitch();
      // Re-check after awaits: Diagnostics toggle must win over restore.
      if (_verboseHitchUserSet) {
        _syncHitchSummaryTimer();
        return;
      }
      _verboseHitch = resolved;
    } catch (_) {
      if (!_verboseHitchUserSet) {
        _verboseHitch = UpdateChannel.current.isDev;
      }
    }
    _syncHitchSummaryTimer();
    if (!_verboseHitchUserSet && before != _verboseHitch) {
      revision.value++;
    }
  }

  /// Dev flavor / channel ON; Stable OFF — same signals as update labeling.
  static Future<bool> _defaultVerboseHitch({String? packageName}) async {
    final channel = await _resolveUpdateChannel(packageName: packageName);
    return channel.isDev;
  }

  /// Same signals as [AppUpdateService.resolveChannel]: baked define, else
  /// Android `*.dev` package, else Stable.
  static Future<UpdateChannel> _resolveUpdateChannel({
    String? packageName,
  }) async {
    final baked = UpdateChannel.bakedOrNull;
    if (baked != null) return baked;
    try {
      final pkg = packageName ?? (await PackageInfo.fromPlatform()).packageName;
      if (pkg.endsWith('.dev')) return UpdateChannel.dev;
    } catch (_) {
      // Fall through to compile-time default.
    }
    return UpdateChannel.current;
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      _pending.clear();
      _stopHitchSummary();
    } else {
      _syncHitchSummaryTimer();
    }
    revision.value++;
    await persistAfterFrame(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(prefsKey, value);
      } catch (_) {
        // The in-memory flag still holds for this session.
      }
    });
  }

  Future<void> setVerboseHitch(bool value) async {
    _verboseHitchUserSet = true;
    if (_verboseHitch == value) {
      _syncHitchSummaryTimer();
      return;
    }
    _verboseHitch = value;
    _resetHitchCounters();
    _syncHitchSummaryTimer();
    revision.value++;
    i(
      'hitch',
      value
          ? 'verbose on threshold=${jankThresholdMs}ms '
                '(not a stack sampler; extra journal volume)'
          : 'verbose off threshold=${jankThresholdMs}ms',
    );
    await persistAfterFrame(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(verboseHitchPrefsKey, value);
      } catch (_) {
        // In-memory flag still holds for this session.
      }
    });
  }

  void _noteJank(int totalMs) {
    if (!_verboseHitch || !_enabled) return;
    _hitchJankCount++;
    if (totalMs > _hitchJankWorstMs) _hitchJankWorstMs = totalMs;
  }

  void _noteNotify() {
    if (!_verboseHitch || !_enabled) return;
    _hitchNotifyCount++;
  }

  void _noteSlowTag(String tag) {
    if (!_verboseHitch || !_enabled) return;
    if (tag.isEmpty) return;
    _hitchSlowTags.remove(tag);
    _hitchSlowTags.add(tag);
    while (_hitchSlowTags.length > _maxRecentSlowTags) {
      _hitchSlowTags.removeAt(0);
    }
  }

  void _noteDesktopEvent(String event, {String? detail}) {
    if (!_enabled) return;
    final isResize = event == 'resize';
    if (isResize && !_verboseHitch) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDesktopEventMs < 1000) return;
    _lastDesktopEventMs = now;
    final extra = detail == null || detail.isEmpty ? '' : ' $detail';
    i('desktop', '$event$extra');
  }

  void _syncHitchSummaryTimer() {
    if (_verboseHitch && _enabled) {
      _hitchSummaryTimer ??= Timer.periodic(
        _hitchSummaryInterval,
        (_) => _emitHitchSummary(),
      );
    } else {
      _stopHitchSummary();
    }
  }

  void _stopHitchSummary() {
    _hitchSummaryTimer?.cancel();
    _hitchSummaryTimer = null;
  }

  void _resetHitchCounters() {
    _hitchJankCount = 0;
    _hitchJankWorstMs = 0;
    _hitchNotifyCount = 0;
    _hitchSlowTags.clear();
  }

  void _emitHitchSummary() {
    if (!_verboseHitch || !_enabled) return;
    if (_hitchJankCount == 0 &&
        _hitchNotifyCount == 0 &&
        _hitchSlowTags.isEmpty) {
      return;
    }
    final tags = _hitchSlowTags.isEmpty ? '-' : _hitchSlowTags.join(',');
    final route = _route ?? '-';
    final stalls = stallBlameProvider?.call() ?? '';
    i(
      'hitch',
      'summary ${_hitchSummaryInterval.inSeconds}s '
          'janks=$_hitchJankCount worst=${_hitchJankWorstMs}ms '
          'notifies=$_hitchNotifyCount tags=$tags '
          'stalls=${stalls.isEmpty ? '-' : stalls} route=$route',
    );
    _resetHitchCounters();
  }

  /// One header per launch, so every log answers "which build, on what" before
  /// anyone has to ask.
  ///
  /// Awaits verbose-hitch restore so `verboseHitch=` matches the resolved
  /// default (including Android `*.dev`), not the optimistic startup guess.
  Future<void> writeHeader({
    required String version,
    required String build,
    String? packageName,
  }) async {
    await ensureVerboseHitchReady();
    final now = DateTime.now();
    final updateChannel = (await _resolveUpdateChannel(
      packageName: packageName,
    )).id;
    i(
      'session',
      'JAVP $version ($build) '
          'host=${JavpHost.label} '
          'channel=${Distribution.label} '
          'update=$updateChannel '
          'verboseHitch=$_verboseHitch '
          'os=${Platform.operatingSystem} ${Platform.operatingSystemVersion} '
          'tv=${TvPlatform.isTvShell} '
          'locale=${Platform.localeName} '
          'tzOffset=${now.timeZoneOffset.inMinutes}m',
    );
  }

  /// Recent log text for the clipboard. Reads the previous archive too, so a
  /// report taken just after a rotation is not almost empty.
  ///
  /// Content is already redacted on the write path ([LogRedactor]); this only
  /// assembles the on-device journal — it never uploads.
  Future<String> exportText({int maxBytes = _defaultExportBytes}) async {
    await flush();
    try {
      final dir = await _ensureDir();
      await pruneExpired();
      final parts = <String>[];
      for (final name in [_archiveName(1), logFileName]) {
        final file = File('${dir.path}/$name');
        if (await file.exists()) {
          parts.add(await file.readAsString());
        }
      }
      final recent = _keepRecentLogText(parts.join(), _cutoffUtc());
      if (recent.length <= maxBytes) {
        return recent.isEmpty ? _ring.join('\n') : recent;
      }
      return recent.substring(recent.length - maxBytes);
    } catch (_) {
      return _ring.join('\n');
    }
  }

  /// Writes a redacted export to a temp file for the platform share sheet.
  ///
  /// Prefer this over the clipboard when attaching to Discord / email — a file
  /// survives paste size limits. JAVP does not upload the file; the OS share
  /// sheet is the only hand-off.
  Future<File> exportShareFile({int maxBytes = _defaultExportBytes}) async {
    final text = await exportText(maxBytes: maxBytes);
    final temp = await getTemporaryDirectory();
    final file = File('${temp.path}/javp-diagnostics.log');
    await file.writeAsString(text.isEmpty ? '(empty log)\n' : text);
    return file;
  }

  /// Total bytes held by the log folder, for Settings reporting.
  Future<int> diskUsage() async {
    try {
      final dir = await _ensureDir();
      final path = dir.path;
      return await Isolate.run(() => _measureLogs(path));
    } catch (_) {
      return 0;
    }
  }

  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _ring.clear();
    _activeBytes = 0;
    revision.value++;
    // Chained so an append already in flight cannot recreate what we delete.
    return _writes = _writes
        .then((_) async {
          try {
            final dir = await _ensureDir();
            for (var slot = 0; slot < _maxFiles; slot++) {
              final name = slot == 0 ? logFileName : _archiveName(slot);
              final file = File('${dir.path}/$name');
              if (await file.exists()) await file.delete();
            }
          } catch (_) {
            // Nothing to clear.
          }
        })
        .catchError((Object _) {});
  }

  /// Test hook: drops cached state so a fresh temp directory is picked up.
  @visibleForTesting
  Future<void> resetForTest() async {
    _timer?.cancel();
    _timer = null;
    _stopHitchSummary();
    _pending.clear();
    _ring.clear();
    _dir = null;
    _dirFuture = null;
    _activeBytes = null;
    _lastPrunedAt = null;
    _started = false;
    _enabled = true;
    _verboseHitch = UpdateChannel.current.isDev;
    _verboseHitchUserSet = false;
    _verboseHitchRestore = null;
    _resetHitchCounters();
    _lastDesktopEventMs = 0;
    _route = null;
    _redactor.forgetSecrets();
    await _writes.catchError((Object _) {});
    _writes = Future<void>.value();
  }
}

String _archiveName(int index) => 'javp.$index.log';

/// Size-rotate, then drop lines older than [cutoffEpochMs] (UTC).
void _rotateAndPrune(String path, int maxFiles, int cutoffEpochMs) {
  _rotateFiles(path, maxFiles);
  _pruneLogFiles(path, maxFiles, cutoffEpochMs);
}

/// Drops the oldest archive, shifts the rest up a slot, then retires the active
/// file. Runs in an isolate because renaming and stat-ing block.
void _rotateFiles(String path, int maxFiles) {
  try {
    final oldest = File('$path/${_archiveName(maxFiles - 1)}');
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = maxFiles - 2; i >= 1; i--) {
      final from = File('$path/${_archiveName(i)}');
      if (from.existsSync()) from.renameSync('$path/${_archiveName(i + 1)}');
    }
    final active = File('$path/${JavpLog.logFileName}');
    if (active.existsSync()) active.renameSync('$path/${_archiveName(1)}');
  } catch (_) {
    // A locked or already-removed file must not take logging down with it.
  }
}

/// Returns the active file's byte length after pruning (0 if it was removed).
int _pruneLogFiles(String path, int maxFiles, int cutoffEpochMs) {
  final cutoff = DateTime.fromMillisecondsSinceEpoch(
    cutoffEpochMs,
    isUtc: true,
  );
  var activeBytes = 0;
  for (var slot = 0; slot < maxFiles; slot++) {
    final name = slot == 0 ? JavpLog.logFileName : _archiveName(slot);
    final file = File('$path/$name');
    if (!file.existsSync()) continue;
    final String original;
    try {
      original = file.readAsStringSync();
    } catch (_) {
      continue;
    }
    final kept = _keepRecentLogText(original, cutoff);
    if (kept.isEmpty) {
      try {
        file.deleteSync();
      } catch (_) {}
      continue;
    }
    if (kept != original) {
      try {
        file.writeAsStringSync(kept, flush: true);
      } catch (_) {
        continue;
      }
    }
    if (slot == 0) {
      try {
        activeBytes = file.lengthSync();
      } catch (_) {}
    }
  }
  return activeBytes;
}

/// Keeps timestamped entries at or after [cutoff], plus continuation lines
/// (stack frames) that belong to a kept entry.
String _keepRecentLogText(String text, DateTime cutoff) {
  if (text.isEmpty) return text;
  final lines = text.split('\n');
  final kept = <String>[];
  var keep = true;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (i == lines.length - 1 && line.isEmpty) break;
    final ts = _logLineTimestamp(line);
    if (ts != null) keep = !ts.isBefore(cutoff);
    if (keep) kept.add(line);
  }
  if (kept.isEmpty) return '';
  return '${kept.join('\n')}\n';
}

DateTime? _logLineTimestamp(String line) {
  if (line.isEmpty) return null;
  final first = line.codeUnitAt(0);
  if (first < 48 || first > 57) return null;
  final space = line.indexOf(' ');
  if (space < 20) return null;
  return DateTime.tryParse(line.substring(0, space))?.toUtc();
}

int _measureLogs(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  var total = 0;
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    try {
      total += entity.statSync().size;
    } catch (_) {
      continue;
    }
  }
  return total;
}
