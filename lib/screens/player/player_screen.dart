import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/platform/desktop_ui.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/caption_style_provider.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/screens/cast/cast_remote_screen.dart';
import 'package:javp/screens/player/gesture_player_controls.dart';
import 'package:javp/screens/player/simple_tv_player_controls.dart';
import 'package:javp/screens/player/tv_remote_player_controls.dart';
import 'package:javp/screens/player/tv_vod_keymap.dart';
import 'package:javp/widgets/multi_view/multi_view_stage.dart';
import 'package:javp/widgets/multi_view/multi_view_toolbar.dart';
import 'package:javp/widgets/playback_video_surface.dart';
import 'package:javp/widgets/player_browse_panel.dart';
import 'package:javp/widgets/player_loading_badge.dart';
import 'package:javp/widgets/player/desktop_pip_chrome.dart';
import 'package:javp/widgets/player/sleep_timer_feedback.dart';
import 'package:javp/widgets/player/stream_stats_overlay.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:javp/widgets/player/vast_ad_overlay.dart';
import 'package:javp/widgets/tv/tv_back_gate.dart';
import 'package:provider/provider.dart';

/// If [pop] cannot leave `/player`, [go] this path instead.
@visibleForTesting
String? playerLeaveHomeFallback(String path) =>
    path == '/player' ? '/home' : null;

