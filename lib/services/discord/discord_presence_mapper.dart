import 'package:javp/models/media_item.dart';
import 'package:javp/services/discord/discord_presence_artwork.dart';
import 'package:javp/services/discord/discord_presence_copy.dart';

/// How Discord should phrase the activity ("Watching …" / "Listening to …").
enum DiscordPresenceActivity { watching, listening }

/// Pure snapshot of what we want Discord to show — no IPC / package types.
class DiscordPresenceSnapshot {
  const DiscordPresenceSnapshot({
    required this.details,
    required this.state,
    this.activity = DiscordPresenceActivity.watching,
    this.startUnixSec,
    this.endUnixSec,
    this.art = DiscordPresenceArt.portalOnly,
  });

  final String details;
  final String state;
  final DiscordPresenceActivity activity;

  /// Activity start as Unix seconds (for elapsed / remaining).
  final int? startUnixSec;

  /// Activity end as Unix seconds when duration is known.
  final int? endUnixSec;

  /// Large/small image keys — never media-server URLs (see artwork resolver).
  final DiscordPresenceArt art;

  /// Idle browsing card for [copy]'s locale.
  static DiscordPresenceSnapshot browsing(DiscordPresenceCopy copy) {
    return DiscordPresenceSnapshot(
      details: copy.browsingDetails,
      state: copy.browsingState,
    );
  }

  /// Same presence apart from sub-[toleranceSec] timestamp jitter.
  ///
  /// Position ticks re-derive `start` as `now - position`, so a steadily
  /// playing title yields a near-constant anchor; a real seek moves it. This
  /// keeps the heartbeat from spending IPC on identical cards.
  bool matchesWithinTolerance(
    DiscordPresenceSnapshot? other, {
    int toleranceSec = 2,
  }) {
    if (other == null) return false;
    if (other.details != details ||
        other.state != state ||
        other.activity != activity ||
        other.art != art) {
      return false;
    }
    return _closeEnough(startUnixSec, other.startUnixSec, toleranceSec) &&
        _closeEnough(endUnixSec, other.endUnixSec, toleranceSec);
  }

  static bool _closeEnough(int? a, int? b, int toleranceSec) {
    if (a == null || b == null) return a == b;
    return (a - b).abs() <= toleranceSec;
  }

  @override
  bool operator ==(Object other) {
    return other is DiscordPresenceSnapshot &&
        other.details == details &&
        other.state == state &&
        other.activity == activity &&
        other.startUnixSec == startUnixSec &&
        other.endUnixSec == endUnixSec &&
        other.art == art;
  }

  @override
  int get hashCode =>
      Object.hash(details, state, activity, startUnixSec, endUnixSec, art);

  @override
  String toString() =>
      'DiscordPresenceSnapshot($details | $state ${activity.name} start=$startUnixSec end=$endUnixSec art=$art)';
}

/// Maps playback fields → [DiscordPresenceSnapshot] (unit-testable, no IPC).
abstract final class DiscordPresenceMapper {
  static const _maxField = 128;

  /// Build a presence from current playback fields.
  ///
  /// [now] is injectable for tests. Timestamps use wall-clock minus position
  /// so Discord shows elapsed / remaining correctly while scrubbing.
  ///
  /// When paused, timestamps are omitted — Discord interpolates progress from
  /// wall clock when both start/end are set, so a paused bar would otherwise
  /// keep advancing.
  ///
  /// [sessionStartedAt] anchors the live elapsed timer to when the channel was
  /// opened; deriving it from [now] would restart the timer on every refresh.
  ///
  /// [hideTitle] is the privacy toggle: keep the activity, drop what it is
  /// (and the poster — OP preference).
  ///
  /// [copy] is the user's UI language (see [DiscordPresenceCopy]).
  static DiscordPresenceSnapshot fromPlayback({
    required bool hasSession,
    MediaItem? item,
    required bool playing,
    required Duration position,
    required Duration duration,
    DateTime? sessionStartedAt,
    bool hideTitle = false,
    DiscordPresenceCopy copy = DiscordPresenceCopy.english,
    DateTime? now,
  }) {
    if (!hasSession || item == null) {
      return DiscordPresenceSnapshot.browsing(copy);
    }

    final clock = now ?? DateTime.now();
    final art = DiscordPresenceArtwork.resolve(
      hasSession: true,
      item: item,
      hideTitle: hideTitle,
    );
    final activity = item.isAudioOnly
        ? DiscordPresenceActivity.listening
        : DiscordPresenceActivity.watching;
    final details = _clamp(
      hideTitle ? _privateDetailsFor(item, copy) : _detailsFor(item, copy),
      _maxField,
    );
    final state = _clamp(
      hideTitle
          ? _privateStateFor(item, playing: playing, copy: copy)
          : _stateFor(item, playing: playing, copy: copy),
      _maxField,
    );

    // Live: elapsed since the channel was opened; no timer when paused.
    if (item.isLive) {
      final anchor = sessionStartedAt ?? clock;
      return DiscordPresenceSnapshot(
        details: details,
        state: state,
        activity: activity,
        art: art,
        startUnixSec: playing ? anchor.millisecondsSinceEpoch ~/ 1000 : null,
      );
    }

    // VOD / catch-up / local: Discord progress bar needs start+end. Omit both
    // while paused so the bar does not keep ticking on wall clock.
    if (!playing) {
      return DiscordPresenceSnapshot(
        details: details,
        state: state,
        activity: activity,
        art: art,
      );
    }

    final pos = position < Duration.zero ? Duration.zero : position;
    final dur = duration;
    if (dur > Duration.zero && pos <= dur) {
      final start = clock.subtract(pos);
      final end = start.add(dur);
      return DiscordPresenceSnapshot(
        details: details,
        state: state,
        activity: activity,
        art: art,
        startUnixSec: start.millisecondsSinceEpoch ~/ 1000,
        endUnixSec: end.millisecondsSinceEpoch ~/ 1000,
      );
    }

    if (pos > Duration.zero) {
      final start = clock.subtract(pos);
      return DiscordPresenceSnapshot(
        details: details,
        state: state,
        activity: activity,
        art: art,
        startUnixSec: start.millisecondsSinceEpoch ~/ 1000,
      );
    }

    return DiscordPresenceSnapshot(
      details: details,
      state: state,
      activity: activity,
      art: art,
    );
  }

