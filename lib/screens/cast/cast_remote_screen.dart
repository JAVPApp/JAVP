import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/cast/cast_service.dart';
import 'package:javp/services/playback/player_clock.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/app_action_button.dart';
import 'package:javp/widgets/cast/cast_transport_extras.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:provider/provider.dart';

/// Chromecast now-playing remote. The local player stays minimized so you can
/// leave this screen and browse without tearing down the Cast session.
class CastRemoteScreen extends StatefulWidget {
  const CastRemoteScreen({super.key});

  @override
  State<CastRemoteScreen> createState() => _CastRemoteScreenState();
}

class _CastRemoteScreenState extends State<CastRemoteScreen> {
  double? _scrub;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<PlaybackProvider>().library.cast.refreshVolume());
    });
  }

  void _leave({bool stopCast = false}) {
    if (_left) return;
    _left = true;
    final playback = context.read<PlaybackProvider>();
    unawaited(playback.minimize());
    if (stopCast) {
      unawaited(playback.library.cast.stop());
    }
    final go = GoRouter.of(context);
    if (go.canPop()) {
      go.pop();
      return;
    }
    go.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackProvider>();
    final cast = playback.library.cast;
    if (!cast.isCasting || !playback.hasSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _left) return;
        if (!context.read<PlaybackProvider>().isCasting ||
            !context.read<PlaybackProvider>().hasSession) {
          _leave();
        }
      });
    }

    final item = playback.item;
    final l10n = context.l10n;
    final device = cast.deviceName ?? '';
    final playing = playback.playing;
    final buffering = playback.buffering;
    final live = item?.isLive == true;
    final duration = playback.duration;
    final position = _scrub != null
        ? Duration(
            milliseconds: (_scrub! * duration.inMilliseconds).round().clamp(
              0,
              duration.inMilliseconds,
            ),
          )
        : playback.position;
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final art = item?.artUrlFor(portrait: false) ?? item?.artUrl;
    final title = item == null
        ? l10n.nowPlaying
        : (item.isLive
              ? context.read<LibraryProvider>().liveOrCatchupDisplayTitle(item)
              : item.title);
    final subtitle = item == null
        ? null
        : localizePersistedSubtitle(l10n, item.subtitle) ?? item.subtitle;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _leave();
      },
      child: Scaffold(
        backgroundColor: AppColors.bgDeep,
        appBar: AppBar(
          leading: IconButton(
            tooltip: l10n.minimize,
            onPressed: _leave,
            icon: const Icon(Icons.expand_more_rounded),
          ),
          title: Text(l10n.castingTo(device)),
          actions: [
            TextButton(
              onPressed: () => _leave(stopCast: true),
              child: Text(l10n.stopCasting),
            ),
          ],
        ),
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.bgDeep, AppColors.bg, AppColors.surface],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppLayout.gutter,
                8,
                AppLayout.gutter,
                16,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Poster(url: art),
                            const SizedBox(height: 28),
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(color: AppColors.text),
                            ),
                            if (subtitle != null &&
                                subtitle.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                subtitle.trim(),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.cast_connected_rounded,
                                  size: 16,
                                  color: AppColors.accentHi,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    l10n.castingTo(device),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.accentHi,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!live) ...[
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 16,
                        ),
                      ),
                      child: Slider(
                        value: progress,
                        onChanged: duration.inMilliseconds <= 0
                            ? null
                            : (v) => setState(() => _scrub = v),
                        onChangeEnd: duration.inMilliseconds <= 0
                            ? null
                            : (v) {
                                setState(() => _scrub = null);
                                unawaited(
                                  playback.seekTo(
                                    Duration(
                                      milliseconds:
                                          (v * duration.inMilliseconds).round(),
                                    ),
                                  ),
                                );
                              },
                        activeColor: AppColors.accent,
                        inactiveColor: AppColors.border,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Text(
                            _fmt(position),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _fmt(duration),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  CastTransportExtras(playback: playback, live: live),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!live)
                        IconButton(
                          tooltip: l10n.rewind10Seconds,
                          iconSize: 36,
                          onPressed: () => unawaited(
                            playback.seekTo(
                              playback.position - const Duration(seconds: 10),
                            ),
                          ),
                          icon: const Icon(Icons.replay_10_rounded),
                        ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        tooltip: playing ? l10n.pause : l10n.play,
                        iconSize: 40,
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(72, 72),
                        ),
                        onPressed: playback.togglePlayPause,
                        icon: buffering && !playing
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                      ),
                      const SizedBox(width: 12),
                      if (!live)
                        IconButton(
                          tooltip: l10n.forward10Seconds,
                          iconSize: 36,
                          onPressed: () => unawaited(
                            playback.seekTo(
                              playback.position + const Duration(seconds: 10),
                            ),
                          ),
                          icon: const Icon(Icons.forward_10_rounded),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _CastRemoteVolume(cast: cast),
                  const SizedBox(height: 12),
                  AppActionButton(
                    label: l10n.stopCasting,
                    variant: AppActionButtonVariant.outlined,
                    icon: Icons.cast_rounded,
                    expand: true,
                    onPressed: () => _leave(stopCast: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) => formatPlayerClock(d, padMinutes: false);
}

class _CastRemoteVolume extends StatefulWidget {
  const _CastRemoteVolume({required this.cast});

  final CastService cast;

  @override
  State<_CastRemoteVolume> createState() => _CastRemoteVolumeState();
}

class _CastRemoteVolumeState extends State<_CastRemoteVolume> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.cast,
      builder: (context, _) {
        if (widget.cast.activeProtocol != CastProtocol.chromecast) {
          return const SizedBox.shrink();
        }
        final value = _drag ?? widget.cast.remoteVolume.clamp(0.0, 1.0);
        final muted = value <= 0;
        return Row(
          children: [
            Icon(
              muted ? Icons.volume_off_rounded : Icons.volume_down_rounded,
              color: AppColors.textMuted,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                ),
                child: Slider(
                  value: value,
                  onChanged: (v) => setState(() => _drag = v),
                  onChangeEnd: (v) {
                    setState(() => _drag = null);
                    unawaited(widget.cast.setRemoteVolume(v));
                  },
                  activeColor: AppColors.accent,
                  inactiveColor: AppColors.border,
                ),
              ),
            ),
            const Icon(Icons.volume_up_rounded, color: AppColors.textMuted),
          ],
        );
      },
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: AppRadius.lgAll,
        child: ColoredBox(
          color: AppColors.surfaceHigh,
          child: Stack(
            fit: StackFit.expand,
            children: [
              JavpArt(url: url, fit: BoxFit.cover, decodeWidth: 720),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x66000000)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
