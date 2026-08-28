import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:javp/models/media_item.dart';
import 'package:javp/platform/app_capabilities.dart';
import 'package:javp/compat/media_kit.dart';
import 'package:javp/compat/media_kit_video.dart';

/// Lightweight second media_kit handle for multi-view live.
///
/// Intentionally thin vs [PlaybackProvider]: no DVR, captions, Cast, or history.
/// [MultiViewProvider.exit] calls [dispose] so the second decoder does not sit
/// warm in RAM after multi-view closes.
class SecondaryLivePlayer {
  Player? _player;
  VideoController? _controller;
  MediaItem? _channel;
  String? _error;
  int _revision = 0;

  Player? get player => _player;
  VideoController? get controller => _controller;
  MediaItem? get channel => _channel;
  String? get error => _error;
  bool get hasSession => _player != null && _channel != null;
  int get revision => _revision;

  static const _defaultHttpHeaders = {'User-Agent': 'JAVP', 'Accept': '*/*'};

  Map<String, String>? _headersFor(MediaItem channel, Map<String, String>? extra) {
    final url = channel.playUrl;
    final remoteHttp =
        url.startsWith('http://') || url.startsWith('https://');
    if (!remoteHttp) {
      if (channel.httpHeaders.isEmpty && (extra == null || extra.isEmpty)) {
        return null;
      }
      return {...channel.httpHeaders, ...?extra};
    }
    return {
      ..._defaultHttpHeaders,
      ...channel.httpHeaders,
      ...?extra,
    };
  }

  Future<void> open(
    MediaItem channel, {
    Map<String, String>? httpHeaders,
    double volume = 0,
  }) async {
    if (!AppCapabilities.multiView) {
      throw UnsupportedError('Multi-view is not available on this platform');
    }
    _error = null;
    _channel = channel;
    _ensureEngine();
    final player = _player!;
    try {
      await player.open(
        Media(
          channel.playUrl,
          httpHeaders: _headersFor(channel, httpHeaders),
        ),
        play: true,
      );
      await player.setVolume(volume.clamp(0.0, 100.0));
    } catch (e, st) {
      debugPrint('SecondaryLivePlayer open failed: $e\n$st');
      _error = e.toString();
      rethrow;
    }
  }

  Future<void> setVolume(double volume) async {
    final player = _player;
    if (player == null) return;
    try {
      await player.setVolume(volume.clamp(0.0, 100.0));
    } catch (e) {
      debugPrint('SecondaryLivePlayer setVolume failed: $e');
    }
  }

  Future<void> pause() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.pause();
    } catch (e) {
      debugPrint('SecondaryLivePlayer pause failed: $e');
    }
  }

  Future<void> play() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.play();
    } catch (e) {
      debugPrint('SecondaryLivePlayer play failed: $e');
    }
  }

  Future<void> stop() async {
    _channel = null;
    _error = null;
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _channel = null;
    _error = null;
    final player = _player;
    _player = null;
    _controller = null;
    if (player == null) return;
    try {
      await player.dispose();
    } catch (e) {
      debugPrint('SecondaryLivePlayer dispose failed: $e');
    }
    _revision++;
  }

  void _ensureEngine() {
    if (_player != null) return;
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        libass: false,
        title: 'JAVP Multi-view',
      ),
    );
    _player = player;
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        hwdec: 'auto-safe',
      ),
    );
    _revision++;
    unawaited(_configureSeekability(player));
    unawaited(_configureHls(player));
  }

  Future<void> _configureSeekability(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('force-seekable', 'yes');
    } catch (_) {}
  }

  Future<void> _configureHls(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('demuxer-lavf-o', 'extension_picky=0');
    } catch (_) {}
  }
}
