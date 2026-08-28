import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/models/playback_speeds.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_modal.dart';
import 'package:provider/provider.dart';

String skipSegmentLabel(BuildContext context, MediaSegmentType type) {
  final l10n = context.l10n;
  return switch (type) {
    MediaSegmentType.intro => l10n.skipIntro,
    MediaSegmentType.recap => l10n.skipRecap,
    MediaSegmentType.credits => l10n.skipCredits,
    MediaSegmentType.preview => l10n.skipPreview,
  };
}

/// Skip intro/credits, playback speed, and next episode for Cast chrome.
class CastTransportExtras extends StatelessWidget {
  const CastTransportExtras({
    super.key,
    required this.playback,
    required this.live,
    this.enabled = true,
  });

  final PlaybackProvider playback;
  final bool live;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (live) return const SizedBox.shrink();
    final l10n = context.l10n;
    final skipType = context.select<PlaybackProvider, MediaSegmentType?>(
      (p) => p.activeSkipSegment?.type,
    );
    final rate = context.select<PlaybackProvider, double>(
      (p) => p.playbackRate,
    );
    final hasNext = context.select<PlaybackProvider, bool>(
      (p) => p.nextEpisode != null,
    );
    final hasPrevious = context.select<PlaybackProvider, bool>(
      (p) => p.previousEpisode != null,
    );
    final showEpisodeSkips = hasPrevious || hasNext;

    final children = <Widget>[
      if (skipType != null)
        FilledButton(
          onPressed: enabled
              ? () => unawaited(playback.skipActiveSegment())
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            visualDensity: VisualDensity.compact,
          ),
          child: Text(
            skipSegmentLabel(context, skipType),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      TextButton(
        onPressed: enabled
            ? () => unawaited(showCastSpeedPicker(context, playback))
            : null,
        child: Text(formatPlaybackRateLabel(rate)),
      ),
      if (showEpisodeSkips)
        TextButton(
          onPressed: enabled && hasPrevious
              ? () => unawaited(playback.playPreviousEpisode())
              : null,
          child: Text(l10n.previousEpisode),
        ),
      if (showEpisodeSkips)
        TextButton(
          onPressed: enabled && hasNext
              ? () => unawaited(playback.playNextEpisode())
              : null,
          child: Text(l10n.nextEpisode),
        ),
    ];

    if (children.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 0,
      children: children,
    );
  }
}

Future<void> showCastSpeedPicker(
  BuildContext context,
  PlaybackProvider playback,
) async {
  final library = context.read<LibraryProvider>();
  final cycle = castPlaybackSpeeds(library.cyclePlaybackSpeeds);
  final chosen = await showAppModal<double>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) {
      final current = playback.playbackRate;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ctx.l10n.playbackSpeed,
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
            for (final speed in cycle)
              ListTile(
                title: Text(formatPlaybackRateLabel(speed)),
                trailing: playbackRatesEqual(speed, current)
                    ? const Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, speed),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (chosen == null) return;
  await playback.setPlaybackRate(chosen);
}
