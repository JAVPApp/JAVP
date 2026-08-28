import 'package:flutter/material.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/providers/playback_provider.dart';
import 'package:javp/models/video_aspect_mode.dart';
import 'package:javp/widgets/audio_only_stage.dart';
import 'package:javp/widgets/player/video_aspect_layout.dart';
import 'package:javp/compat/media_kit_video.dart';

/// Video plane for the active playback backend (media_kit or video_player).
class PlaybackVideoSurface extends StatelessWidget {
  const PlaybackVideoSurface({
    super.key,
    required this.playback,
    this.fit = BoxFit.contain,
    this.aspectLock,
    this.controls,
    this.subtitleViewConfiguration,
    this.pauseUponEnteringBackgroundMode = false,
    this.resumeUponEnteringForegroundMode = false,
  });

  /// Full player, live overlay, and mini dock share [PlaybackProvider.videoSurfaceKey]
  /// on the inner texture so minimize reparents media_kit [Video] instead of
  /// destroying it.
  ///
  /// The key is **not** on this wrapper: player chrome must not travel with
  /// the texture. media_kit's `VideoViewParameters.copyWith` treats
  /// [NoVideoControls] (`null`) as "keep previous", so a keyed [Video] that
  /// once hosted [controls] keeps them on the mini dock (hover wakes the
  /// fullscreen overlay).
  ///
  /// Only one widget may mount the keyed texture in a given frame —
  /// [PlaybackProvider.fullPlayerOwnsVideo] is the exclusive lock.
  static PlaybackVideoSurface forSession(
    PlaybackProvider playback, {
    BoxFit fit = BoxFit.contain,
    VideoAspectMode? aspectLock,
    Widget Function(BuildContext context)? controls,
    SubtitleViewConfiguration? subtitleViewConfiguration,
    bool pauseUponEnteringBackgroundMode = false,
    bool resumeUponEnteringForegroundMode = false,
  }) {
    return PlaybackVideoSurface(
      playback: playback,
      fit: fit,
      aspectLock: aspectLock,
      controls: controls,
      subtitleViewConfiguration: subtitleViewConfiguration,
      pauseUponEnteringBackgroundMode: pauseUponEnteringBackgroundMode,
      resumeUponEnteringForegroundMode: resumeUponEnteringForegroundMode,
    );
  }

  final PlaybackProvider playback;
  final BoxFit fit;

  /// Mini dock / cover thumb: ignore [PlaybackProvider.videoAspectMode].
  final VideoAspectMode? aspectLock;

  /// Optional chrome drawn above the video (both backends).
  ///
  /// Always a sibling of the keyed texture — never a media_kit [Video.controls]
  /// builder — so minimize cannot reparent it onto the mini dock.
  final Widget Function(BuildContext context)? controls;

  /// media_kit only — ignored on the video_player backend.
  final SubtitleViewConfiguration? subtitleViewConfiguration;

  /// media_kit lifecycle pause. Kept off so PiP is not frozen: Android
  /// `onPause` fires before `onPictureInPictureModeChanged`. AFK pause is
  /// [PlaybackProvider.onAppBackgrounded], which skips PiP.
  final bool pauseUponEnteringBackgroundMode;
  final bool resumeUponEnteringForegroundMode;

  @override
  Widget build(BuildContext context) {
    return _buildPlane(context);
  }

  Widget _buildPlane(BuildContext context) {
    final audioOnly = playback.isAudioOnly;
    final item = playback.item ?? playback.liveChannel;
    final texture = VideoAspectLayout(
      lock: aspectLock,
      child: _keyedTexture(),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        texture,
        if (audioOnly && item != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AudioOnlyStage(item: item, compact: fit == BoxFit.cover),
            ),
          ),
        if (controls != null)
          Positioned.fill(child: Builder(builder: controls!)),
      ],
    );
  }

  /// The only widget that carries [PlaybackProvider.videoSurfaceKey].
  ///
  /// Always [BoxFit.fill]: the parent [VideoAspectLayout] sizes this plane.
  /// Changing [Video.fit] / [Video.aspectRatio] hitches the native view.
  Widget _keyedTexture() {
    if (AppCapabilities.usesVideoPlayerBackend) {
      return KeyedSubtree(
        key: playback.videoSurfaceKey,
        child: playback.buildVideoSurface(fit: BoxFit.fill),
      );
    }
    return Video(
      key: playback.videoSurfaceKey,
      controller: playback.controller,
      fit: BoxFit.fill,
      pauseUponEnteringBackgroundMode: pauseUponEnteringBackgroundMode,
      resumeUponEnteringForegroundMode: resumeUponEnteringForegroundMode,
      subtitleViewConfiguration:
          subtitleViewConfiguration ?? const SubtitleViewConfiguration(),
      controls: NoVideoControls,
    );
  }
}
