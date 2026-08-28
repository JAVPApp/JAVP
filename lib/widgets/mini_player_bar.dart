import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/widgets/javp_art.dart';
import 'package:javp/l10n/app_localizations.dart';
import 'package:javp/l10n/ui_copy_l10n.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/models/video_aspect_mode.dart';
import 'package:javp/platform/adaptive_layout.dart';
import 'package:javp/platform/app_layout.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/theme/app_theme.dart';
import 'package:javp/widgets/playback_video_surface.dart';
import 'package:javp/widgets/tv/tv_channel_logo.dart';
import 'package:javp/widgets/tv/tv_corner_mini_player.dart';
import 'package:javp/widgets/tv/tv_focusable.dart';
import 'package:provider/provider.dart';

/// Progress strip + 64px row — keep in sync with [MiniPlayerBar] layout.
const double kMiniPlayerBarHeight = 66;

/// Shell tab paths (bottom nav / desktop rail hosts these).
bool isShellTabPath(String path) {
  return path == '/home' ||
      path == '/tv' ||
      path == '/catalog' ||
      path == '/music' ||
      path == '/library' ||
      path == '/settings' ||
      path.startsWith('/settings/');
}

/// Routes where the overlay dock is owned elsewhere (or must stay full-bleed).
bool _miniPlayerOverlayExcluded({required String path}) {
  if (path == '/tv/watch') return true;
  // Full player owns the window — reserve no dock band (cinema / expanded).
  if (path == '/player' || path == '/cast') return true;
  // Phone bottom-nav and desktop/tablet rail shells own the dock so collapsing
  // /player does not re-inset the navigator (that relayout stuttered Home).
  // Inflating padding here on the phone column would also slide the tab bar
  // under the mini bar.
  if (isShellTabPath(path)) return true;
  return false;
}

/// Whether [PersistentMiniPlayer] should physically inset the navigator above
/// the mini dock (so sheets/SafeAreas clear the bar).
///
/// Only while the mini bar is actually shown. Reserving space for the whole
/// session left a dead dock band under expanded / cinema playback (Windows
/// fullscreen black strip). Idle and expanded routes stay full-bleed.
bool shouldInflateMiniPlayerMediaQuery({
  required String path,
  required bool hasSession,
  required bool useRail,
  required bool minimized,
}) {
  if (!hasSession || !minimized) return false;
  if (TvPlatform.isAndroidTv) return false;
  if (_miniPlayerOverlayExcluded(path: path)) return false;
  return true;
}

/// MediaQuery for the navigator sitting above a [dockHeight] band.
///
/// The dock is already clipped out of the child's box, so the IME overlap that
/// still covers the child is `viewInsets.bottom - dockHeight`, not the
/// full-window inset. Passing the full inset through (and shrinking [size] by
/// the dock) double-counts the dock and leaves a gap after the keyboard closes.
MediaQueryData mediaQueryAboveMiniPlayerDock({
  required MediaQueryData parent,
  required double dockHeight,
  Size? childSize,
}) {
  final width = childSize?.width ?? parent.size.width;
  final height =
      childSize?.height ??
      (parent.size.height - dockHeight).clamp(0.0, double.infinity);
  final innerKeyboard = (parent.viewInsets.bottom - dockHeight).clamp(
    0.0,
    double.infinity,
  );
  return parent.copyWith(
    size: Size(width, height),
    padding: parent.padding.copyWith(bottom: 0),
    viewPadding: parent.viewPadding.copyWith(bottom: 0),
    viewInsets: parent.viewInsets.copyWith(bottom: innerKeyboard),
  );
}

/// Whether [PersistentMiniPlayer] should paint the mini bar overlay.
bool shouldHostMiniPlayerDock({
  required String path,
  required bool minimized,
  required bool useRail,
}) {
  if (!minimized) return false;
  if (_miniPlayerOverlayExcluded(path: path)) return false;
  return true;
}

/// Full-player route the mini dock should restore.
///
/// Live on Android TV uses the set-top zapper, not `/player`. In-session DVR
/// (the item becomes catchup) still belongs on that overlay.
/// An active Cast session opens the remote instead of expanding local video.
String miniPlayerRestorePath(
  MediaItem item, {
  bool casting = false,
  bool liveSession = false,
}) {
  if (casting) return '/cast';
  if (TvPlatform.isAndroidTv && (item.isLive || liveSession)) {
    return '/tv/watch';
  }
  return '/player';
}

