part of '../playback_provider.dart';

extension PlaybackEngine on PlaybackProvider {
  Player get player {
    if (!AppCapabilities.usesMediaKit) {
      throw UnsupportedError(
        'media_kit Player is only available when AppCapabilities.usesMediaKit is true',
      );
    }
    _ensureEngine();
    return _player!;
  }

  VideoController get controller {
    if (!AppCapabilities.usesMediaKit) {
      throw UnsupportedError(
        'media_kit VideoController is only available when AppCapabilities.usesMediaKit is true',
      );
    }
    _ensureEngine();
    return _controller!;
  }

  Future<void> _enginePlay() async {
    if (AppCapabilities.usesVideoPlayerBackend) {
      unawaited(_vp?.play());
      return;
    }
    final player = _player;
    if (player == null) return;
    if (player.state.completed) {
      unawaited(player.play());
      return;
    }
    await _mpvSetPaused(false);
  }

  Future<void> _enginePause() async {
    if (AppCapabilities.usesVideoPlayerBackend) {
      unawaited(_vp?.pause());
      return;
    }
    await _mpvSetPaused(true);
  }

  /// Pause/resume libmpv immediately.
  ///
  /// [Player.pause] waits on media_kit's command lock and an async property
  /// ACK, so the decoder keeps rolling after a click. `mpv_set_property_string`
  /// (`pause=yes/no`) is synchronous FFI.
  Future<void> _mpvSetPaused(bool paused) async {
    final player = _player;
    if (player == null) return;
    final platform = player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty(
          'pause',
          paused ? 'yes' : 'no',
          waitForInitialization: false,
        );
        return;
      } catch (_) {}
    }
    if (paused) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _applyEnginePlaying(bool play) async {
    try {
      if (play) {
        await _enginePlay();
      } else {
        await _enginePause();
      }
    } catch (_) {
      if (_playingOverride != null) {
        _playingOverride = null;
        _notifySession();
      }
    }
  }

  void _setPlayingOverride(bool value) {
    if (_playingOverride == value) return;
    _playingOverride = value;
    _notifySession();
  }

  void _onEnginePlayingChanged(bool playing) {
    if (_playingOverride != null) {
      if (_playingOverride != playing) return;
      _playingOverride = null;
    }
    if (playing) {
      _maybeMarkPlaybackActuallyStarted();
      _resetAudioDecodeErrorTracking();
    } else if (_position > Duration.zero) {
      _onInitialPlaybackStarted();
    }
    _notifySession();
    unawaited(_pip.setPlaying(playing));
    _reportServerProgress(isPaused: !playing, force: true);
    library.setPlaybackActive(hasSession);
    if (!playing) {
      // Don't hitch the pause frame with history JSON on the UI isolate.
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        unawaited(library.flushPendingWrites());
      });
    }
  }

  Future<void> _engineSeek(Duration position) async {
    if (AppCapabilities.usesVideoPlayerBackend) {
      await _vp?.seek(position);
    } else {
      await _player?.seek(position);
    }
  }

  Future<void> _engineStop() async {
    if (AppCapabilities.usesVideoPlayerBackend) {
      await _vp?.stop();
    } else {
      await _player?.stop();
    }
  }

  double get _engineRate => AppCapabilities.usesVideoPlayerBackend
      ? (_vp?.rate ?? 1.0)
      : (_player?.state.rate ?? 1.0);

  Future<void> _engineSetRate(double rate) async {
    if (AppCapabilities.usesVideoPlayerBackend) {
      await _vp?.setRate(rate);
    } else {
      await _player?.setRate(rate);
    }
  }

  /// Drop >1x back to wall-clock when sitting on the live edge.
  ///
  /// Faster-than-realtime there only drains the last HLS/TS segment and then
  /// buffers waiting for the next one ("end of segment"). DVR catch-up behind
  /// live is left alone so 2x can still close the gap.
  ///
  /// Pass [force] when joining live from timeshift (before [_dvrStart] clears).
  Future<void> _snapRateToRealtimeIfNeeded({
    required String reason,
    bool force = false,
  }) async {
    if (!shouldSnapPlaybackRateToRealtime(
      atLiveEdge: force || isAtLiveEdge,
      rate: _engineRate,
    )) {
      return;
    }
    final from = _engineRate;
    JavpLog.i(
      'playback',
      'snap rate ${from.toStringAsFixed(2)}→1.0 at live edge ($reason)',
    );
    try {
      await _engineSetRate(1.0);
    } catch (e) {
      JavpLog.w('playback', 'snap rate failed', error: e);
    }
  }

  /// Tear down the current decoder/buffer before attaching different media.
  ///
  /// Keeps [_item] so the session (and mini player) stay visible; clears the
  /// playhead and stops audio/video so the previous stream cannot leak.
  Future<void> _clearEngineBeforeLoad({bool notify = true}) async {
    _endMediaServerLiveSession(stopped: true);
    _error = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _lastSavedSecond = -1;
    if (notify) _notifySession();
    _resetVideoOutputPin();
    try {
      await _engineStop();
    } catch (_) {}
    if (AppCapabilities.usesVideoPlayerBackend) {
      // video_player keeps the last frame until dispose — drop the controller.
      final vp = _vp;
      if (vp != null) {
        await _cancelEngineSubscriptions();
        try {
          await vp.dispose();
        } catch (_) {}
        _vp = null;
        _vpPlayUrl = null;
        _engineRevision++;
      }
    }
  }

  Future<void> _awaitEngineSetup() async {
    _ensureEngine();
    await _engineSetup;
    // Reused engines skip `_finishEngineSetup`; sync gain before every load.
    await _applyEngineVolume();
  }

  Future<void> _openMedia(Media media, {bool play = true}) async {
    await _awaitEngineSetup();
    if (kIsWeb && WebAppLimitation.isInsecureHttpUrl(media.uri)) {
      throw Exception(
        '${WebAppLimitation.httpStreamTitle}. ${WebAppLimitation.httpStreamBody}',
      );
    }
    if (AppCapabilities.usesVideoPlayerBackend) {
      final vp = _vp!;
      final uri = media.uri;
      _vpPlayUrl = uri;
      _activePlayUrl = uri;
      final headers = media.httpHeaders;
      await vp.open(
        uri,
        httpHeaders: (headers == null || headers.isEmpty) ? null : headers,
        play: play,
      );
      // video_player has no Media.start — seek after open when requested.
      final start = media.start;
      if (start != null && start > Duration.zero) {
        try {
          await vp.seek(start);
          _position = start;
        } catch (_) {}
      }
      return;
    }
    await _configureStreamTransport(media.uri, httpHeaders: media.httpHeaders);
    _activePlayUrl = media.uri;
    await _engine.open(media, play: play);
    // Muxed HLS master: Auto stays on vid=auto. A session lock is applied
    // once lavf publishes the programs (do not block open on that wait).
    if (_hlsOpenMasterForAbr && _hlsVariants.length > 1 && _player != null) {
      if (_hlsQualityAuto) {
        try {
          await _player!.setVideoTrack(VideoTrack.auto());
        } catch (_) {}
      } else if (_hlsLockedVariantUrl != null) {
        final locked = _hlsLockedVariantUrl;
        unawaited(_applyHlsQualityInPlace(auto: false, variantUrl: locked));
      }
    }
  }

  /// Apply catalog `User-Agent` when present; otherwise default to `JAVP`.
  Future<void> _configureStreamTransport(
    String url, {
    Map<String, String>? httpHeaders,
  }) async {
    final platform = _player?.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
        'user-agent',
        userAgentFromHttpHeaders(httpHeaders) ?? 'JAVP',
      );
    } catch (e) {
      debugPrint('Stream transport config failed: $e');
    }
  }

  /// Video plane for the active backend (media_kit [Video] or [VideoPlayerEngine]).
  Widget buildVideoSurface({
    BoxFit fit = BoxFit.contain,
    Widget Function(BuildContext context)? controls,
  }) {
    if (AppCapabilities.usesVideoPlayerBackend) {
      _ensureEngine();
      final view =
          _vp?.buildView(fit: fit) ?? const ColoredBox(color: Colors.black);
      if (controls == null) return view;
      return Stack(
        fit: StackFit.expand,
        children: [
          view,
          Builder(builder: controls),
        ],
      );
    }
    _ensureEngine();
    return Video(
      controller: _controller!,
      fit: fit,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
      controls: controls == null
          ? NoVideoControls
          : (state) => controls(state.context),
    );
  }

  /// Bumped whenever the libmpv / video_player handle is created or released,
  /// so surfaces bound to [player]/[controller] can rebuild without watching
  /// every tick.
  int get engineRevision => _engineRevision;

  void _ensureEngine() {
    if (AppCapabilities.usesVideoPlayerBackend) {
      if (_vp != null) return;
      _engineRevision++;
      final vp = VideoPlayerEngine();
      _vp = vp;
      _wireVideoPlayerEngine(vp);
      return;
    }
    if (_player != null) return;
    _engineRevision++;
    MediaKit.ensureInitialized();
    // libass renders captions; Prefer ASS keeps file styles when the track is ASS/SSA.
    final player = Player(
      configuration: const PlayerConfiguration(libass: true, title: 'JAVP'),
    );
    _player = player;
    final software = _useSoftwareDecoder;
    _controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        // Explicit hwdec so we don't rely only on enableHardwareAcceleration
        // (Android TV emulators sometimes still pick a broken path).
        // auto-safe matches Settings copy; falls back to software on codec fail.
        enableHardwareAcceleration: !software,
        hwdec: software ? 'no' : 'auto-safe',
      ),
    );
    _engineSetup = _finishEngineSetup(player);
    _wireMediaKitEngine(player);
  }

  void _wireVideoPlayerEngine(VideoPlayerEngine vp) {
    _errorSub = vp.errorStream.listen((message) {
      if (message.isEmpty) return;
      _error = surfacePlayerError(message);
      final item = _item;
      if (item != null) {
        _maybeSuggestLowerQualityOnFailure(item);
        _maybeFallbackLiveQualityOnOpenError(item, message);
      }
      _notifySession();
    });
    _playingSub = vp.playingStream.listen(_onEnginePlayingChanged);
    _bufferingSub = vp.bufferingStream.listen(_onEngineBufferingChanged);
    _completedSub = vp.completedStream.listen(_onCompleted);
    _positionSub = vp.positionStream.listen((position) {
      _onPositionTick(position, vp.duration);
    });
    _durationSub = vp.durationStream.listen(_onEngineDuration);
  }

  void _onEngineDuration(Duration d) {
    _duration = d;
    _noteLongerVodRuntime(d);
    if (_pendingNativeHlsLiveJoin &&
        _dvrStart == null &&
        _item?.isLive == true &&
        liveEdgeSeekTarget(d) != null) {
      if (hlsNativeDvrAtLiveEdge(position: _position, duration: d)) {
        _pendingNativeHlsLiveJoin = false;
      } else {
        _pendingNativeHlsLiveJoin = false;
        unawaited(_seekNearLiveEdge(openEpoch: _openEpoch));
      }
    }
    _notifySession();
  }

  void _wireMediaKitEngine(Player player) {
    _errorSub = player.stream.error.listen((message) {
      if (!PlaybackProvider.shouldSurfacePlayerError(
        message,
        playing: player.state.playing,
        awaitingInitialPlayback: _awaitingInitialPlayback,
      )) {
        if (message.trim().isNotEmpty) {
          _noteNonsurfacedPlayerError(message);
        }
        return;
      }
      if (PlaybackProvider.isCodecOpenFailure(message) &&
          !_useSoftwareDecoder &&
          !_codecFallbackInFlight) {
        debugPrint('Hardware decoder failed; retrying with software: $message');
        unawaited(_fallbackToSoftwareDecoder());
        return;
      }
      _error = surfacePlayerError(message);
      final item = _item;
      if (item != null) {
        _maybeSuggestLowerQualityOnFailure(item);
        _maybeFallbackLiveQualityOnOpenError(item, message);
      }
      _notifySession();
    });
    _playingSub = player.stream.playing.listen(_onEnginePlayingChanged);
    _bufferingSub = player.stream.buffering.listen(_onEngineBufferingChanged);
    _tracksSub = player.stream.tracks.listen((_) {
      unawaited(_maybeApplyLanguagePreferences());
      _notifySession();
    });
    _trackSub = player.stream.track.listen((_) {
      unawaited(_applyCaptionRenderingMode(_captionStyle));
      _notifySession();
    });
    _widthSub = player.stream.width.listen((_) {
      _syncPipAspectRatio();
      unawaited(_maybePinVideoOutput());
      // Audio-only chrome depends on demuxer width/height settling.
      _notifySession();
    });
    _heightSub = player.stream.height.listen((_) {
      _syncPipAspectRatio();
      unawaited(_maybePinVideoOutput());
      _notifySession();
    });
    _completedSub = player.stream.completed.listen(_onCompleted);
    _positionSub = player.stream.position.listen((position) {
      _onPositionTick(position, player.state.duration);
    });
    _durationSub = player.stream.duration.listen(_onEngineDuration);
  }

  Future<void> _cancelEngineSubscriptions() async {
    await _errorSub?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    await _tracksSub?.cancel();
    await _trackSub?.cancel();
    await _completedSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _widthSub?.cancel();
    await _heightSub?.cancel();
    _errorSub = null;
    _playingSub = null;
    _bufferingSub = null;
    _tracksSub = null;
    _trackSub = null;
    _completedSub = null;
    _positionSub = null;
    _durationSub = null;
    _widthSub = null;
    _heightSub = null;
  }

  Future<void> _releaseEngine() async {
    final vp = _vp;
    final player = _player;
    if (vp == null && player == null) return;
    await _cancelEngineSubscriptions();
    if (vp != null) {
      try {
        await vp.stop();
      } catch (_) {}
      await vp.dispose();
      _vp = null;
      _vpPlayUrl = null;
    }
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      await player.dispose();
      _player = null;
      _controller = null;
      _engineSetup = null;
    }
    _resetVideoOutputPin();
    _engineRevision++;
  }
}
