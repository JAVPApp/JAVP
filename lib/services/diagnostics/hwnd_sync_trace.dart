import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/diagnostics/ui_stall_watchdog.dart';

/// Wall-clock breadcrumbs for Windows Sync focus/interaction death.
///
/// This is **not** "Not Responding": the process keeps running, status text
/// can still update, but the HWND refuses focus / title-bar / clicks. That
/// starts at the Sources **Synchroniser** press — [clickSync] is T0.
///
/// Do **not** treat `lastYield=` / `yieldAge=` as "how long Sync has been
/// stuck". Those only mean ms since the last cooperative [pumpUi]/yield.
/// Idle code often never yields, so the age grows while nothing is syncing.
class HwndSyncTrace {
  HwndSyncTrace._(this.tag, this._sourceId) : _watch = Stopwatch()..start();

  static final Map<String, HwndSyncTrace> _bySource = {};

  /// Active trace for [sourceId], if Sync is in flight.
  static HwndSyncTrace? of(String sourceId) => _bySource[sourceId];

  /// T0: user pressed Synchroniser (or equivalent). Call from the button
  /// handler **before** awaiting [LibraryProvider.syncSource].
  factory HwndSyncTrace.clickSync({
    required String sourceId,
    String? sourceName,
    String reason = 'manual',
  }) {
    _bySource[sourceId]?.mark('replaced');
    final t = HwndSyncTrace._('user-sync', _short(sourceId));
    _bySource[sourceId] = t;
    final name = (sourceName == null || sourceName.isEmpty)
        ? '-'
        : sourceName.replaceAll(RegExp(r'\s+'), '_');
    // Loud, greppable: this is when the nonsense starts.
    JavpLog.i(
      'hwnd',
      '*** SYNC_BUTTON_CLICK *** src=${_short(sourceId)} '
          'name=$name reason=$reason '
          'stall=${UiStallWatchdog.phase} '
          'yieldAge=${UiStallWatchdog.lastYieldAgeMs}ms '
          '— T0; later hwnd lines are +ms since this click '
          '(focus/click death ≠ Windows Not Responding)',
    );
    t._lastMarkMs = 0;
    t.mark('click', 'name=$name reason=$reason');
    return t;
  }

  /// Soft / non-UI sync path (no button). Still gives a T0 for that job.
  factory HwndSyncTrace.begin(String tag, {required String sourceId}) {
    final t = HwndSyncTrace._(tag, _short(sourceId));
    _bySource[sourceId] = t;
    t.mark('begin');
    return t;
  }

  final String tag;
  final String _sourceId;
  final Stopwatch _watch;
  var _lastMarkMs = 0;
  var _chunkN = 0;
  var _chunkRows = 0;
  var _chunkDecodeMs = 0;
  var _chunkWriteMs = 0;
  var _chunkPumpMs = 0;

  static String _short(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  /// Named phase. [detail] is free-form (`n=400 writeMs=12` …).
  void mark(String phase, [String detail = '']) {
    final total = _watch.elapsedMilliseconds;
    final delta = total - _lastMarkMs;
    _lastMarkMs = total;
    final extra = detail.isEmpty ? '' : ' $detail';
    JavpLog.i(
      'hwnd',
      '$tag src=$_sourceId phase=$phase '
          '+${delta}ms sinceClick=${total}ms '
          'stall=${UiStallWatchdog.phase} '
          'yieldAge=${UiStallWatchdog.lastYieldAgeMs}ms'
          '$extra',
    );
  }

  /// Time a step; always logs (Sync debug — we need every boundary).
  Future<T> step<T>(String phase, Future<T> Function() body) async {
    final sw = Stopwatch()..start();
    mark('${phase}:start');
    try {
      return await body();
    } finally {
      mark('${phase}:done', 'took=${sw.elapsedMilliseconds}ms');
    }
  }

  /// Per-SQL-chunk timings; flush every [every] chunks + first chunk.
  void noteSqlChunk({
    required int rows,
    required int decodeMs,
    required int writeMs,
    required int pumpMs,
    String kind = 'sql',
    int every = 25,
  }) {
    _chunkN++;
    _chunkRows += rows;
    _chunkDecodeMs += decodeMs;
    _chunkWriteMs += writeMs;
    _chunkPumpMs += pumpMs;
    if (_chunkN == 1 || _chunkN % every == 0) {
      mark(
        '$kind-chunk',
        'i=$_chunkN rows=$rows '
            'decode=${decodeMs}ms write=${writeMs}ms pump=${pumpMs}ms '
            'sumRows=$_chunkRows '
            'sumDecode=${_chunkDecodeMs}ms sumWrite=${_chunkWriteMs}ms '
            'sumPump=${_chunkPumpMs}ms',
      );
    }
  }

  void end([String detail = '']) {
    mark('end', detail);
    _bySource.removeWhere((_, v) => identical(v, this));
  }

  /// Correlate Win32 focus/blur with an in-flight Synchroniser timeline.
  static void noteDesktop(String event) {
    if (_bySource.isEmpty) return;
    for (final t in _bySource.values) {
      t.mark('desktop-$event');
    }
  }
}
