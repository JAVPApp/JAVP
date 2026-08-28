import 'package:flutter/material.dart';
import 'package:javp/models/video_aspect_mode.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:provider/provider.dart';

/// Sizes the keyed video texture without changing media_kit [Video.fit].
///
/// The child must paint with [BoxFit.fill]. This widget owns the
/// [PlaybackProvider.videoAspectMode] subscription so PlayerScreen does not
/// rebuild the controls / GlobalKey [Video] when the user toggles aspect.
class VideoAspectLayout extends StatelessWidget {
  const VideoAspectLayout({super.key, required this.child, this.lock});

  final Widget child;

  /// Mini dock / PiP: ignore the session aspect preference.
  final VideoAspectMode? lock;

  @override
  Widget build(BuildContext context) {
    final mode =
        lock ??
        context.select<PlaybackProvider, VideoAspectMode>(
          (p) => p.videoAspectMode,
        );
    final frame = context.select<PlaybackProvider, (int, int)>(
      (p) => (p.videoFrameWidth, p.videoFrameHeight),
    );
    final contentAspect = frame.$1 > 0 && frame.$2 > 0
        ? frame.$1 / frame.$2
        : 16 / 9;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = mode.destinationRect(
          viewport,
          contentAspect: contentAspect,
        );
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
                child: child,
              ),
            ],
          ),
        );
      },
    );
  }
}
