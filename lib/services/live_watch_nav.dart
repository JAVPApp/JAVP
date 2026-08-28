import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/tv_platform.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/widgets/live_quality_picker.dart';
import 'package:provider/provider.dart';

/// Live playback entry: Android TV fullscreen zapper, phone `/player`.
///
/// Catchup / VOD should keep using `/player` directly.
///
/// Quality uses the global live rule (Auto by default). Ask mode may prompt
/// once per family. On TV we **await** [PlaybackProvider.open] before navigating
/// so [TvLiveOverlayScreen] bootstrap does not race and retune the first
/// channel in its zap list. [expand] is true so the corner mini player does
/// not paint on the channel list while `/tv/watch` is pushing.
///
/// Uses [GoRouter.push] (not [GoRouter.go]) so opening from Home keeps Accueil
/// under the fullscreen route — Back returns there instead of flashing Direct.
Future<void> openLivePlayback(BuildContext context, MediaItem item) async {
  final library = context.read<LibraryProvider>();
  final channel = await promptLiveQualityIfNeeded(context, item);
  if (!context.mounted) return;

  if (TvPlatform.isAndroidTv && channel.isLive) {
    final playback = context.read<PlaybackProvider>();
    // The tile that started this can be rebuilt away while the stream opens,
    // so hold the router instead of reading it from a stale element.
    final router = GoRouter.of(context);
    final resolved = await library.resolveLiveChannelAsync(channel);
    await playback.open(resolved, expand: true);
    // Replace an existing zapper if already open; otherwise push so the prior
    // shell tab (Home / Live list) stays on the stack.
    final loc = router.routerDelegate.currentConfiguration.uri.path;
    if (loc == '/tv/watch') {
      router.go('/tv/watch');
    } else {
      router.push('/tv/watch');
    }
    return;
  }
  final playback = context.read<PlaybackProvider>();
  if (playback.hasSession && playback.isMinimized) {
    playback.applyIncomingPlayerChrome();
  }
  context.push('/player', extra: channel);
}
