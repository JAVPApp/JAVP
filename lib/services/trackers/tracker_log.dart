import 'package:javp/models/tracker_status.dart';
import 'package:javp/services/diagnostics/javp_log.dart';
import 'package:javp/services/trackers/tracker_progress_merger.dart';

/// Compact [JavpLog] lines for tracker sync / progress / scrobble.
///
/// Tag is always `tracker` so Diagnostics filters stay simple. Never log tokens,
/// emails, or hosts — titles + public ids only (same as typical media logs).
class TrackerLog {
  TrackerLog._();

  static const tag = 'tracker';

  /// Cap per-title apply lines so a huge Watching list stays readable.
  static const maxApplyLines = 8;

  static void syncStart(
    String source, {
    bool force = false,
    String? detail,
  }) {
    final extra = detail == null || detail.isEmpty ? '' : ' $detail';
    JavpLog.i(tag, 'sync start source=$source force=$force$extra');
  }

  static void syncEnd(
    String source, {
    required int ms,
    bool ok = true,
    String? detail,
  }) {
    final extra = detail == null || detail.isEmpty ? '' : ' $detail';
    if (ok) {
      JavpLog.i(tag, 'sync end source=$source in ${ms}ms$extra');
    } else {
      JavpLog.w(tag, 'sync end source=$source failed in ${ms}ms$extra');
    }
  }

  static void syncSkip(String source, String reason) {
    JavpLog.i(tag, 'sync skip source=$source reason=$reason');
  }

  /// Watching / plan / watchlist shelf snapshot after match.
  static void shelf(
    String source,
    String name, {
    required int count,
    bool? changed,
  }) {
    final delta = changed == null ? '' : ' changed=$changed';
    JavpLog.i(tag, 'shelf source=$source $name=$count$delta');
  }

  /// One inbound progress merge wave (Simkl / Trakt / … share this path).
  static void mergeResult(
    String source,
    TrackerProgressMergeResult result, {
    int entries = 0,
  }) {
    if (!result.changed) {
      JavpLog.i(
        tag,
        'merge source=$source entries=$entries changed=false',
      );
      return;
    }
    final applied = result.applied;
    JavpLog.i(
      tag,
      'merge source=$source entries=$entries changed=true '
      'titles=${applied.length} '
      'epsMarked=${result.episodesMarked} '
      'movies=${result.moviesUpdated}',
    );
    final show = applied.length > maxApplyLines
        ? applied.take(maxApplyLines).toList()
        : applied;
    for (final row in show) {
      JavpLog.i(tag, 'apply ${row.toLogLine()}');
    }
    final rest = applied.length - show.length;
    if (rest > 0) {
      JavpLog.i(tag, 'apply … +$rest more');
    }
  }

  /// Scrobble attempt — outcome is success / skip / queued / fail (no secrets).
  static void scrobble(
    String source, {
    required String outcome,
    String? title,
    String? id,
    int? season,
    int? episode,
    double? progress,
    String? detail,
  }) {
    final parts = <String>[
      'scrobble source=$source',
      'outcome=$outcome',
      if (id != null && id.isNotEmpty) 'id=$id',
      if (title != null && title.isNotEmpty) 'title=${compactTitle(title)}',
      if (season != null && episode != null) 'ep=${formatSe(season, episode)}',
      if (progress != null) 'progress=${(progress * 100).round()}%',
      if (detail != null && detail.isNotEmpty) detail,
    ];
    if (outcome == 'fail') {
      JavpLog.w(tag, parts.join(' '));
    } else {
      JavpLog.i(tag, parts.join(' '));
    }
  }

  static void scrobbleFlush(
    String source, {
    required int sent,
    required int remaining,
  }) {
    JavpLog.i(
      tag,
      'scrobble flush source=$source sent=$sent remaining=$remaining',
    );
  }

  static String compactTitle(String title, {int max = 40}) {
    final t = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    return '${t.substring(0, max - 1)}…';
  }

  static String formatSe(int season, int episode) {
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  static String entryId(TrackerStatusEntry entry) => entry.identityKey;

  static String mediaId({
    int? tmdbId,
    String? imdbId,
    int? tvdbId,
    int? anilistId,
    String? simklId,
    String? fallback,
  }) {
    if (anilistId != null && anilistId > 0) return 'al:$anilistId';
    if (tmdbId != null && tmdbId > 0) return 'tmdb:$tmdbId';
    final imdb = imdbId?.trim().toLowerCase();
    if (imdb != null && imdb.isNotEmpty) return 'imdb:$imdb';
    if (tvdbId != null && tvdbId > 0) return 'tvdb:$tvdbId';
    final simkl = simklId?.trim();
    if (simkl != null && simkl.isNotEmpty) return 'simkl:$simkl';
    final fb = fallback?.trim();
    if (fb != null && fb.isNotEmpty) {
      return fb.length > 48 ? '${fb.substring(0, 47)}…' : fb;
    }
    return '-';
  }
}
