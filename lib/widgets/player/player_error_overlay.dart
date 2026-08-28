import 'package:flutter/material.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/platform/external_player.dart';
import 'package:javp/services/platform/external_player_actions.dart';
import 'package:javp/services/playback/drm_detect.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Blocking "couldn't play" sheet: localized DRM copy, retry, external player.
class PlayerErrorOverlay extends StatelessWidget {
  const PlayerErrorOverlay({
    super.key,
    required this.error,
    this.onRetry,
    this.onBack,
    this.tvFocus = false,
  });

  final String error;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;
  final bool tvFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final url = context.select<PlaybackProvider, String?>(
      (p) => p.currentPlayUrl ?? p.item?.playUrl,
    );
    final canExternal = ExternalPlayer.canOpenUrl(url);
    final drm = isProtectedErrorMessage(error);
    final body = drm ? l10n.drmPlaybackUnsupported : error;
    final autofocusBack = onRetry == null && !canExternal;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!tvFocus) ...[
                const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white70,
                  size: 42,
                ),
                const SizedBox(height: 12),
              ],
              Text(
                l10n.couldntPlayVideo,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tvFocus ? Colors.white : Colors.white70,
                  fontSize: tvFocus ? 14 : 12,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (onBack != null)
                    _ErrorAction(
                      tvFocus: tvFocus,
                      autofocus: autofocusBack,
                      outlined: true,
                      onPressed: onBack!,
                      label: l10n.back,
                    ),
                  if (canExternal)
                    _ErrorAction(
                      tvFocus: tvFocus,
                      autofocus: drm || (onRetry == null && onBack == null),
                      outlined: !drm,
                      onPressed: () =>
                          openCurrentInExternalPlayer(context, playUrl: url),
                      label: l10n.openInExternalPlayer,
                    ),
                  if (onRetry != null)
                    _ErrorAction(
                      tvFocus: tvFocus,
                      autofocus: !drm && !autofocusBack,
                      outlined: drm && canExternal,
                      onPressed: onRetry!,
                      label: l10n.retry,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorAction extends StatelessWidget {
  const _ErrorAction({
    required this.tvFocus,
    required this.autofocus,
    required this.outlined,
    required this.onPressed,
    required this.label,
  });

  final bool tvFocus;
  final bool autofocus;
  final bool outlined;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (tvFocus) {
      return TvFocusable(
        autofocus: autofocus,
        onSelect: onPressed,
        child: Padding(padding: const EdgeInsets.all(12), child: Text(label)),
      );
    }
    if (outlined) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white54),
        ),
        child: Text(label),
      );
    }
    return FilledButton(onPressed: onPressed, child: Text(label));
  }
}