/// Extra space under the last TV row so the corner PIP does not cover it.
class MiniPlayerScrollClearance extends StatelessWidget {
  const MiniPlayerScrollClearance({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: miniPlayerScrollBottomInset(context));
  }
}

/// Bottom inset for browse lists. Grows while the TV corner mini player is up.
double miniPlayerScrollBottomInset(BuildContext context) {
  final tvMini =
      TvPlatform.isAndroidTv &&
      context.select<PlaybackProvider, bool>((p) => p.isMinimized);
  return AppLayout.scrollBottomInset(tvMiniPlayerVisible: tvMini);
}

/// Push the Cast remote. Replaces `/player` so Back returns to browse.
void pushCastRemote(GoRouter go) {
  final path = go.routerDelegate.currentConfiguration.uri.path;
  if (path == '/cast') return;
  if (path == '/player') {
    go.pushReplacement('/cast');
    return;
  }
  go.push('/cast');
}

/// Minimize the local player and open the Cast remote (session stays up).
///
/// Navigate first so `/player` never paints a minimized blank frame.
Future<void> handOffPlayerToCastRemote(BuildContext context) async {
  if (!context.mounted) return;
  final playback = context.read<PlaybackProvider>();
  unawaited(playback.minimize());
  if (!context.mounted) return;
  pushCastRemote(GoRouter.of(context));
}

/// Push the full player from the mini dock.
void pushMiniPlayerRestore(GoRouter go, PlaybackProvider playback) {
  final item = playback.item;
  if (item == null) return;
  if (playback.isCasting) {
    pushCastRemote(go);
    return;
  }
  // Expand chrome before the route mounts so `/player`'s first paint is
  // watch+browse (not a full-bleed AppBar hop). Claim the texture in the
  // same turn so Mini and PlayerScreen never share [videoSurfaceKey].
  playback.applyIncomingPlayerChrome();
  playback.claimVideoSurface();
  if (TvPlatform.isAndroidTv &&
      (item.isLive || playback.liveChannel != null)) {
    go.push('/tv/watch');
    return;
  }
  go.push('/player', extra: item);
}

/// Mini player dock for routes *outside* the phone bottom-nav shell.
///
/// Phone shell tabs host [MiniPlayerBar] in [ShellScreen]'s
/// [Scaffold.bottomNavigationBar] column so the tab bar keeps its own
/// [SafeArea] and stays visible. Insetting the navigator here on those tabs
/// would shrink the shell and fight that column layout.
///
/// Root routes (`/title`, `/series`, `/search`, `/sources`, …) and rail
/// layouts dock under a physically shorter navigator so modal sheets stay
/// above the bar (Save / Add source actions remain tappable).
///
/// Uses a deferred [GoRouterDelegate] listener instead of [ListenableBuilder]:
/// mounting the navigator notifies the delegate mid-build, and a synchronous
/// setState there trips Flutter's `!_dirty` assert (debug-only) and cascades
/// into navigator GlobalKey failures.
class PersistentMiniPlayer extends StatefulWidget {
  const PersistentMiniPlayer({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget? child;

  @override
  State<PersistentMiniPlayer> createState() => _PersistentMiniPlayerState();
}

class _PersistentMiniPlayerState extends State<PersistentMiniPlayer> {
  var _routeFrameScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onRouteChanged);
  }

  @override
  void didUpdateWidget(covariant PersistentMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router.routerDelegate == widget.router.routerDelegate) {
      return;
    }
    oldWidget.router.routerDelegate.removeListener(_onRouteChanged);
    widget.router.routerDelegate.addListener(_onRouteChanged);
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  void _onRouteChanged() {
    if (!mounted || _routeFrameScheduled) return;
    _routeFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeFrameScheduled = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.child ?? const SizedBox.shrink();
    final config = widget.router.routerDelegate.currentConfiguration;
    if (config.matches.isEmpty) return page;

    return _PersistentMiniPlayerBody(
      router: widget.router,
      path: config.uri.path,
      child: page,
    );
  }
}

class _PersistentMiniPlayerBody extends StatefulWidget {
  const _PersistentMiniPlayerBody({
    required this.router,
    required this.path,
    required this.child,
  });

  final GoRouter router;
  final String path;
  final Widget child;

  @override
  State<_PersistentMiniPlayerBody> createState() =>
      _PersistentMiniPlayerBodyState();
}

