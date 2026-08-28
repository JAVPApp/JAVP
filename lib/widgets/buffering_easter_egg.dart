import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/services/ui/persist_after_frame.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_logo.dart';
import 'package:javp/widgets/kicker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hidden delight in Settings → General → About.
///
/// Triple-tap the JAVP brand tile to open Eternal Buffering — a fake player
/// stuck at 99% with absurd tips. English-only on purpose; the joke is the secret.
class BufferingEasterEgg {
  const BufferingEasterEgg._();

  static const prefsKey = 'easter_egg_buffering_discovered';

  static const tips = <String>[
    'Calibrating vibes…',
    'Asking the router nicely…',
    'Warming up the pixels…',
    'Convincing the last byte…',
    'Untangling HDMI spaghetti…',
    'Bribing the CDN with snacks…',
    'Downloading more buffering…',
    'Consulting the Wi-Fi ghosts…',
    'Almost. So almost. Extremely almost.',
    'Rendering the spinner in 8K…',
  ];

  /// Opens the overlay and marks the egg discovered after first reveal.
  static Future<void> reveal(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final returning = prefs.getBool(prefsKey) ?? false;
    if (!context.mounted) return;

    unawaited(HapticFeedback.lightImpact());
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.78),
      transitionDuration: AppMotion.of(context, AppMotion.normal),
      pageBuilder: (context, animation, secondaryAnimation) {
        return _BufferingOverlay(returning: returning);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: AppMotion.ease);
        return FadeTransition(opacity: curved, child: child);
      },
    );

    if (!returning) {
      await persistAfterFrame(() async {
        final p = await SharedPreferences.getInstance();
        await p.setBool(prefsKey, true);
      });
    }
  }
}

/// Counts rapid taps and opens [BufferingEasterEgg] when armed.
class BufferingTapTarget extends StatefulWidget {
  const BufferingTapTarget({super.key, required this.child});

  final Widget child;

  static const tapsRequired = 3;
  static const window = Duration(milliseconds: 900);

  @override
  State<BufferingTapTarget> createState() => _BufferingTapTargetState();
}

class _BufferingTapTargetState extends State<BufferingTapTarget> {
  int _taps = 0;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _onTap() {
    _reset?.cancel();
    _taps += 1;
    if (_taps >= BufferingTapTarget.tapsRequired) {
      _taps = 0;
      unawaited(BufferingEasterEgg.reveal(context));
      return;
    }
    _reset = Timer(BufferingTapTarget.window, () => _taps = 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: widget.child,
    );
  }
}

class _BufferingOverlay extends StatefulWidget {
  const _BufferingOverlay({required this.returning});

  final bool returning;

  @override
  State<_BufferingOverlay> createState() => _BufferingOverlayState();
}

class _BufferingOverlayState extends State<_BufferingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _tipTimer;
  Timer? _wiggleTimer;
  int _tipIndex = 0;
  /// Fake progress that forever approaches — and never reaches — 100.
  double _progress = 0.99;
  String _eta = 'soon™';
  String _bitrate = '12 kb/s (optimistic)';

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _tipIndex = math.Random().nextInt(BufferingEasterEgg.tips.length);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) {
      _pulse.stop();
      _tipTimer?.cancel();
      _wiggleTimer?.cancel();
      _progress = 0.99;
      return;
    }
    _tipTimer ??= Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (!mounted) return;
      setState(() {
        _tipIndex = (_tipIndex + 1) % BufferingEasterEgg.tips.length;
      });
    });
    _wiggleTimer ??= Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (!mounted) return;
      setState(_wiggleProgress);
    });
  }

  void _wiggleProgress() {
    // Dip a hair, then crawl back toward 99 — never finish.
    final rng = math.Random();
    if (_progress >= 0.989) {
      _progress = 0.987 + rng.nextDouble() * 0.002;
      _eta = 'still soon™';
      _bitrate = '${8 + rng.nextInt(7)} kb/s (courageous)';
    } else {
      _progress = math.min(0.99, _progress + 0.001 + rng.nextDouble() * 0.0015);
      _eta = 'any second now';
      _bitrate = '${10 + rng.nextInt(9)} kb/s (optimistic)';
    }
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _wiggleTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final tip = BufferingEasterEgg.tips[_tipIndex];
    final pct = (_progress * 100).toStringAsFixed(1);

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: AppRadius.xlAll,
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.panel,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const AppLogo(size: 28),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Kicker(
                                  widget.returning
                                      ? 'Again? Bold.'
                                      : 'Please stand by',
                                  color: AppColors.accentHi,
                                ),
                                Text(
                                  'Eternal Buffering',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.4,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // Fake player stage.
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.bgDeep,
                            borderRadius: AppRadius.mdAll,
                            border: Border.all(color: AppColors.borderSoft),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (!reduce)
                                AnimatedBuilder(
                                  animation: _pulse,
                                  builder: (context, _) {
                                    final t = _pulse.value;
                                    return Icon(
                                      Icons.hourglass_top_rounded,
                                      size: 44 + t * 4,
                                      color: AppColors.accent.withValues(
                                        alpha: 0.55 + t * 0.35,
                                      ),
                                    );
                                  },
                                )
                              else
                                const Icon(
                                  Icons.hourglass_top_rounded,
                                  size: 46,
                                  color: AppColors.accent,
                                ),
                              Positioned(
                                left: 12,
                                right: 12,
                                bottom: 12,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '$pct%',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w800,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '· 1 byte remaining',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: AppColors.textDim,
                                              ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    ClipRRect(
                                      borderRadius: AppRadius.pillAll,
                                      child: LinearProgressIndicator(
                                        value: _progress,
                                        minHeight: 8,
                                        backgroundColor: AppColors.surfaceHigh,
                                        color: AppColors.accent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tip,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: AppColors.textMuted,
                              height: 1.35,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'ETA $_eta  ·  $_bitrate',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: AppColors.textDim,
                              letterSpacing: 0.2,
                            ),
                      ),
                      if (widget.returning) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Still stuck. We respect the bit.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: AppColors.textDim,
                                  ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text("I've waited long enough"),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
