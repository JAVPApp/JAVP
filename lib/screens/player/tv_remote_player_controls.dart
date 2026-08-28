import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/media_segment.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/player/tv_seek_step.dart';
import 'package:javp/screens/player/tv_vod_keymap.dart';
import 'package:javp/widgets/player/tv_player_transport.dart';
import 'package:javp/screens/player/tv_vod_up_next.dart';
import 'package:javp/screens/tv/tv_remote_screen.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/widgets/player/player_error_overlay.dart';
import 'package:javp/widgets/player/slow_load_quality_prompt.dart';
import 'package:javp/widgets/player/tv_player_icon_button.dart';
import 'package:javp/widgets/tv/tv_back_gate.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:javp/widgets/tv/tv_player_settings_overlay.dart';
import 'package:javp/widgets/tv/tv_vod_side_overlays.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:javp/compat/media_kit_video.dart';
import 'package:provider/provider.dart';

/// Big Picture–style D-pad chrome for VOD on the TV shell.
///
/// Fullscreen session stays king; OK opens a quick-access bar; episodes and
/// settings are stacked overlays that Back dismisses one level at a time.
class TvRemotePlayerControls extends StatefulWidget {
  const TvRemotePlayerControls({
    super.key,
    required this.player,
    required this.controller,
    required this.item,
    this.error,
    this.onRetry,
    this.onClose,
    this.backDispatcher,
  });

  final Player player;
  final VideoController controller;
  final MediaItem item;
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
  final TvBackDispatcher? backDispatcher;

  @override
  State<TvRemotePlayerControls> createState() => _TvRemotePlayerControlsState();
}

enum _VodPanel { none, settings, episodes, related, search }

