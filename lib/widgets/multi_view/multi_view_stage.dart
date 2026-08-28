import 'package:flutter/material.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/multi_view_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/playback_video_surface.dart';
import 'package:javp/compat/media_kit_video.dart';
import 'package:provider/provider.dart';

/// Composes primary + secondary live surfaces for multi-view MVP.
class MultiViewStage extends StatelessWidget {
  const MultiViewStage({
    super.key,
    required this.playback,
    required this.primarySurface,
    this.controls,
  });

  final PlaybackProvider playback;

  /// Already-built primary video plane (keeps captions / existing chrome).
  final Widget primarySurface;

  /// Optional overlay chrome drawn once above the whole stage.
  final Widget Function(BuildContext context)? controls;

  @override
  Widget build(BuildContext context) {
    final multi = context.watch<MultiViewProvider>();
    if (!multi.isActive) {
      return Stack(
        fit: StackFit.expand,
        children: [
          primarySurface,
          if (controls != null)
            Positioned.fill(child: Builder(builder: controls!)),
        ],
      );
    }

    final secondary = multi.secondaryController;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final usePip = multi.layoutMode == MultiViewLayoutMode.pip || !wide;

    final stage = usePip
        ? _PipLayout(
            primary: _pane(
              context,
              pane: MultiViewPane.primary,
              child: primarySurface,
              channel: playback.item ?? playback.liveChannel,
              multi: multi,
            ),
            secondary: secondary == null
                ? const ColoredBox(color: Colors.black)
                : _pane(
                    context,
                    pane: MultiViewPane.secondary,
                    child: Video(
                      controller: secondary,
                      fit: BoxFit.contain,
                      controls: NoVideoControls,
                    ),
                    channel: multi.secondaryChannel,
                    multi: multi,
                  ),
          )
        : Row(
            children: [
              Expanded(
                child: _pane(
                  context,
                  pane: MultiViewPane.primary,
                  child: primarySurface,
                  channel: playback.item ?? playback.liveChannel,
                  multi: multi,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: secondary == null
                    ? const ColoredBox(color: Colors.black)
                    : _pane(
                        context,
                        pane: MultiViewPane.secondary,
                        child: Video(
                          controller: secondary,
                          fit: BoxFit.contain,
                          controls: NoVideoControls,
                        ),
                        channel: multi.secondaryChannel,
                        multi: multi,
                      ),
              ),
            ],
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black, child: stage),
        if (controls != null)
          Positioned.fill(child: Builder(builder: controls!)),
      ],
    );
  }

  Widget _pane(
    BuildContext context, {
    required MultiViewPane pane,
    required Widget child,
    required MediaItem? channel,
    required MultiViewProvider multi,
  }) {
    final l10n = AppLocalizations.of(context);
    final focused = multi.focusedPane == pane;
    final hasAudio = multi.audioPane == pane;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => multi.setFocusedPane(pane),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: IgnorePointer(
              child: Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: focused
                              ? AppColors.accent
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        channel?.title ??
                            (pane == MultiViewPane.primary
                                ? l10n.multiViewPrimary
                                : l10n.multiViewSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: focused ? AppColors.accent : AppColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (hasAudio)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.volume_up_rounded,
                        size: 14,
                        color: AppColors.accent,
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.volume_off_rounded,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PipLayout extends StatelessWidget {
  const _PipLayout({required this.primary, required this.secondary});

  final Widget primary;
  final Widget secondary;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pipW = (constraints.maxWidth * 0.32).clamp(140.0, 320.0);
        final pipH = pipW * 9 / 16;
        return Stack(
          fit: StackFit.expand,
          children: [
            primary,
            Positioned(
              right: 12,
              bottom: 12,
              width: pipW,
              height: pipH,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: secondary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Convenience when the caller only has [PlaybackProvider] + captions config.
class MultiViewPlaybackSurface extends StatelessWidget {
  const MultiViewPlaybackSurface({
    super.key,
    required this.playback,
    this.fit = BoxFit.contain,
    this.controls,
    this.subtitleViewConfiguration,
  });

  final PlaybackProvider playback;
  final BoxFit fit;
  final Widget Function(BuildContext context)? controls;
  final SubtitleViewConfiguration? subtitleViewConfiguration;

  @override
  Widget build(BuildContext context) {
    final multi = context.watch<MultiViewProvider>();
    final primary = PlaybackVideoSurface.forSession(
      playback,
      fit: fit,
      subtitleViewConfiguration: subtitleViewConfiguration,
      // When multi-view is active, chrome is drawn once on the stage.
      controls: multi.isActive ? null : controls,
    );
    return MultiViewStage(
      playback: playback,
      primarySurface: primary,
      controls: multi.isActive ? controls : null,
    );
  }
}