class _PersistentMiniPlayerBodyState extends State<_PersistentMiniPlayerBody> {
  final _expandFocus = FocusNode(
    debugLabel: 'miniPlayerExpand',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void dispose() {
    _expandFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSession = context.select<PlaybackProvider, bool>(
      (p) => p.hasSession && !p.isInPip,
    );
    final minimized = context.select<PlaybackProvider, bool>(
      (p) => p.isMinimized,
    );
    final useRail = AdaptiveLayout.useRail(context);
    // Inflate and paint stay locked together: never reserve an empty dock band
    // under expanded / cinema (that was the Windows fullscreen black strip).
    final paintDock = shouldHostMiniPlayerDock(
      path: widget.path,
      minimized: minimized,
      useRail: useRail,
    );
    final inflate = shouldInflateMiniPlayerMediaQuery(
      path: widget.path,
      hasSession: hasSession,
      useRail: useRail,
      minimized: minimized,
    );
    if (!paintDock) {
      return widget.child;
    }

    if (TvPlatform.isAndroidTv) {
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: TvCornerMiniPlayer(
              child: MiniPlayerBar(
                router: widget.router,
                expandFocusNode: _expandFocus,
              ),
            ),
          ),
        ],
      );
    }

    if (!inflate) {
      return widget.child;
    }

    final mq = MediaQuery.of(context);
    final safeBottom = mq.viewPadding.bottom;
    final tvInset = TvPlatform.isAndroidTv ? AppLayout.tvOverscan : 0.0;
    // The dock's own SafeArea already absorbs [safeBottom], so the space it
    // occupies is bar + inset — adding padding.bottom on top double-counted the
    // system inset and left a dead band above the bar.
    final dockHeight = kMiniPlayerBarHeight + safeBottom + tvInset;

    final railInset = useRail && isShellTabPath(widget.path)
        ? AdaptiveLayout.railWidth(context)
        : 0.0;

    // Physically inset the navigator above the dock. Inflating MediaQuery
    // padding alone left the navigator overlay full-bleed, so modal sheets
    // (Manage sources → Add / Save) painted under the mini player and hid
    // their action buttons. With a shorter navigator, popups lay out above
    // the dock and stay tappable on desktop and phone root routes.
    //
    // Size comes from the Positioned box (LayoutBuilder), not
    // `mq.size.height - dock`, so a window that already shrank for the IME
    // is not shortened twice. viewInsets are reduced by [dockHeight] so the
    // keyboard is not double-counted against that shorter box.
    final insetChild = LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : (mq.size.height - dockHeight).clamp(0.0, double.infinity);
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : mq.size.width;
        return MediaQuery(
          data: mediaQueryAboveMiniPlayerDock(
            parent: mq,
            dockHeight: dockHeight,
            childSize: Size(width, height),
          ),
          child: widget.child,
        );
      },
    );

    final stack = Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: dockHeight,
          child: insetChild,
        ),
        Positioned(
          left: railInset + tvInset,
          right: tvInset,
          bottom: 0,
          height: dockHeight,
          child: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlayerBar(
                router: widget.router,
                expandFocusNode: TvPlatform.isAndroidTv ? _expandFocus : null,
              ),
            ),
          ),
        ),
      ],
    );

    return stack;
  }
}