class _TvRemotePlayerControlsState extends State<TvRemotePlayerControls> {
  bool _visible = true;
  bool _quickAccess = false;
  Timer? _hide;
  _VodPanel _panel = _VodPanel.none;
  MediaSegmentBundle? _segments;
  MediaSegment? _activeSegment;
  bool _autoSkipped = false;
  StreamSubscription<Duration>? _positionSub;
  int _seekStepSeconds = 10;
  DateTime? _lastSeekAt;
  bool _upNextDismissed = false;
  bool _upNextVisible = false;
  int _upNextSeconds = tvVodUpNextCountdownSeconds;
  Timer? _upNextTimer;
  final _settingsKey = GlobalKey<TvPlayerSettingsOverlayState>();
  final _quickAccessFocus = FocusNode(debugLabel: 'tvVodQuickAccess');

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    _positionSub = widget.player.stream.position.listen(_onPosition);
    widget.backDispatcher?.attach(_consumeBack);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadSegments());
    });
  }

  @override
  void didUpdateWidget(covariant TvRemotePlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backDispatcher != widget.backDispatcher) {
      oldWidget.backDispatcher?.detach();
      widget.backDispatcher?.attach(_consumeBack);
    }
    if (oldWidget.item.id != widget.item.id) {
      _segments = null;
      _activeSegment = null;
      _autoSkipped = false;
      _resetUpNext();
      unawaited(_loadSegments());
    }
  }

  @override
  void dispose() {
    widget.backDispatcher?.detach();
    _hide?.cancel();
    _upNextTimer?.cancel();
    unawaited(_positionSub?.cancel());
    _quickAccessFocus.dispose();
    super.dispose();
  }

  void _resetUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    _upNextDismissed = false;
    _upNextVisible = false;
    _upNextSeconds = tvVodUpNextCountdownSeconds;
  }

  void _dismissUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    setState(() {
      _upNextDismissed = true;
      _upNextVisible = false;
    });
  }

  void _startUpNextCountdown() {
    _upNextTimer?.cancel();
    _upNextSeconds = tvVodUpNextCountdownSeconds;
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_upNextSeconds <= 1) {
        timer.cancel();
        unawaited(context.read<PlaybackProvider>().playNextEpisode());
        return;
      }
      setState(() => _upNextSeconds -= 1);
    });
  }

  void _syncUpNext(PlaybackProvider playback) {
    final item = playback.item ?? widget.item;
    final offer = tvVodShouldShowUpNext(
      dismissed: _upNextDismissed,
      isEpisode: item.isEpisode,
      hasNextEpisode: playback.nextEpisode != null,
      creditsActive: _activeSegment?.type == MediaSegmentType.credits,
      position: playback.position,
      duration: playback.duration,
    );
    if (offer && !_upNextVisible) {
      setState(() {
        _upNextVisible = true;
        _quickAccess = false;
        _visible = true;
      });
      _hide?.cancel();
      _startUpNextCountdown();
    } else if (!offer && _upNextVisible && !_upNextDismissed) {
      _upNextTimer?.cancel();
      setState(() => _upNextVisible = false);
    }
  }

  Future<void> _loadSegments() async {
    if (widget.item.isLive) return;
    try {
      final library = context.read<LibraryProvider>();
      final bundle = await library.segmentsFor(widget.item);
      if (!mounted) return;
      setState(() => _segments = bundle);
      _onPosition(widget.player.state.position);
    } catch (_) {}
  }

  void _onPosition(Duration position) {
    final playback = context.read<PlaybackProvider>();
    final bundle = _segments;
    if (bundle != null && bundle.segments.isNotEmpty) {
      final active = bundle.activeAt(position);
      if (active?.type != _activeSegment?.type) {
        if (mounted) setState(() => _activeSegment = active);
      } else {
        _activeSegment = active;
      }
      if (active == null) {
        _autoSkipped = false;
      } else {
        final settings = context.read<LibraryProvider>().skipSettings;
        final shouldAuto = switch (active.type) {
          MediaSegmentType.intro => settings.autoSkipIntro,
          MediaSegmentType.recap => settings.autoSkipRecap,
          // Keep credits on-screen so the Up next card can offer a choice.
          MediaSegmentType.credits => false,
          MediaSegmentType.preview => false,
        };
        if (shouldAuto && !_autoSkipped && active.end != null) {
          _autoSkipped = true;
          unawaited(playback.seekTo(active.end!));
        }
      }
    }
    _syncUpNext(playback);
  }

  Future<void> _skipActiveSegment() async {
    final seg = _activeSegment;
    if (seg == null) return;
    final target = seg.end ?? seg.start + const Duration(seconds: 1);
    await context.read<PlaybackProvider>().seekTo(target);
    _showChrome();
  }

  String _skipLabel(MediaSegmentType type) {
    return switch (type) {
      MediaSegmentType.intro => context.l10n.skipIntro,
      MediaSegmentType.recap => context.l10n.skipRecap,
      MediaSegmentType.credits => context.l10n.skipCredits,
      MediaSegmentType.preview => context.l10n.skipPreview,
    };
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (_panel != _VodPanel.none || _quickAccess || _upNextVisible) return;
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          _panel == _VodPanel.none &&
          !_quickAccess &&
          !_upNextVisible) {
        setState(() => _visible = false);
      }
    });
  }

  void _showChrome() {
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _openQuickAccess() {
    _hide?.cancel();
    setState(() {
      _visible = true;
      _quickAccess = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_quickAccess) return;
      if (_quickAccessFocus.canRequestFocus) {
        _quickAccessFocus.requestFocus();
      }
    });
  }

  void _openPanel(_VodPanel panel) {
    _hide?.cancel();
    setState(() {
      _panel = panel;
      _visible = true;
      _quickAccess = false;
    });
  }

  void _closePanel() {
    setState(() => _panel = _VodPanel.none);
    _scheduleHide();
  }

  /// Returns true when Back should stay in the player (menu / chrome closed).
  bool _consumeBack() {
    if (_panel == _VodPanel.settings &&
        (_settingsKey.currentState?.handleBack() ?? false)) {
      return true;
    }
    switch (tvVodBackAction(
      panelOpen: _panel != _VodPanel.none,
      upNextVisible: _upNextVisible,
      quickAccessOpen: _quickAccess,
      chromeVisible: _visible,
    )) {
      case TvVodBackAction.closePanel:
        _closePanel();
        return true;
      case TvVodBackAction.dismissUpNext:
        _dismissUpNext();
        return true;
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

  /// If the platform only delivered a key (no twin popRoute), still leave.
  void _scheduleLeaveIfPopScopeMissed() {
    final dispatcher = widget.backDispatcher;
    if (dispatcher == null) {
      widget.onClose?.call();
      return;
    }
    // Past [TvBackGate.coalesceWindow] so twin popRoute is not still in flight.
    Future<void>.delayed(TvBackGate.leaveFallbackDelay, () {
      if (!mounted) return;
      if (!dispatcher.takeLeavePending()) return;
      widget.onClose?.call();
    });
  }

  Future<void> _togglePlay() async {
    final playback = context.read<PlaybackProvider>();
    if (playback.playing) {
      await widget.player.pause();
    } else {
      await widget.player.play();
    }
    _showChrome();
  }

  Future<void> _seekBy(Duration delta) async {
    final now = DateTime.now();
    _seekStepSeconds = nextTvSeekStepSeconds(
      currentStep: _seekStepSeconds,
      now: now,
      lastSeekAt: _lastSeekAt,
      maxStep: 120,
      doubleEachBurst: true,
    );
    _lastSeekAt = now;
    final playback = context.read<PlaybackProvider>();
    final step = Duration(seconds: _seekStepSeconds);
    final signed = delta.isNegative ? -step : step;
    final next = playback.position + signed;
    await playback.seekTo(next < Duration.zero ? Duration.zero : next);
    _showChrome();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final playback = context.read<PlaybackProvider>();
    final item = playback.item ?? widget.item;

    if (isTvBackKey(key)) {
      if (!tvRouteIsCurrent(context)) return KeyEventResult.ignored;
      final dispatcher = widget.backDispatcher;
      if (dispatcher != null) {
        // Chrome may consume; leaving is owned by PlayerScreen's PopScope so
        // the twin Android popRoute cannot finish the Activity after we pop.
        if (!dispatcher.handleKey()) {
          _scheduleLeaveIfPopScopeMissed();
        }
        return KeyEventResult.handled;
      }
      if (_consumeBack()) return KeyEventResult.handled;
      _scheduleLeaveIfPopScopeMissed();
      return KeyEventResult.handled;
    }

    if (_panel != _VodPanel.none) {
      return KeyEventResult.ignored;
    }

    if (_upNextVisible) {
      // Focusable Play now / Start over buttons own Select.
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      switch (tvVodSelectAction(quickAccessOpen: _quickAccess)) {
        case TvVodSelectAction.deferToActions:
          // Quick-access buttons own Select / ←→ while the bar is open.
          return KeyEventResult.ignored;
        case TvVodSelectAction.openQuickAccess:
          _openQuickAccess();
          return KeyEventResult.handled;
      }
    }

    // While the OK menu is open, arrows move between its buttons.
    if (tvVodMenuOwnsDpad(quickAccessOpen: _quickAccess) &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.space) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }

    _showChrome();

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.period) {
      unawaited(_seekBy(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.comma) {
      unawaited(_seekBy(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      unawaited(playback.playNextEpisode());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      unawaited(playback.playPreviousEpisode());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (item.isEpisode) {
        _openPanel(_VodPanel.episodes);
      } else {
        unawaited(playback.playNextEpisode());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(playback.playPreviousEpisode());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.mediaTopMenu) {
      _openPanel(_VodPanel.settings);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE && item.isEpisode) {
      _openPanel(_VodPanel.episodes);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      _openPanel(_VodPanel.related);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyP && phoneRemoteEntryAvailable) {
      _openPanel(_VodPanel.search);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS && playback.isPlayingAd) {
      if (playback.canSkipAd) unawaited(playback.skipAd());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS && _activeSegment != null) {
      unawaited(_skipActiveSegment());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackProvider>();
    final item = playback.item ?? widget.item;
    final leftPanel =
        _panel == _VodPanel.episodes ||
        _panel == _VodPanel.related ||
        _panel == _VodPanel.search;
    final next = playback.nextEpisode;
    final phoneRemote = phoneRemoteEntryAvailable;

    return Focus(
      autofocus: _panel == _VodPanel.none && !_quickAccess && !_upNextVisible,
      onKeyEvent: _onKey,
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
          if (playback.suggestLowerQuality)
            const Positioned(
              left: 48,
              right: 48,
              bottom: 48,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SlowLoadQualityPrompt(tvFocus: true),
              ),
            ),
          if (_activeSegment != null &&
              _panel == _VodPanel.none &&
              !_upNextVisible)
            Positioned(
              right: AppLayout.tvOverscan,
              top: _visible ? 88 : AppLayout.tvOverscan,
              child: TvFocusable(
                autofocus: false,
                onSelect: () => unawaited(_skipActiveSegment()),
                borderRadius: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.accent),
                  ),
                  child: Text(
                    _skipLabel(_activeSegment!.type),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          if (leftPanel)
            const Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xCC07080C),
                        Color(0x6607080C),
                        Color(0x1407080C),
                      ],
                      stops: [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          if (_visible && _panel == _VodPanel.none && !_upNextVisible)
            Positioned.fill(
              child: _VodInfoBar(
                item: item,
                playing: playback.playing,
                position: playback.position,
                duration: playback.duration,
                quickAccess: _quickAccess,
                firstActionFocus: _quickAccessFocus,
                onPlayPause: () => unawaited(_togglePlay()),
                onRewind: () =>
                    unawaited(_seekBy(const Duration(seconds: -10))),
                onForward: () =>
                    unawaited(_seekBy(const Duration(seconds: 10))),
                onEpisodes: item.isEpisode
                    ? () => _openPanel(_VodPanel.episodes)
                    : null,
                onNextEpisode: playback.nextEpisode != null
                    ? () => unawaited(playback.playNextEpisode())
                    : null,
                onPreviousEpisode: playback.previousEpisode != null
                    ? () => unawaited(playback.playPreviousEpisode())
                    : null,
                onRelated: () => _openPanel(_VodPanel.related),
                onSearch: phoneRemote
                    ? () => _openPanel(_VodPanel.search)
                    : null,
                onSettings: () => _openPanel(_VodPanel.settings),
                onSkipSegment: _activeSegment != null
                    ? () => unawaited(_skipActiveSegment())
                    : null,
                skipLabel: _activeSegment != null
                    ? _skipLabel(_activeSegment!.type)
                    : null,
              ),
            ),
          if (_upNextVisible && next != null && _panel == _VodPanel.none)
            Positioned(
              right: 36,
              bottom: 36,
              child: _TvUpNextCard(
                next: next,
                seconds: _upNextSeconds,
                onPlayNow: () {
                  _upNextTimer?.cancel();
                  unawaited(playback.playNextEpisode());
                },
                onReplay: () {
                  _dismissUpNext();
                  unawaited(playback.seekTo(Duration.zero));
                  unawaited(widget.player.play());
                },
                onDismiss: _dismissUpNext,
              ),
            ),
          if (_panel == _VodPanel.settings)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 420,
              child: TvPlayerSettingsOverlay(
                key: _settingsKey,
                onClose: _closePanel,
              ),
            ),
          if (_panel == _VodPanel.episodes)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 440,
              child: TvEpisodePickerOverlay(onClose: _closePanel),
            ),
          if (_panel == _VodPanel.related)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 440,
              child: TvRelatedOverlay(onClose: _closePanel),
            ),
          if (_panel == _VodPanel.search)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 440,
              child: TvLibrarySearchOverlay(onClose: _closePanel),
            ),
        ],
      ),
    );
  }
}

