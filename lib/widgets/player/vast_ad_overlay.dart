import 'dart:async';

import 'package:flutter/material.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/ads/vast_models.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Linear ad chrome: Ad badge, Skip, Learn more, AdChoices icons, companion.
class VastAdOverlay extends StatelessWidget {
  const VastAdOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final snapshot = context.select<PlaybackProvider, _AdChrome?>(
      (p) => p.isPlayingAd
          ? _AdChrome(
              canSkip: p.canSkipAd,
              remainingSeconds: p.adRemaining?.inSeconds,
              hasClickThrough: p.adClickThroughUrl != null,
              position: p.position,
              icons: p.adIcons,
              companion: p.adCompanion,
            )
          : null,
    );
    if (snapshot == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final remaining = snapshot.remainingSeconds;
    final skipLabel = snapshot.canSkip
        ? l10n.skipAd
        : remaining == null
        ? l10n.advertisement
        : l10n.skipAdInSeconds(remaining);
    final playback = context.read<PlaybackProvider>();
    final pad = MediaQuery.paddingOf(context);

    return IgnorePointer(
      ignoring: false,
      child: Stack(
        children: [
          Positioned(
            left: 16,
            top: pad.top + 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  remaining == null
                      ? l10n.advertisement
                      : '${l10n.advertisement} · ${remaining}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
          for (final icon in snapshot.visibleIcons)
            _IconSlot(
              icon: icon,
              padding: pad,
              onTap: () => unawaited(playback.openAdIcon(icon)),
            ),
          if (snapshot.companion != null)
            Positioned(
              left: 16,
              bottom: pad.bottom + 88,
              child: _CompanionBanner(
                companion: snapshot.companion!,
                onTap: () =>
                    unawaited(playback.openAdCompanion(snapshot.companion!)),
              ),
            ),
          Positioned(
            right: 16,
            bottom: pad.bottom + 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (snapshot.hasClickThrough) ...[
                  TextButton(
                    onPressed: () => unawaited(playback.openAdClickThrough()),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black45,
                    ),
                    child: Text(l10n.learnMore),
                  ),
                  const SizedBox(width: 8),
                ],
                if (TvPlatform.isTvShell)
                  TvFocusable(
                    autofocus: snapshot.canSkip,
                    enabled: snapshot.canSkip,
                    onSelect: snapshot.canSkip
                        ? () => unawaited(playback.skipAd())
                        : null,
                    child: _SkipChip(
                      label: skipLabel,
                      enabled: snapshot.canSkip,
                    ),
                  )
                else
                  FilledButton(
                    onPressed: snapshot.canSkip
                        ? () => unawaited(playback.skipAd())
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: snapshot.canSkip
                          ? Colors.white
                          : Colors.white24,
                      foregroundColor: snapshot.canSkip
                          ? Colors.black
                          : Colors.white70,
                    ),
                    child: Text(
                      skipLabel,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IconSlot extends StatelessWidget {
  const _IconSlot({
    required this.icon,
    required this.padding,
    required this.onTap,
  });

  final VastIcon icon;
  final EdgeInsets padding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final width = (icon.width ?? 40).clamp(16, 80).toDouble();
    final height = (icon.height ?? 40).clamp(16, 80).toDouble();
    final left = _axis(icon.xPosition, start: true);
    final top = _axis(icon.yPosition, start: false);
    return Positioned(
      left: left ? 16 : null,
      right: left ? null : 16,
      top: top ? padding.top + 48 : null,
      bottom: top ? null : padding.bottom + 96,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: height,
          child: JavpArt(
            url: icon.staticUrl,
            fit: BoxFit.contain,
            decodeWidth: width.round() * 2,
            fadeIn: false,
          ),
        ),
      ),
    );
  }

  static bool _axis(String raw, {required bool start}) {
    final v = raw.trim().toLowerCase();
    if (start) {
      if (v == 'left') return true;
      if (v == 'right') return false;
    } else {
      if (v == 'top') return true;
      if (v == 'bottom') return false;
    }
    final n = double.tryParse(v);
    if (n != null) return n < 50;
    return !start;
  }
}

class _CompanionBanner extends StatelessWidget {
  const _CompanionBanner({required this.companion, required this.onTap});

  final VastCompanion companion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final w = (companion.width ?? 300).clamp(80, 400).toDouble();
    final h = (companion.height ?? 60).clamp(32, 120).toDouble();
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: SizedBox(
          width: w,
          height: h,
          child: JavpArt(
            url: companion.staticUrl,
            fit: BoxFit.contain,
            decodeWidth: w.round() * 2,
            fadeIn: false,
          ),
        ),
      ),
    );
  }
}

class _SkipChip extends StatelessWidget {
  const _SkipChip({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: enabled ? Colors.white : Colors.white24,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.black : Colors.white70,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _AdChrome {
  const _AdChrome({
    required this.canSkip,
    required this.remainingSeconds,
    required this.hasClickThrough,
    required this.position,
    required this.icons,
    required this.companion,
  });

  final bool canSkip;
  final int? remainingSeconds;
  final bool hasClickThrough;
  final Duration position;
  final List<VastIcon> icons;
  final VastCompanion? companion;

  List<VastIcon> get visibleIcons {
    return [
      for (final icon in icons)
        if (_iconVisible(icon, position)) icon,
    ];
  }

  static bool _iconVisible(VastIcon icon, Duration position) {
    final start = icon.offset ?? Duration.zero;
    if (position < start) return false;
    if (icon.duration == null) return true;
    return position <= start + icon.duration!;
  }
}