/// Whether `/player` should paint watch+browse instead of the mini leave-handoff.
///
/// Arriving from the dock (or a channel tap while mini is up) used to paint a
/// full-bleed AppBar scaffold until post-frame [PlaybackProvider.expand], then
/// snap to the side panel — a one-frame hitch that felt like a cheap maximize.
@visibleForTesting
bool playerPaintsWatchBrowseOnArrival({
  required bool minimized,
  required bool bootstrapPending,
  required bool sessionHandedOff,
}) {
  if (sessionHandedOff) return false;
  if (!minimized) return true;
  return bootstrapPending;
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.item});

  final MediaItem item;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// Last orientation we synced cinema mode to (rotate → cinema).
  Orientation? _syncedOrientation;

  /// True after minimize/stop so [dispose] does not treat teardown as orphaned.
  bool _sessionHandedOff = false;

  /// True until the first-frame open/expand bootstrap finishes. Prevents the
  /// minimized-route pop from racing channel taps that push `/player` while the
  /// mini bar is still up (open() is async; audio would continue with no chrome).
  bool _bootstrapPending = true;

  /// [PlaybackProvider.claimVideoSurface] ran; [dispose] always releases.
  bool _claimedSurface = false;
  PlaybackProvider? _playback;
  final _tvBack = TvBackDispatcher();

  /// Survives landscape ↔ portrait so hide/show does not remount the panel.
  final _browsePanelKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final playback = context.read<PlaybackProvider>();
        // Live on Android TV uses the set-top overlay, not VOD player chrome.
        if (TvPlatform.isAndroidTv &&
            (widget.item.isLive ||
                (widget.item.kind == MediaKind.catchup &&
                    playback.liveChannel != null))) {
          _sessionHandedOff = true;
          // DVR/catchup of the current live channel must not retune to live.
          if (playback.hasSession &&
              (playback.sessionMatches(widget.item) ||
                  playback.liveChannel != null)) {
            if (!playback.isExpanded) await playback.expand();
          } else if (widget.item.isLive) {
            final library = context.read<LibraryProvider>();
            await playback.open(
              library.resolveLiveChannel(widget.item),
              expand: true,
            );
          }
          if (mounted) context.go('/tv/watch');
          return;
        }
        // Same session as the mini player: expand in place — do not open()
        // again (that restarts / jumps the playhead). Incoming chrome is
        // already expanded; this syncs system chrome / PiP if needed.
        if (playback.hasSession) {
          final matches = playback.sessionMatches(widget.item);
          if (matches) {
            if (playback.isCasting) {
              _sessionHandedOff = true;
              unawaited(playback.minimize());
              if (mounted) context.pushReplacement('/cast');
              return;
            }
            // Never re-open() the same stream — that was collapsing the mini
            // dock (expand:true default) while media_kit kept playing.
            if (!playback.isExpanded) {
              await playback.expand();
            }
            return;
          }
        }
        await playback.open(widget.item, expand: true);
      } finally {
        if (mounted) setState(() => _bootstrapPending = false);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playback = context.read<PlaybackProvider>();
    // Claim once. Provider notifies on every tick would otherwise steal the
    // texture back from the mini dock after [_minimize].
    if (!_sessionHandedOff && !_claimedSurface) {
      _claimedSurface = true;
      // Silent expand so the first paint is watch+browse, not the full-bleed
      // AppBar handoff. claimVideoSurface notifies (when it actually claims).
      _playback!.applyIncomingPlayerChrome();
      _playback!.claimVideoSurface();
    }
  }

  /// Pop `/player` back to the prior screen. Only [go]/home`) when the route
  /// was opened without a stack (deep link) — never after a successful pop,
  /// or a post-frame handoff will yank the user off TV/Catalog/etc.
  ///
  /// Always re-check the path after [pop]: PopScope `canPop: false` plus
  /// [GoRouter.canPop] can disagree, and a handed-off minimize used to no-op
  /// while still sitting on `/player`.
  void _leaveFullPlayerRoute() {
    if (!mounted) return;
    final router = GoRouter.of(context);
    try {
      if (router.canPop()) {
        router.pop();
      }
    } catch (_) {}
    if (!mounted) return;
    final path = router.routerDelegate.currentConfiguration.uri.path;
    final home = playerLeaveHomeFallback(path);
    if (home != null) router.go(home);
  }

  @override
  void dispose() {
    // If this route is torn down without [_minimize] (unexpected pop / replace),
    // stop so audio cannot continue with no player chrome. Cast keeps the
    // session on the TV — just dock the phone.
    if (!_sessionHandedOff) {
      final playback = _playback;
      if (playback != null &&
          playback.hasSession &&
          !playback.isMinimized &&
          !playback.isInPip) {
        if (playback.isCasting) {
          unawaited(playback.minimize());
        } else {
          unawaited(playback.stop());
        }
      }
    }
    _playback?.releaseVideoSurface();
    super.dispose();
  }

  /// Back / Close from the fullscreen player.
  ///
  /// Phones always dock. Android TV keeps live playing and stops VOD.
  /// A failed / never-started open stops instead of docking a dead spinner.
  Future<void> _leavePlayer() async {
    final playback = context.read<PlaybackProvider>();
    if (playback.isInPip && playback.pip.usesDesktopMiniWindow) {
      if (_sessionHandedOff) {
        _leaveFullPlayerRoute();
        return;
      }
      await playback.expand();
      return;
    }
    if (playback.shouldAbandonSessionOnLeave) {
      await _stopAndLeave();
      return;
    }
    final live = (playback.item ?? widget.item).isLive;
    if (TvPlatform.isAndroidTv &&
        !tvLeaveFullscreenKeepsSession(isLive: live)) {
      await _stopAndLeave();
      return;
    }
    await _minimize();
  }

  Future<void> _minimize() async {
    final playback = context.read<PlaybackProvider>();
    if (playback.shouldAbandonSessionOnLeave) {
      await _stopAndLeave();
      return;
    }
    // Repeat Back while already handing off must still leave `/player`.
    if (_sessionHandedOff) {
      _leaveFullPlayerRoute();
      return;
    }
    _sessionHandedOff = true;
    FocusManager.instance.primaryFocus?.unfocus();
    // minimize() notifies synchronously before its first await — that schedules
    // a rebuild which also tries to leave. [_sessionHandedOff] stops the
    // post-frame path from calling go('/home') after this pop succeeds.
    unawaited(playback.minimize());
    _leaveFullPlayerRoute();
  }

  Future<void> _stopAndLeave() async {
    if (_sessionHandedOff) {
      _leaveFullPlayerRoute();
      return;
    }
    final playback = context.read<PlaybackProvider>();
    _sessionHandedOff = true;
    FocusManager.instance.primaryFocus?.unfocus();
    await playback.stop();
    if (!mounted) return;
    _leaveFullPlayerRoute();
  }

  /// Landscape → cinema (fullscreen); portrait → watch + browse.
  /// Only reacts to orientation changes so a manual cinema toggle in portrait
  /// is kept until the device rotates.
  void _syncCinemaForOrientation(Orientation orientation) {
    // A desktop window is almost always "landscape" — auto-cinema would open
    // every video fullscreen and fight the F / double-click toggle.
    if (DesktopUi.enabled) return;
    if (_syncedOrientation == orientation) return;
    final was = _syncedOrientation;
    _syncedOrientation = orientation;
    final playback = context.read<PlaybackProvider>();
    // Don't fight minimize / mini-player / PiP — only sync while expanded.
    if (playback.isMinimized || playback.isInPip || !playback.isExpanded) {
      return;
    }
    if (was == null) {
      // First frame: open landscape already in cinema.
      if (orientation == Orientation.landscape && !playback.cinemaMode) {
        unawaited(playback.setCinemaMode(true));
      }
      return;
    }
    unawaited(playback.setCinemaMode(orientation == Orientation.landscape));
  }

  Widget _videoSurface({
    required PlaybackProvider playback,
    required CaptionStyleProvider captions,
    required MediaItem item,
  }) {
    // One overlay only — see lib/screens/player/README.md.
    final controlsBuilder = AppCapabilities.usesVideoPlayerBackend
        ? (BuildContext _) => SimpleTvPlayerControls(
            item: item,
            error: playback.error,
            onRetry: playback.retry,
            onClose: _leavePlayer,
            backDispatcher: _tvBack,
          )
        : (BuildContext _) => TvPlatform.isAndroidTv
              ? TvRemotePlayerControls(
                  player: playback.player,
                  controller: playback.controller,
                  item: item,
                  error: playback.error,
                  onRetry: playback.retry,
                  onClose: _leavePlayer,
                  backDispatcher: _tvBack,
                )
              : GesturePlayerControls(
                  player: playback.player,
                  controller: playback.controller,
                  item: item,
                  error: playback.error,
                  onRetry: playback.retry,
                  onMinimize: _leavePlayer,
                  onClose: _leavePlayer,
                  onCaptionSettings: () => context.push('/captions'),
                  onToggleCinema: () => unawaited(playback.toggleCinemaMode()),
                  onToggleBrowsePanel: playback.toggleBrowsePanel,
                );

    final surface = AppCapabilities.multiView
        ? MultiViewPlaybackSurface(
            playback: playback,
            subtitleViewConfiguration: captions.style
                .toSubtitleViewConfiguration(),
            controls: controlsBuilder,
          )
        : ColoredBox(
            color: Colors.black,
            child: PlaybackVideoSurface.forSession(
              playback,
              subtitleViewConfiguration: AppCapabilities.usesVideoPlayerBackend
                  ? null
                  : captions.style.toSubtitleViewConfiguration(),
              controls: controlsBuilder,
            ),
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black, child: surface),
        const _PlayerLoadingLayer(),
        if (AppCapabilities.multiView)
          const Positioned(right: 12, top: 12, child: MultiViewToolbar()),
        const VastAdOverlay(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    // Position ticks notify a few times a second; rebuilding the video surface
    // that often churns the whole controls tree for nothing.
    context.select<PlaybackProvider, int>(
      (p) => Object.hash(
        p.isInPip,
        p.engineRevision,
        p.isMinimized,
        p.isAudioOnly,
        p.isCasting,
      ),
    );
    // Cast owns the chrome — never paint a minimized blank /player.
    if (playback.isCasting) {
      if (!_sessionHandedOff) {
        _sessionHandedOff = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(playback.minimize());
          final path = GoRouter.of(
            context,
          ).routerDelegate.currentConfiguration.uri.path;
          if (path == '/player') {
            context.pushReplacement('/cast');
          }
        });
      }
      return const CastRemoteScreen();
    }
    // Minimized session on /player: leave so Shell can host the mini dock.
    // Skip when [_minimize] already handed off — otherwise canPop is false
    // after the pop and a blind go('/home') steals the prior tab.
    //
    // Arriving from mini still has isMinimized until applyIncomingPlayerChrome
    // / expand(); paint watch+browse anyway so we do not flash a full-bleed
    // AppBar scaffold then snap in the side panel.
    //
    // Do not keep [forSession] here after handoff: the mini dock attaches
    // the same GlobalKey in this frame. Two Videos was the black flash.
    if (playback.isMinimized &&
        !playerPaintsWatchBrowseOnArrival(
          minimized: true,
          bootstrapPending: _bootstrapPending,
          sessionHandedOff: _sessionHandedOff,
        )) {
      return _MinimizedPlayerHandoff(
        sessionHandedOff: _sessionHandedOff,
        onLeave: _leaveFullPlayerRoute,
        onHandOff: () => _sessionHandedOff = true,
      );
    }
    final captions = context.watch<CaptionStyleProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        playback.applyCaptionStyle(
          captions.style,
          extraFontsDir: captions.extraFontsDir,
        ),
      );
    });
    final item = playback.item ?? widget.item;
    final video = _videoSurface(
      playback: playback,
      captions: captions,
      item: item,
    );

    // Android/iOS back must not pop the route while leaving an expanded
    // session (audio with no chrome). Same path as the minimize chevron.
    // Android TV VOD stops instead of docking; live stays on `/tv/watch`.
    //
    // PersistentMiniPlayer only insets while the mini bar is painted. Strip
    // any leftover dock padding so cinema / SafeAreas stay edge-to-edge on
    // the system bottom only.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final playback = context.read<PlaybackProvider>();
          if (playback.shouldAbandonSessionOnLeave) {
            unawaited(_leavePlayer());
          }
        },
      },
      child: Focus(
        // Desktop shortcuts live on [DesktopPlayerKeyboard]. Autofocus here
        // would win over the picture and leave Space / J / L dead until click.
        autofocus: !DesktopUi.enabled,
        skipTraversal: true,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (TvPlatform.isAndroidTv) {
              if (!tvRouteIsCurrent(context)) return;
              if (_tvBack.handle()) return;
            }
            unawaited(_leavePlayer());
          },
          child: SleepTimerFeedback(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _WatchBrowseScaffold(
                  video: video,
                  panel: PlayerBrowsePanel(key: _browsePanelKey),
                  onPipClose: _stopAndLeave,
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  width: 0,
                  height: 0,
                  child: const _StreamStatsLayer(),
                ),
                _CinemaOrientationBinder(
                  onOrientation: _syncCinemaForOrientation,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Drops artificial mini-player [MediaQuery] bottom padding from [child].
Widget _withoutMiniPlayerDockInset(BuildContext context, Widget child) {
  final padding = MediaQuery.paddingOf(context);
  final systemBottom = MediaQuery.viewPaddingOf(context).bottom;
  if (padding.bottom <= systemBottom + 0.5) return child;
  return MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(padding: padding.copyWith(bottom: systemBottom)),
    child: child,
  );
}

/// Watch + browse chrome. Lives in its own [InheritedWidget] subscription so
/// cinema / panel / window-size changes do not rebuild the keyed video.
class _WatchBrowseScaffold extends StatelessWidget {
  const _WatchBrowseScaffold({
    required this.video,
    required this.panel,
    required this.onPipClose,
  });

  final Widget video;
  final Widget panel;
  final Future<void> Function() onPipClose;

  @override
  Widget build(BuildContext context) {
    final chrome = context
        .select<PlaybackProvider, ({bool cinema, bool collapsed, bool pip})>(
          (p) => (
            cinema: p.cinemaMode,
            collapsed: p.browsePanelCollapsed,
            pip: p.isInPip,
          ),
        );
    final pipDesktop = context.select<PlaybackProvider, bool>(
      (p) => p.pip.usesDesktopMiniWindow,
    );
    if (chrome.pip) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            video,
            if (pipDesktop) DesktopPipChrome(onClose: onPipClose),
          ],
        ),
      );
    }

    final orientation = MediaQuery.orientationOf(context);
    final landscape = orientation == Orientation.landscape;
    final width = MediaQuery.sizeOf(context).width;
    final useSideBrowse = landscape || AdaptiveLayout.useRail(context);
    final hidePanel = chrome.cinema || chrome.collapsed;
    final picture = RepaintBoundary(child: video);
    // Channel / EPG tiles must not steal keyboard focus on desktop — otherwise
    // play/pause and ±10s stay dead until the picture is clicked.
    final browse = DesktopUi.enabled ? ExcludeFocus(child: panel) : panel;

    final Widget body;
    if (useSideBrowse) {
      // Share the row with the picture so the panel sits beside the video
      // instead of covering it. Clip via [PlayerBrowsePanelSlot] so hide/show
      // does not remount the panel (or the keyed texture).
      final extent = (DesktopUi.enabled || AdaptiveLayout.useRail(context))
          ? (width * 0.3).clamp(320.0, 420.0)
          : width * 0.42;
      body = Row(
        children: [
          Expanded(child: picture),
          PlayerBrowsePanelSlot(
            collapsed: hidePanel,
            axis: Axis.horizontal,
            extent: extent,
            child: browse,
          ),
        ],
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final openVideoH = constraints.maxWidth * 9 / 16;
          final openPanelH = (constraints.maxHeight - openVideoH).clamp(
            0.0,
            constraints.maxHeight,
          );
          final videoH = hidePanel
              ? constraints.maxHeight
              : openVideoH.clamp(0.0, constraints.maxHeight);
          return Column(
            children: [
              SizedBox(
                height: videoH,
                width: constraints.maxWidth,
                child: picture,
              ),
              PlayerBrowsePanelSlot(
                collapsed: hidePanel,
                axis: Axis.vertical,
                extent: openPanelH,
                child: browse,
              ),
            ],
          );
        },
      );
    }

    return _withoutMiniPlayerDockInset(
      context,
      Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          left: !chrome.cinema,
          top: !chrome.cinema,
          right: !chrome.cinema,
          bottom: !chrome.cinema,
          child: body,
        ),
      ),
    );
  }
}

