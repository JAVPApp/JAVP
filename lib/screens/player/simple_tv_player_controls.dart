import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/player/tv_seek_step.dart';
import 'package:javp/screens/player/tv_vod_keymap.dart';
import 'package:javp/widgets/player/player_error_overlay.dart';
import 'package:javp/widgets/player/slow_load_quality_prompt.dart';
import 'package:javp/widgets/player/tv_player_icon_button.dart';
import 'package:javp/widgets/player/tv_player_transport.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/widgets/tv/tv_back_gate.dart';
import 'package:provider/provider.dart';

/// Lightweight TV chrome that talks only to [PlaybackProvider].
///
/// Used when [AppCapabilities.usesVideoPlayerBackend] so we never touch
/// media_kit's [Player] / [VideoController].
class SimpleTvPlayerControls extends StatefulWidget {
  const SimpleTvPlayerControls({
    super.key,
    required this.item,
    this.error,
    this.onRetry,
    this.onClose,
    this.backDispatcher,
  });

  final MediaItem item;
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
  final TvBackDispatcher? backDispatcher;

  @override
  State<SimpleTvPlayerControls> createState() => _SimpleTvPlayerControlsState();
}

class _SimpleTvPlayerControlsState extends State<SimpleTvPlayerControls> {
  bool _visible = true;
  bool _quickAccess = false;
  Timer? _hide;
  int _seekStepSeconds = 10;
  DateTime? _lastSeekAt;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    widget.backDispatcher?.attach(_consumeBack);
  }

  @override
  void didUpdateWidget(covariant SimpleTvPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backDispatcher != widget.backDispatcher) {
      oldWidget.backDispatcher?.detach();
      widget.backDispatcher?.attach(_consumeBack);
    }
  }

  @override
  void dispose() {
    widget.backDispatcher?.detach();
    _hide?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (_quickAccess) return;
    _hide = Timer(const Duration(seconds: 4), () {
      if (!mounted || _quickAccess) return;
      setState(() => _visible = false);
    });
  }

  void _bump() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _openQuickAccess() {
    _hide?.cancel();
    setState(() {
      _visible = true;
      _quickAccess = true;
    });
  }

  bool _consumeBack() {
    switch (tvVodBackAction(
      panelOpen: false,
      upNextVisible: false,
      quickAccessOpen: _quickAccess,
      chromeVisible: _visible,
    )) {
      case TvVodBackAction.closePanel:
      case TvVodBackAction.dismissUpNext:
        return false;
      case TvVodBackAction.closeQuickAccess:
      case TvVodBackAction.hideChrome:
        _hide?.cancel();
        setState(() {
          _visible = false;
          _quickAccess = false;
        });
        return true;
      case TvVodBackAction.leavePlayer:
        return false;
    }
  }

  void _scheduleLeaveIfPopScopeMissed() {
    final dispatcher = widget.backDispatcher;
    if (dispatcher == null) {
      widget.onClose?.call();
      return;
    }
    Future<void>.delayed(TvBackGate.leaveFallbackDelay, () {
      if (!mounted) return;
      if (!dispatcher.takeLeavePending()) return;
      widget.onClose?.call();
    });
  }

  Future<void> _seekBy(int seconds) async {
    final playback = context.read<PlaybackProvider>();
    final now = DateTime.now();
    _seekStepSeconds = nextTvSeekStepSeconds(
      currentStep: _seekStepSeconds,
      now: now,
      lastSeekAt: _lastSeekAt,
    );
    _lastSeekAt = now;
    final delta = Duration(
      seconds: seconds.isNegative ? -_seekStepSeconds : _seekStepSeconds,
    );
    var target = playback.position + delta;
    if (target.isNegative) target = Duration.zero;
    final dur = playback.duration;
    if (dur > Duration.zero && target > dur) target = dur;
    await playback.seekTo(target);
    _bump();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final playback = context.read<PlaybackProvider>();

    if (isTvBackKey(key)) {
      if (!tvRouteIsCurrent(context)) return KeyEventResult.ignored;
      final dispatcher = widget.backDispatcher;
      if (dispatcher != null) {
        // Leave via PopScope only — key-path pop + twin popRoute exits the app.
        if (!dispatcher.handleKey()) {
          _scheduleLeaveIfPopScopeMissed();
        }
        return KeyEventResult.handled;
      }
      if (_consumeBack()) return KeyEventResult.handled;
      _scheduleLeaveIfPopScopeMissed();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      switch (tvVodSelectAction(quickAccessOpen: _quickAccess)) {
        case TvVodSelectAction.deferToActions:
          return KeyEventResult.ignored;
        case TvVodSelectAction.openQuickAccess:
          _openQuickAccess();
          return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(playback.togglePlayPause());
      _bump();
      return KeyEventResult.handled;
    }
    if (_quickAccess &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      unawaited(_seekBy(-10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(_seekBy(10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      unawaited(playback.playNextEpisode());
      _bump();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      unawaited(playback.playPreviousEpisode());
      _bump();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _bump();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackProvider>();
    final dur = playback.duration;
    final pos = playback.position;
    final hasPrevious = playback.previousEpisode != null;
    final hasNext = playback.nextEpisode != null;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _bump,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.error != null)
              PlayerErrorOverlay(
                error: widget.error!,
                onRetry: widget.onRetry,
                onBack: widget.onClose,
                tvFocus: true,
              ),
            // Loading spinner is owned by PlayerScreen so open/resolve does not
            // stack an anonymous indicator under the labeled badge.
            if (playback.suggestLowerQuality)
              const Positioned(
                left: 48,
                right: 48,
                bottom: 96,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SlowLoadQualityPrompt(tvFocus: true),
                ),
              ),
            if (_visible && widget.error == null)
              Positioned.fill(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xCC000000), Colors.transparent],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppLayout.tvOverscan + 4,
                          AppLayout.tvOverscan,
                          AppLayout.tvOverscan + 4,
                          28,
                        ),
                        child: Text(
                          widget.item.isLive ||
                                  widget.item.kind == MediaKind.catchup
                              ? context
                                    .read<LibraryProvider>()
                                    .liveOrCatchupDisplayTitle(widget.item)
                              : widget.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xE6000000)],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppLayout.tvOverscan,
                          28,
                          AppLayout.tvOverscan,
                          AppLayout.tvOverscan,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TvPlayerScrubRow(position: pos, duration: dur),
                            const SizedBox(height: 10),
                            TvPlayerTransportCluster(
                              playing: playback.playing,
                              enabled: _quickAccess,
                              onPlayPause: () {
                                unawaited(playback.togglePlayPause());
                                _bump();
                              },
                              onRewind: () => unawaited(_seekBy(-10)),
                              onForward: () => unawaited(_seekBy(10)),
                              onPreviousEpisode: hasPrevious
                                  ? () {
                                      unawaited(playback.playPreviousEpisode());
                                      _bump();
                                    }
                                  : null,
                              onNextEpisode: hasNext
                                  ? () {
                                      unawaited(playback.playNextEpisode());
                                      _bump();
                                    }
                                  : null,
                              trailing: [
                                if (widget.onClose != null)
                                  TvPlayerIconButton(
                                    icon: Icons.close_rounded,
                                    tooltip: context.l10n.close,
                                    onSelect: widget.onClose!,
                                    enabled: _quickAccess,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
