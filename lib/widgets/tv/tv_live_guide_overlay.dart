import 'package:flutter/material.dart';
import 'package:javp/models/epg_program.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/epg_guide_grid.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';

/// Full guide grid drawn over live playback — video keeps running behind it.
class TvLiveGuideOverlay extends StatelessWidget {
  const TvLiveGuideOverlay({
    super.key,
    required this.channels,
    required this.onTune,
    required this.onPlayProgram,
    required this.onClose,
    this.currentChannel,
    this.onNearEnd,
  });

  final List<MediaItem> channels;
  final MediaItem? currentChannel;

  /// Selecting a channel row / "watch live" retunes without leaving playback.
  final ValueChanged<MediaItem> onTune;
  final void Function(MediaItem channel, EpgProgram program) onPlayProgram;
  final VoidCallback onClose;
  final VoidCallback? onNearEnd;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.82),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.grid_view_rounded,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.guide,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    context.l10n.tvGuideOverlayHint,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    borderRadius: 8,
                    onSelect: onClose,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        context.l10n.close,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: EpgGuideGrid(
                channels: channels,
                translucent: true,
                autofocusChannelId:
                    currentChannel?.id ?? currentChannel?.streamId,
                onNearEnd: onNearEnd,
                onPlayLive: onTune,
                onPlayProgram: onPlayProgram,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