class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({
    super.key,
    this.router,
    this.expandFocusNode,
    this.autofocusExpand = false,
  });

  /// Required when hosted above the Router (see [PersistentMiniPlayer] /
  /// [DesktopShortcuts]); shell tabs can omit and use [GoRouter.of].
  final GoRouter? router;

  /// TV overlay dock: first D-pad Down past page content lands here.
  final FocusNode? expandFocusNode;

  /// TV shell: focus the restore control when the dock first appears.
  final bool autofocusExpand;

  @override
  Widget build(BuildContext context) {
    // Identity only — position ticks must not rebuild the whole bar/surface.
    final minimized = context.select<PlaybackProvider, bool>(
      (p) => p.isMinimized,
    );
    final hasSession = context.select<PlaybackProvider, bool>(
      (p) => p.hasSession && !p.isInPip,
    );
    final itemId = context.select<PlaybackProvider, String?>((p) => p.item?.id);
    final liveId = context.select<PlaybackProvider, String?>(
      (p) => p.liveChannel?.id,
    );
    final playing = context.select<PlaybackProvider, bool>((p) => p.playing);
    final casting = context.select<PlaybackProvider, bool>((p) => p.isCasting);
    // Claim/release and a new engine must rebuild the thumb in the same frame.
    context.select<PlaybackProvider, int>(
      (p) => Object.hash(p.fullPlayerOwnsVideo, p.engineRevision),
    );
    if (itemId == null || !hasSession) {
      return const SizedBox.shrink();
    }
    // Phone shell hosts this in bottomNavigationBar. Keep the dock extent
    // while expanded (under /player) so minimize/expand does not resize the
    // Scaffold body; the bar itself only paints when minimized.
    // TV must not keep an empty band — the shell column would leave a gap.
    if (!minimized) {
      if (TvPlatform.isAndroidTv) return const SizedBox.shrink();
      return const SizedBox(height: kMiniPlayerBarHeight);
    }

    final playback = context.read<PlaybackProvider>();
    final item = playback.liveChannel ?? playback.item!;
    final library = context.read<LibraryProvider>();
    final hostVideo = miniPlayerShouldHostVideo(playback);
    final labels = () {
      final base = _miniPlayerLabels(item, playback, library, context.l10n);
      if (!casting) return base;
      return (base.$1, context.l10n.castingTo(library.cast.deviceName ?? ''));
    }();

    if (TvPlatform.isAndroidTv) {
      return _TvMiniPlayerBar(
        router: router,
        playback: playback,
        labels: labels,
        playing: playing,
        hostVideo: hostVideo,
        expandFocusNode: expandFocusNode,
        autofocusExpand: autofocusExpand,
      );
    }

    return Material(
      elevation: 8,
      color: AppColors.surfaceHigh,
      child: InkWell(
        onTap: () {
          // Prefer the injected router: MaterialApp.builder sits above
          // InheritedGoRouter, so context.push fails for the overlay dock.
          final go = router ?? GoRouter.of(context);
          pushMiniPlayerRestore(go, playback);
        },
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _MiniPlayerProgressStrip(),
              SizedBox(
                height: 64,
                // Gutter-aligned with shelves, grids and section headers so the
                // artwork sits on the same left line as the posters above it.
                // The trailing side is short by the icon buttons' own slack.
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppLayout.gutter,
                    0,
                    AppLayout.gutter - 12,
                    0,
                  ),
                  child: Row(
                    children: [
                      _miniPlayerThumb(
                        playback,
                        casting: casting,
                        hostVideo: hostVideo,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: _MiniPlayerLabels(labels: labels)),
                      IconButton(
                        // Re-read playing via key so the icon updates without a
                        // full bar rebuild from position ticks.
                        key: ValueKey('mini-pp-$itemId-$liveId-$playing'),
                        onPressed: playback.togglePlayPause,
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: AppColors.text,
                        ),
                      ),
                      IconButton(
                        onPressed: playback.stop,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
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

class _TvMiniPlayerBar extends StatelessWidget {
  const _TvMiniPlayerBar({
    required this.playback,
    required this.labels,
    required this.playing,
    required this.hostVideo,
    this.router,
    this.expandFocusNode,
    this.autofocusExpand = false,
  });

  final GoRouter? router;
  final PlaybackProvider playback;
  final (String, String) labels;
  final bool playing;
  final bool hostVideo;
  final FocusNode? expandFocusNode;
  final bool autofocusExpand;

  void _restore(BuildContext context) {
    final go = router ?? GoRouter.of(context);
    pushMiniPlayerRestore(go, playback);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = (MediaQuery.sizeOf(context).width * 0.26).clamp(240.0, 360.0);
    return Material(
      elevation: 16,
      color: AppColors.surfaceHigh,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: TvFocusable(
          focusNode: expandFocusNode,
          autofocus: autofocusExpand,
          onSelect: () => _restore(context),
          onLongSelect: playback.stop,
          borderRadius: 12,
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: hostVideo
                            ? PlaybackVideoSurface.forSession(
                                playback,
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      if (!playing)
                        const ColoredBox(
                          color: Color(0x66000000),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _MiniPlayerProgressStrip(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    if (playback.item?.isLive == true ||
                        playback.liveChannel != null) ...[
                      TvChannelLogo(
                        url:
                            playback.liveChannel?.thumbnailUrl ??
                            playback.item?.thumbnailUrl,
                        size: 40,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(child: _MiniPlayerLabels(labels: labels)),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: Text(
                  l10n.holdOkToClose,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
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

class _MiniPlayerLabels extends StatelessWidget {
  const _MiniPlayerLabels({required this.labels});

  final (String, String) labels;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          labels.$1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          labels.$2,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

/// Whether this dock may attach [PlaybackVideoSurface.forSession].
///
/// Full player and mini dock share one [PlaybackProvider.videoSurfaceKey].
/// Only host here when the full-screen route has released that key.
bool miniPlayerShouldHostVideo(PlaybackProvider playback) {
  if (playback.isCasting) return false;
  if (playback.engineRevision == 0) return false;
  if (playback.fullPlayerOwnsVideo) return false;
  return playback.isMinimized;
}

Widget _miniPlayerThumb(
  PlaybackProvider playback, {
  required bool casting,
  required bool hostVideo,
}) {
  final art =
      playback.item?.artUrlFor(portrait: false) ?? playback.item?.artUrl;
  return AspectRatio(
    aspectRatio: 16 / 9,
    child: ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          if (casting)
            JavpArt(
              url: art,
              fit: BoxFit.cover,
              decodeWidth: 160,
              fadeIn: false,
            )
          else if (hostVideo)
            PlaybackVideoSurface.forSession(
              playback,
              fit: BoxFit.cover,
              aspectLock: VideoAspectMode.zoom,
            ),
          if (casting)
            const ColoredBox(
              color: Color(0x66000000),
              child: Icon(
                Icons.cast_connected_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Progress-only strip so position notifies (~5 Hz) do not rebuild the
/// thumbnail / labels / buttons.
class _MiniPlayerProgressStrip extends StatelessWidget {
  const _MiniPlayerProgressStrip();

  @override
  Widget build(BuildContext context) {
    final progress = context.select<PlaybackProvider, double>((p) {
      final duration = p.duration;
      if (p.isAtLiveEdge) return 1.0;
      if (p.canLiveDvr) return p.liveDvrProgress;
      if (duration.inMilliseconds <= 0) return 0.0;
      return p.position.inMilliseconds / duration.inMilliseconds;
    });
    final dvrBehind = context.select<PlaybackProvider, bool>(
      (p) => p.canLiveDvr && !p.isAtLiveEdge,
    );
    return LinearProgressIndicator(
      value: progress.clamp(0.0, 1.0),
      minHeight: 2,
      backgroundColor: AppColors.border,
      color: dvrBehind ? AppColors.live : AppColors.accent,
    );
  }
}

/// `(title, subtitle)` for the mini bar — show name first for episodes.
(String, String) _miniPlayerLabels(
  MediaItem item,
  PlaybackProvider playback,
  LibraryProvider library,
  AppLocalizations l10n,
) {
  final program = playback.currentProgram;
  final fallback = item.isAudioOnly || playback.isAudioOnly
      ? l10n.radio
      : l10n.nowPlaying;
  final subtitle = localizePersistedSubtitle(l10n, item.subtitle);
  if (item.isLive || item.kind == MediaKind.catchup) {
    final secondary = program?.title ?? subtitle ?? item.group ?? fallback;
    return (library.liveOrCatchupDisplayTitle(item), secondary);
  }

  if (item.isEpisode) {
    final series = library.seriesShellForEpisode(item);
    final showFromShell = series?.title.trim();
    final showFromSubtitle = () {
      final sub = item.subtitle?.trim();
      if (sub == null || !sub.contains(' · ')) return null;
      final head = sub.split(' · ').first.trim();
      return head.isEmpty ? null : head;
    }();
    final showName = (showFromShell != null && showFromShell.isNotEmpty)
        ? showFromShell
        : showFromSubtitle;

    final sn = item.seasonNumber;
    final en = item.episodeNumber;
    final epLabel = (sn != null || en != null)
        ? 'S${(sn ?? 1).toString().padLeft(2, '0')}'
              'E${(en ?? 0).toString().padLeft(2, '0')}'
        : null;
    final epTitle = item.title.trim();
    final secondaryParts = <String>[
      ?epLabel,
      if (epTitle.isNotEmpty &&
          epTitle != epLabel &&
          (showName == null || epTitle.toLowerCase() != showName.toLowerCase()))
        epTitle,
    ];
    final secondary = secondaryParts.join(' · ');

    if (showName != null && showName.isNotEmpty) {
      return (
        showName,
        secondary.isNotEmpty
            ? secondary
            : (subtitle ?? item.group ?? l10n.nowPlaying),
      );
    }
  }

  return (
    item.title,
    program?.title ?? subtitle ?? item.group ?? l10n.nowPlaying,
  );
}