/// Subscribes to orientation without rebuilding [PlayerScreen] / the video.
class _CinemaOrientationBinder extends StatelessWidget {
  const _CinemaOrientationBinder({required this.onOrientation});

  final void Function(Orientation orientation) onOrientation;

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.orientationOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onOrientation(orientation);
    });
    return const Positioned(
      left: 0,
      top: 0,
      width: 0,
      height: 0,
      child: SizedBox.shrink(),
    );
  }
}

/// Stats live in the navigator [Overlay] so toggling them does not relayout
/// the keyed video (a sibling [Positioned] in the player [Stack] did).
class _StreamStatsLayer extends StatefulWidget {
  const _StreamStatsLayer();

  @override
  State<_StreamStatsLayer> createState() => _StreamStatsLayerState();
}

class _StreamStatsLayerState extends State<_StreamStatsLayer> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_portal.isShowing) _portal.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Do not select [showStreamStats] here — rebuilding OverlayPortal
    // re-inserts the overlay entry and hitches the keyed video.
    final playback = context.read<PlaybackProvider>();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        if (!AppCapabilities.usesMediaKit) return const SizedBox.shrink();
        return Positioned(
          left: 12,
          top: 12,
          child: ChangeNotifierProvider<PlaybackProvider>.value(
            value: playback,
            child: _StreamStatsGate(player: playback.player),
          ),
        );
      },
      child: const SizedBox.shrink(),
    );
  }
}

