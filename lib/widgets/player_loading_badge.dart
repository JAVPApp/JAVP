import 'package:flutter/material.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/providers/locale_controller.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/widgets/javp_art.dart';

/// Single open/buffer affordance for PlayerScreen / TV live.
///
/// Keep one instance mounted for the whole [PlaybackProvider.isLoading]
/// stretch: only the [label] text changes (Résolution → Chargement). The
/// spinner child is const so Flutter does not remount / restart it.
///
/// Live / radio load states paint the channel logo *inside* the spinner so
/// the two sit on one layer instead of the ring covering a separate icon.
class PlayerLoadingBadge extends StatelessWidget {
  const PlayerLoadingBadge({super.key, this.label, this.artworkUrl});

  /// Stable identity across open-path rebuilds (label updates only).
  static const overlayKey = ValueKey<String>('player-loading-badge');

  final String? label;

  /// Channel logo (or radio art) drawn in the same slot as the spinner.
  final String? artworkUrl;

  /// Label for the current loading phase — never null while [playback.isLoading]
  /// so the badge never swaps to an anonymous spinner style.
  static String labelFor(BuildContext context, PlaybackProvider playback) {
    if (playback.isResolvingTorrent) {
      return context.l10n.resolvingEllipsis;
    }
    return context.l10n.loadingEllipsis;
  }

  /// Channel / station art for the loading badge. VOD posters stay out so
  /// movie open chrome does not shrink a poster into the spinner.
  static String? artworkFor(PlaybackProvider playback) {
    return artworkForItem(
      playback.liveChannel ?? playback.item,
      audioOnly: playback.isAudioOnly,
    );
  }

  /// Pure helper for tests — [item] is the live channel or current title.
  static String? artworkForItem(MediaItem? item, {bool audioOnly = false}) {
    if (item == null) return null;
    final liveLike =
        item.isLive ||
        item.kind == MediaKind.catchup ||
        audioOnly ||
        item.isAudioOnly;
    if (!liveLike) return null;
    final logo = item.thumbnailUrl?.trim();
    if (logo != null && logo.isNotEmpty) return logo;
    final art = item.artUrl?.trim();
    if (art != null && art.isNotEmpty) return art;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final text = label?.trim();
    final hasLabel = text != null && text.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PlayerLoadingMark(artworkUrl: artworkUrl),
        // Fixed-height slot: text swaps in place without shifting the spinner.
        SizedBox(
          height: 36,
          child: hasLabel
              ? Align(
                  alignment: Alignment.bottomCenter,
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

class _PlayerLoadingMark extends StatelessWidget {
  const _PlayerLoadingMark({this.artworkUrl});

  final String? artworkUrl;

  static const _size = 52.0;
  static const _artSize = 34.0;

  @override
  Widget build(BuildContext context) {
    final art = artworkUrl?.trim();
    final hasArt = art != null && art.isNotEmpty;
    if (!hasArt) return const _PlayerLoadingSpinner();

    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: _artSize,
              height: _artSize,
              child: JavpArt(
                url: art,
                fit: BoxFit.contain,
                decodeWidth: 72,
                fadeIn: false,
                fallback: const SizedBox.shrink(),
              ),
            ),
          ),
          const _PlayerLoadingSpinner(),
        ],
      ),
    );
  }
}

class _PlayerLoadingSpinner extends StatelessWidget {
  const _PlayerLoadingSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 52,
      height: 52,
      child: CircularProgressIndicator(
        strokeWidth: 3.2,
        color: Colors.white,
        backgroundColor: Colors.white24,
      ),
    );
  }
}