  static String _detailsFor(MediaItem item, DiscordPresenceCopy copy) {
    if (item.isLive || item.kind == MediaKind.catchup) {
      final channel = (item.channelName ?? item.title).trim();
      return channel.isEmpty ? copy.liveTvFallback : channel;
    }

    if (item.isEpisode) {
      final show = _seriesName(item);
      if (show != null) return show;
    }

    final title = item.title.trim();
    return title.isEmpty ? copy.browsingState : title;
  }

  static String _stateFor(
    MediaItem item, {
    required bool playing,
    required DiscordPresenceCopy copy,
  }) {
    if (item.isLive) {
      return playing ? copy.live : copy.livePaused;
    }
    if (item.kind == MediaKind.catchup) {
      return playing ? copy.catchup : copy.catchupPaused;
    }

    final status = playing ? copy.playing : copy.paused;
    if (!item.isEpisode) return status;

    final sn = item.seasonNumber;
    final en = item.episodeNumber;
    if (sn == null && en == null) return status;

    final epLabel =
        'S${(sn ?? 1).toString().padLeft(2, '0')}E${(en ?? 0).toString().padLeft(2, '0')}';
    final epTitle = _episodeTitle(item);
    if (epTitle == null) return copy.episodeWithStatus(epLabel, status);
    return copy.episodeWithTitleStatus(epLabel, epTitle, status);
  }

  static String _privateDetailsFor(MediaItem item, DiscordPresenceCopy copy) {
    if (item.isLive || item.kind == MediaKind.catchup) {
      return copy.privateLiveTv;
    }
    return item.isAudioOnly ? copy.privateListening : copy.privateWatching;
  }

  static String _privateStateFor(
    MediaItem item, {
    required bool playing,
    required DiscordPresenceCopy copy,
  }) {
    if (item.isLive) return playing ? copy.live : copy.livePaused;
    return playing ? copy.playing : copy.paused;
  }

  /// Series name from `subtitle` (`Show · …`) when present.
  static String? _seriesName(MediaItem item) {
    final sub = item.subtitle?.trim();
    if (sub == null || sub.isEmpty) return null;
    if (!sub.contains(' · ')) {
      // Some catalogs put the show name alone in subtitle.
      if (sub.toLowerCase() != item.title.trim().toLowerCase()) return sub;
      return null;
    }
    final head = sub.split(' · ').first.trim();
    return head.isEmpty ? null : head;
  }

  /// Episode name, unless the catalog only stored a placeholder like `S01E01`
  /// or repeated the show name.
  static String? _episodeTitle(MediaItem item) {
    final title = item.title.trim();
    if (title.isEmpty) return null;
    final show = _seriesName(item);
    if (show != null && show.toLowerCase() == title.toLowerCase()) return null;
    if (_looksLikeEpisodeCode(title)) return null;
    return title;
  }

  static final _episodeCode = RegExp(
    r'^(s\s*\d{1,3}\s*[ex]\s*\d{1,3}|episode\s*\d+|ep\.?\s*\d+|\d{1,3})$',
    caseSensitive: false,
  );

  static bool _looksLikeEpisodeCode(String value) =>
      _episodeCode.hasMatch(value.trim());

  /// Truncate to [max] UTF-16 units without splitting a surrogate pair —
  /// a lone surrogate half cannot be encoded and breaks the IPC payload.
  static String _clamp(String value, int max) {
    if (value.length <= max) return value;
    if (max <= 1) return '…';

    var cut = max - 1;
    final last = value.codeUnitAt(cut - 1);
    final isHighSurrogate = last >= 0xD800 && last <= 0xDBFF;
    if (isHighSurrogate) cut -= 1;
    return '${value.substring(0, cut)}…';
  }
}
