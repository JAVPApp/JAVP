import 'package:javp/models/epg_program.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/sports_models.dart';
import 'package:javp/services/iptv/channel_quality.dart';
import 'package:javp/services/iptv/epg_channel_matcher.dart';

/// Fuzzy-matches a football fixture to the user's live channels / EPG titles.
class SportsChannelMatch {
  const SportsChannelMatch({
    required this.channel,
    required this.score,
    required this.reason,
  });

  final MediaItem channel;
  final double score;
  final String reason;
}

class SportsChannelMatcher {
  const SportsChannelMatcher._();

  /// Best channel for [fixture], or null when nothing clears the threshold.
  static SportsChannelMatch? bestMatch({
    required SportsFixture fixture,
    required List<MediaItem> channels,
    EpgProgram? Function(MediaItem channel)? nowPlaying,
    double minScore = 2.0,
  }) {
    SportsChannelMatch? best;
    for (final channel in channels) {
      if (!channel.isLive) continue;
      final hit = scoreChannel(
        fixture: fixture,
        channel: channel,
        program: nowPlaying?.call(channel),
      );
      if (hit == null) continue;
      if (hit.score < minScore) continue;
      if (best == null || hit.score > best.score) best = hit;
    }
    return best;
  }

  static SportsChannelMatch? scoreChannel({
    required SportsFixture fixture,
    required MediaItem channel,
    EpgProgram? program,
  }) {
    final teams = [fixture.homeTeam, fixture.awayTeam];
    final fields = <String>[
      channel.title,
      if (channel.channelName != null) channel.channelName!,
      if (channel.group != null) channel.group!,
      if (program != null) program.title,
      if (program?.description != null) program!.description!,
    ];

    var score = 0.0;
    final reasons = <String>[];

    for (final team in teams) {
      final teamKey = _norm(team);
      if (teamKey.length < 3) continue;
      for (final field in fields) {
        final fieldKey = _norm(field);
        if (fieldKey.isEmpty) continue;
        if (_hasTerm(fieldKey, teamKey) ||
            (fieldKey.length >= 4 && _hasTerm(teamKey, fieldKey))) {
          score += field == program?.title ? 3.0 : 2.0;
          reasons.add(team);
          break;
        }
        // Token overlap (e.g. "Man City" vs "Manchester City").
        final overlap = _tokenOverlap(teamKey, fieldKey);
        if (overlap >= 0.66) {
          score += field == program?.title ? 2.5 : 1.5;
          reasons.add(team);
          break;
        }
      }
    }

    // Both teams mentioned in EPG title is a strong sports-broadcast signal.
    if (program != null) {
      final prog = _norm(program.title);
      final home = _norm(fixture.homeTeam);
      final away = _norm(fixture.awayTeam);
      if (home.length >= 3 &&
          away.length >= 3 &&
          _hasTerm(prog, home) &&
          _hasTerm(prog, away)) {
        score += 2.0;
      }
    }

    // Channel name looks like a sports network carrying league keywords.
    final channelBlob = _norm(
      '${channel.title} ${channel.channelName ?? ''} ${channel.group ?? ''}',
    );
    final leagueKey = _norm(fixture.leagueName);
    if (leagueKey.length >= 5 && _hasTerm(channelBlob, leagueKey)) {
      score += 0.75;
    }

    if (score <= 0) return null;
    return SportsChannelMatch(
      channel: channel,
      score: score,
      reason: reasons.toSet().join(' · '),
    );
  }

  static String _norm(String raw) {
    final cleaned = ChannelQuality.baseTitle(raw);
    return EpgChannelMatcher.normalizeName(cleaned)
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Whole-term match so short keys like `inter` do not hit `winter`.
  static bool _hasTerm(String haystack, String needle) {
    if (needle.isEmpty || haystack.isEmpty) return false;
    if (haystack == needle) return true;
    return RegExp(
      '(?:^| )${RegExp.escape(needle)}(?: |\$)',
    ).hasMatch(haystack);
  }

  static double _tokenOverlap(String a, String b) {
    final ta = a.split(' ').where((t) => t.length >= 3).toSet();
    final tb = b.split(' ').where((t) => t.length >= 3).toSet();
    if (ta.isEmpty || tb.isEmpty) return 0;
    final inter = ta.intersection(tb).length;
    final denom = ta.length < tb.length ? ta.length : tb.length;
    return inter / denom;
  }
}
