import 'package:flutter/material.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:provider/provider.dart';

/// Visual stage for radio / audio-only playback (replaces an empty video plane).
class AudioOnlyStage extends StatelessWidget {
  const AudioOnlyStage({super.key, required this.item, this.compact = false});

  final MediaItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final art = item.artUrl;
    final hasArt = art != null && art.trim().isNotEmpty;
    // Full-player load chrome ([PlayerLoadingBadge]) owns the center slot
    // (logo + spinner on one layer). Hide this mark so they do not stack.
    final loading =
        !compact &&
        context.select<PlaybackProvider, bool>(
          (p) => p.isLoading && p.error == null,
        );

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.bgDeep, AppColors.surface, Color(0xFF1A1220)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Soft accent wash so the stage is not a flat black void.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.2),
                radius: 1.1,
                colors: [AppColors.accentSoft, Colors.transparent],
              ),
            ),
          ),
          if (hasArt && !compact)
            Opacity(
              opacity: 0.22,
              child: JavpArt(
                url: art,
                fit: BoxFit.cover,
                decodeWidth: 720,
                fadeIn: false,
              ),
            ),
          if (!loading)
            Center(
              child: Padding(
                padding: EdgeInsets.all(compact ? 8 : 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ArtBadge(url: art, compact: compact),
                    if (!compact) ...[
                      const SizedBox(height: 20),
                      Text(
                        item.isLive || item.kind == MediaKind.catchup
                            ? context
                                  .read<LibraryProvider>()
                                  .liveOrCatchupDisplayTitle(item)
                            : item.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.subtitle?.trim().isNotEmpty == true
                            ? (localizePersistedSubtitle(
                                    context.l10n,
                                    item.subtitle,
                                  ) ??
                                  item.subtitle!.trim())
                            : (item.group ?? context.l10n.radio),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.live.withValues(alpha: 0.16),
                          borderRadius: AppRadius.pillAll,
                          border: Border.all(
                            color: AppColors.live.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.graphic_eq_rounded,
                              size: 14,
                              color: AppColors.live,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              context.l10n.liveBadge,
                              style: const TextStyle(
                                color: AppColors.live,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtBadge extends StatelessWidget {
  const _ArtBadge({required this.url, required this.compact});

  final String? url;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 40.0 : 148.0;
    final radius = compact ? 8.0 : 22.0;
    final hasArt = url != null && url!.trim().isNotEmpty;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: AppColors.surfaceHigh,
        border: Border.all(color: AppColors.border),
        boxShadow: compact
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: hasArt
          ? JavpArt(
              url: url,
              fit: BoxFit.cover,
              decodeWidth: (size * 2).round(),
              fadeIn: !compact,
              fallback: _glyph(size),
            )
          : _glyph(size),
    );
  }

  Widget _glyph(double size) {
    return ColoredBox(
      color: AppColors.surfaceHigher,
      child: Center(
        child: Icon(
          Icons.radio_rounded,
          size: size * 0.42,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}
