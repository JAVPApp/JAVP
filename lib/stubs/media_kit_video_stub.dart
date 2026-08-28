/// Web stub for media_kit_video — no-op implementations.
library media_kit_video_stub;

import 'package:flutter/widgets.dart';
import 'package:javp/stubs/media_kit_stub.dart';

export 'package:javp/stubs/media_kit_stub.dart';

class VideoController {
  VideoController(
    this.player, {
    VideoControllerConfiguration? configuration,
  });

  final Player player;
  int get id => 0;
  Rect get rect => Rect.zero;

  Future<void> waitUntilFirstFrameRendered() async {}
  Future<void> setSize({int? width, int? height}) async {}
}

class VideoControllerConfiguration {
  const VideoControllerConfiguration({
    this.enableHardwareAcceleration = true,
    this.width,
    this.height,
    this.vo,
    this.hwdec,
    this.androidAttachSurfaceAfterVideoParameters = true,
  });

  final bool enableHardwareAcceleration;
  final int? width;
  final int? height;
  final String? vo;
  final String? hwdec;
  final bool androidAttachSurfaceAfterVideoParameters;
}

/// Minimal stand-in for media_kit_video's [VideoState] (only `.context` is used).
class VideoState {
  VideoState(this.context);
  final BuildContext context;
}

class Video extends StatelessWidget {
  const Video({
    super.key,
    this.controller,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.fill = const Color(0xFF000000),
    this.alignment = Alignment.center,
    this.aspectRatio,
    this.filterQuality = FilterQuality.low,
    this.controls,
    this.subtitleViewConfiguration,
    this.wakelock = true,
    this.pauseUponEnteringBackgroundMode = true,
    this.resumeUponEnteringForegroundMode = false,
    this.onEnterFullscreen,
    this.onExitFullscreen,
  });

  final VideoController? controller;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Color fill;
  final Alignment alignment;
  final double? aspectRatio;
  final FilterQuality filterQuality;
  final Widget Function(VideoState)? controls;
  final SubtitleViewConfiguration? subtitleViewConfiguration;
  final bool wakelock;
  final bool pauseUponEnteringBackgroundMode;
  final bool resumeUponEnteringForegroundMode;
  final Future<void> Function()? onEnterFullscreen;
  final Future<void> Function()? onExitFullscreen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(color: fill),
    );
  }
}

class SubtitleViewConfiguration {
  const SubtitleViewConfiguration({
    this.style,
    this.textAlign,
    this.padding,
    this.visible = true,
  });

  final TextStyle? style;
  final TextAlign? textAlign;
  final EdgeInsets? padding;
  final bool visible;
}

/// Real media_kit_video uses `const NoVideoControls = null`.
const dynamic NoVideoControls = null;