class _VodInfoBar extends StatelessWidget {
  const _VodInfoBar({
    required this.item,
    required this.playing,
    required this.position,
    required this.duration,
    required this.quickAccess,
    this.firstActionFocus,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
    required this.onSettings,
    required this.onRelated,
    this.onEpisodes,
    this.onNextEpisode,
    this.onPreviousEpisode,
    this.onSearch,
    this.onSkipSegment,
    this.skipLabel,
  });

  final MediaItem item;
  final bool playing;
  final Duration position;
  final Duration duration;
  final bool quickAccess;
  final FocusNode? firstActionFocus;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback onSettings;
  final VoidCallback onRelated;
  final VoidCallback? onEpisodes;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onSearch;
  final VoidCallback? onSkipSegment;
  final String? skipLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final subtitle = (item.subtitle ?? '').trim();

    return Column(
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
              ],
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TvPlayerScrubRow(position: position, duration: duration),
                const SizedBox(height: 10),
                FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: TvPlayerTransportCluster(
                    playing: playing,
                    enabled: quickAccess,
                    firstActionFocus: firstActionFocus,
                    onPlayPause: onPlayPause,
                    onRewind: onRewind,
                    onForward: onForward,
                    onPreviousEpisode: onPreviousEpisode,
                    onNextEpisode: onNextEpisode,
                    trailing: [
                      if (onEpisodes != null)
                        TvPlayerIconButton(
                          icon: Icons.playlist_play_rounded,
                          tooltip: l10n.episodes,
                          onSelect: onEpisodes!,
                          enabled: quickAccess,
                        ),
                      TvPlayerIconButton(
                        icon: Icons.movie_filter_outlined,
                        tooltip: l10n.moreLikeThis,
                        onSelect: onRelated,
                        enabled: quickAccess,
                      ),
                      if (onSearch != null)
                        TvPlayerIconButton(
                          icon: Icons.search_rounded,
                          tooltip: l10n.searchLibrary,
                          onSelect: onSearch!,
                          enabled: quickAccess,
                        ),
                      if (onSkipSegment != null && skipLabel != null)
                        TvPlayerIconButton(
                          icon: Icons.skip_next_rounded,
                          tooltip: skipLabel!,
                          onSelect: onSkipSegment!,
                          enabled: quickAccess,
                        ),
                      TvPlayerIconButton(
                        icon: Icons.settings_outlined,
                        tooltip: l10n.navSettings,
                        onSelect: onSettings,
                        enabled: quickAccess,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TvUpNextCard extends StatelessWidget {
  const _TvUpNextCard({
    required this.next,
    required this.seconds,
    required this.onPlayNow,
    required this.onReplay,
    required this.onDismiss,
  });

  final MediaItem next;
  final int seconds;
  final VoidCallback onPlayNow;
  final VoidCallback onReplay;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final art = next.artUrlFor(portrait: true) ?? next.artUrl;
    final meta = [
      if (next.seasonNumber != null && next.episodeNumber != null)
        'S${next.seasonNumber.toString().padLeft(2, '0')}'
            'E${next.episodeNumber.toString().padLeft(2, '0')}',
      if ((next.subtitle ?? '').trim().isNotEmpty) next.subtitle!.trim(),
    ].join(' · ');

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xF00B0D12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.upNext,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    TvFocusable(
                      onSelect: onDismiss,
                      borderRadius: 16,
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(Icons.close_rounded, size: 20),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 72,
                        height: 108,
                        child: ColoredBox(
                          color: AppColors.surfaceHigh,
                          child: JavpArt(
                            url: art,
                            decodeWidth: 144,
                            fallback: const Icon(
                              Icons.movie_rounded,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            next.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (meta.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              meta,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    TvFocusable(
                      autofocus: true,
                      onSelect: onPlayNow,
                      borderRadius: 12,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Text(
                          '${context.l10n.playNow} · $seconds',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    TvFocusable(
                      onSelect: onReplay,
                      borderRadius: 12,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Text(
                          context.l10n.startOver,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
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
    );
  }
}
