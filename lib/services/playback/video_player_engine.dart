import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Lightweight HTTP/HLS playback for Tizen / webOS via `video_player`.
///
/// Not a feature peer of media_kit: no libass captions, limited track picking,
/// and codec support is whatever the TV OEM player exposes.
class VideoPlayerEngine {
  VideoPlayerController? _controller;
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();

  VoidCallback? _listener;
  bool _wasCompleted = false;
  double _rate = 1.0;

  VideoPlayerController? get controller => _controller;

  Stream<bool> get playingStream => _playing.stream;
  Stream<bool> get bufferingStream => _buffering.stream;
  Stream<Duration> get positionStream => _position.stream;
  Stream<Duration> get durationStream => _duration.stream;
  Stream<bool> get completedStream => _completed.stream;
  Stream<String> get errorStream => _error.stream;

  bool get playing => _controller?.value.isPlaying ?? false;
  bool get buffering => _controller?.value.isBuffering ?? false;
  Duration get position => _controller?.value.position ?? Duration.zero;
  Duration get duration => _controller?.value.duration ?? Duration.zero;

  /// Furthest end of any buffered range (classical “loaded” scrub extent).
  Duration get buffer {
    final ranges = _controller?.value.buffered;
    if (ranges == null || ranges.isEmpty) return Duration.zero;
    var end = Duration.zero;
    for (final range in ranges) {
      if (range.end > end) end = range.end;
    }
    return end;
  }

  double get rate => _rate;

  Future<void> open(
    String url, {
    Map<String, String>? httpHeaders,
    bool play = true,
  }) async {
    await dispose();
    _wasCompleted = false;
    final uri = Uri.parse(url);
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: httpHeaders ?? const {},
    );
    _controller = controller;
    _listener = () => _onTick(controller);
    controller.addListener(_listener!);
    try {
      await controller.initialize();
      _duration.add(controller.value.duration);
      if (play) {
        await controller.play();
      }
      _playing.add(controller.value.isPlaying);
    } catch (e, st) {
      debugPrint('VideoPlayerEngine open failed: $e\n$st');
      _error.add(e.toString());
      rethrow;
    }
  }

  void _onTick(VideoPlayerController controller) {
    if (!identical(_controller, controller)) return;
    final v = controller.value;
    if (v.hasError) {
      final msg = v.errorDescription ?? 'Playback error';
      _error.add(msg);
    }
    _playing.add(v.isPlaying);
    _buffering.add(v.isBuffering);
    _position.add(v.position);
    if (v.duration > Duration.zero) {
      _duration.add(v.duration);
    }
    final ended = v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 400) &&
        !v.isPlaying;
    if (ended && !_wasCompleted) {
      _wasCompleted = true;
      _completed.add(true);
    } else if (!ended) {
      _wasCompleted = false;
    }
  }

  Future<void> play() async => _controller?.play();

  Future<void> pause() async => _controller?.pause();

  Future<void> togglePlayPause() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
  }

  Future<void> seek(Duration position) async {
    final c = _controller;
    if (c == null) return;
    await c.seekTo(position);
  }

  Future<void> setRate(double rate) async {
    _rate = rate;
    await _controller?.setPlaybackSpeed(rate);
  }

  Future<void> stop() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
      await c.seekTo(Duration.zero);
    } catch (_) {}
  }

  Widget buildView({BoxFit fit = BoxFit.contain}) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    final size = c.value.size;
    final aspect = size.width > 0 && size.height > 0
        ? size.width / size.height
        : 16 / 9;
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width > 0 ? size.width : 1920,
          height: size.height > 0 ? size.height : 1080,
          child: AspectRatio(
            aspectRatio: aspect,
            child: VideoPlayer(c),
          ),
        ),
      ),
    );
  }

  Future<void> dispose() async {
    final c = _controller;
    final listener = _listener;
    _controller = null;
    _listener = null;
    if (c != null) {
      if (listener != null) c.removeListener(listener);
      await c.dispose();
    }
  }

  Future<void> closeStreams() async {
    await _playing.close();
    await _buffering.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
    await _error.close();
  }
}
