import 'package:flutter/material.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/library_provider.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/services/platform/external_player.dart';
import 'package:provider/provider.dart';

/// Pause in-app playback and open the current (or given) stream externally.
Future<void> openCurrentInExternalPlayer(
  BuildContext context, {
  MediaItem? item,
  String? playUrl,
}) async {
  final playback = context.read<PlaybackProvider>();
  final library = context.read<LibraryProvider>();
  final target = item ?? playback.item;
  var url = (playUrl ?? playback.currentPlayUrl ?? target?.playUrl)?.trim();
  // Xtream catalog URLs are stored without panel credentials; inject before
  // handing off so external players get an authenticated stream.
  if (target != null &&
      target.origin == MediaOrigin.iptvXtream &&
      url != null &&
      url.isNotEmpty) {
    url = library.resolveXtreamStreamUrl(target.copyWith(playUrl: url));
  }
  if (target == null || url == null || !ExternalPlayer.canOpenUrl(url)) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.externalPlayerFailed)));
    return;
  }

  if (playback.playing) {
    await playback.togglePlayPause();
  }

  final result = await ExternalPlayer.open(url: url, title: target.title);
  if (!context.mounted) return;

  switch (result) {
    case ExternalPlayerLaunch.opened:
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.externalPlayerNoProgress)),
      );
    case ExternalPlayerLaunch.failed:
    case ExternalPlayerLaunch.unavailable:
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.externalPlayerFailed)),
      );
  }
}