/// Own subscription so toggling stats does not rebuild [OverlayPortal].
class _StreamStatsGate extends StatelessWidget {
  const _StreamStatsGate({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    final show = context.select<PlaybackProvider, bool>(
      (p) => p.showStreamStats,
    );
    return IgnorePointer(
      child: Offstage(
        offstage: !show,
        child: StreamStatsOverlay(player: player),
      ),
    );
  }
}

/// Minimized `/player` after the user left — drop the keyed texture so the
/// mini dock can attach it, then pop. Arriving from mini paints watch+browse
/// instead (see [playerPaintsWatchBrowseOnArrival]).
class _MinimizedPlayerHandoff extends StatelessWidget {
  const _MinimizedPlayerHandoff({
    required this.sessionHandedOff,
    required this.onLeave,
    required this.onHandOff,
  });

  final bool sessionHandedOff;
  final VoidCallback onLeave;
  final VoidCallback onHandOff;

  @override
  Widget build(BuildContext context) {
    if (sessionHandedOff) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onLeave());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final p = context.read<PlaybackProvider>();
        if (!p.isMinimized || p.isOpening || p.isLoading) return;
        onHandOff();
        onLeave();
      });
    }
    return const SizedBox.shrink();
  }
}

/// Spinner lives outside [PlayerScreen]'s select so a channel zap does not
/// rebuild the keyed video / cinema scaffold (that hitch felt like maximize).
class _PlayerLoadingLayer extends StatelessWidget {
  const _PlayerLoadingLayer();

  @override
  Widget build(BuildContext context) {
    final show = context.select<PlaybackProvider, bool>(
      (p) => p.isLoading && p.error == null,
    );
    final playback = context.read<PlaybackProvider>();
    return Positioned.fill(
      child: !show
          ? const SizedBox.shrink()
          : IgnorePointer(
              child: Center(
                child: PlayerLoadingBadge(
                  key: PlayerLoadingBadge.overlayKey,
                  label: PlayerLoadingBadge.labelFor(context, playback),
                  artworkUrl: PlayerLoadingBadge.artworkFor(playback),
                ),
              ),
            ),
    );
  }
}
