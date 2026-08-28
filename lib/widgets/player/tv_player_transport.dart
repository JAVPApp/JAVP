import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/services/playback/player_clock.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/player/tv_player_icon_button.dart';

/// Clock + progress used by both TV VOD chromes.
class TvPlayerScrubRow extends StatelessWidget {
  const TvPlayerScrubRow({
    super.key,
    required this.position,
    required this.duration,
  });

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    const style = TextStyle(
      color: Colors.white70,
      fontWeight: FontWeight.w600,
      fontSize: 14,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Text(formatPlayerClock(position), style: style),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              backgroundColor: Colors.white24,
              color: AppColors.accent,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(formatPlayerClock(duration), style: style),
      ],
    );
  }
}

/// Prev / −10 / play / +10 / next. Extra actions go in [trailing].
class TvPlayerTransportCluster extends StatelessWidget {
  const TvPlayerTransportCluster({
    super.key,
    required this.playing,
    required this.enabled,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.firstActionFocus,
    this.trailing = const [],
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final FocusNode? firstActionFocus;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showEpisodeSkips = onPreviousEpisode != null || onNextEpisode != null;
    return Row(
      children: [
        if (showEpisodeSkips)
          TvPlayerIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: l10n.previousEpisode,
            onSelect: onPreviousEpisode ?? () {},
            enabled: enabled && onPreviousEpisode != null,
            muted: onPreviousEpisode == null,
          ),
        TvPlayerIconButton(
          icon: Icons.replay_10_rounded,
          tooltip: l10n.rewind10Seconds,
          onSelect: onRewind,
          enabled: enabled,
        ),
        TvPlayerIconButton(
          autofocus: true,
          focusNode: firstActionFocus,
          icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: playing ? l10n.pause : l10n.play,
          onSelect: onPlayPause,
          primary: true,
          enabled: enabled,
        ),
        TvPlayerIconButton(
          icon: Icons.forward_10_rounded,
          tooltip: l10n.forward10Seconds,
          onSelect: onForward,
          enabled: enabled,
        ),
        if (showEpisodeSkips)
          TvPlayerIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: l10n.nextEpisode,
            onSelect: onNextEpisode ?? () {},
            enabled: enabled && onNextEpisode != null,
            muted: onNextEpisode == null,
          ),
        const Spacer(),
        ...trailing,
      ],
    );
  }
}
