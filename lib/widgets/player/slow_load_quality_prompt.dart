import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/models/media_server_stream_quality.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Soft tip when a Plex / Jellyfin / Emby stream stays loading too long.
///
/// Suggests a lower quality; does not interrupt playback or force a choice.
class SlowLoadQualityPrompt extends StatelessWidget {
  const SlowLoadQualityPrompt({
    super.key,
    this.tvFocus = false,
  });

  /// Use D-pad friendly controls (Android TV / video_player backend).
  final bool tvFocus;

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<PlaybackProvider, ({bool suggest, MediaServerStreamQuality? next})>(
      (p) => (
        suggest: p.suggestLowerQuality,
        next: p.nextLowerMediaServerQuality,
      ),
    );
    if (!snapshot.suggest) {
      return const SizedBox.shrink();
    }
    final next = snapshot.next;
    if (next == null) return const SizedBox.shrink();

    final playback = context.read<PlaybackProvider>();

    final l10n = context.l10n;
    final label = '${l10n.slowStreamLoadHint} · ${next.localizedLabel(l10n)}';

    final tip = Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tvFocus
            ? null
            : () => unawaited(playback.tryLowerMediaServerQuality()),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 10, tvFocus ? 14 : 6, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.high_quality_outlined,
                color: Colors.white70,
                size: 18,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (!tvFocus)
                IconButton(
                  tooltip: l10n.close,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: playback.dismissLowerQualitySuggestion,
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (!tvFocus) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: tip,
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: TvFocusable(
        autofocus: true,
        onSelect: () => unawaited(playback.tryLowerMediaServerQuality()),
        borderRadius: 12,
        child: tip,
      ),
    );
  }
}
